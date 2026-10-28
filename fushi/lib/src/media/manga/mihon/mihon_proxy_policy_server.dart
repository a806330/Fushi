import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fushi_engine/utils/net/app_proxy.dart';

import 'package:fushi/src/media/manga/mihon/mihon_cf_delegation.dart';

/// Authenticated loopback policy lookup for the JVM's per-URL ProxySelector.
/// Secrets stay in memory, never in process arguments, URLs, or logs.
class MihonProxyPolicyServer {
  MihonProxyPolicyServer._(
    this._server,
    this._token, [
    this._cfFetchProxyPort,
  ]) {
    _server.listen((HttpRequest request) => unawaited(_serve(request)));
  }

  final HttpServer _server;
  final String _token;

  /// 宿主 CF 代发 relay 的端口（见 [MihonCfFetchProxy]）。非 null 时，凡是被
  /// [MihonCfDelegation] 登记为 CF 代发对象的 host，其代理指令都指向这个 relay，
  /// 由 relay 用宿主内置 WebView2 取回内容（绕开 OkHttp 的 Java TLS 指纹被 CF 拦）。
  /// 为 null（代发未启用）时完全走原 [resolveAppProxyDirective]，行为等同现状。
  final int? _cfFetchProxyPort;

  int get port => _server.port;

  static Future<MihonProxyPolicyServer> start(
    String token, {
    int? cfFetchProxyPort,
  }) async {
    await primeAppProxy();
    final HttpServer server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    return MihonProxyPolicyServer._(server, token, cfFetchProxyPort);
  }

  Future<void> _serve(HttpRequest request) async {
    try {
      if (request.headers.value(HttpHeaders.authorizationHeader) !=
          'Bearer $_token') {
        request.response.statusCode = HttpStatus.unauthorized;
        return;
      }
      final Uri? uri = Uri.tryParse(request.uri.queryParameters['url'] ?? '');
      if (request.method != 'GET' ||
          request.uri.path != '/proxy-policy' ||
          uri == null ||
          !const <String>['http', 'https'].contains(uri.scheme) ||
          uri.host.isEmpty) {
        request.response.statusCode = HttpStatus.badRequest;
        return;
      }
      // CF 代发对象优先：把该 host 的出站指到宿主 relay（内置 WebView2 取内容），
      // 绕开 OkHttp 的 Java TLS 指纹被 CF 拦。非 CF host 或代发未启用 → 原逻辑不变。
      final int? cfPort = _cfFetchProxyPort;
      final String directive =
          (cfPort != null && MihonCfDelegation.shouldDelegate(uri))
              ? 'PROXY 127.0.0.1:$cfPort'
              : resolveAppProxyDirective(uri);
      // 代发 relay 是本机回环、无需认证；只有原逻辑的手动代理才需要凭据。
      final ({String username, String password})? credentials =
          directive == 'PROXY 127.0.0.1:$cfPort'
              ? null
              : resolveAppProxyCredentials(uri);
      request.response.headers.contentType = ContentType.json;
      request.response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
      request.response.write(
        jsonEncode(<String, Object?>{
          'directive': directive,
          if (credentials != null) 'username': credentials.username,
          if (credentials != null) 'password': credentials.password,
        }),
      );
    } on Object {
      request.response.statusCode = HttpStatus.internalServerError;
    } finally {
      await request.response.close();
    }
  }

  Future<void> close() async => _server.close(force: true);
}
