import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:fushi/src/media/manga/mihon/mihon_cf_builtin_certs.dart';
import 'package:fushi/src/media/manga/mihon/mihon_cf_delegation.dart';

/// Fushi 内置 WebView2「CF 代发」的证书 / 信任库管理（宿主侧）。
///
/// 见 [MihonCfDelegation]：CF 保护源的出站被路由到宿主本地代发 relay，relay 把连接
/// 桥到「每 host 一个内置叶子证书」的本地 TLS 端点终止；sidecar JVM 必须信任这段 CA。
///
/// 所有 PEM 由 `mihon_cf_certificates_build.py` 用 openssl 预生成并内联进
/// [MihonCfBuiltInCerts]（构建产物，勿手改），本管理器只做**文件 I/O + 一次 keytool
/// 合成**——运行时不生成任何新密钥，零 openssl 依赖。
final class MihonCfCertManager {
  MihonCfCertManager(this.dataDirectory);

  /// Fushi 数据根（与 sidecar 数据目录同层，见 `desktop_mihon_runtime.dart`）。
  final Directory dataDirectory;

  /// JVM 侧**不用** `javax.net.ssl.trustStoreCertBundle`（追加信任）——它在 Temurin 21
  /// 上实测 PKIX 仍失败（追加没生效）。生产用 [materializeMergedTrustStore] 把
  /// 「runtime 自带 cacerts + 本 CA」合成一个 PKCS12，用 `-Djavax.net.ssl.trustStore`
  /// **替换**默认信任库（144 系统根 + 1 CA，双目标实测 local+public 均通过，不破坏
  /// sidecar 访问其它漫画源）。
  static const String caPem = MihonCfBuiltInCerts.caPem;

  /// CF host 的叶子证书（host -> [certPem, keyPem]）。
  static Map<String, List<String>> get leafMap => MihonCfBuiltInCerts.leaves;

  /// 取 [host] 的叶子证书 + 私钥（PEM）。代取代理终止该 host 的 TLS 用。
  ///
  /// 未在 [leafMap] 里的 host 返回 null——调用方应**放弃代发、退回原路**。
  /// 新增 CF 源 = 在 `mihon_cf_certificates_build.py` 里加一行重跑脚本，
  /// 不是在这里写密钥。
  List<String>? leafMaterialFor(String host) {
    final List<String>? l = MihonCfBuiltInCerts.leaves[_norm(host)];
    if (l == null) return null;
    return <String>[l[0], l[1]]; // [cert, key]
  }

  /// 该 host 是否可代发（有内置叶子 + 是已知 CF host）。
  bool canDelegate(String host) =>
      MihonCfDelegation.isCfHost(host) &&
      MihonCfBuiltInCerts.leaves[_norm(host)] != null;

  /// 把「runtime 自带 cacerts + [caPem]」用 [keytool] 合成一个 PKCS12 信任库，落到
  /// 数据目录，返回其路径（供 ④ 的 JVM `-Djavax.net.ssl.trustStore` 指向它）。
  ///
  /// **失败返回 null**（keytool 缺失 / cacerts 读不出 / 合成报错）：调用方据此**降级**
  /// ——不挂代发、不给 JVM 加 trustStore 参数、JVM 照旧，行为等同现状（绝不比现状差）。
  ///
  /// 幂等：目标文件已存在就不重做（避免每次启动都跑 keytool）。
  /// [runtimeCacerts] 是 Fushi 自带 Temurin runtime 的 `lib/security/cacerts`；
  /// 合并它（而非系统 ca-bundle）才能保证与 JVM 实际信任的根证书集合一致。
  Future<File?> materializeMergedTrustStore({
    required File keytool,
    required File runtimeCacerts,
    String storePassword = 'changeit',
  }) async {
    final File dest =
        File(p.join(dataDirectory.path, 'mihon', 'cf_truststore.p12'));
    try {
      dest.parent.createSync(recursive: true);
      if (dest.existsSync()) return dest;
      if (!keytool.existsSync() || !runtimeCacerts.existsSync()) {
        return null;
      }
      // 内置 CA 的 PEM 落盘（keytool 只能读文件，不能从内存 importcert）。
      final File caFile =
          File(p.join(dataDirectory.path, 'mihon', 'cf_ca.pem'));
      if (!caFile.existsSync() || caFile.readAsStringSync() != caPem) {
        caFile.writeAsStringSync(caPem);
      }
      // 1) runtime cacerts -> dest（JDK9+ cacerts 是 PKCS12；JKS 兜底）。
      final ProcessResult step1 = await Process.run(
        keytool.path,
        <String>[
          '-importkeystore',
          '-srckeystore', runtimeCacerts.path,
          '-srcstoretype', 'PKCS12',
          '-srcstorepass', storePassword,
          '-destkeystore', dest.path,
          '-deststoretype', 'PKCS12',
          '-deststorepass', storePassword,
          '-noprompt',
        ],
      );
      if (step1.exitCode != 0) {
        // PKCS12 读不了源就试 JKS（老 runtime）。
        final ProcessResult step1jks = await Process.run(
          keytool.path,
          <String>[
            '-importkeystore',
            '-srckeystore', runtimeCacerts.path,
            '-srcstoretype', 'JKS',
            '-srcstorepass', storePassword,
            '-destkeystore', dest.path,
            '-deststoretype', 'PKCS12',
            '-deststorepass', storePassword,
            '-noprompt',
          ],
        );
        if (step1jks.exitCode != 0) {
          // 两种都读不了：合成失败 → 降级。
          if (dest.existsSync()) {
            try {
              dest.deleteSync();
            } on Object {
              // 删不掉不影响降级（调用方按 null 处理）
            }
          }
          return null;
        }
      }
      // 2) 追加我们的 CA。
      final ProcessResult step2 = await Process.run(
        keytool.path,
        <String>[
          '-importcert',
          '-noprompt',
          '-alias', 'fushi-cf-ca',
          '-keystore', dest.path,
          '-storetype', 'PKCS12',
          '-storepass', storePassword,
          '-file', caFile.path,
        ],
      );
      if (step2.exitCode != 0) {
        return null;
      }
      return dest;
    } on Object {
      return null;
    }
  }

  static String _norm(String host) {
    final String h = host.trim().toLowerCase();
    return h.endsWith('.') ? h.substring(0, h.length - 1) : h;
  }
}
