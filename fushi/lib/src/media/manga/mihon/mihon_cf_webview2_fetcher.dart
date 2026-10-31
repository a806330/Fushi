import 'dart:async';
import 'dart:convert';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'package:fushi/src/media/manga/cookie/manga_web_view_environment.dart';
import 'package:fushi/src/media/manga/mihon/mihon_cf_delegation.dart';

/// 从「被 CF 拦的 URL」取回内容的抽象。
///
/// 代取代理拿到 JVM 的明文请求后，把目标 URL 交给 [fetch]，拿回
/// [CfFetchResult] 原样回填给 JVM。不同实现对应不同「指纹」：
/// - [WebView2CfFetcher]：用 Fushi 自带的 [HeadlessInAppWebView]（Chromium 指纹，
///   与「站点验证」页共用 WebView2 user data folder → cf_clearance 天然可见），
///   导航到 URL 后 `evaluateJavascript` 取 `outerHTML`（或图片 fetch→base64）。
///   这是能过 CF 模式2 的唯一正路（其它 TLS 栈在 Node/Java 侧 PoC 里已被证伪）。
/// - [DartHttpCfFetcher]：纯 `package:http` + 浏览器 UA。**PoC 已证它会被 CF 拦**，
///   只作 WebView2 不可用时的**兜底**（退回现状，不更坏），绝不期待它过 CF。
///
/// 之所以是抽象而非写死：代取代理（纯 dart:io）与取数（需 Flutter 引擎/WebView2）解耦，
/// 代理协议层可脱离 WebView 单独对拍验证；取数失败/未就绪时切换实现而非让整条
/// 链路崩掉。
abstract class MihonCfFetcher {
  /// 取 [url]；[resource] 决定取 HTML 还是二进制图片。
  ///
  /// 返回 [CfFetchResult.failed] 时，代取代理应**放弃这次代发、让 JVM 走原路**
  /// （或直接回 502），绝不让一个「取不到」伪装成「取到了空页」。
  Future<CfFetchResult> fetch(Uri url, CfResource resource);

  /// 宿主 dispose 时调用；默认空实现，让代理 stop() 时无需关心具体 fetcher 类型。
  Future<void> dispose() async {}
}

/// 一次代发取数的结果。
final class CfFetchResult {
  const CfFetchResult.success({
    required this.body,
    required this.contentType,
    this.status = 200,
    this.additionalHeaders = const <String, String>{},
    this.error = '',
  });

  const CfFetchResult.failed({required this.error})
      : body = const <int>[],
        contentType = '',
        status = 0,
        additionalHeaders = const <String, String>{};

  final List<int> body;
  final String contentType;
  final int status;
  final Map<String, String> additionalHeaders;
  final String error;

  bool get ok => status != 0;

  factory CfFetchResult.image(List<int> bytes, String contentType) =>
      CfFetchResult.success(body: bytes, contentType: contentType);

  factory CfFetchResult.page(String html, String contentType) =>
      CfFetchResult.success(body: utf8.encode(html), contentType: contentType);
}

/// 用 Fushi 自带的 [HeadlessInAppWebView]（与「站点验证」页同一套 WebView2 环境）
/// 取 CF 源内容。
///
/// 复用 [MangaWebViewEnvironment]：与「站点验证」页同一 user data folder，故
/// 浏览器里已完成的 CF 验证（cf_clearance）对本 fetcher 天然可见——这正是代发
/// 能过 CF 的关键（浏览器指纹 + 有效 cookie 同源）。
///
/// **headless 语义**：`HeadlessInAppWebView` 是 6.1.5 主包内置的「脱离 widget 树」
/// 执行器（`run()` 启动 WebView2 renderer，`webViewController` 拿到控制器；不挂载
/// 到任何 Flutter 页面，也不弹窗口——Windows 上是 offscreen / 非激活的）。取数
/// 串行（同一时刻一个 renderer，避免 WebView2 0x8007139F），取完不销毁（下一次
/// fetch 直接复用），宿主 dispose 时统一 `dispose()`。
class WebView2CfFetcher extends MihonCfFetcher {
  HeadlessInAppWebView? _headless;
  InAppWebViewController? _controller;
  bool _disposed = false;

  /// 串行门：所有 fetch 排队跑，避免并发建/复用同一 renderer 撞 WebView2
  /// 0x8007139F。用「Future 接力」而不是 Completer（Completer 只能 complete 一次，
  /// 第二次 fetch 就崩）。
  Future<void> _head = Future<void>.value();

  /// 每个 fetch 之间的 settle 时间：给 CF 5 秒盾 + 首帧渲染留足。
  /// 已带 cf_clearance 的场景（用户之前过验证）实际 1s 内就够；留 3s 覆盖
  /// 首次请求。图片 fetch 是页内 fetch，无额外 settle 需求。
  static const Duration _loadSettle = Duration(seconds: 3);

  /// 拿到 [InAppWebViewController] 前的最大等待（40 × 250ms = 10s 起步，WebView2
  /// 冷启动一般 < 2s）。
  static const int _controllerPollTimes = 40;
  static const Duration _controllerPollStep = Duration(milliseconds: 250);

  @override
  Future<CfFetchResult> fetch(Uri url, CfResource resource) async {
    if (_disposed) {
      return CfFetchResult.failed(error: 'fetcher disposed');
    }
    // 串行门：把本次 fetch 挂到队尾，无论前一个 body 成败都让下一个继续。
    final Future<CfFetchResult> queued = _head.then((_) => _doFetch(url, resource));
    _head = queued.catchError((_) {}).then((_) {});
    return queued;
  }

  Future<CfFetchResult> _doFetch(Uri url, CfResource resource) async {
    final InAppWebViewController? c = await _ensureController();
    if (c == null) {
      return CfFetchResult.failed(
        error: 'WebView2 headless controller not ready (headless unavailable?)',
      );
    }
    try {
      // loadUrl 是签名 `loadUrl({required URLRequest urlRequest, ...})`。
      await c.loadUrl(urlRequest: URLRequest(url: WebUri.uri(url)));
      // 轮询等页面就绪，替代原先固定 3 秒：页面快时几乎立刻返回，
      // 慢时最多等 _loadSettle 上限。这条路径对每个代发请求都会走一次，
      // 固定等待是「所有源都慢」的主因。
      await _waitForDomReady(c, maxWait: _loadSettle);
      return resource == CfResource.image
          ? await _fetchImage(c, url)
          : await _fetchPage(c);
    } on Object catch (e, st) {
      // 取数失败一律降级：调用方退回原路（=现状）。绝不崩 app。
      debugLogMihonCf('fetch error for $url: $e\n$st');
      return CfFetchResult.failed(error: e.toString());
    }
  }

  /// 轮询 `document.readyState` 直到 `complete`，最多 [maxWait]。
  ///
  /// 之所以不用固定 delay：固定 3 秒会让**每一次**代发请求都白等 3 秒；
  /// 而页面实际就绪时间差异很大（列表页 ~1s，章节页可能 5s+）。
  Future<void> _waitForDomReady(
    InAppWebViewController c, {
    required Duration maxWait,
  }) async {
    final int steps = maxWait.inMilliseconds ~/ 250;
    for (int i = 0; i < steps; i++) {
      try {
        final Object? state =
            await c.evaluateJavascript(source: 'document.readyState');
        if ((state?.toString() ?? '') == 'complete') return;
      } on Object {
        // 导航过程中 evaluate 可能抛，继续等
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
  }

  /// 惰性建 headless；同一实例复用（不 per-fetch 重建，避免 0x8007139F）。
  Future<InAppWebViewController?> _ensureController() async {
    final InAppWebViewController? existing = _controller;
    if (existing != null && (_headless?.isRunning() ?? false)) return existing;
    if (_disposed) return null;

    // 与站点验证页同一 WebView2 环境（MangaWebViewEnvironment），cf_clearance 共享。
    final WebViewEnvironment? env = await MangaWebViewEnvironment.obtain();
    final HeadlessInAppWebView h = HeadlessInAppWebView(
      // initialSize 默认 (-1, -1) = offscreen / 无窗口。
      initialSize: Size.zero,
      webViewEnvironment: env,
      initialSettings: InAppWebViewSettings(
        javaScriptEnabled: true,
        sharedCookiesEnabled: true,
        transparentBackground: true,
      ),
      // renderer 死掉（进程崩溃等）：置空 controller，下次 fetch 时重建。
      onRenderProcessGone: (InAppWebViewController _, RenderProcessGoneDetail __) {
        _controller = null;
      },
      onWebContentProcessDidTerminate: (InAppWebViewController _) {
        _controller = null;
      },
    );
    _headless = h;
    if (!h.isRunning()) {
      try {
        await h.run();
      } on Object catch (e) {
        debugLogMihonCf('headless.run() failed: $e');
        return null;
      }
    }
    for (int i = 0; i < _controllerPollTimes; i++) {
      final InAppWebViewController? c = h.webViewController;
      if (c != null) {
        _controller = c;
        return c;
      }
      await Future<void>.delayed(_controllerPollStep);
    }
    return null;
  }

  Future<CfFetchResult> _fetchPage(InAppWebViewController c) async {
    // 章节页的图片是 Alpine `x-intersect` 懒加载：不把页面滚到底，部分 <img>
    // 不会进入已渲染状态（data-src/src 为空），扩展的 `img[x-ref]` 解析就会拿到
    // 空清单 → 阅读器显示「本章尚未下载」。这里滚到底触发一轮再取 DOM。
    try {
      await c.evaluateJavascript(source: '''
        (function(){try{
          var h = document.body ? document.body.scrollHeight : 0;
          window.scrollTo(0, h);
          return String(h);
        }catch(e){return "0";}})()
      ''');
      await Future<void>.delayed(const Duration(milliseconds: 600));
    } on Object {
      // 滚动失败不影响后续取 HTML
    }

    // 轮询等待 DOM 真正可用，而不是死等固定 settle：
    // 实测同一站点「列表页」3s 内就绪、「详情页」3s 时还是 loading，
    // 旧实现在后者上取到空串 → 回填 0 字节 → 扩展侧 NPE。
    const String stateJs = 'document.readyState';
    const String htmlJs =
        '(function(){try{'
        'return document.documentElement ? document.documentElement.outerHTML : "";'
        '}catch(e){return "";}})()';
    String html = '';
    for (int i = 0; i < 24; i++) {
      Object? state;
      try {
        state = await c.evaluateJavascript(source: stateJs);
      } on Object {
        state = null;
      }
      final String s = state?.toString() ?? '';
      if (s == 'complete' || s == 'interactive') {
        final Object? v = await c.evaluateJavascript(source: htmlJs);
        html = (v?.toString() ?? '').trim();
        if (html.isNotEmpty) break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }

    // 诊断：把最后一次页面 HTML 落盘，便于核对解析失败是「没元素」还是「属性空」。
    try {
      final File dump = File(
        '${Directory.systemTemp.path}${Platform.pathSeparator}fushi_cf_page_dump.html',
      );
      await dump.writeAsString(html);
      final int imgs = RegExp(r'<img\b').allMatches(html).length;
      final int xrefs = RegExp(r'x-ref=').allMatches(html).length;
      final int biccam = RegExp(r'biccam\.com').allMatches(html).length;
      debugLogMihonCf(
        'page html len=${html.length} imgs=$imgs xrefs=$xrefs biccam=$biccam -> ${dump.path}',
      );
    } on Object catch (e) {
      debugLogMihonCf('page html len=${html.length} (dump failed: $e)');
    }

    if (html.isEmpty) {
      // 取不到就明确失败（上层回 502 让 JVM 重试），绝不伪装成「取到了空页」。
      debugLogMihonCf('page DOM stayed empty after wait');
      return CfFetchResult.failed(error: 'page DOM empty after wait');
    }
    return CfFetchResult.page(html, 'text/html; charset=utf-8');
  }

  Future<CfFetchResult> _fetchImage(InAppWebViewController c, Uri url) async {
    // 先导航到同域（携带 cf_clearance），再在页内 fetch 图片 → arrayBuffer → base64。
    // WebView2 内部 fetch 用浏览器指纹发请求，也能过 CF。
    const String jsTpl = '''
      (async function(){
        try {
          const r = await fetch("%URL%", {credentials: 'include'});
          if (!r.ok) return JSON.stringify({ok:false,status:r.status});
          const b = await r.arrayBuffer();
          const by = new Uint8Array(b);
          let bin='';
          for (let i=0;i<by.length;i++) bin+=String.fromCharCode(by[i]);
          return JSON.stringify({ok:true,ct:r.headers.get('content-type')||'',b64:btoa(bin)});
        } catch (e) { return JSON.stringify({ok:false,err:String(e)}); }
      })()
    ''';
    final String js = jsTpl.replaceAll('%URL%', url.toString().replaceAll('"', r'\"'));
    final Object? raw = await c.evaluateJavascript(source: js);
    final String s = raw?.toString() ?? '';
    final Map<String, Object?> m;
    try {
      m = jsonDecode(s.isEmpty ? '{}' : s) as Map<String, Object?>;
    } on FormatException {
      return CfFetchResult.failed(error: 'image fetch returned non-JSON: $s');
    }
    if (m['ok'] != true) {
      return CfFetchResult.failed(
        error: 'image fetch failed: status=${m['status'] ?? m['err'] ?? 'n/a'}',
      );
    }
    final String b64 = m['b64'].toString();
    final List<int> bytes;
    try {
      bytes = base64.decode(b64);
    } on FormatException {
      return CfFetchResult.failed(error: 'image base64 decode failed');
    }
    final String ct = m['ct'].toString();
    return CfFetchResult.image(
      bytes,
      ct.isEmpty ? 'application/octet-stream' : ct,
    );
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    _controller = null;
    final HeadlessInAppWebView? h = _headless;
    _headless = null;
    if (h == null) return;
    try {
      await h.dispose();
    } on Object catch (e) {
      // renderer 已死 / 从未 run：忽略。
      debugLogMihonCf('headless.dispose: $e');
    }
  }
}

/// 纯 `package:http` 降级取数（**PoC 已证会被 CF 拦**，仅兜底，不期待过 CF）。
///
/// 保留它的意义：WebView2 平台插件缺失（widget 测试 / 非 Windows / headless
/// 不可用）时仍有明确行为，且让「代发链路本身」可脱离真浏览器被验证（HTTP
/// 协议部分）。
class DartHttpCfFetcher extends MihonCfFetcher {
  DartHttpCfFetcher(this._http);
  final dynamic _http; // package:http 的 Client；用 dynamic 避免引入对宿主 http 封装的耦合

  @override
  Future<CfFetchResult> fetch(Uri url, CfResource resource) async {
    try {
      final dynamic req = _http.get(url, headers: _headers);
      final dynamic resp = await req;
      final int status = resp.statusCode as int;
      if (status < 200 || status >= 300) {
        return CfFetchResult.failed(error: 'http $status');
      }
      final dynamic bytes = resp.bodyBytes;
      final String ct = (resp.headers?['content-type'] ?? '').toString();
      return CfFetchResult.success(
        body: bytes as List<int>,
        contentType: ct,
        status: status,
      );
    } on Object catch (e) {
      return CfFetchResult.failed(error: e.toString());
    }
  }

  static const Map<String, String> _headers = {
    'User-Agent':
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36',
    'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
    'Accept-Language': 'zh-TW,zh;q=0.9',
  };
}

/// 宿主侧取数失败诊断（与 `desktop_mihon_runtime.dart` 的 sidecar 日志同规格：
/// 只记 URL 与错误，不落请求体/cookie 值——后者含会话凭据）。
void debugLogMihonCf(String message) {
  // 与 Fushi 其余网络诊断同向：走 debugPrint 避免生产误打全量堆栈。
  debugPrint('[Fushi][mihon-cf] $message');
}
