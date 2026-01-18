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
        data.icons.first.src.toString(), 'https://example.com/static/icon.svg');
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
}
