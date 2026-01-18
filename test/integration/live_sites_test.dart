import 'package:metalink/metalink.dart';
import 'package:test/test.dart';

void main() {
  group('live site smoke tests', tags: ['live'], () {
    // ---------------------------------------------------------------------------
    // LIVE INTEGRATION TESTS
    // ---------------------------------------------------------------------------
    // These tests make REAL network requests.
    // usage: dart test -t live
    // ---------------------------------------------------------------------------

    const browserUserAgent =
        'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

    const browserOptions = MetaLinkClientOptions(
      fetch: FetchOptions(userAgent: browserUserAgent),
    );

    test('Live: Extract metadata from example.com', () async {
      // example.com is a stable test target reserved by IANA.
      final result = await MetaLink.extract('https://example.com');

      expect(result.isSuccess, isTrue, reason: 'Extraction should succeed');
      expect(result.metadata.title, contains('Example Domain'));
      expect(result.metadata.resolvedUrl.host, 'example.com');
    });

    test('Live: Extract metadata from flutter.dev', () async {
      final result = await MetaLink.extract(
        'https://flutter.dev',
        options: browserOptions,
      );

      expect(result.isSuccess, isTrue);
      expect(result.metadata.title, contains('Flutter'));
      expect(result.metadata.description, isNotEmpty);
      // Flutter site usually has a favicon or OG image
      expect(
          result.metadata.images.isNotEmpty || result.metadata.icons.isNotEmpty,
          isTrue,
          reason: 'Should find at least one image or icon');
    });
  });
}
