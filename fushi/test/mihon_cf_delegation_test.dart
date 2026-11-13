// 纯逻辑单测：CF 代发 host 判定（归一化 / 名单 / scheme / source 判定）。
//
// 目的：把「哪些 host 该走 WebView2 代发」的判据固化成可自动断言的测试，防回归。
// 这是云端验证的第一层——不联网、不需浏览器，CI 里跑，能证明移植后的判定逻辑
// 与原设计一致（大小写/末尾点归一化、scheme 限制、名单正确、Bbato 已移除）。
// 注意：它不能证明「Cloudflare 是否真被绕过」（那需要真实浏览器+真实出口 IP，
// 见本机影子目录验证），只保证判定逻辑不被悄悄改坏。
import 'package:fushi/src/media/manga/mihon/mihon_cf_delegation.dart';
import 'package:fushi/src/media/manga/mihon/mihon_models.dart';
import 'package:test/test.dart';

void main() {
  group('MihonCfDelegation 归一化', () {
    test('大小写不敏感', () {
      expect(MihonCfDelegation.isCfHost('MyComic.com'), isTrue);
      expect(MihonCfDelegation.isCfHost('MYCOMIC.COM'), isTrue);
      expect(MihonCfDelegation.isCfHost('Ahri8.Monster'), isTrue);
    });
    test('去末尾点', () {
      expect(MihonCfDelegation.isCfHost('mycomic.com.'), isTrue);
      expect(MihonCfDelegation.isCfHost('ahri8.com.'), isTrue);
    });
    test('未登记 host 返回 false', () {
      expect(MihonCfDelegation.isCfHost('example.com'), isFalse);
      // Bbato 已卸载，不应出现在代发名单（用户 2026-11-13 变更）
      expect(MihonCfDelegation.isCfHost('bato1.com'), isFalse);
      expect(MihonCfDelegation.isCfHost('stevenyomi.github.io'), isFalse);
    });
  });

  group('shouldDelegate（scheme + host）', () {
    test('cf host 的 http/https 应代发', () {
      expect(
          MihonCfDelegation.shouldDelegate(Uri.parse('https://mycomic.com/x')),
          isTrue);
      expect(
          MihonCfDelegation.shouldDelegate(Uri.parse('http://ahri8.com/x')),
          isTrue);
      expect(
          MihonCfDelegation
              .shouldDelegate(Uri.parse('https://ahri8.monster/x')),
          isTrue);
    });
    test('非 cf host 不应代发', () {
      expect(
          MihonCfDelegation.shouldDelegate(Uri.parse('https://example.com/x')),
          isFalse);
    });
    test('非 http(s) scheme 不应代发', () {
      expect(
          MihonCfDelegation.shouldDelegate(Uri.parse('ftp://mycomic.com/x')),
          isFalse);
    });
  });

  group('cfHosts 名单', () {
    test('恰好三个 host，且无已卸载源', () {
      expect(
        MihonCfDelegation.cfHosts,
        unorderedEquals(['mycomic.com', 'ahri8.com', 'ahri8.monster']),
      );
      expect(MihonCfDelegation.cfHosts, isNot(contains('bato1.com')));
    });
  });

  group('sourceIsCfProtected', () {
    test('mycomic baseUrl 判定为受保护', () {
      final MihonSource s = MihonSource(
        extensionPackage: 'x',
        id: '1',
        name: 'MyComic',
        language: 'zh',
        baseUrl: 'https://mycomic.com',
      );
      expect(MihonCfDelegation.sourceIsCfProtected(s), isTrue);
    });
    test('其他 baseUrl 判定为不受保护', () {
      final MihonSource s = MihonSource(
        extensionPackage: 'x',
        id: '2',
        name: 'Other',
        language: 'en',
        baseUrl: 'https://other.com',
      );
      expect(MihonCfDelegation.sourceIsCfProtected(s), isFalse);
    });
  });
}
