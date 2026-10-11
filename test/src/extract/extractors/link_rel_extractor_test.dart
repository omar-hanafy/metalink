import 'package:metalink/src/extract/extractors/link_rel_extractor.dart';
import 'package:metalink/src/options.dart';
import 'package:test/test.dart';

import '../../../support/fake_fetcher.dart';
import '../../../support/fixture_loader.dart';
import '../../../support/test_helpers.dart';

void main() {
  test('extracts canonical, icons, oembed, and manifest', () async {
    final html = readFixture('html/link_rel.html');
    final oembedUrl = Uri.parse('https://example.com/oembed.json');
    final manifestUrl = Uri.parse('https://example.com/manifest.json');

    final fetcher = FakeFetcher();
    fetcher.registerGetResponse(
      oembedUrl,
      FakeFetcher.buildResponse(
        url: oembedUrl,
        statusCode: 200,
        headers: const {'content-type': 'application/json'},
        bodyText: readFixture('json/oembed.json'),
      ),
    );
    fetcher.registerGetResponse(
      manifestUrl,
      FakeFetcher.buildResponse(
        url: manifestUrl,
        statusCode: 200,
        headers: const {'content-type': 'application/json'},
        bodyText: readFixture('json/manifest.json'),
      ),
    );

    final metadata = await runPipeline(
      html: html,
      stages: const [LinkRelExtractor()],
      fetcher: fetcher,
      extractOptions: const ExtractOptions(
        extractLinkRels: true,
        enableOEmbed: true,
        enableManifest: true,
      ),
    );

    expect(metadata.canonicalUrl.toString(), 'https://example.com/canonical');
    expect(metadata.icons.length, 4);
    expect(metadata.oembed, isNotNull);
    expect(metadata.manifest, isNotNull);
    expect(metadata.manifest!.name, 'Test App');
  });

  test('skips link rels when disabled', () async {
    final html = readFixture('html/link_rel.html');
    final metadata = await runPipeline(
      html: html,
      stages: const [LinkRelExtractor()],
      extractOptions: const ExtractOptions(
        extractLinkRels: false,
        enableOEmbed: false,
        enableManifest: false,
      ),
    );

    expect(metadata.canonicalUrl, isNull);
    expect(metadata.icons, isEmpty);
  });

  test('infers oembed xml format from type', () async {
    const html =
        '<link rel="alternate" '
        'type="text/xml+oembed" '
        'href="https://example.com/oembed.xml">';
    final oembedUrl = Uri.parse('https://example.com/oembed.xml');
    final fetcher = FakeFetcher();
    fetcher.registerGetResponse(
      oembedUrl,
      FakeFetcher.buildResponse(
        url: oembedUrl,
        statusCode: 200,
        headers: const {'content-type': 'text/xml'},
        bodyText: readFixture('xml/oembed.xml'),
      ),
    );

    final metadata = await runPipeline(
      html: html,
      stages: const [LinkRelExtractor()],
      fetcher: fetcher,
      extractOptions: const ExtractOptions(enableOEmbed: true),
    );
    expect(metadata.oembed, isNotNull);
    expect(metadata.oembed!.title, 'OEmbed XML');
  });

  test('a later duplicate icon contributes its richer attributes', () async {
    const html =
        '<link rel="icon" href="/icon.png">'
        '<link rel="apple-touch-icon" href="/icon.png" sizes="180x180" '
        'type="image/png">';
    final metadata = await runPipeline(
      html: html,
      stages: const [LinkRelExtractor()],
    );

    expect(metadata.icons, hasLength(1));
    final icon = metadata.icons.single;
    expect(icon.url.toString(), 'https://example.com/icon.png');
    expect(icon.rel, 'apple-touch-icon');
    expect(icon.sizes, '180x180');
    expect(icon.type, 'image/png');
  });

  test('empty sizes and type attributes are absent, not empty', () async {
    const html =
        '<link rel="icon" href="/a.png" sizes="" type=" ">'
        '<link rel="icon" href="/a.png" sizes="32x32" type="image/png">';
    final metadata = await runPipeline(
      html: html,
      stages: const [LinkRelExtractor()],
    );

    expect(metadata.icons, hasLength(1));
    expect(metadata.icons.single.sizes, '32x32');
    expect(metadata.icons.single.type, 'image/png');
  });

  test('an icon without sizes or type reports null attributes', () async {
    const html = '<link rel="icon" href="/b.png" sizes="" type="">';
    final metadata = await runPipeline(
      html: html,
      stages: const [LinkRelExtractor()],
    );

    expect(metadata.icons.single.sizes, isNull);
    expect(metadata.icons.single.type, isNull);
  });

  test('EXT-R2-5 removes newlines from a link icon href', () async {
    const html = '<link rel="icon" href="/icons/\nfavicon.ico">';
    final metadata = await runPipeline(
      html: html,
      stages: const [LinkRelExtractor()],
    );

    expect(
      metadata.icons.single.url.toString(),
      'https://example.com/icons/favicon.ico',
    );
  });
}
