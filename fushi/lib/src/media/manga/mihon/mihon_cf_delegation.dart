import 'package:fushi/src/media/manga/mihon/mihon_models.dart';

/// 资源类型：决定代取代理怎么「回填」一个被委托的请求。
///
/// - [page]：列表 / 详情 / 搜索等，响应体是 HTML/JSON。代取代理用 WebView2 导航到
///   该 URL、`evaluateJavascript` 取 `document.documentElement.outerHTML` 原样回填，
///   扩展侧的 Kotlin 解析（正则 chapters / div[data-flux-card]…）一字不动。
/// - [image]：章节页图片等二进制。代取代理在 WebView2 里 `fetch(url).arrayBuffer()`
///   转 base64 取回，宿主再 decode 成字节回填。Chromium 的 fetch 也是浏览器指纹，
///   能过 CF 拿图。
enum CfResource { page, image }

/// Cloudflare「浏览器代发」宿主侧的 host 名单与资源类型判定。
///
/// 背景（见 docs `MyComic_WebView2代发_实现蓝图.md`）：CF 保护的漫画源（MyComic 等）
/// 其数据请求走 sidecar 的 OkHttp（Java TLS 指纹），会被 CF 在握手层识别为非浏览器而
/// 拦（即便带正确 cf_clearance 也照样 403）。唯一能过的是 **Chromium 指纹**——即 Fushi
/// 应用自带的内置 WebView2（"站点验证"按钮已在用的那个，**不是**任何独立 Chrome 进程）。
///
/// 本文件钉死「哪些 host、什么类型的请求」该被 **委托给宿主的 WebView2 代取代理**，
/// 由 [MihonProxyPolicyServer]（按 URL 给 sidecar 下发代理指令的现成挂点）据此把对应
/// host 的出站路由到本地代取端口。其余 host 完全不受影响（指令仍是原 DIRECT/PROXY）。
///
/// 之所以集中在这里而不散在各处：CF host 名单是**会增长的运维事实**（一个源可能跨
/// 页面域 + 图片域，后续每加一个 CF 源都动这一处），判定逻辑必须是纯函数、可被单测
/// 直接断言——绝不能藏在「代理要不要指向代发」的分支里悄悄漂移（与
/// `mihonLoginTarget` 同一范式：判据一旦悄悄恒假，表现就是按钮/路由从此不出现）。
class MihonCfDelegation {
  MihonCfDelegation._();

  /// host → 资源类型 的登记表（**全小写**、去末尾点）。新增一个 CF 源就加一行。
  ///
  /// MyComic（Mihon 扩展 `eu.kanade.tachiyomi.extension.zh.mycomic`）：
  /// - `mycomic.com`：Laravel/Livewire 页面，被 CF 拦（TLS 指纹）→ [CfResource.page]。
  ///
  /// ** biccam.com（封面/章节图床）刻意不在名单内**：实测它对请求只做 Referer
  /// 防盗链（WebView2 图片页内 fetch 的 Referer 是 biccam 自身 → 403；而
  /// OkHttp 直连一直正常），并不是 CF 指纹墙。把它放进代发不仅每张图都
  /// 403，还会让列表/详情的几十个封面全部挤进 WebView2 串行队列（8s 级
  /// 单次导航），是「全源都慢」的主因。图片请求交给 OkHttp 原路即可。
  ///
  /// 先收录这一类；任何**未登记** host 一律不当 CF 源处理（走原路），宁缺毋滥——
  /// 把一个不被 CF 拦的 host 误送进代发只会平白加延迟、还可能把它也拖进 403 循环。
  static final Map<String, CfResource> _cfHosts = <String, CfResource>{
    'mycomic.com': CfResource.page,
  };

  /// host 归一：小写、去末尾 `.`。与 [MihonCookie.canonicalizeDomain] 同一口径，避免
  /// `MyComic.com` / `mycomic.com.` 这类同域异写漏判。
  static String _norm(String host) {
    final String h = host.trim().toLowerCase();
    return h.endsWith('.') ? h.substring(0, h.length - 1) : h;
  }

  /// 所有登记的 CF 代发 host（小写）。代取代理据此为每个 host 起一个独立的
  /// 本地 TLS 服务端（各挂自己那枚内置叶子证书，SNI/SAN 各不相同）。
  /// 空名单 = 代发不启用（宿主不拉 SOCKS5 relay）。
  static List<String> get cfHosts =>
      _cfHosts.keys.toList(growable: false);

  /// 该 [host] 是否应委托给 WebView2 代取；不委托返回 null（走原 DIRECT/PROXY）。
  static CfResource? resourceFor(String host) => _cfHosts[_norm(host)];

  /// 便捷判定：该 host 是否在册 CF 代发对象。
  static bool isCfHost(String host) => resourceFor(host) != null;

  /// 该 host 是否应走代发（供 [MihonProxyPolicyServer] 一行调用）：在册才指代取端口。
  static bool shouldDelegate(Uri uri) {
    final String scheme = uri.scheme.toLowerCase();
    if (scheme != 'http' && scheme != 'https') return false;
    return isCfHost(uri.host);
  }

  /// 从 [MihonSource] 的 baseUrl 判该源是否被 CF 保护（用于 UI 层「受 Cloudflare 保护」
  /// 徽标与提示，与 `manga_global_search_runner` 的按文案判型并列，不替代它）。
  static bool sourceIsCfProtected(MihonSource source) {
    final String host = source.baseUrl.trim();
    final Uri? parsed = Uri.tryParse(host);
    final String h = parsed != null && parsed.host.isNotEmpty ? parsed.host : host;
    return isCfHost(h);
  }
}
