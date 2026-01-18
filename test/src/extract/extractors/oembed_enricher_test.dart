import 'package:metalink/src/extract/extractors/oembed_enricher.dart';
import 'package:metalink/src/model/oembed.dart';
import 'package:metalink/src/options.dart';
import 'package:test/test.dart';

import '../../../support/fake_fetcher.dart';
import '../../../support/fixture_loader.dart';

void main() {
  test('parses JSON oEmbed', () async {
    final fetcher = FakeFetcher();
    final url = Uri.parse('https://example.com/oembed.json');
    fetcher.registerGetResponse(
      url,
      FakeFetcher.buildResponse(
        url: url,
        statusCode: 200,
        headers: const {'content-type': 'application/json'},
        bodyText: readFixture('json/oembed.json'),
      ),
    );

    final data = await const OEmbedEnricher().fetchAndParse(
      fetcher: fetcher,
      fetchOptions: const FetchOptions(),
      endpoint: OEmbedEndpoint(url: url, format: OEmbedFormat.json),
    );

    expect(data, isNotNull);
    expect(data!.title, 'OEmbed Title');
    expect(data.thumbnailWidth, 320);
  });

  test('parses XML oEmbed', () async {
    final fetcher = FakeFetcher();
    final url = Uri.parse('https://example.com/oembed.xml');
    fetcher.registerGetResponse(
      url,
      FakeFetcher.buildResponse(
        url: url,
        statusCode: 200,
        headers: const {'content-type': 'text/xml'},
        bodyText: readFixture('xml/oembed.xml'),
      ),
    );

    final data = await const OEmbedEnricher().fetchAndParse(
      fetcher: fetcher,
      fetchOptions: const FetchOptions(),
      endpoint: OEmbedEndpoint(url: url, format: OEmbedFormat.xml),
    );

    expect(data, isNotNull);
    expect(data!.title, 'OEmbed XML');
  });

  test('returns null on non-200', () async {
    final fetcher = FakeFetcher();
    final url = Uri.parse('https://example.com/oembed.json');
    fetcher.registerGetResponse(
      url,
      FakeFetcher.buildResponse(url: url, statusCode: 404),
    );

    final data = await const OEmbedEnricher().fetchAndParse(
      fetcher: fetcher,
      fetchOptions: const FetchOptions(),
      endpoint: OEmbedEndpoint(url: url, format: OEmbedFormat.json),
    );
    expect(data, isNull);
  });
}
