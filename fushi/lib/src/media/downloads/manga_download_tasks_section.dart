import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi/src/media/downloads/download_source_method.dart';
import 'package:fushi/src/media/downloads/download_task_card.dart';
import 'package:fushi/src/media/downloads/download_task_entry.dart';
import 'package:fushi/src/media/manga/download/manga_download_service.dart';
import 'package:fushi/src/media/manga/library/manga_chapter_list.dart'
    show mangaChapterDownloadFailedLabel;
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/utils.dart';

/// 「下载」页任务 tab 的漫画分区：读 `manga_download_jobs`（在线章节 +
/// mokuro.moe 整卷同一张表）输出 [DownloadTaskEntry]，与 torrent / 直链 / 远端
/// 任务并列进统一列表（设计稿 2026-09-12 §4，取代原 `MokuroMoeTasksSection`）。
///
/// 只做映射，不持有任务：动作全部委托 [MangaDownloadService]（取消 / 重试 /
/// 清除），行的真相是表——`watchJobs` 一响就整体重取。独立使用时空表不占位；
/// [tasksBuilder] 把条目接进外层统一列表。
class MangaDownloadTasksSection extends ConsumerStatefulWidget {
  const MangaDownloadTasksSection({
    super.key,
    this.downloadsOverride,
    this.tasksBuilder,
  });

  /// 测试注入服务（null = 取 [AppModel.mangaDownloadService]）。
  final MangaDownloadService? downloadsOverride;

  /// Parent owns unified filtering, sorting and grouping, including empty lists.
  final DownloadTasksBuilder? tasksBuilder;

  @override
  ConsumerState<MangaDownloadTasksSection> createState() =>
      _MangaDownloadTasksSectionState();
}

class _MangaDownloadTasksSectionState
    extends ConsumerState<MangaDownloadTasksSection> {
  MangaDownloadService? _downloads;
  List<MangaDownloadJobRow> _jobs = const <MangaDownloadJobRow>[];
  StreamSubscription<void>? _watch;

  @override
  void initState() {
    super.initState();
    _downloads = widget.downloadsOverride ?? _appService();
    final MangaDownloadService? downloads = _downloads;
    if (downloads == null) return;
    _watch = downloads.watchJobs().listen(
      (_) => unawaited(_reload()),
      onError: (Object error, StackTrace stack) {
        ErrorLogService.instance.log(
          'MangaDownloadTasksSection.watch',
          error,
          stack,
        );
      },
    );
    unawaited(_reload());
  }

  @override
  void dispose() {
    unawaited(_watch?.cancel());
    _watch = null;
    super.dispose();
  }

  /// Do not initialize the database-backed service when one is injected.
  MangaDownloadService? _appService() {
    final AppModel appModel = ref.read(appProvider);
    return appModel.isDatabaseReady ? appModel.mangaDownloadService : null;
  }

  Future<void> _reload() async {
    final MangaDownloadService? downloads = _downloads;
    if (downloads == null) return;
    final List<MangaDownloadJobRow> jobs = await downloads.listJobs();
    if (!mounted) return;
    setState(() => _jobs = jobs);
  }

  @override
  Widget build(BuildContext context) {
    final MangaDownloadService? downloads = _downloads;
    final List<DownloadTaskEntry> entries = <DownloadTaskEntry>[
      if (downloads != null)
        for (final MangaDownloadJobRow job in _jobs)
          mangaDownloadTaskEntry(job, downloads),
    ];
    final DownloadTasksBuilder? builder = widget.tasksBuilder;
    if (builder != null) return builder(context, entries);
    if (entries.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        for (final DownloadTaskEntry entry in entries) entry.builder(context),
      ],
    );
  }
}

/// 一条任务行 → 统一下载中心条目。
///
/// `id = manga:<jobId>`；`collectionKey` 在线章节取 bookKey、mokuro 卷取
/// `mokuro:<系列>`（表里的 bookKey 本来就是这个形状）；动作：未结束可取消、
/// failed / cancelled 可重试（同一行复位，BUG-1433）、已结束可清除。
DownloadTaskEntry mangaDownloadTaskEntry(
  MangaDownloadJobRow job,
  MangaDownloadService downloads,
) {
  final String id = 'manga:${job.jobId}';
  final bool finished = _isFinished(job);
  final bool retryable = job.status == MangaDownloadJobStatus.failed ||
      job.status == MangaDownloadJobStatus.cancelled;
  final double? progress = job.status == MangaDownloadJobStatus.done
      ? 1
      : job.pagesTotal > 0
          ? (job.pagesDone / job.pagesTotal).clamp(0.0, 1.0)
          : null;
  final String? seriesName = mokuroMoeSeriesNameOf(job.bookKey);
  final String collectionTitle = seriesName ?? job.title;
  // 暂停态不落库（数据库 status 的 CHECK 不允许 `paused`），靠服务的 [_pausedJobIds]
  // 内存集合在当次会话内区分「暂停」与「真取消」。
  final bool paused = downloads.isPaused(job.jobId);
  final String status = _statusLabel(job, paused);
  final ({DownloadTransferMethod method, bool external}) source =
      mangaDownloadSourceOf(job.runtime);
  final DownloadTaskStatus entryStatus = switch (job.status) {
    MangaDownloadJobStatus.queued => DownloadTaskStatus.queued,
    MangaDownloadJobStatus.running => DownloadTaskStatus.active,
    MangaDownloadJobStatus.done => DownloadTaskStatus.completed,
    MangaDownloadJobStatus.failed => DownloadTaskStatus.attention,
    _ => paused ? DownloadTaskStatus.paused : DownloadTaskStatus.cancelled,
  };
  // 行尾圆形快捷钮：下载中/排队给「暂停」（保留文件）、已暂停给「继续」、失败/已取消
  // 给「重试」/「继续」。
  final DownloadTaskQuickAction? quickAction = switch (job.status) {
    MangaDownloadJobStatus.queued || MangaDownloadJobStatus.running =>
      DownloadTaskQuickAction(
        icon: FushiIcons.pause,
        tooltip: t.download_task_pause,
        onPressed: () => unawaited(downloads.pause(job.jobId)),
      ),
    MangaDownloadJobStatus.failed => DownloadTaskQuickAction(
        icon: FushiIcons.refresh,
        tooltip: t.retry,
        onPressed: () => unawaited(downloads.retry(job.jobId)),
      ),
    MangaDownloadJobStatus.cancelled => paused
        ? DownloadTaskQuickAction(
            icon: FushiIcons.play,
            tooltip: t.download_task_resume,
            onPressed: () => unawaited(downloads.resume(job.jobId)),
          )
        : DownloadTaskQuickAction(
            icon: FushiIcons.refresh,
            tooltip: t.retry,
            onPressed: () => unawaited(downloads.retry(job.jobId)),
          ),
    _ => null,
  };
  return DownloadTaskEntry(
    id: id,
    title: job.kind == MangaDownloadJobKind.mokuroVolume
        ? job.title
        : '${job.title} · ${job.chapterTitle}',
    createdAt: job.createdAt,
    kind: DownloadTaskKind.manga,
    status: entryStatus,
    progress: progress,
    collectionKey: job.bookKey,
    collectionTitle: collectionTitle,
    searchTerms: <String>[job.title, job.chapterTitle, collectionTitle],
    // 漫画下载是单跑道持久队列：早期没有暂停态，现补充 pause / resume（保留已落地
    // 页原地续跑）与 delete（删任务行 + 已下载内容）；cancel 仍是「放弃并删半成品」。
    actions: DownloadTaskActions(
      retry: retryable ? () => downloads.retry(job.jobId) : null,
      clear: finished ? () => downloads.remove(job.jobId) : null,
      cancel: finished
          ? null
          : () => downloads.cancel(job.jobId),
      pause: (job.status == MangaDownloadJobStatus.queued ||
              job.status == MangaDownloadJobStatus.running)
          ? () => downloads.pause(job.jobId)
          : null,
      resume: (job.status == MangaDownloadJobStatus.cancelled && paused)
          ? () => downloads.resume(job.jobId)
          : null,
      delete: ({required bool deleteFiles}) =>
          downloads.deleteJob(job.jobId, deleteFiles: deleteFiles),
      deletesFiles: true,
    ),
    builder: (BuildContext context) => DownloadTaskCard(
      key: ValueKey<String>(id),
      taskId: id,
      method: source.method,
      externalSource: source.external,
      title: job.kind == MangaDownloadJobKind.mokuroVolume
          ? job.title
          : job.chapterTitle,
      status: status,
      subtitle: collectionTitle,
      progress: progress,
      quickAction: quickAction,
      details: _MangaDownloadTaskRow(
        job: job,
        status: status,
        downloads: downloads,
      ),
    ),
  );
}

/// 漫画下载任务的传输方式与是否外部来源（按 `runtime` 列）：Mihon / 旧
/// Aidoku 是扩展从第三方站点抓、mokuro.moe 是该站的 HTTP 直链、互联是从自己
/// 已配对的设备 HTTP 拉取（不算外部来源）。未知值按扩展源处理并标外部。
({DownloadTransferMethod method, bool external}) mangaDownloadSourceOf(
  String runtime,
) =>
    switch (runtime) {
      kMokuroMoeDownloadRuntime => (
          method: DownloadTransferMethod.direct,
          external: true,
        ),
      'interconnect' => (
          method: DownloadTransferMethod.direct,
          external: false
        ),
      _ => (method: DownloadTransferMethod.extension, external: true),
    };

bool _isFinished(MangaDownloadJobRow job) =>
    job.status == MangaDownloadJobStatus.done ||
    job.status == MangaDownloadJobStatus.failed ||
    job.status == MangaDownloadJobStatus.cancelled;

String _statusLabel(MangaDownloadJobRow job, bool paused) {
  // 暂停态复用 cancelled 状态，靠 paused 标记区分；此处给明确的「已暂停」文案。
  if (paused) return '已暂停';
  return switch (job.status) {
      MangaDownloadJobStatus.queued => t.download_status_queued,
      MangaDownloadJobStatus.running => job.pagesTotal > 0
          ? t.manga_ocr_wizard_page_progress(
              done: job.pagesDone,
              total: job.pagesTotal,
            )
          : t.manga_chapter_download_status_downloading(
              done: '${job.pagesDone}',
              total: '${job.pagesTotal}',
            ),
      MangaDownloadJobStatus.done => t.manga_online_downloaded,
      MangaDownloadJobStatus.cancelled => t.download_status_cancelled,
      // 2026-10 体验优化：lastError 为空时原写法留下「失败: 」尾冒号；与章节列表
      // 共用同一个失败文案拼法。
      _ => mangaChapterDownloadFailedLabel(job.lastError),
    };
}

/// 卡片展开后的详情行：状态图标 + 标题 + 状态文案 + 行内动作。
class _MangaDownloadTaskRow extends StatelessWidget {
  const _MangaDownloadTaskRow({
    required this.job,
    required this.status,
    required this.downloads,
  });

  final MangaDownloadJobRow job;
  final String status;
  final MangaDownloadService downloads;

  /// 2026-10 体验优化：20 号图标 + 默认 8 内边距只有 36dp 命中区，低于触摸
  /// 最小 48dp；手机上重试 / 取消常点空。
  static const BoxConstraints _actionTarget = BoxConstraints(
    minWidth: 48,
    minHeight: 48,
  );

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final bool eink = isEinkTheme(context);
    final Widget statusIcon = switch (job.status) {
      MangaDownloadJobStatus.queued =>
        FushiIcon(Icons.schedule_outlined, size: 20, color: scheme.outline),
      MangaDownloadJobStatus.done =>
        FushiIcon(Icons.check_circle_outline, size: 20, color: scheme.primary),
      MangaDownloadJobStatus.failed =>
        FushiIcon(Icons.error_outline, size: 20, color: scheme.error),
      MangaDownloadJobStatus.cancelled =>
        FushiIcon(Icons.block_outlined, size: 20, color: scheme.outline),
      _ => eink
          ? const FushiIcon(Icons.downloading_outlined, size: 20)
          : SizedBox(
              width: 20,
              height: 20,
              child: Padding(
                padding: const EdgeInsets.all(2),
                child: FushiCircularProgressIndicator(
                  strokeWidth: 2,
                  value: job.pagesTotal > 0
                      ? (job.pagesDone / job.pagesTotal).clamp(0.0, 1.0)
                      : null,
                ),
              ),
            ),
    };
    final bool errorTone = job.status == MangaDownloadJobStatus.failed;
    final bool paused = downloads.isPaused(job.jobId);
    final bool retryable = job.status == MangaDownloadJobStatus.failed ||
        job.status == MangaDownloadJobStatus.cancelled;
    return FushiListItem(
      density: FushiListDensity.compact,
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      subtitleMaxLines: 2,
      titleMaxLines: 2,
      leading: statusIcon,
      title: Text(
        job.kind == MangaDownloadJobKind.mokuroVolume
            ? job.title
            : '${job.title} · ${job.chapterTitle}',
      ),
      subtitle: Text(
        status,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall?.copyWith(
          color: errorTone ? scheme.error : null,
        ),
      ),
      trailing: retryable
          ? FushiIconButton(
              tooltip: paused ? t.download_task_resume : t.retry,
              icon: paused ? Icons.play_arrow : Icons.refresh,
              size: 20,
              constraints: _actionTarget,
              onTap: () => unawaited(
                paused
                    ? downloads.resume(job.jobId)
                    : downloads.retry(job.jobId),
              ),
            )
          : job.status == MangaDownloadJobStatus.done
              ? null
              : FushiIconButton(
                  tooltip: t.download_task_pause,
                  icon: Icons.pause,
                  size: 20,
                  constraints: _actionTarget,
                  onTap: () => unawaited(downloads.pause(job.jobId)),
                ),
    );
  }
}
