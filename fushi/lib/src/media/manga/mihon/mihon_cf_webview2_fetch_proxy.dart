import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fushi/src/media/manga/mihon/mihon_cf_cert_manager.dart';
import 'package:fushi/src/media/manga/mihon/mihon_cf_delegation.dart';
import 'package:fushi/src/media/manga/mihon/mihon_cf_webview2_fetcher.dart';

/// Fushi 本地「CF 代发」桥接代理（纯 [dart:io]，零外部协议库，零 sidecar 改动）。
///
/// ## 链路（本地已用 Node/Java 逐字节验证，见 poc/node_bridge_relay.js + ViaConnect.java）
///
/// ```
/// MyComic(OkHttp，经 ③ 的 PROXY 指令指向 relayPort)
///   --明文 CONNECT mycomic.com:443-->  [relay] _bridge
///   [relay] 回 200 + pipe -->           [per-host TLS] _serveHost
///   [per-host] 用该 host 内置叶子证书终止 TLS（JVM 仅信任 Fushi CA），
///             解出明文 GET，交给 [fetcher]（= 宿主内置 WebView2 取真实内容）
///   [per-host] 以 HTTP 响应格式回填 200 + body --> OkHttp 照旧解析
/// ```
///
/// 关键决策（勿回退）：用**桥接模型**——relay 只回 200 并把连接 pipe 到「每 host 一个独立
/// 的 [SecureServerSocket]」（各挂自己那枚内置叶子证书，SNI/SAN 固定）。**不在同一条
/// 连接上做中途 TLS 终止**（`SecureSocket.secureServer` 的 bufferedData 时序本地无法验证，
/// 风险高）；桥接模型 Dart 侧全是标准 API（[ServerSocket] + [Socket.connect] +
/// [SecureServerSocket]），已被 PoC 100% 实证。
///
/// ## 安全边界
/// - 所有监听只绑 [InternetAddress.loopbackIPv4]；无内置证书的 host 一律 `502` 断开
///   （不代发、不泄露），行为等同现状。
/// - 只「取内容回填」，不参与 cookie/会话解析；`cf_clearance` 由 [MihonCfFetcher] 的
///   WebView2 环境（与「站点验证」共用）自带。
/// - 取数失败/超时 → `502`（JVM 走原路 / 重试），绝不把「取不到」伪装成「取到了空页」。
final class MihonCfFetchProxy {
  MihonCfFetchProxy({
    required this.certManager,
    required this.fetcher,
  });

  final MihonCfCertManager certManager;
  final MihonCfFetcher fetcher;

  /// 单次取数上限：CF 大 HTML + 渲染 + 图片都留足；超时 = 放弃这次代发。
  static const Duration kFetchTimeout = Duration(seconds: 45);

  final RegExp _connectRe = RegExp(r'^CONNECT\s+(\S+)\s+HTTP/[\d.]+');
  final RegExp _reqLineRe =
      RegExp(r'^(GET|POST|PUT|HEAD|DELETE)\s+(\S+)\s+HTTP/[\d.]+');
  // 注意：这里曾有一个 `RegExp(r'(?i)^Host:...')` 字段。Dart 的正则走 ECMAScript
  // 语法，不支持 `(?i)` 内联标志，该字段在**对象构造时**就抛
  // `FormatException: Invalid group`，导致整个 MihonCfFetchProxy 构造失败、CF 代发
  // 从未启用（且被上层 catch 静默吞掉）。该字段本来就没人用，已移除；
  // 将来若要按 Host 头匹配，请用 `RegExp(r'^Host:\s*(\S+)', caseSensitive: false)`。

  ServerSocket? _relay;
  final List<SecureServerSocket> _tlsSockets = <SecureServerSocket>[];
  final Map<String, int> _hostPort = <String, int>{};
  int _relayPort = 0;

  /// relay 端口（供 ③ 路由：CF host → `PROXY 127.0.0.1:<relayPort>`）。0 = 未启动。
  int get relayPort => _relayPort;

  bool get running => _relayPort != 0;

  /// 起 relay + 每个可代发 host 的独立 TLS 端点。无可代发 host 时仍起 relay（全 502），
  /// 让 ③ 的路由有稳定端口可指（行为=现状，不更坏）。
  Future<int> start() async {
    if (_relayPort != 0) return _relayPort;
    debugLogMihonCf(
      'start: probing ${MihonCfDelegation.cfHosts.length} CF host(s) '
      '${MihonCfDelegation.cfHosts.join(",")}',
    );
    for (final String host in MihonCfDelegation.cfHosts) {
      final List<String>? material = certManager.leafMaterialFor(host);
      if (material == null) {
        debugLogMihonCf('start: no built-in leaf material for $host (skipped)');
        continue; // 无内置证书：该 host 不代发
      }
      try {
        final SecurityContext ctx = SecurityContext()
          ..useCertificateChain(material[0])
          ..usePrivateKey(material[1]);
        final SecureServerSocket tlsSock = await SecureServerSocket.bind(
          InternetAddress.loopbackIPv4,
          0,
          ctx,
        );
        _tlsSockets.add(tlsSock);
        _hostPort[host] = tlsSock.port;
        debugLogMihonCf('start: TLS endpoint ready for $host:${tlsSock.port}');
        tlsSock.listen(
          (SecureSocket conn) => unawaited(_serveHost(conn, host)),
          onError: (Object _) {},
        );
      } on Object catch (e, st) {
        debugLogMihonCf('start: TLS endpoint for $host FAILED: $e\n$st');
      }
    }
    try {
      _relay = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    } on Object catch (e, st) {
      debugLogMihonCf('start: relay bind FAILED: $e\n$st');
      rethrow;
    }
    _relayPort = _relay!.port;
    debugLogMihonCf('start: relay listening on 127.0.0.1:$_relayPort '
        '(tls ports: $_hostPort)');
    _relay!.listen(
      (Socket sock) => unawaited(_bridge(sock)),
      onError: (Object _) {},
    );
    return _relayPort;
  }

  Future<void> stop() async {
    try {
      await _relay?.close();
    } on Object {
      // closing anyway
    }
    _relay = null;
    for (final SecureServerSocket s in _tlsSockets) {
      try {
        await s.close();
      } on Object {
        // ignore per-socket close errors
      }
    }
    _tlsSockets.clear();
    _hostPort.clear();
    _relayPort = 0;
    await fetcher.dispose();
  }

  /// relay 的一个入站连接：读 `CONNECT host` → 回 200 → pipe 到该 host 的 TLS 端点。
  ///
  /// **单一 [sock.listen] + 双标志状态机**（PoC 已实证的范式）：本连接对 [sock] 只
  /// `listen` 一次，回调里按 [forwarding]/[routed] 决定「累积解析 CONNECT」/「进 pending
  /// 等上游」/「原样转发」三态。**绝不叠加第二个 data 监听器**（Node 版踩过的坑：叠加
  /// 监听器 → 每个字节写两遍 → 上游 TLS 收翻倍数据 → `unexpected_message`）。
  Future<void> _bridge(Socket sock) async {
    final BytesBuilder connBuf = BytesBuilder(copy: false);
    final List<List<int>> pending = <List<int>>[];
    Socket? up;
    bool routed = false;
    bool forwarding = false;

    void route(String host) {
      final int? targetPort = _hostPort[host];
      if (targetPort == null) {
        // 未登记 / 无内置证书的 host：不代发，行为等同现状。
        sock.write('HTTP/1.1 502 Bad Gateway\r\n\r\n');
        unawaited(sock.close());
        return;
      }
      sock.write('HTTP/1.1 200 Connection Established\r\n\r\n');
      routed = true;
      unawaited(
        Socket.connect(InternetAddress.loopbackIPv4, targetPort).then((Socket s) {
          up = s;
          for (final List<int> p in pending) {
            s.add(p);
          }
          pending.clear();
          forwarding = true;
          s.listen(
            (List<int> d) => sock.add(d),
            onDone: () => unawaited(sock.flush()),
            onError: (Object _) => sock.destroy(),
          );
        }).catchError((Object _) {
          // 上游连不上（该 host 的 TLS 端点没起）：安全断开，JVM 走原路。
          unawaited(sock.close());
        }),
      );
    }

    sock.listen(
      (List<int> data) {
        if (forwarding) {
          up?.add(data);
          return;
        }
        if (routed) {
          // 已回 200 但上游还没连好：先攒着，连上后统一 flush。
          pending.add(data);
          return;
        }
        // 未路由：累积到能解析出 CONNECT 行。用 toBytes()（保留已累积字节），
        // 不是 takeBytes()（会排空、多分包到达时丢前面的字节）。
        connBuf.add(data);
        final String head =
            utf8.decode(connBuf.toBytes(), allowMalformed: true);
        if (!head.contains('\r\n\r\n')) return;
        final String firstLine = head.split('\r\n')[0];
        final Match? m = _connectRe.firstMatch(firstLine);
        if (m == null) {
          sock.write('HTTP/1.1 400 Bad Request\r\n\r\n');
          unawaited(sock.close());
          return;
        }
        route(m.group(1)!.split(':').first.toLowerCase());
      },
      onDone: () => unawaited(up?.close()),
      onError: (Object _) => up?.destroy(),
    );
  }

  /// per-host TLS 端点的一个连接：TLS 已终止，读明文请求 → 交 [fetcher] 取数 → 回填。
  Future<void> _serveHost(SecureSocket conn, String host) async {
    final CfResource resource =
        MihonCfDelegation.resourceFor(host) ?? CfResource.page;
    try {
      final BytesBuilder req = BytesBuilder(copy: false);
      String? method;
      String? target;
      // 读完整请求头（MyComic 页面/图片均 GET，无 body）。
      await for (final List<int> chunk in conn) {
        req.add(chunk);
        final String text = utf8.decode(req.toBytes(), allowMalformed: true);
        final Match? m = _reqLineRe.firstMatch(text);
        if (m == null) continue;
        method = m.group(1);
        target = m.group(2);
        break; // 头行读完即止
      }
      if (method == null || target == null) {
        conn.destroy();
        return;
      }
      final Uri url =
          Uri.parse('https://$host${target.startsWith('/') ? '' : '/'}$target');
      final CfFetchResult result =
          await fetcher.fetch(url, resource).timeout(kFetchTimeout);
      final int status = result.ok ? result.status : HttpStatus.badGateway;
      final List<int> body = result.ok ? result.body : const <int>[];
      conn.write(
        'HTTP/1.1 $status ${_statusText(status)}\r\n'
        'Server: fushi-cf-proxy\r\n'
        'Content-Type: ${result.contentType.isEmpty ? 'application/octet-stream' : result.contentType}\r\n'
        'X-Served-Host: $host\r\n'
        'Content-Length: ${body.length}\r\n'
        'Connection: close\r\n'
        '\r\n',
      );
      if (body.isNotEmpty) conn.add(body);
      await conn.flush();
      await conn.close();
    } on Object {
      // 取数失败 / 连接断开：安全断开（JVM 收到 502 或连接关闭 → 走原路/重试，不更坏）。
      try {
        conn.destroy();
      } on Object {
        // already gone
      }
    }
  }

  String _statusText(int code) => switch (code) {
        200 => 'OK',
        502 => 'Bad Gateway',
        504 => 'Gateway Timeout',
        _ => 'Unknown',
      };
}
