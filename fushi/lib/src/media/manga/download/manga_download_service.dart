/// 在线漫画章节下载服务（设计稿 2026-09-12 §4，app 级、挂 `AppModel`）。
///
/// 下载是在线直读之外的离线入口（2026-09-26 起点章即在线直读，设计稿 §1 补记）：
/// 单 worker 串行取 `manga_download_jobs`
/// 里最早的 `queued` 任务，任务内 4 并发取页落到章目录，全部齐后写章 `manga.json`
/// → `done`。失败按 2s / 8s / 20s 退避重试三次，再失败留 `failed` + `last_error`；
/// 取消真中止并删半成品目录。进程重启后 `running` 行复位为 `queued` 续跑，已落地的
/// 页按磁盘现状跳过。
///
/// 完成钩子 [onChapterDownloaded]：`auto_ocr` 为真时由装配方（AppModel）解析引擎
/// 并经 `MangaOcrJobRegistry.enqueue` 起整卷 OCR。钩子抛错只记日志，不影响任务
/// 状态——下载已经成功，OCR 失败是另一件事。
///
/// **mokuro.moe 整卷**（阶段 C，设计稿 §4）：`kind = mokuro_volume` 的任务由同一个
/// worker 调既有 [MokuroMoeVolumeDownloader]（`.part` 续传 / 原子 rename / 解包 /
/// `importFromMokuroPath` 落库语义原样）。`pages_done / pages_total` **只记页**
/// （导入阶段）；CBZ 阶段的字节进度是瞬态，只存在内存 [MangaDownloadService]
/// 的传输进度里，由 [MangaDownloadService.progressOf] 统一成带单位的
/// [MangaDownloadProgress]（BUG：字节曾被塞进页列，UI 显示「第 4718782 /
/// 31302239 页」）。原内存队列 `MokuroMoeDownloadQueue` 已删除：
/// 任务落表后关目录页、重启 app 都不丢，重试仍是**同一行**复位成 `queued`
/// （BUG-1433 的「就地重试不新建行」语义）。
///
/// **合规**：本服务**不**挂 `StoreRestrictedCapability.downloads`——互联对端漫画
/// 在 iOS 是保留的在线源，改成必须下载后读，若下载被门挡住就是死路。Mihon
/// 入口继续受 `onlineMangaSource` 门控（iOS 无入口）。Kavita 按运行时问用户自配
/// 服务器能力（直读与下载 iOS 都保留，2026-10-27 用户拍板），判据收在
/// `online_manga_download_gate.dart`，[MangaDownloadService.enqueueChapter] 再判
/// 一次兜住所有入队路径（作品页 / 阅读器 / 订阅自动下载 / 下载中心）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart' show ValueNotifier;
import 'package:path/path.dart' as p;

import 'package:fushi/src/media/manga/library/manga_chapter_storage.dart';
import 'package:fushi/src/media/manga/library/online_manga_chapter_updates.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_service.dart';
import 'package:fushi/src/media/manga/library/online_manga_runtime_adapter.dart';
import 'package:fushi/src/media/manga/download/manga_download_sidecar.dart';
import 'package:fushi/src/media/manga/download/online_manga_download_gate.dart';
import 'package:fushi/src/media/manga/manga_json_writeback.dart';
import 'package:fushi/src/media/manga/mihon/manga_page_provider.dart';
import 'package:fushi/src/media/manga/online/mokuro_moe_volume_downloader.dart';
import 'package:fushi/src/platform/mobile/android_download_keep_alive.dart';
import 'package:fushi/src/platform/mobile/download_keep_alive_hub.dart';
import 'package:fushi/src/storage/app_paths.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/manga/manga_storage.dart';
import 'package:fushi_engine/media/manga/mokuro_payload.dart';
import 'package:fushi_engine/media/manga/mokuro_sidecar.dart';

/// mokuro.moe 卷任务的 `runtime` 列值。
const String kMokuroMoeDownloadRuntime = 'mokuro_moe';

/// mokuro.moe 卷任务的 `book_key` 前缀（`mokuro:<seriesName>`，设计稿 §2.2）。
const String kMokuroMoeBookKeyPrefix = 'mokuro:';

/// mokuro.moe 系列 → 任务表 `book_key`。
String mokuroMoeBookKey(String seriesName) =>
    '$kMokuroMoeBookKeyPrefix$seriesName';

/// 任务表 `book_key` → mokuro.moe 系列名；不是 mokuro 任务返回 null。
String? mokuroMoeSeriesNameOf(String bookKey) =>
    bookKey.startsWith(kMokuroMoeBookKeyPrefix)
    ? bookKey.substring(kMokuroMoeBookKeyPrefix.length)
    : null;

/// 生产用 [MokuroMoeVolumeDownloader] 的构造口（一个下载器只跑一次 run）；
/// 测试注入假下载器。
typedef MokuroMoeVolumeDownloaderFactory = MokuroMoeVolumeDownloader Function();

/// 一个任务当前的进度，带单位：页（章节取页 / 卷导入）或字节（mokuro CBZ 下载）。
///
/// 任务表的 `pages_done / pages_total` 只承载页；字节进度不落库（瞬态，进程重启
/// 后从 `.part` 续传重新计），两者经 [MangaDownloadService.progressOf] 合成本类型，
/// UI 据子类型选文案，不再把任意两个整数当页数显示。
sealed class MangaDownloadProgress {
  const MangaDownloadProgress();

  /// 0..1；总量未知时 null（不定进度）。
  double? get fraction;
}

/// 页进度（总量为 0 = 还不知道有几页）。
final class MangaDownloadPageProgress extends MangaDownloadProgress {
  const MangaDownloadPageProgress({required this.done, required this.total});

  final int done;
  final int total;

  @override
  double? get fraction => total > 0 ? (done / total).clamp(0.0, 1.0) : null;
}

/// 字节进度（[total] 为 null = 服务端没给 Content-Length）。
final class MangaDownloadByteProgress extends MangaDownloadProgress {
  const MangaDownloadByteProgress({required this.received, this.total});

  final int received;
  final int? total;

  @override
  double? get fraction {
    final int? all = total;
    return all != null && all > 0 ? (received / all).clamp(0.0, 1.0) : null;
  }
}

/// 一章下载完成后交给钩子的上下文。
class MangaDownloadedChapter {
  const MangaDownloadedChapter({
    required this.job,
    required this.bookKey,
    required this.chapterKey,
    required this.title,
    required this.chapterTitle,
    required this.chapterDirectory,
    required this.mangaJsonPath,
  });

  final MangaDownloadJobRow job;
  final String bookKey;
  final String chapterKey;
  final String title;
  final String chapterTitle;

  /// 章目录（含 `manga.json` + `images/`）。
  final Directory chapterDirectory;
  final String mangaJsonPath;
}

/// `auto_ocr` 为真的任务完成后调用；装配方负责解析引擎并起任务。
typedef MangaDownloadOcrHook =
    Future<void> Function(MangaDownloadedChapter chapter);

/// 三次自动重试之间的退避（与 mokuro 队列既有语义一致）。
const List<Duration> kMangaDownloadRetryBackoff = <Duration>[
  Duration(seconds: 2),
  Duration(seconds: 8),
  Duration(seconds: 20),
];

/// 一个任务最多尝试的次数：失败后 `attempt_count < 3` 才退避重跑，否则 `failed`。
const int kMangaDownloadMaxAttempts = 3;

/// 同时执行的章节任务数。3 是「明显比串行快」与「不像爬虫」之间的折中：
/// DB 的 claimNextQueuedMangaDownloadJob 在事务内原子领取，多 worker 不会抢同一条。
const int kMangaDownloadChapterConcurrency = 3;

/// 全局取页最小间隔；配合 [kMangaDownloadJitterMs] 的随机抖动打散节奏。
const int kMangaDownloadMinIntervalMs = 60;
const int kMangaDownloadJitterMs = 90;

/// 分隔身份串的 NUL（写成转义而不是裸字节：裸 NUL 会让 git 把源码判成 binary）。
final String _identitySeparator = String.fromCharCode(0);

/// 任务 id：`sha256(kind NUL bookKey NUL chapterKey)[:32]`。
String mangaDownloadJobId({
  required String kind,
  required String bookKey,
  required String chapterKey,
}) {
  final String identity = <String>[
    kind,
    bookKey,
    chapterKey,
  ].join(_identitySeparator);
  return sha256.convert(utf8.encode(identity)).toString().substring(0, 32);
}

/// 中止信号。用户取消（[cancelled]）与服务停止（[stopped]）必须分开：前者把行改成
/// `cancelled` 并删半成品，后者只是进程要退出，行保持 `running` 留给下次启动续跑。
class _CancelToken {
  bool cancelled = false;
  bool stopped = false;
  /// 取消时**保留**已落地的章目录（不删）；用于「暂停」——之后由 resume / retry
  /// 把行复位成 queued 原地续跑。与 [cancelled]（真放弃并删半成品）区分。
  bool cancelKeepFiles = false;
}

class _ActiveJob {
  _ActiveJob(this.jobId);

  final String jobId;
  final _CancelToken token = _CancelToken();
  final Completer<void> done = Completer<void>();

  /// 中止当前执行体的钩子（mokuro 卷任务挂 downloader.cancel；章节任务按页
  /// 检查 token，不需要）。取消 / 停止时与 token 一起触发。
  void Function()? abort;
}

class _PageFile {
  const _PageFile({required this.relativeUrl, required this.file});

  final String relativeUrl;
  final File file;
}

class MangaDownloadService {
  MangaDownloadService({
    required FushiDatabase database,
    required OnlineMangaLibraryService Function(OnlineMangaRuntimeKind runtime)
    serviceFor,
    MangaDownloadOcrHook? onChapterDownloaded,
    MangaDownloadSidecarFetcher? sidecarFetcher,
    MokuroMoeVolumeDownloaderFactory? mokuroDownloader,
    DateTime Function()? clock,
    Future<void> Function(Duration duration)? wait,
    DownloadKeepAlive? keepAlive,
    this.pageConcurrency = 4,
    this.chapterConcurrency = kMangaDownloadChapterConcurrency,
  }) : _database = database,
       _serviceFor = serviceFor,
       _onChapterDownloaded = onChapterDownloaded,
       _sidecarFetcher = sidecarFetcher,
       _mokuroDownloader = mokuroDownloader,
       _clock = clock ?? DateTime.now,
       _wait = wait ?? ((Duration duration) => Future<void>.delayed(duration)),
       _keepAlive = keepAlive ?? downloadKeepAliveHub.lease('manga');

  final FushiDatabase _database;
  final OnlineMangaLibraryService Function(OnlineMangaRuntimeKind runtime)
  _serviceFor;
  final MangaDownloadOcrHook? _onChapterDownloaded;
  final MangaDownloadSidecarFetcher? _sidecarFetcher;
  final MokuroMoeVolumeDownloaderFactory? _mokuroDownloader;
  final DateTime Function() _clock;
  final Future<void> Function(Duration duration) _wait;

  /// BUG-2714：worker 有任务在跑就挂下载保活（Android 前台服务），队列排空 /
  /// 服务停止时撤。与其它下载来源经 [downloadKeepAliveHub] 汇总，互不撤对方。
  final DownloadKeepAlive _keepAlive;
  bool _keepAliveActive = false;

  /// 任务内同时在飞的取页数（保持不变，避免单章请求过密）。
  final int pageConcurrency;

  /// 同时执行的章节任务数（多任务下载）。
  final int chapterConcurrency;

  /// 全局发车节流：所有章节共享，控制对源站的总请求节奏。
  final _DownloadThrottle _throttle = _DownloadThrottle(
    minInterval: const Duration(milliseconds: kMangaDownloadMinIntervalMs),
    maxJitter: const Duration(milliseconds: kMangaDownloadJitterMs),
  );

  /// mokuro.moe 卷**真正新建书行**的累计数（书架据增量失效 provider 刷新列表；
  /// 已在库被 `DuplicatePolicy.skip()` 跳过的不计）。替代旧内存队列的
  /// `importedCount`。
  final ValueNotifier<int> mokuroImportedCount = ValueNotifier<int>(0);

  bool _started = false;
  bool _disposed = false;
  bool _draining = false;
  bool _wakeRequested = false;
  /// 在飞任务按 jobId 索引：多 worker 下 cancel/pause/delete 仍精确命中。
  final Map<String, _ActiveJob> _activeJobs = <String, _ActiveJob>{};
  Completer<void>? _idle;

  /// 「暂停」态的任务（内存态，不落库）：数据库 status 仍记为 `cancelled`
  /// （既有的 5 值 CHECK 不允许 `paused`），靠这个集合在当次会话内区分「暂停」与
  /// 「真取消」。续传 / 删任务时清掉；进程重启后集合清空，暂停任务退化为
  /// `cancelled`，UI 仍给「继续」（retry 复用 cancelled → queued 复位）。
  final Set<String> _pausedJobIds = <String>{};

  /// 任务是否处于「暂停」态（仅当次会话内有效）。
  bool isPaused(String jobId) => _pausedJobIds.contains(jobId);

  /// 「仅明文落盘」模式的导出根目录映射：jobId → 用户所选根目录。仅当次进程有效，
  /// 跨进程重启后的删除由 [_knownExportRoots] 的持久化清单兜底。
  final Map<String, String> _exportRoots = <String, String>{};

  /// 用户用过的导出根目录清单，落在应用支持目录的
  /// `mihon/manga_export_roots.json`。
  ///
  /// 起因：只靠内存 Map 时，用户下完漫画、关掉 Fushi、隔天回来删任务，映射已空，
  /// `<root>/<作品名>/<章名>/` 就成了没人管的孤儿（实测 G:\漫画\坂本日常 删完
  /// 任务仍留 2.4G）。删除时按「本次映射 + 历史根目录」双重定位即可跨重启清干净。
  static const String _exportRootsFileName = 'manga_export_roots.json';
  final Set<String> _knownExportRoots = <String>{};
  bool _exportRootsLoaded = false;

  static Future<File> _exportRootsFile() async {
    final Directory supportRoot = await AppPaths.supportRootDirectory();
    return File(p.join(supportRoot.path, 'mihon', _exportRootsFileName));
  }

  Future<void> _loadKnownExportRoots() async {
    if (_exportRootsLoaded) return;
    _exportRootsLoaded = true;
    try {
      final File file = await _exportRootsFile();
      if (!await file.exists()) return;
      final Object? decoded = jsonDecode(await file.readAsString());
      if (decoded is List) {
        for (final Object? item in decoded) {
          if (item is String && item.isNotEmpty) _knownExportRoots.add(item);
        }
      }
    } on Object catch (_) {
      // 记录损坏就当没有历史根目录，不影响删任务行本身。
    }
  }

  Future<void> _rememberExportRoot(String root) async {
    await _loadKnownExportRoots();
    if (!_knownExportRoots.add(root)) return;
    try {
      final File file = await _exportRootsFile();
      await file.parent.create(recursive: true);
      final List<String> sorted = _knownExportRoots.toList()..sort();
      await file.writeAsString(jsonEncode(sorted), flush: true);
    } on Object catch (_) {
      // 落盘失败也要让下载继续：内存态仍在，本次会话内删除照样有效。
    }
  }

  /// 取任务的导出根目录（null = 非导出任务，走既有内部目录逻辑）。
  String? exportRootOf(String jobId) => _exportRoots[jobId];

  /// 当前任务的瞬态字节进度（只有 mokuro CBZ 下载阶段非空）；键 = jobId。
  ({String jobId, MangaDownloadByteProgress progress})? _transfer;

  /// 瞬态进度变化的信号；并入 [watchJobs]，消费方无需另外订阅。
  final StreamController<void> _transferChanges =
      StreamController<void>.broadcast(sync: true);

  void _setTransfer(String jobId, MangaDownloadByteProgress? progress) {
    final ({String jobId, MangaDownloadByteProgress progress})? previous =
        _transfer;
    if (progress == null) {
      if (previous == null || previous.jobId != jobId) return;
      _transfer = null;
    } else {
      _transfer = (jobId: jobId, progress: progress);
    }
    if (!_transferChanges.isClosed) _transferChanges.add(null);
  }

  /// 任务当前进度（带单位）：正在下载 CBZ 的任务给字节，其余给表里的页数。
  MangaDownloadProgress progressOf(MangaDownloadJobRow job) {
    final ({String jobId, MangaDownloadByteProgress progress})? transfer =
        _transfer;
    if (transfer != null &&
        transfer.jobId == job.jobId &&
        job.status == MangaDownloadJobStatus.running) {
      return transfer.progress;
    }
    return MangaDownloadPageProgress(
      done: job.pagesDone,
      total: job.pagesTotal,
    );
  }

  int get _now => _clock().millisecondsSinceEpoch;

  /// 上一条新排任务的 `created_at`。worker 按 `(created_at, job_id)` 领取，同一
  /// 毫秒内批量入队（「下载全部」几十章）若共用同一时刻，领取序会退化成哈希序、
  /// 章序丢失；这里保证每条新任务的 `created_at` 严格递增。
  int _lastCreatedAt = 0;

  int _nextCreatedAt() {
    final int now = _now;
    _lastCreatedAt = now > _lastCreatedAt ? now : _lastCreatedAt + 1;
    return _lastCreatedAt;
  }

  /// worker 是否空闲（测试用；生产不需要等它）。
  Future<void> get whenIdle => _idle?.future ?? Future<void>.value();

  /// 启动：把上次进程死亡留下的 `running` 复位并开始消费队列。幂等。
  Future<void> start() async {
    if (_started || _disposed) return;
    _started = true;
    await _database.resetRunningMangaDownloadJobs(updatedAt: _now);
    _kick();
  }

  /// 停止消费（正在飞的任务中止；行保持 `running`，下次 [start] 复位续跑）。
  void dispose() {
    _disposed = true;
    for (final _ActiveJob active in _activeJobs.values.toList()) {
      active.token.stopped = true;
      active.abort?.call();
    }
    _stopKeepAlive();
    unawaited(_transferChanges.close());
  }

  /// 任务表变了（或当前任务的瞬态字节进度变了）的信号流（不带行，消费方自己
  /// [listJobs]，进度经 [progressOf] 取）。
  Stream<void> watchJobs() {
    StreamSubscription<void>? table;
    StreamSubscription<void>? transfer;
    late final StreamController<void> merged;
    merged = StreamController<void>(
      onListen: () {
        table = _database.watchMangaDownloadJobs().listen(
          merged.add,
          onError: merged.addError,
        );
        transfer = _transferChanges.stream.listen(merged.add);
      },
      onCancel: () async {
        await transfer?.cancel();
        await table?.cancel();
      },
    );
    return merged.stream;
  }

  Future<List<MangaDownloadJobRow>> listJobs({
    Set<String> statuses = const <String>{},
  }) => _database.listMangaDownloadJobs(statuses: statuses);

  /// 一本书的任务，按 chapterKey 索引（作品页 / 章节选择器一次取全量）。
  Future<Map<String, MangaDownloadJobRow>> jobsForBook(String bookKey) async {
    final List<MangaDownloadJobRow> rows = await _database
        .listMangaDownloadJobs();
    return <String, MangaDownloadJobRow>{
      for (final MangaDownloadJobRow row in rows)
        if (row.bookKey == bookKey && row.kind == MangaDownloadJobKind.chapter)
          row.chapterKey: row,
    };
  }

  /// 一个 mokuro.moe 系列的卷任务，按卷名索引（目录页渲染行内状态用）。
  Future<Map<String, MangaDownloadJobRow>> mokuroJobsForSeries(
    String seriesName,
  ) async {
    final String bookKey = mokuroMoeBookKey(seriesName);
    final List<MangaDownloadJobRow> rows = await _database
        .listMangaDownloadJobs();
    return <String, MangaDownloadJobRow>{
      for (final MangaDownloadJobRow row in rows)
        if (row.bookKey == bookKey &&
            row.kind == MangaDownloadJobKind.mokuroVolume)
          row.chapterKey: row,
    };
  }

  /// 入队一卷 mokuro.moe 卷（`kind = mokuro_volume`，`bookKey = mokuro:<系列>`，
  /// `chapterKey = 卷名`）。
  ///
  /// 幂等：`queued` / `running` 原样返回；`done` / `failed` / `cancelled` 复位成
  /// `queued`**同一行**重跑（done 的卷重下会被下载器的 `DuplicatePolicy.skip()`
  /// 判成已在库，视作成功但无新行）。返回 `(row, added)`：added = 这次是否真的
  /// 新排了任务（目录页据此计数 toast）。
  Future<({MangaDownloadJobRow row, bool added})> enqueueMokuroVolume({
    required String seriesName,
    required String volumeName,
  }) async {
    final String bookKey = mokuroMoeBookKey(seriesName);
    final String jobId = mangaDownloadJobId(
      kind: MangaDownloadJobKind.mokuroVolume,
      bookKey: bookKey,
      chapterKey: volumeName,
    );
    final MangaDownloadJobRow? existing = await _database.getMangaDownloadJob(
      jobId,
    );
    if (existing != null &&
        (existing.status == MangaDownloadJobStatus.queued ||
            existing.status == MangaDownloadJobStatus.running)) {
      return (row: existing, added: false);
    }
    final int now = _now;
    await _database.upsertMangaDownloadJob(
      MangaDownloadJobsCompanion(
        jobId: Value<String>(jobId),
        kind: const Value<String>(MangaDownloadJobKind.mokuroVolume),
        bookKey: Value<String>(bookKey),
        chapterKey: Value<String>(volumeName),
        runtime: const Value<String>(kMokuroMoeDownloadRuntime),
        title: Value<String>(
          MokuroMoeVolumeDownloader.volumeTitle(seriesName, volumeName),
        ),
        chapterTitle: Value<String>(volumeName),
        status: const Value<String>(MangaDownloadJobStatus.queued),
        pagesDone: const Value<int>(0),
        pagesTotal: const Value<int>(0),
        attemptCount: const Value<int>(0),
        lastError: const Value<String?>(null),
        autoOcr: const Value<bool>(false),
        createdAt: Value<int>(existing?.createdAt ?? _nextCreatedAt()),
        updatedAt: Value<int>(now),
        completedAt: const Value<int?>(null),
      ),
    );
    _kick();
    return (row: (await _database.getMangaDownloadJob(jobId))!, added: true);
  }

  /// 批量入队若干卷（保持传入顺序）。返回真正新排的卷数。
  Future<int> enqueueMokuroVolumes({
    required String seriesName,
    required Iterable<String> volumeNames,
  }) async {
    int added = 0;
    for (final String volume in volumeNames) {
      final ({MangaDownloadJobRow row, bool added}) result =
          await enqueueMokuroVolume(seriesName: seriesName, volumeName: volume);
      if (result.added) added += 1;
    }
    return added;
  }

  /// 入队一章。
  ///
  /// 幂等：已 `done` 且目录判据为真 → 原样返回不重下；`queued` / `running` →
  /// 原样返回；`failed` / `cancelled` / 已 done 但目录被删 → 重置成 `queued`。
  /// 条目必须已在书架（`bookKey` 由条目身份推导，与作品页入库用的同一条）。
  Future<MangaDownloadJobRow> enqueueChapter({
    required OnlineMangaLibraryEntry entry,
    required OnlineMangaChapter chapter,
    required bool autoOcr,
  }) async {
    if (!onlineMangaChapterDownloadsAvailable(entry.runtime)) {
      throw StateError('Chapter downloads are unavailable on this platform');
    }
    final String bookKey = OnlineMangaLibraryService.bookKeyOf(entry);
    final String jobId = mangaDownloadJobId(
      kind: MangaDownloadJobKind.chapter,
      bookKey: bookKey,
      chapterKey: chapter.key,
    );
    final MangaDownloadJobRow? existing = await _database.getMangaDownloadJob(
      jobId,
    );
    if (existing != null) {
      switch (existing.status) {
        case MangaDownloadJobStatus.queued:
        case MangaDownloadJobStatus.running:
          return existing;
        case MangaDownloadJobStatus.done:
          final EpubBookRow? row = await _database.getEpubBook(bookKey);
          if (row != null &&
              await isChapterDownloaded(
                await MangaStorage.bookPath(row.bookKey),
                chapter.key,
              )) {
            return existing;
          }
      }
    }
    final int now = _now;
    await _database.upsertMangaDownloadJob(
      MangaDownloadJobsCompanion(
        jobId: Value<String>(jobId),
        kind: const Value<String>(MangaDownloadJobKind.chapter),
        bookKey: Value<String>(bookKey),
        chapterKey: Value<String>(chapter.key),
        runtime: Value<String>(entry.runtime.wireValue),
        title: Value<String>(entry.series.title),
        chapterTitle: Value<String>(mangaChapterDisplayName(chapter)),
        status: const Value<String>(MangaDownloadJobStatus.queued),
        pagesDone: const Value<int>(0),
        pagesTotal: const Value<int>(0),
        attemptCount: const Value<int>(0),
        lastError: const Value<String?>(null),
        autoOcr: Value<bool>(autoOcr),
        createdAt: Value<int>(existing?.createdAt ?? _nextCreatedAt()),
        updatedAt: Value<int>(now),
        completedAt: const Value<int?>(null),
      ),
    );
    _kick();
    return (await _database.getMangaDownloadJob(jobId))!;
  }

  /// 批量入队（按给定顺序）。
  Future<void> enqueueChapters({
    required OnlineMangaLibraryEntry entry,
    required Iterable<OnlineMangaChapter> chapters,
    required bool autoOcr,
  }) async {
    for (final OnlineMangaChapter chapter in chapters) {
      await enqueueChapter(entry: entry, chapter: chapter, autoOcr: autoOcr);
    }
  }

  /// 批量入队到「仅明文落盘」模式：每章按既有逻辑入队到内部目录，完成后由 [_markDone]
  /// 整体搬到 [root]/<作品名>/<章名>/ 并删内部副本。[root] 由宿主每次弹文件夹选择框取得。
  Future<void> enqueueChaptersToExport({
    required OnlineMangaLibraryEntry entry,
    required Iterable<OnlineMangaChapter> chapters,
    required String root,
    required bool autoOcr,
  }) async {
    await _rememberExportRoot(root);
    for (final OnlineMangaChapter chapter in chapters) {
      final MangaDownloadJobRow row = await enqueueChapter(
        entry: entry,
        chapter: chapter,
        autoOcr: autoOcr,
      );
      _exportRoots[row.jobId] = root;
    }
  }

  /// 取消（真放弃）：`queued` 直接改状态并删半成品目录；正在飞的任务中止并删半成品。
  /// 与 [pause] 区分：cancel 删已落地的页，pause 保留。
  Future<void> cancel(String jobId) async {
    final MangaDownloadJobRow? row = await _database.getMangaDownloadJob(jobId);
    if (row == null) return;
    final _ActiveJob? active = _activeJobs[jobId];
    if (active != null) {
      active.token.cancelled = true;
      active.abort?.call();
      return;
    }
    if (row.status == MangaDownloadJobStatus.queued ||
        row.status == MangaDownloadJobStatus.running) {
      await _database.updateMangaDownloadJobStatus(
        jobId,
        status: MangaDownloadJobStatus.cancelled,
        updatedAt: _now,
      );
      await _discardPartialDownload(row);
    }
  }

  /// 重试 `failed` / `cancelled` 的任务（同一行复位成 `queued` 续跑，BUG-1433）。
  /// 「暂停」后的任务（status 也是 `cancelled`）走这里继续。
  Future<void> retry(String jobId) async {
    final MangaDownloadJobRow? row = await _database.getMangaDownloadJob(jobId);
    if (row == null) return;
    if (row.status != MangaDownloadJobStatus.failed &&
        row.status != MangaDownloadJobStatus.cancelled) {
      return;
    }
    _pausedJobIds.remove(jobId);
    await _database.updateMangaDownloadJobStatus(
      jobId,
      status: MangaDownloadJobStatus.queued,
      updatedAt: _now,
      clearLastError: true,
      attemptCount: 0,
    );
    _kick();
  }

  /// 删任务行（正在飞的先取消）。不删已下载的章目录——那是内容，走
  /// [deleteChapterDownload]。
  Future<void> remove(String jobId) async {
    final _ActiveJob? active = _activeJobs[jobId];
    if (active != null) {
      active.token.cancelled = true;
      active.abort?.call();
      await active.done.future;
    }
    _pausedJobIds.remove(jobId);
    await _database.deleteMangaDownloadJob(jobId);
  }

  /// 暂停：queued / running → 中止在飞任务并保留已落地的页（不删章目录），status 记
  /// `cancelled`（既有 5 值 CHECK 不允许单独的 `paused`，故复用 cancelled 并在内存
  /// [_pausedJobIds] 里标出）。续传由 [resume]（= [retry] 复位 cancelled → queued）
  /// 完成，已落地的页由 [_download] 按磁盘现状跳过。
  Future<void> pause(String jobId) async {
    final MangaDownloadJobRow? row = await _database.getMangaDownloadJob(jobId);
    if (row == null) return;
    final _ActiveJob? active = _activeJobs[jobId];
    if (active != null) {
      // 正在飞：让执行体在捕获 [_Cancelled] 时保留章目录（cancelKeepFiles）。
      active.token.cancelled = true;
      active.token.cancelKeepFiles = true;
      active.abort?.call();
      _pausedJobIds.add(jobId);
      return;
    }
    if (row.status == MangaDownloadJobStatus.queued ||
        row.status == MangaDownloadJobStatus.running) {
      await _database.updateMangaDownloadJobStatus(
        jobId,
        status: MangaDownloadJobStatus.cancelled,
        updatedAt: _now,
      );
      _pausedJobIds.add(jobId);
    }
  }

  /// 继续：把「暂停」（status = `cancelled` 且记在 [_pausedJobIds]）或 `failed` 的
  /// 任务复位成 `queued` 续跑；复用 [retry] 的同一行复位语义。
  Future<void> resume(String jobId) async {
    await retry(jobId);
  }

  /// 删除任务行；[deleteFiles] 为真时连已下载内容一起删（内部章目录 + 明文导出目录）。
  ///
  /// 与 [cancel] 不同：cancel 只中止在飞任务并删半成品；本方法面向「任务列表里删掉
  /// 这一条并清掉它落地的文件」。
  Future<void> deleteJob(String jobId, {required bool deleteFiles}) async {
    final MangaDownloadJobRow? row = await _database.getMangaDownloadJob(jobId);
    if (row == null) return;
    final _ActiveJob? active = _activeJobs[jobId];
    if (active != null) {
      active.token.cancelled = true;
      active.abort?.call();
      await active.done.future;
    }
    if (deleteFiles) {
      await _deleteChapterContent(row);
    }
    _pausedJobIds.remove(jobId);
    await _database.deleteMangaDownloadJob(jobId);
  }

  /// 删除一章的已下载内容：内部章目录（manga.json + images）。「仅明文落盘」模式下
  /// 的明文导出目录删除由 [_deleteCleanExportIfAny] 补充（见需求 A 落盘改造）。
  Future<void> _deleteChapterContent(MangaDownloadJobRow job) async {
    if (job.kind != MangaDownloadJobKind.chapter) return;
    try {
      final EpubBookRow? row = await _database.getEpubBook(job.bookKey);
      if (row != null) {
        await deleteChapterDownload(
          await MangaStorage.bookPath(row.bookKey),
          job.chapterKey,
        );
      }
      // 「仅明文落盘」模式下，导出目录独立于内部存储，也要清掉。
      await _deleteCleanExportIfAny(job);
    } on Object catch (error, stack) {
      ErrorLogService.instance.log(
        'MangaDownloadService.deleteContent ${job.jobId}',
        error,
        stack,
      );
    }
  }

  /// 删除「仅明文落盘」模式下可能存在的明文导出目录。
  ///
  /// 先用当次进程的精确映射 [_exportRoots]，再拿持久化的历史根目录清单兜底：
  /// 关掉 Fushi 隔天回来删任务时映射已空，只有兜底才能把外部导出目录一起清掉。
  /// 无根目录记录时静默跳过（与内部章目录删除互不影响）。
  Future<void> _deleteCleanExportIfAny(MangaDownloadJobRow job) async {
    if (job.kind != MangaDownloadJobKind.chapter) return;
    final String? exactRoot = _exportRoots.remove(job.jobId);
    await _loadKnownExportRoots();
    final Set<String> roots = <String>{
      if (exactRoot != null) exactRoot,
      ..._knownExportRoots,
    };
    if (roots.isEmpty) return;
    final String series = _safeName(job.title);
    final String chapter = _safeName(job.chapterTitle);
    for (final String root in roots) {
      final Directory abs = Directory(p.join(root, series, chapter));
      try {
        if (!await abs.exists()) continue;
        await abs.delete(recursive: true);
        // 删光一部作品的全部章节后，<root>/<作品名>/ 会变成永远没人管的空壳。
        // 每删一章都试一次清父目录，只有真空时才删，批量删除会在最后一章自动收掉。
        await _pruneEmptyExportParent(abs.parent);
      } on Object catch (error, stack) {
        ErrorLogService.instance.log(
          'MangaDownloadService.deleteExport ${job.jobId}',
          error,
          stack,
        );
      }
    }
  }

  /// 只清「作品名」这一层的空目录，绝不往上递归到用户选的导出根目录；
  /// 且必须确认目录里一个条目都没有才删，用户自己放进去的文件一律不动。
  /// 清理属于收尾动作，目录被占用 / 权限不足时留空壳即可，不影响删除任务本身。
  static Future<void> _pruneEmptyExportParent(Directory seriesDir) async {
    try {
      if (!await seriesDir.exists()) return;
      if (await seriesDir.list().isEmpty) {
        await seriesDir.delete(recursive: false);
      }
    } on Object catch (_) {
      // 刻意吞掉：父目录清不掉不该让「删除章节」报错。
    }
  }

  /// 把刚下完的内部章目录整体搬到明文导出目录：`<root>/<作品名>/<章名>/<page-NNN.ext>`。
  /// 只搬图片，不要 manga.json；搬完删内部章目录（Fushi 不留 hash 副本）。跨盘 rename
  /// 会失败，自动退化为「复制 + 删除源」。
  Future<void> _moveChapterToExport(
    MangaDownloadJobRow job,
    Directory chapterDir,
  ) async {
    final String? root = _exportRoots[job.jobId];
    if (root == null) return;
    final Directory target = Directory(
      p.join(root, _safeName(job.title), _safeName(job.chapterTitle)),
    );
    try {
      await target.create(recursive: true);
      final Directory images = mangaChapterImagesDirectory(chapterDir);
      if (await images.exists()) {
        await for (final FileSystemEntity entity in images.list()) {
          if (entity is File && !entity.path.endsWith('.tmp')) {
            final File dest = File(p.join(target.path, p.basename(entity.path)));
            if (await dest.exists()) await dest.delete();
            await _moveFile(entity, dest);
          }
        }
      }
      // 删内部章目录（manga.json + 已搬空的 images + 空壳）。
      if (await chapterDir.exists()) {
        await chapterDir.delete(recursive: true);
      }
    } on Object catch (error, stack) {
      ErrorLogService.instance.log(
        'MangaDownloadService.exportMove ${job.jobId}',
        error,
        stack,
      );
    }
  }

  /// 移动文件；跨文件系统（跨盘）rename 抛 [FileSystemException]，退化成复制 + 删源。
  static Future<void> _moveFile(File src, File dest) async {
    try {
      await src.rename(dest.path);
    } on FileSystemException {
      await src.copy(dest.path);
      await src.delete();
    }
  }

  /// 单个路径段的最大字符数。Windows 全路径上限 260，`<root>\<作品名>\<章名>\<页名>`
  /// 四段叠加、加上用户选的根目录本身很深时很容易超限；各平台文件名上限也普遍在
  /// 255 字节。按 rune 截到 60 留足余量（rune 而非 code unit，避免切断 emoji/生僻字）。
  static const int _maxSegmentRunes = 60;

  /// Windows 保留设备名：`NUL` / `CON` / `COM1` 之类无法作为文件名创建，
  /// 且不区分大小写（`nul.txt` 同样非法）。
  static const Set<String> _windowsReserved = <String>{
    'con', 'prn', 'aux', 'nul',
    'com1', 'com2', 'com3', 'com4', 'com5', 'com6', 'com7', 'com8', 'com9',
    'lpt1', 'lpt2', 'lpt3', 'lpt4', 'lpt5', 'lpt6', 'lpt7', 'lpt8', 'lpt9',
  };

  /// Windows / 各平台都安全的文件夹名：
  /// ① 替换非法字符；② 去掉控制字符；③ 折叠空白并去首尾空白；④ 剥掉结尾的
  /// `.` 与空格（Windows 会静默丢弃它们，导致实际目录名与预期不一致——之后
  /// 删除/查找按预期名去找必然落空，留下永远删不掉的孤儿目录）；⑤ 截断过长名；
  /// ⑥ 保留设备名加前缀；⑦ 空名回退 `untitled`。
  static String _safeName(String name) {
    String cleaned = name
        .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')
        .replaceAll(RegExp(r'[\x00-\x1F\x7F]'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    String stripTrailingDots(String value) {
      while (value.isNotEmpty &&
          (value.endsWith('.') || value.endsWith(' '))) {
        value = value.substring(0, value.length - 1);
      }
      return value;
    }

    cleaned = stripTrailingDots(cleaned);
    if (cleaned.runes.length > _maxSegmentRunes) {
      cleaned = stripTrailingDots(
        String.fromCharCodes(cleaned.runes.take(_maxSegmentRunes)),
      );
    }
    if (cleaned.isEmpty) return 'untitled';
    if (_windowsReserved.contains(cleaned.toLowerCase())) {
      return '_$cleaned';
    }
    return cleaned;
  }

  /// 删所有已结束（done / failed / cancelled）的任务行（下载中心「清除已完成」）。
  Future<void> clearFinished() async {
    final List<MangaDownloadJobRow> rows = await _database
        .listMangaDownloadJobs(
          statuses: const <String>{
            MangaDownloadJobStatus.done,
            MangaDownloadJobStatus.failed,
            MangaDownloadJobStatus.cancelled,
          },
        );
    for (final MangaDownloadJobRow row in rows) {
      await _database.deleteMangaDownloadJob(row.jobId);
    }
  }

  // ── worker ─────────────────────────────────────────────────────────

  void _kick() {
    if (!_started || _disposed) return;
    if (_draining) {
      _wakeRequested = true;
      return;
    }
    _draining = true;
    _idle = Completer<void>();
    unawaited(_drain());
  }

  Future<void> _drain() async {
    try {
      final int lanes = chapterConcurrency < 1 ? 1 : chapterConcurrency;
      await Future.wait<void>(<Future<void>>[
        for (int i = 0; i < lanes; i++) _workerLoop(),
      ]);
    } finally {
      _draining = false;
      final Completer<void>? idle = _idle;
      _idle = null;
      idle?.complete();
      if (_wakeRequested && !_disposed) {
        // 马上还有下一轮：不撤保活——撤了之后 app 若已在后台，Android 不允许
        // 再拉起前台服务，后续任务就失去保护。
        _wakeRequested = false;
        _kick();
      } else {
        _stopKeepAlive();
      }
    }
  }

  /// 一条下载通道：不断从队列原子领取任务并执行，直到队列空或已 dispose。
  /// 多条通道并行 = 多章节同时下载；每条通道内部仍由 _run 按页并发取图。
  Future<void> _workerLoop() async {
    while (!_disposed) {
      final MangaDownloadJobRow? next = await _database
          .claimNextQueuedMangaDownloadJob(updatedAt: _now);
      if (next == null) return;
      final _ActiveJob active = _ActiveJob(next.jobId);
      _activeJobs[next.jobId] = active;
      _reportKeepAlive(next);
      try {
        await _run(next, active);
      } on Object catch (error, stack) {
        // _run 自己把失败落库；能到这里的是落库本身失败（库已关等）。
        ErrorLogService.instance.log(
          'MangaDownloadService.run ${next.jobId}',
          error,
          stack,
        );
      } finally {
        _activeJobs.remove(next.jobId);
        active.done.complete();
      }
    }
  }

  /// 当前任务的保活通知：标题是作品名，正文是章 / 卷名（有页数时带百分比）。
  /// 节流 / 去重在 [DownloadKeepAlive] 实现里做，这里每次进度变化都如实报。
  void _reportKeepAlive(
    MangaDownloadJobRow job, {
    int done = 0,
    int total = 0,
  }) {
    if (_disposed) return;
    final int? percent = total > 0
        ? (done.clamp(0, total) * 100 ~/ total)
        : null;
    _keepAliveActive = true;
    unawaited(
      _keepAlive.update(
        title: job.title,
        text: percent == null
            ? job.chapterTitle
            : '${job.chapterTitle} · $percent%',
        percent: percent,
      ),
    );
  }

  void _stopKeepAlive() {
    if (!_keepAliveActive) return;
    _keepAliveActive = false;
    unawaited(_keepAlive.stop());
  }

  Future<void> _run(MangaDownloadJobRow job, _ActiveJob active) async {
    final _CancelToken token = active.token;
    int attempt = job.attemptCount;
    while (true) {
      try {
        switch (job.kind) {
          case MangaDownloadJobKind.mokuroVolume:
            await _downloadMokuroVolume(job, active);
          default:
            await _download(job, token);
        }
        return;
      } on _Stopped {
        // 服务停止：行保持 running，下次 start() 复位成 queued 续跑。
        return;
      } on _Cancelled {
        if (token.cancelKeepFiles) {
          // 用户「暂停」：保留已落地的页（不删章目录），状态记 cancelled，之后
          // [resume]（= [retry]）把行复位成 queued 原地续跑。
          await _database.updateMangaDownloadJobStatus(
            job.jobId,
            status: MangaDownloadJobStatus.cancelled,
            updatedAt: _now,
          );
          return;
        }
        await _database.updateMangaDownloadJobStatus(
          job.jobId,
          status: MangaDownloadJobStatus.cancelled,
          updatedAt: _now,
        );
        await _discardPartialDownload(job);
        return;
      } on Object catch (error, stack) {
        ErrorLogService.instance.log(
          'MangaDownloadService.download ${job.jobId}',
          error,
          stack,
        );
        attempt += 1;
        if (attempt >= kMangaDownloadMaxAttempts || _disposed) {
          await _database.updateMangaDownloadJobStatus(
            job.jobId,
            status: MangaDownloadJobStatus.failed,
            updatedAt: _now,
            lastError: '$error',
            attemptCount: attempt,
          );
          return;
        }
        await _database.updateMangaDownloadJobStatus(
          job.jobId,
          status: MangaDownloadJobStatus.running,
          updatedAt: _now,
          lastError: '$error',
          attemptCount: attempt,
        );
        await _wait(
          kMangaDownloadRetryBackoff[(attempt - 1).clamp(
            0,
            kMangaDownloadRetryBackoff.length - 1,
          )],
        );
        if (token.stopped) return;
        if (token.cancelled) {
          if (token.cancelKeepFiles) {
            await _database.updateMangaDownloadJobStatus(
              job.jobId,
              status: MangaDownloadJobStatus.cancelled,
              updatedAt: _now,
            );
            return;
          }
          await _database.updateMangaDownloadJobStatus(
            job.jobId,
            status: MangaDownloadJobStatus.cancelled,
            updatedAt: _now,
          );
          await _discardPartialDownload(job);
          return;
        }
      }
    }
  }

  Future<void> _download(MangaDownloadJobRow job, _CancelToken token) async {
    final OnlineMangaRuntimeKind? runtime = OnlineMangaRuntimeKind.fromWire(
      job.runtime,
    );
    if (runtime == null) {
      throw StateError('Unknown manga runtime: ${job.runtime}');
    }
    final OnlineMangaLibraryService service = _serviceFor(runtime);
    EpubBookRow? row = await _database.getEpubBook(job.bookKey);
    if (row == null) {
      throw StateError('The manga is no longer in the library: ${job.bookKey}');
    }
    final OnlineMangaLibraryEntry? entry = OnlineMangaLibraryEntry.tryParse(
      row.sourceMetadata,
    );
    if (entry == null) {
      throw StateError('The library row has no online descriptor');
    }
    final int chapterIndex = entry.indexOfChapterKey(job.chapterKey);
    if (chapterIndex < 0) {
      throw StateError('The chapter is no longer listed: ${job.chapterKey}');
    }
    final OnlineMangaChapter chapter = entry.chapters[chapterIndex];
    row = await service.ensureBookDirectory(row);
    final String bookDir = row.extractDir;
    final Directory chapterDir = mangaChapterDirectory(bookDir, chapter.key);
    final File mangaJson = mangaChapterJsonFile(chapterDir);
    if (await isChapterDownloaded(bookDir, chapter.key)) {
      await _markDone(job, chapterDir, mangaJson, entry, chapter);
      return;
    }
    _throwIfCancelled(token);
    final List<OnlineMangaPageRef> pages = await service.adapter
        .resolveChapterPages(entry: entry, chapter: chapter);
    if (pages.isEmpty) {
      throw StateError('The chapter has no pages');
    }
    _throwIfCancelled(token);
    final Directory images = mangaChapterImagesDirectory(chapterDir);
    await images.create(recursive: true);
    final List<_PageFile?> files = List<_PageFile?>.filled(pages.length, null);
    int done = 0;
    // 续跑：磁盘上已完整落地的页直接认（`.tmp` 不算）。
    for (int index = 0; index < pages.length; index++) {
      final _PageFile? existing = await _existingPageFile(images, index);
      if (existing != null) {
        files[index] = existing;
        done += 1;
      }
    }
    await _database.updateMangaDownloadJobProgress(
      job.jobId,
      pagesDone: done,
      pagesTotal: pages.length,
      updatedAt: _now,
    );
    _reportKeepAlive(job, done: done, total: pages.length);
    final List<int> pending = <int>[
      for (int index = 0; index < pages.length; index++)
        if (files[index] == null) index,
    ];
    Object? firstError;
    StackTrace? firstStack;
    Future<void> worker() async {
      while (pending.isNotEmpty && firstError == null) {
        if (token.cancelled || token.stopped) return;
        final int index = pending.removeAt(0);
        try {
          files[index] = await _fetchPage(
            service.adapter,
            pages[index],
            images,
            index,
          );
          done += 1;
          await _database.updateMangaDownloadJobProgress(
            job.jobId,
            pagesDone: done,
            pagesTotal: pages.length,
            updatedAt: _now,
          );
          _reportKeepAlive(job, done: done, total: pages.length);
        } on Object catch (error, stack) {
          firstError ??= error;
          firstStack ??= stack;
        }
      }
    }

    final int concurrency = pageConcurrency < 1 ? 1 : pageConcurrency;
    await Future.wait<void>(<Future<void>>[
      for (int i = 0; i < concurrency; i++) worker(),
    ]);
    _throwIfCancelled(token);
    if (firstError != null) {
      Error.throwWithStackTrace(firstError!, firstStack!);
    }
    // 全部页齐 → 用真实字节尺寸写章 manga.json。
    final List<MokuroImage> payloadImages = <MokuroImage>[];
    for (final _PageFile? file in files) {
      if (file == null) throw StateError('A page is missing after download');
      final Uint8List bytes = await file.file.readAsBytes();
      final ({int width, int height})? size = await mangaImageDimensions(bytes);
      if (size == null) {
        throw StateError('Undecodable page image: ${file.relativeUrl}');
      }
      payloadImages.add(
        MokuroImage(
          url: file.relativeUrl,
          size: MokuroSize(size.width.toDouble(), size.height.toDouble()),
          blocks: const <MokuroBlock>[],
        ),
      );
    }
    _throwIfCancelled(token);
    MokuroPayload payload = MokuroPayload(images: payloadImages);
    final List<String> sourceUrls = <String>[
      for (final OnlineMangaPageRef page in pages) page.sourceUrl ?? '',
    ];
    final MangaDownloadSidecarFetcher? sidecarFetcher =
        _sidecarFetcher ??
        (service.adapter is MangaOcrSidecarProvider
            ? (OnlineMangaLibraryEntry e, OnlineMangaChapter c) =>
                  (service.adapter as MangaOcrSidecarProvider)
                      .fetchChapterOcrSidecar(entry: e, chapter: c)
            : null);
    if (sidecarFetcher != null) {
      try {
        final String? sidecar = await sidecarFetcher(entry, chapter);
        if (sidecar != null && looksLikeMokuroSidecar(sidecar)) {
          final MokuroSidecarMergeResult merged = mergeMokuroSidecar(
            downloaded: payload,
            sidecarJson: sidecar,
            sourceUrls: sourceUrls,
          );
          if (merged.accepted) payload = merged.payload;
        }
      } on Object catch (error, stack) {
        // sidecar 是增强能力，网络或格式问题不得让图片下载失败。
        ErrorLogService.instance.log(
          'MangaDownloadService.sidecar ${job.jobId}',
          error,
          stack,
        );
      }
    }
    _throwIfCancelled(token);
    await runExclusiveOnMangaJson<void>(
      mangaJson.path,
      () => writeMangaJsonAtomically(mangaJson.path, payload),
    );
    await _markDone(job, chapterDir, mangaJson, entry, chapter);
  }

  /// mokuro.moe 卷：把 [MokuroMoeVolumeDownloader.run] 的事件流映射到任务行。
  ///
  /// 进度：CBZ 阶段的字节只进内存 [_transfer]（经 [progressOf] / [watchJobs]
  /// 给 UI），导入阶段的页才落 `pages_done / pages_total`——页列永远是页。开跑先把
  /// 页列清零：旧版本曾把字节写进页列，续跑的行不能带着它显示。取消 / 停止经 [_ActiveJob.abort] 直接掐下载器
  /// （它在下个 chunk 处抛 [MokuroMoeDownloadCancelled]，`.part` 保留续传），再
  /// 由 token 区分是用户取消还是服务停止。流没走到 done 就正常结束按取消处理
  /// （与旧队列语义一致）。
  Future<void> _downloadMokuroVolume(
    MangaDownloadJobRow job,
    _ActiveJob active,
  ) async {
    final MokuroMoeVolumeDownloaderFactory? factory = _mokuroDownloader;
    if (factory == null) {
      throw StateError('No mokuro.moe downloader is wired into this service');
    }
    final String? seriesName = mokuroMoeSeriesNameOf(job.bookKey);
    if (seriesName == null) {
      throw StateError('Not a mokuro.moe task: ${job.bookKey}');
    }
    final _CancelToken token = active.token;
    _throwIfCancelled(token);
    await _database.updateMangaDownloadJobProgress(
      job.jobId,
      pagesDone: 0,
      pagesTotal: 0,
      updatedAt: _now,
    );
    final MokuroMoeVolumeDownloader downloader = factory();
    active.abort = downloader.cancel;
    MokuroMoeVolumeDownloadEvent? last;
    try {
      await for (final MokuroMoeVolumeDownloadEvent event in downloader.run(
        db: _database,
        seriesName: seriesName,
        volumeName: job.chapterKey,
      )) {
        last = event;
        switch (_mokuroProgressOf(event)) {
          case MangaDownloadByteProgress bytes:
            _setTransfer(job.jobId, bytes);
            final int? total = bytes.total;
            if (total != null) {
              _reportKeepAlive(job, done: bytes.received, total: total);
            }
          case MangaDownloadPageProgress pages:
            _setTransfer(job.jobId, null);
            await _database.updateMangaDownloadJobProgress(
              job.jobId,
              pagesDone: pages.done,
              pagesTotal: pages.total,
              updatedAt: _now,
            );
            _reportKeepAlive(job, done: pages.done, total: pages.total);
          case null:
            // 字节阶段之后（解包 / 落库前）不再有字节可报。
            if (event.stage != MokuroMoeDownloadStage.downloadingCbz) {
              _setTransfer(job.jobId, null);
            }
        }
      }
    } on MokuroMoeDownloadCancelled {
      _throwIfCancelled(token);
      // 下载器自己中止但服务没要求（不该发生）：按取消收尾。
      throw const _Cancelled();
    } finally {
      active.abort = null;
      _setTransfer(job.jobId, null);
    }
    _throwIfCancelled(token);
    if (last == null || last.stage != MokuroMoeDownloadStage.done) {
      throw const _Cancelled();
    }
    final int now = _now;
    await _database.updateMangaDownloadJobStatus(
      job.jobId,
      status: MangaDownloadJobStatus.done,
      updatedAt: now,
      clearLastError: true,
      completedAt: now,
    );
    if (!last.skippedExisting && last.bookKey != null) {
      mokuroImportedCount.value += 1;
    }
  }

  /// 事件 → 带单位的进度：CBZ 阶段是字节（只进内存），导入阶段是页（落
  /// `pages_done / pages_total`）；本阶段没有可报的进度返回 null。
  static MangaDownloadProgress? _mokuroProgressOf(
    MokuroMoeVolumeDownloadEvent event,
  ) {
    switch (event.stage) {
      case MokuroMoeDownloadStage.downloadingCbz:
        final int? total = event.totalBytes;
        if (total == null || total <= 0) {
          return MangaDownloadByteProgress(
            received: event.receivedBytes < 0 ? 0 : event.receivedBytes,
          );
        }
        return MangaDownloadByteProgress(
          received: event.receivedBytes.clamp(0, total),
          total: total,
        );
      case MokuroMoeDownloadStage.importing:
        if (event.pagesTotal <= 0) return null;
        return MangaDownloadPageProgress(
          done: event.pagesDone.clamp(0, event.pagesTotal),
          total: event.pagesTotal,
        );
      case MokuroMoeDownloadStage.done:
      case MokuroMoeDownloadStage.downloadingMokuro:
      case MokuroMoeDownloadStage.extracting:
        return null;
    }
  }

  Future<void> _markDone(
    MangaDownloadJobRow job,
    Directory chapterDir,
    File mangaJson,
    OnlineMangaLibraryEntry entry,
    OnlineMangaChapter chapter,
  ) async {
    final int now = _now;
    await _database.updateMangaDownloadJobStatus(
      job.jobId,
      status: MangaDownloadJobStatus.done,
      updatedAt: now,
      clearLastError: true,
      completedAt: now,
    );
    // 「仅明文落盘」模式：把刚写好的内部章目录整体搬到用户所选明文根目录
    // `<root>/<作品名>/<章名>/`，并删内部副本——Fushi 自己不再留 hash 副本。
    final String? exportRoot = _exportRoots[job.jobId];
    await _moveChapterToExport(job, chapterDir);
    final MangaDownloadJobRow? current = await _database.getMangaDownloadJob(
      job.jobId,
    );
    if (current == null || !current.autoOcr) return;
    // 明文模式下内部章目录（含 manga.json）已随导出被删除：既没有 sidecar 可读，
    // 也没有目录可供 OCR 钩子使用。此处直接返回，避免每次完成都抛一次
    // `readAsString` 失败并刷错误日志（用户看到的是「已完成」却莫名有报错）。
    if (exportRoot != null) return;
    try {
      final MokuroPayload existing = parseMangaJson(
        await mangaJson.readAsString(),
      );
      if (existing.images.isNotEmpty &&
          existing.images.every(
            (MokuroImage image) => image.blocks.isNotEmpty,
          )) {
        return;
      }
    } on Object catch (error, stack) {
      ErrorLogService.instance.log(
        'MangaDownloadService.sidecarOcrCheck ${job.jobId}',
        error,
        stack,
      );
    }
    final MangaDownloadOcrHook? hook = _onChapterDownloaded;
    if (hook == null) return;
    try {
      await hook(
        MangaDownloadedChapter(
          job: current,
          bookKey: job.bookKey,
          chapterKey: chapter.key,
          title: entry.series.title,
          chapterTitle: mangaChapterDisplayName(chapter),
          chapterDirectory: chapterDir,
          mangaJsonPath: mangaJson.path,
        ),
      );
    } on Object catch (error, stack) {
      ErrorLogService.instance.log(
        'MangaDownloadService.autoOcr ${job.jobId}',
        error,
        stack,
      );
    }
  }

  Future<_PageFile> _fetchPage(
    OnlineMangaRuntimeAdapter adapter,
    OnlineMangaPageRef page,
    Directory images,
    int index,
  ) async {
    // 多任务并发时统一排队发车：同域请求之间至少隔开最小间隔 + 随机抖动，
    // 避免十几个请求同一瞬间打向源站被判为爬虫 / 触发限流封禁。
    await _throttle.beforeRequest();
    final Uint8List bytes = await adapter.fetchChapterPage(page);
    if (bytes.isEmpty) {
      throw StateError('Empty page image at index $index');
    }
    final String name = '${_pageStem(index)}${_extensionFor(bytes)}';
    final File target = File(p.join(images.path, name));
    // 先写 .tmp 再 rename：半截文件被续跑当成有效页就是一页永久坏图。
    final File staged = File('${target.path}.tmp');
    await staged.writeAsBytes(bytes, flush: true);
    await staged.rename(target.path);
    return _PageFile(
      relativeUrl: '${MangaStorage.kImagesDirName}/$name',
      file: target,
    );
  }

  static String _pageStem(int index) =>
      'page-${(index + 1).toString().padLeft(6, '0')}';

  /// 续跑时找磁盘上已落地的第 [index] 页（任意扩展名，`.tmp` 除外，空文件不算）。
  Future<_PageFile?> _existingPageFile(Directory images, int index) async {
    final String stem = _pageStem(index);
    for (final String ext in const <String>[
      '.jpg',
      '.png',
      '.webp',
      '.gif',
      '.avif',
    ]) {
      final File file = File(p.join(images.path, '$stem$ext'));
      if (await file.exists() && await file.length() > 0) {
        return _PageFile(
          relativeUrl: '${MangaStorage.kImagesDirName}/$stem$ext',
          file: file,
        );
      }
    }
    return null;
  }

  static String _extensionFor(Uint8List bytes) {
    switch (mangaImageContentType(bytes)) {
      case 'image/png':
        return '.png';
      case 'image/webp':
        return '.webp';
      case 'image/gif':
        return '.gif';
      case 'image/avif':
        // 以前落进 default 存成 `.jpg`：WebView 按扩展名给 image/jpeg、导入白名单也照旧，
        // 但内容其实是 AVIF，换扩展名就能对上真实格式。
        return '.avif';
      default:
        return '.jpg';
    }
  }

  /// 用户取消后丢掉这条任务的半成品（issue #2720）。
  ///
  /// - 章节任务：删未完成章的目录（页图 / `.tmp`）；章已完整落地（manga.json
  ///   在、判据 [isChapterDownloaded] 为真）就是用户的内容，**不删**——取消一条
  ///   排队中的重下任务不能把已下好的章顺手抹掉。
  /// - mokuro 卷：删下载器 staging（`.part` / 未导入的 `.cbz`）；已导入的卷在库
  ///   目录里，不在 staging，不受影响。失败 / 服务停止不走这里，`.part` 照留续传。
  Future<void> _discardPartialDownload(MangaDownloadJobRow job) async {
    try {
      if (job.kind == MangaDownloadJobKind.mokuroVolume) {
        final String? seriesName = mokuroMoeSeriesNameOf(job.bookKey);
        final MokuroMoeVolumeDownloaderFactory? factory = _mokuroDownloader;
        if (seriesName == null || factory == null) return;
        await factory().discardStaging(
          seriesName: seriesName,
          volumeName: job.chapterKey,
        );
        return;
      }
      if (job.kind != MangaDownloadJobKind.chapter) return;
      final EpubBookRow? row = await _database.getEpubBook(job.bookKey);
      if (row == null) return;
      final String bookDir = await MangaStorage.bookPath(row.bookKey);
      if (await isChapterDownloaded(bookDir, job.chapterKey)) return;
      await deleteChapterDownload(bookDir, job.chapterKey);
    } on Object catch (error, stack) {
      ErrorLogService.instance.log(
        'MangaDownloadService.deleteChapter ${job.jobId}',
        error,
        stack,
      );
    }
  }

  static void _throwIfCancelled(_CancelToken token) {
    if (token.stopped) throw const _Stopped();
    if (token.cancelled) throw const _Cancelled();
  }
}

/// 全局「发车闸门」：把并发取页的启动时刻排成一条带随机抖动的队，
/// 保证任意两次请求之间有间隔，又不形成固定周期（固定周期同样是机器特征）。
class _DownloadThrottle {
  _DownloadThrottle({required this.minInterval, required this.maxJitter});

  final Duration minInterval;
  final Duration maxJitter;
  final math.Random _random = math.Random();
  Future<void> _tail = Future<void>.value();
  DateTime? _lastStarted;

  Future<void> beforeRequest() async {
    final Future<void> previous = _tail;
    final Completer<void> mine = Completer<void>();
    _tail = mine.future;
    await previous;
    try {
      final int jitterMs = maxJitter.inMilliseconds > 0
          ? _random.nextInt(maxJitter.inMilliseconds)
          : 0;
      int waitMs = minInterval.inMilliseconds + jitterMs;
      final DateTime? last = _lastStarted;
      if (last != null) {
        waitMs -= DateTime.now().difference(last).inMilliseconds;
      }
      if (waitMs > 0) {
        await Future<void>.delayed(Duration(milliseconds: waitMs));
      }
      _lastStarted = DateTime.now();
    } finally {
      if (!mine.isCompleted) mine.complete();
    }
  }
}

class _Cancelled implements Exception {
  const _Cancelled();
}

class _Stopped implements Exception {
  const _Stopped();
}
