import 'package:metalink/src/util/url_normalizer.dart';
import 'package:test/test.dart';

void main() {
  group('UrlNormalizer.parseLoose', () {
    test('rejects empty and forbidden schemes', () {
      expect(UrlNormalizer.parseLoose(''), isNull);
      expect(UrlNormalizer.parseLoose('  '), isNull);
      expect(UrlNormalizer.parseLoose('mailto:test@example.com'), isNull);
      expect(UrlNormalizer.parseLoose('javascript:alert(1)'), isNull);
      expect(UrlNormalizer.parseLoose('data:text/plain,hi'), isNull);
      expect(UrlNormalizer.parseLoose('file:///tmp/a'), isNull);
      expect(UrlNormalizer.parseLoose('ftp://example.com'), isNull);
    });

    test('accepts http and https URLs', () {
      final httpUrl = UrlNormalizer.parseLoose('http://example.com');
      final httpsUrl = UrlNormalizer.parseLoose('https://example.com/path');
      expect(httpUrl, isNotNull);
      expect(httpUrl!.scheme, 'http');
      expect(httpUrl.host, 'example.com');
      expect(httpsUrl, isNotNull);
      expect(httpsUrl!.scheme, 'https');
      expect(httpsUrl.path, '/path');
    });

    test('normalizes protocol-relative URLs', () {
      final url = UrlNormalizer.parseLoose('//example.com/foo');
      expect(url, isNotNull);
      expect(url!.scheme, 'https');
      expect(url.host, 'example.com');
      expect(url.path, '/foo');
    });

    test('rejects relative-only paths', () {
      expect(UrlNormalizer.parseLoose('/only/path'), isNull);
    });

    test('assumes https for host without scheme', () {
      final url = UrlNormalizer.parseLoose('example.com/abc');
      expect(url, isNotNull);
      expect(url!.scheme, 'https');
      expect(url.host, 'example.com');
      expect(url.path, '/abc');
    });
  });

  group('UrlNormalizer helpers', () {
    test('ensureHttpsScheme upgrades http and empty scheme', () {
      final httpUrl = Uri.parse('http://example.com');
      final httpsUrl = UrlNormalizer.ensureHttpsScheme(httpUrl);
      expect(httpsUrl.scheme, 'https');

      final noScheme = Uri.parse('example.com');
      final normalized = UrlNormalizer.ensureHttpsScheme(noScheme);
      expect(normalized.scheme, 'https');
    });

    test('ensureHttpsScheme keeps unknown schemes', () {
      final custom = Uri.parse('custom://example.com');
      expect(UrlNormalizer.ensureHttpsScheme(custom).scheme, 'custom');
    });

    test('removeFragment strips fragment only', () {
      final uri = Uri.parse('https://example.com/path?x=1#frag');
      final stripped = UrlNormalizer.removeFragment(uri);
      expect(stripped.toString(), 'https://example.com/path?x=1');
    });

    test('normalizeForRequest lowercases scheme and host', () {
      final uri = Uri.parse('HTTP://Example.COM');
      final normalized = UrlNormalizer.normalizeForRequest(uri);
      expect(normalized.scheme, 'http');
      expect(normalized.host, 'example.com');
      expect(normalized.path, '/');
    });

    test('normalizeForRequest drops default ports', () {
      final httpUrl = Uri.parse('http://example.com:80/path');
      final httpsUrl = Uri.parse('https://example.com:443/path');
      expect(UrlNormalizer.normalizeForRequest(httpUrl).toString(),
          'http://example.com/path');
      expect(UrlNormalizer.normalizeForRequest(httpsUrl).toString(),
          'https://example.com/path');
    });

    test('normalizeForRequest keeps non-default port', () {
      final uri = Uri.parse('https://example.com:8443/path');
      final normalized = UrlNormalizer.normalizeForRequest(uri);
      expect(normalized.port, 8443);
    });

    test('normalizeForCacheKey mirrors normalizeForRequest', () {
      final uri = Uri.parse('https://Example.com');
      final normalized = UrlNormalizer.normalizeForCacheKey(uri);
      expect(normalized.host, 'example.com');
      expect(normalized.path, '/');
    });

    test('applyProxy supports placeholders and prefix', () {
      final target = Uri.parse('https://example.com/path?x=1');
      final proxyEncoded = UrlNormalizer.applyProxy(
        target,
        'https://proxy.test?u={urlEncoded}',
      );
      expect(proxyEncoded.toString(),
          'https://proxy.test?u=https%3A%2F%2Fexample.com%2Fpath%3Fx%3D1');

      final proxyRaw = UrlNormalizer.applyProxy(
        target,
        'https://proxy.test?u={url}',
      );
      expect(proxyRaw.toString(),
          'https://proxy.test?u=https://example.com/path?x=1');

      final proxyPrefix = UrlNormalizer.applyProxy(
        target,
        'https://proxy.test/',
      );
      expect(proxyPrefix.toString(),
          'https://proxy.test/https://example.com/path?x=1');
    });
  });
}
