/// 多线路注入：命中特定漫画源运行时拉取的「动态域名清单」URL 时，在原始清单后追加
/// x99dh 镜像线路，使扩展的「网站可选项」自动多出几十条镜像，**无需改 APK / 重签 / 新建仓库**。
///
/// ## 背景（见 `new_manga_sources/PLAN_multiroute_mycomic.md` 第三节）
///
/// WNACG(99漫画) 在 `fetchBaseUrls()` 里 `client.get("https://stevenyomi.github.io/
/// source-domains/wnacg.txt")` 拉**逗号分隔**的域名清单。relay 命中该 URL 时，返回
/// 「原清单 + `x99dh_routes.json` 的 wnacg 镜像」。扩展解析逻辑（`.split(',')`）一字不动。
///
/// ## 为什么只做 WNACG
///
/// - **禁漫天堂(JM)**：`SERVER_LIST_URL`（`rup4a04-...bytepluses.com/newsvr-2025.txt`）
///   返回内容是**加密**的（`SERVER_LIST_SECRET` 解密后解析 `ServerListDto.server`），无法纯文本追加。
/// - **Bbato / Hentai**：keiyoushi 扩展无运行时 txt 清单（镜像写在 build.gradle.kts），本机制不适用。
///
/// 二者如需多线路，须走 APK 重打包（见任务 #93），不在本 relay 注入范围内。
///
/// ## 安全边界
///
/// 命中规则**精确匹配 host + path**，绝不误伤同 host 的其它请求；非命中请求根本不会经本路径
/// 路由到 relay（由 [MihonProxyPolicyServer] 按 URL 决定）。relay 取真实清单用**直连** HttpClient
/// （`findProxy = DIRECT`），不递归经过自身。
final class MihonRouteInjection {
  MihonRouteInjection._();

  /// 需要被 relay MITM 的 host（JVM 信任 Fushi CA，relay 用内置叶子证书终止 TLS）。
  static const List<String> injectionHosts = <String>['stevenyomi.github.io'];

  /// 命中规则：host + path 精确匹配才注入。
  static bool shouldInject(Uri uri) => _sourceKeyFor(uri) != null;

  /// 该 URL 对应的源 key（用于取对应镜像线路）；非注入目标返回 null。
  static String? _sourceKeyFor(Uri uri) {
    final String host = uri.host.toLowerCase();
    final String path = uri.path.toLowerCase();
    if (host == 'stevenyomi.github.io' && path == '/source-domains/wnacg.txt') {
      return 'wnacg';
    }
    return null;
  }

  /// x99dh 镜像线路（来自 `new_manga_sources/x99dh_routes.json` 的 `wnacg` 组，33 条）。
  /// 这些数据是运维事实，集中在此一处，新增镜像只动这里。
  static const List<String> _wnacgRoutes = <String>[
    'https://www.wnacg02.net',
    'https://www.wnacg02.com',
    'https://www.wnacg01.net',
    'https://wnacg.my',
    'https://www.wnacg.my',
    'https://wnacg888.net',
    'https://www.wnacg888.net',
    'https://wnacg888.com',
    'https://www.wnacg888.com',
    'https://wnacg666.net',
    'https://www.wnacg666.net',
    'https://wnacg666.com',
    'https://www.wnacg666.com',
    'https://99mh.nl',
    'https://www.99mh.nl',
    'https://wnacg.pw',
    'https://www.wnacg.pw',
    'https://wnacg.one',
    'https://www.wnacg.one',
    'https://wnacg.nl',
    'https://www.wnacg.nl',
    'https://wnacg.sbs',
    'https://www.wnacg.sbs',
    'https://wnacg.vip',
    'https://www.wnacg.vip',
    'https://99mh.one',
    'https://www.99mh.one',
    'https://99mh.men',
    'https://www.99mh.men',
    'https://99mh.net',
    'https://www.99mh.net',
    'https://99xmh.top',
    'https://www.99xmh.top',
  ];

  /// 注入：把 [originalBody]（逗号分隔域名）与 x99dh 镜像合并、去重，返回合并后的逗号串。
  ///
  /// [originalBody] 为空或解析异常时原样返回（绝不伪装成「取到了空页」——上游会按空清单处理，
  /// 等同现状，不更坏）。
  static String inject(Uri uri, String originalBody) {
    final String? key = _sourceKeyFor(uri);
    if (key == null) return originalBody;
    final List<String> base = originalBody
        .split(',')
        .map((String s) => s.trim())
        .where((String s) => s.isNotEmpty)
        .toList();
    final List<String> extra = switch (key) {
      'wnacg' => _wnacgRoutes,
      _ => const <String>[],
    };
    final Set<String> seen = <String>{for (final String e in base) e.toLowerCase()};
    final List<String> merged = <String>[...base];
    for (final String r in extra) {
      final String rl = r.toLowerCase();
      if (!seen.contains(rl)) {
        seen.add(rl);
        merged.add(r);
      }
    }
    return merged.join(',');
  }
}
