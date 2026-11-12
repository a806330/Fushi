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
      // 轮询等 DOM 可解析（interactive），而非 complete——complete 要等图片等
      // 全部子资源下完，对「取 outerHTML」毫无必要，白等数秒。
      await _waitForDomReady(c, maxWait: const Duration(seconds: 6));
      return resource == CfResource.image
          ? await _fetchImage(c, url)
          : await _fetchPage(c, url);
    } on Object catch (e, st) {
      // 取数失败一律降级：调用方退回原路（=现状）。绝不崩 app。
      debugLogMihonCf('fetch error for $url: $e\n$st');
      return CfFetchResult.failed(error: e.toString());
    }
  }

  /// 轮询 `document.readyState` 到 interactive（DOM 解析完成，可安全取
  /// outerHTML）即返回；超过 [maxWait] 放弃等待直接尝试取。
  Future<void> _waitForDomReady(
    InAppWebViewController c, {
    required Duration maxWait,
  }) async {
    final int steps = maxWait.inMilliseconds ~/ 200;
    for (int i = 0; i < steps; i++) {
      try {
        final Object? state =
            await c.evaluateJavascript(source: 'document.readyState');
        final String v = state?.toString() ?? '';
        if (v == 'interactive' || v == 'complete') return;
      } on Object {
        // 导航过程中 evaluate 可能抛，继续等
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
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

  Future<CfFetchResult> _fetchPage(InAppWebViewController c, Uri url) async {
    // 只有章节阅读页需要滚动触发 Alpine `x-intersect` 懒加载（否则 img[x-ref]
    // 的地址不填充，扩展解析出空清单）；列表/详情不滚，省 300ms。
    if (url.path.contains('/chapters/')) {
      try {
        await c.evaluateJavascript(
          source:
              'window.scrollTo(0, document.body ? document.body.scrollHeight : 0)',
        );
        await Future<void>.delayed(const Duration(milliseconds: 300));
      } on Object {
        // 滚动失败不影响取 HTML
      }
    }

    const String htmlJs =
        '(function(){try{'
        'return document.documentElement ? document.documentElement.outerHTML : "";'
        '}catch(e){return "";}})()';
    String html = '';
    // _doFetch 已等到 interactive；这里直接取，若为空（个别页 interactive 时
    // 还没挂 body）再给最多 ~3 秒轮询。
    for (int i = 0; i < 10; i++) {
      final Object? v = await c.evaluateJavascript(source: htmlJs);
      html = (v?.toString() ?? '').trim();
      if (html.isNotEmpty) break;
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }

    if (html.isEmpty) {
      // 取不到就明确失败（上层回 502 让 JVM 重试），绝不伪装成「取到了空页」。
      debugLogMihonCf('page DOM stayed empty for $url');
      return CfFetchResult.failed(error: 'page DOM empty after wait');
    }
    return CfFetchResult.page(html, 'text/html; charset=utf-8');
  }

  Future<CfFetchResult> _fetchImage(InAppWebViewController c, Uri url) async {
    // 先导航到同域（携带 cf_clearance），再在页内 fetch 图片 → arrayBuffer → base64。
    // WebView2 内部 fetch 用浏览器指纹发请求，也能过 CF。
    //
    // 重要：不能用「evaluateJavascript(async IIFE) 直接拿返回值」——WebView2 的
    // ExecuteScript **不等待 Promise**，未完成的 Promise 会被序列化成 "{}"（实测
    // 全部图片 status=n/a 的根因）。这里改成：JS 侧发起 fetch 并把结果写到
    // window.__imgResult，Dart 侧轮询取回 —— 全程同步求值，绕开 Promise 序列化。
    final String u = jsonEncode(url.toString());
    final Object? started = await c.evaluateJavascript(source: '''
      (function(){
        try {
          window.__imgResult = null;
          fetch($u, {credentials: 'include'}).then(async function(r){
            if (!r.ok) { window.__imgResult = {ok:false, status:r.status}; return; }
            const b = await r.arrayBuffer();
            const by = new Uint8Array(b);
            let bin = '';
            const CHUNK = 0x8000;
            for (let i = 0; i < by.length; i += CHUNK) {
              bin += String.fromCharCode.apply(null, by.subarray(i, i + CHUNK));
            }
            window.__imgResult = {ok:true, ct:r.headers.get('content-type')||'', b64:btoa(bin)};
          }).catch(function(e){ window.__imgResult = {ok:false, err:String(e)}; });
          return 'started';
        } catch (e) { return 'throw:' + String(e); }
      })()
    ''');
    final String startedS = started?.toString() ?? '';
    if (startedS != 'started') {
      debugLogMihonCf('image: kick-off failed for $url: $startedS');
      return CfFetchResult.failed(error: 'image kick-off failed: $startedS');
    }
    final Map<String, Object?> m;
    // 轮询结果（fetch 图片通常 1-3 秒；给足 40s，仍在 kFetchTimeout 内）。
    Object? picked;
    for (int i = 0; i < 130; i++) {
      final Object? v = await c.evaluateJavascript(
        source: r'window.__imgResult === null ? null : JSON.stringify(window.__imgResult)',
      );
      final String s = v?.toString() ?? '';
      if (s.isNotEmpty && s != 'null') {
        picked = s;
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    if (picked == null) {
      debugLogMihonCf('image: result never arrived within 39s for $url');
      return CfFetchResult.failed(error: 'image result timeout');
    }
    final Map<String, Object?> parsed;
    try {
      parsed = jsonDecode(picked.toString()) as Map<String, Object?>;
    } on FormatException {
      debugLogMihonCf('image: non-JSON result for $url');
      return CfFetchResult.failed(error: 'image result non-JSON');
    }
    m = parsed;
    if (m['ok'] != true) {
      debugLogMihonCf(
        'image: fetch failed for $url: status=${m['status'] ?? m['err'] ?? 'n/a'}',
      );
      return CfFetchResult.failed(
        error: 'image fetch failed: status=${m['status'] ?? m['err'] ?? 'n/a'}',
      );
    }
    final String b64 = m['b64'].toString();
    final List<int> bytes;
    try {
      bytes = base64.decode(b64);
    } on FormatException {
      debugLogMihonCf('image: base64 decode failed for $url (b64 len=${b64.length})');
      return CfFetchResult.failed(error: 'image base64 decode failed');
    }
    final String ct = m['ct'].toString();
    debugLogMihonCf('image: OK $url bytes=${bytes.length} ct=$ct');
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
