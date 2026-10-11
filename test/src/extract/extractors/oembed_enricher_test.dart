import 'package:metalink/src/extract/extractors/link_rel_extractor.dart';
import 'package:metalink/src/extract/extractors/oembed_enricher.dart';
import 'package:metalink/src/model/oembed.dart';
import 'package:metalink/src/options.dart';
import 'package:test/test.dart';

import '../../../support/fake_fetcher.dart';
import '../../../support/fixture_loader.dart';
import '../../../support/test_helpers.dart';

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

  test('keeps the payload when numeric dimensions overflow', () async {
    final fetcher = FakeFetcher();
    final url = Uri.parse('https://example.com/oembed.json');
    fetcher.registerGetResponse(
      url,
      FakeFetcher.buildResponse(
        url: url,
        statusCode: 200,
        headers: const {'content-type': 'application/json'},
        bodyText:
            '{"type":"video","title":"Huge","author_name":"Author",'
            '"thumbnail_url":"https://example.com/thumb.jpg",'
            '"width":1e400,"height":1e300,'
            '"thumbnail_width":"640.0","thumbnail_height":-1e400}',
      ),
    );

    final data = await const OEmbedEnricher().fetchAndParse(
      fetcher: fetcher,
      fetchOptions: const FetchOptions(),
      endpoint: OEmbedEndpoint(url: url, format: OEmbedFormat.json),
    );

    expect(data, isNotNull);
    expect(data!.title, 'Huge');
    expect(data.authorName, 'Author');
    expect(data.thumbnailUrl, Uri.parse('https://example.com/thumb.jpg'));
    expect(data.width, isNull);
    expect(data.height, isNull);
    expect(data.thumbnailWidth, 640);
    expect(data.thumbnailHeight, isNull);
  });

  test('parses decimal and rejects non-finite XML dimensions', () async {
    final fetcher = FakeFetcher();
    final url = Uri.parse('https://example.com/oembed.xml');
    fetcher.registerGetResponse(
      url,
      FakeFetcher.buildResponse(
        url: url,
        statusCode: 200,
        headers: const {'content-type': 'text/xml'},
        bodyText:
            '<?xml version="1.0" encoding="utf-8"?><oembed>'
            '<title>Decimal</title><width>640.0</width>'
            '<height>Infinity</height><thumbnail_width>320</thumbnail_width>'
            '</oembed>',
      ),
    );

    final data = await const OEmbedEnricher().fetchAndParse(
      fetcher: fetcher,
      fetchOptions: const FetchOptions(),
      endpoint: OEmbedEndpoint(url: url, format: OEmbedFormat.xml),
    );

    expect(data, isNotNull);
    expect(data!.title, 'Decimal');
    expect(data.width, 640);
    expect(data.height, isNull);
    expect(data.thumbnailWidth, 320);
  });

  Future<OEmbedData?> parseBody(
    String body, {
    OEmbedFormat format = OEmbedFormat.json,
  }) {
    final fetcher = FakeFetcher();
    final url = Uri.parse('https://example.com/oembed');
    fetcher.registerGetResponse(
      url,
      FakeFetcher.buildResponse(url: url, statusCode: 200, bodyText: body),
    );
    return const OEmbedEnricher().fetchAndParse(
      fetcher: fetcher,
      fetchOptions: const FetchOptions(),
      endpoint: OEmbedEndpoint(url: url, format: format),
    );
  }

  test('non-positive and oversized JSON dimensions become null', () async {
    final data = await parseBody(
      '{"title":"Dims","width":0,"height":-5,'
      '"thumbnail_width":9007199254740993,'
      '"thumbnail_height":9007199254740991}',
    );

    expect(data, isNotNull);
    expect(data!.title, 'Dims');
    expect(data.width, isNull);
    expect(data.height, isNull);
    expect(data.thumbnailWidth, isNull);
    expect(data.thumbnailHeight, 9007199254740991);
  });

  test('non-positive and oversized XML dimensions become null', () async {
    final data = await parseBody(
      '<oembed><title>Dims</title><width>0</width><height>-2.5</height>'
      '<thumbnail_width>9007199254740993</thumbnail_width>'
      '<thumbnail_height>120</thumbnail_height></oembed>',
      format: OEmbedFormat.xml,
    );

    expect(data, isNotNull);
    expect(data!.width, isNull);
    expect(data.height, isNull);
    expect(data.thumbnailWidth, isNull);
    expect(data.thumbnailHeight, 120);
  });

  test('non-string oEmbed text and URL fields become null', () async {
    final data = await parseBody(
      '{"type":["video"],"version":1.0,"title":123,"author_name":{"n":1},'
      '"author_url":5,"provider_name":false,"provider_url":[],'
      '"thumbnail_url":true,"html":{"a":1},"width":"320"}',
    );

    expect(data, isNotNull);
    expect(data!.type, isNull);
    expect(data.version, '1.0');
    expect(data.title, isNull);
    expect(data.authorName, isNull);
    expect(data.authorUrl, isNull);
    expect(data.providerName, isNull);
    expect(data.providerUrl, isNull);
    expect(data.thumbnailUrl, isNull);
    expect(data.html, isNull);
    expect(data.width, 320);
  });

  test('numeric versions format the same on every platform', () async {
    // On the web, `1.0.toString()` is "1", so integral numbers must not
    // depend on `num.toString()`.
    for (final (raw, expected) in [
      ('1', '1.0'),
      ('1.0', '1.0'),
      ('1.5', '1.5'),
      ('"1.0"', '1.0'),
      ('1e400', null),
    ]) {
      final data = await parseBody('{"title":"V","version":$raw}');

      expect(data, isNotNull, reason: raw);
      expect(data!.version, expected, reason: raw);
    }
  });

  test('resolves relative URLs against the final endpoint URL', () async {
    final fetcher = FakeFetcher();
    final startUrl = Uri.parse('https://oembed.provider.example/oembed');
    final finalUrl = Uri.parse('https://oembed.provider.example/v2/oembed');
    fetcher.registerGetResponse(
      startUrl,
      FakeFetcher.buildResponse(
        url: startUrl,
        statusCode: 302,
        headers: const {'location': '/v2/oembed'},
      ),
    );
    fetcher.registerGetResponse(
      finalUrl,
      FakeFetcher.buildResponse(
        url: finalUrl,
        statusCode: 200,
        bodyText:
            '{"thumbnail_url":"thumbs/1.jpg","author_url":"/users/alice",'
            '"provider_url":"/"}',
      ),
    );

    final data = await const OEmbedEnricher().fetchAndParse(
      fetcher: fetcher,
      fetchOptions: const FetchOptions(),
      endpoint: OEmbedEndpoint(url: startUrl, format: OEmbedFormat.json),
    );

    expect(
      data!.thumbnailUrl,
      Uri.parse('https://oembed.provider.example/v2/thumbs/1.jpg'),
    );
    expect(
      data.authorUrl,
      Uri.parse('https://oembed.provider.example/users/alice'),
    );
    expect(data.providerUrl, Uri.parse('https://oembed.provider.example/'));
  });

  test('relative oEmbed thumbnails resolve against the provider host, not the page', () async {
    final fetcher = FakeFetcher();
    final endpoint = Uri.parse('https://oembed.provider.example/oembed');
    fetcher.registerGetResponse(
      endpoint,
      FakeFetcher.buildResponse(
        url: endpoint,
        statusCode: 200,
        bodyText: '{"title":"Embedded","thumbnail_url":"/thumbs/1.jpg"}',
      ),
    );

    final metadata = await runPipeline(
      html:
          '<link rel="alternate" type="application/json+oembed" '
          'href="https://oembed.provider.example/oembed">',
      stages: const [LinkRelExtractor()],
      fetcher: fetcher,
      extractOptions: const ExtractOptions(enableOEmbed: true),
    );

    expect(metadata.images.map((image) => image.url.toString()), [
      'https://oembed.provider.example/thumbs/1.jpg',
    ]);
  });
}
