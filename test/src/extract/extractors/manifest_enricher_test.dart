import 'package:metalink/src/extract/extractors/manifest_enricher.dart';
import 'package:metalink/src/options.dart';
import 'package:test/test.dart';

import '../../../support/fake_fetcher.dart';
import '../../../support/fixture_loader.dart';

void main() {
  test('parses manifest and resolves relative URLs', () async {
    final fetcher = FakeFetcher();
    final url = Uri.parse('https://example.com/manifest.json');
    fetcher.registerGetResponse(
      url,
      FakeFetcher.buildResponse(
        url: url,
        statusCode: 200,
        headers: const {'content-type': 'application/json'},
        bodyText: readFixture('json/manifest.json'),
      ),
    );

    final data = await const ManifestEnricher().fetchAndParse(
      fetcher: fetcher,
      fetchOptions: const FetchOptions(),
      manifestUrl: url,
    );

    expect(data, isNotNull);
    expect(data!.name, 'Test App');
    expect(data.startUrl.toString(), 'https://example.com/start');
    expect(data.icons.length, 2);
    expect(
      data.icons.first.src.toString(),
      'https://example.com/static/icon.svg',
    );
  });

  test('returns null on invalid JSON', () async {
    final fetcher = FakeFetcher();
    final url = Uri.parse('https://example.com/manifest.json');
    fetcher.registerGetResponse(
      url,
      FakeFetcher.buildResponse(
        url: url,
        statusCode: 200,
        headers: const {'content-type': 'application/json'},
        bodyText: 'not-json',
      ),
    );

    final data = await const ManifestEnricher().fetchAndParse(
      fetcher: fetcher,
      fetchOptions: const FetchOptions(),
      manifestUrl: url,
    );
    expect(data, isNull);
  });

  test('caps response bytes by both caller and manifest limits', () async {
    final fetcher = FakeFetcher();
    final callerLimitedUrl = Uri.parse(
      'https://example.com/caller-limited.webmanifest',
    );
    final enrichmentLimitedUrl = Uri.parse(
      'https://example.com/enrichment-limited.webmanifest',
    );
    for (final url in [callerLimitedUrl, enrichmentLimitedUrl]) {
      fetcher.registerGetResponse(
        url,
        FakeFetcher.buildResponse(url: url, statusCode: 200, bodyText: '{}'),
      );
    }

    await const ManifestEnricher().fetchAndParse(
      fetcher: fetcher,
      fetchOptions: const FetchOptions(maxBytes: 1024),
      manifestUrl: callerLimitedUrl,
    );
    await const ManifestEnricher().fetchAndParse(
      fetcher: fetcher,
      fetchOptions: const FetchOptions(maxBytes: 1024 * 1024),
      manifestUrl: enrichmentLimitedUrl,
    );

    expect(fetcher.requests.map((request) => request.maxBytes), [
      1024,
      512 * 1024,
    ]);
  });

  test('resolves manifest fields against the final redirected URL', () async {
    final fetcher = FakeFetcher();
    final originalUrl = Uri.parse('https://example.com/manifest.json');
    final finalUrl = Uri.parse('https://example.com/nested/app.webmanifest');
    fetcher.registerGetResponse(
      originalUrl,
      FakeFetcher.buildResponse(
        url: originalUrl,
        statusCode: 302,
        headers: const {'location': '/nested/app.webmanifest'},
      ),
    );
    fetcher.registerGetResponse(
      finalUrl,
      FakeFetcher.buildResponse(
        url: finalUrl,
        statusCode: 200,
        headers: const {'content-type': 'application/manifest+json'},
        bodyText: '''
          {
            "name": "Redirected",
            "start_url": "./start",
            "icons": [{"src": "icons/app.png"}]
          }
        ''',
      ),
    );

    final data = await const ManifestEnricher().fetchAndParse(
      fetcher: fetcher,
      fetchOptions: const FetchOptions(),
      manifestUrl: originalUrl,
    );

    expect(data, isNotNull);
    expect(data!.manifestUrl, finalUrl);
    expect(data.startUrl, Uri.parse('https://example.com/nested/start'));
    expect(
      data.icons.single.src,
      Uri.parse('https://example.com/nested/icons/app.png'),
    );
    expect(fetcher.requests, hasLength(2));
  });
}
