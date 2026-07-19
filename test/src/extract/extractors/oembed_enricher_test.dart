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
    expect(
      fetcher.requests.single.headers?['user-agent'],
      'MetaLink (+https://github.com/omar-hanafy/metalink)',
    );
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

  test('caps response bytes by both caller and oEmbed limits', () async {
    final fetcher = FakeFetcher();
    final callerLimitedUrl = Uri.parse(
      'https://example.com/caller-limited-oembed.json',
    );
    final enrichmentLimitedUrl = Uri.parse(
      'https://example.com/enrichment-limited-oembed.json',
    );
    for (final url in [callerLimitedUrl, enrichmentLimitedUrl]) {
      fetcher.registerGetResponse(
        url,
        FakeFetcher.buildResponse(url: url, statusCode: 200, bodyText: '{}'),
      );
    }

    await const OEmbedEnricher().fetchAndParse(
      fetcher: fetcher,
      fetchOptions: const FetchOptions(maxBytes: 1024),
      endpoint: OEmbedEndpoint(
        url: callerLimitedUrl,
        format: OEmbedFormat.json,
      ),
    );
    await const OEmbedEnricher().fetchAndParse(
      fetcher: fetcher,
      fetchOptions: const FetchOptions(maxBytes: 1024 * 1024),
      endpoint: OEmbedEndpoint(
        url: enrichmentLimitedUrl,
        format: OEmbedFormat.json,
      ),
    );

    expect(fetcher.requests.map((request) => request.maxBytes), [
      1024,
      256 * 1024,
    ]);
  });

  test('records the final redirected endpoint URL', () async {
    final fetcher = FakeFetcher();
    final originalUrl = Uri.parse('https://example.com/oembed.json');
    final finalUrl = Uri.parse('https://example.com/providers/oembed.json');
    fetcher.registerGetResponse(
      originalUrl,
      FakeFetcher.buildResponse(
        url: originalUrl,
        statusCode: 302,
        headers: const {'location': '/providers/oembed.json'},
      ),
    );
    fetcher.registerGetResponse(
      finalUrl,
      FakeFetcher.buildResponse(
        url: finalUrl,
        statusCode: 200,
        headers: const {'content-type': 'application/json'},
        bodyText: '{"title":"Redirected"}',
      ),
    );

    final data = await const OEmbedEnricher().fetchAndParse(
      fetcher: fetcher,
      fetchOptions: const FetchOptions(),
      endpoint: OEmbedEndpoint(url: originalUrl, format: OEmbedFormat.json),
    );

    expect(data, isNotNull);
    expect(data!.endpoint, finalUrl);
    expect(data.title, 'Redirected');
    expect(fetcher.requests, hasLength(2));
  });
}
