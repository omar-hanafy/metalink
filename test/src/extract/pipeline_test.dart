import 'package:metalink/src/extract/extractors/link_rel_extractor.dart';
import 'package:metalink/src/extract/extractors/open_graph_extractor.dart';
import 'package:metalink/src/extract/extractors/standard_meta_extractor.dart';
import 'package:metalink/src/extract/pipeline.dart';
import 'package:metalink/src/fetch/html_snippet_fetcher.dart';
import 'package:metalink/src/model/diagnostics.dart';
import 'package:metalink/src/options.dart';
import 'package:test/test.dart';

import '../../support/fake_fetcher.dart';
import '../../support/fixture_loader.dart';

void main() {
  HtmlFetchResult pageFromHtml(String html) {
    return HtmlFetchResult(
      originalUrl: Uri.parse('https://example.com/page'),
      finalUrl: Uri.parse('https://example.com/page'),
      redirects: const [],
      statusCode: 200,
      headers: const {'content-type': 'text/html; charset=utf-8'},
      bodyBytes: html.codeUnits,
      bodyText: html,
      detectedCharset: 'utf-8',
      charsetSource: CharsetSource.header,
      truncated: false,
      duration: Duration.zero,
    );
  }

  test('prefers higher score candidates', () async {
    const html = '<title>Standard</title>'
        '<meta property="og:title" content="OG">';
    final pipeline = ExtractPipeline(
      stages: const [OpenGraphExtractor(), StandardMetaExtractor()],
    );
    final output = await pipeline.run(
      page: pageFromHtml(html),
      fetcher: FakeFetcher(),
      fetchOptions: const FetchOptions(),
      extractOptions: const ExtractOptions(),
    );
    expect(output.metadata.title, 'OG');
    expect(output.fieldProvenance[MetaField.title], isNotNull);
  });

  test('dedupes images and respects maxImages', () async {
    const html =
        '<meta property="og:image" content="https://example.com/a.png">'
        '<meta property="og:image" content="https://example.com/a.png">'
        '<meta property="og:image" content="https://example.com/b.png">';
    final pipeline = ExtractPipeline(stages: const [OpenGraphExtractor()]);
    final output = await pipeline.run(
      page: pageFromHtml(html),
      fetcher: FakeFetcher(),
      fetchOptions: const FetchOptions(),
      extractOptions: const ExtractOptions(maxImages: 1),
    );
    expect(output.metadata.images.length, 1);
    expect(output.metadata.images.first.url.toString(),
        'https://example.com/a.png');
  });

  test('resolves base href for relative images', () async {
    final html = readFixture('html/base_href.html');
    final pipeline = ExtractPipeline(stages: const [OpenGraphExtractor()]);
    final output = await pipeline.run(
      page: pageFromHtml(html),
      fetcher: FakeFetcher(),
      fetchOptions: const FetchOptions(),
      extractOptions: const ExtractOptions(),
    );
    expect(output.metadata.images.first.url.toString(),
        'https://example.com/base/images/relative.png');
  });

  test('captures raw metadata when enabled', () async {
    const html = '<meta name="description" content="desc">'
        '<link rel="icon" href="/icon.png">';
    final pipeline = ExtractPipeline(stages: const [StandardMetaExtractor()]);
    final output = await pipeline.run(
      page: pageFromHtml(html),
      fetcher: FakeFetcher(),
      fetchOptions: const FetchOptions(),
      extractOptions: const ExtractOptions(includeRawMetadata: true),
    );
    expect(output.raw, isNotNull);
    expect(output.raw!.meta['description'], ['desc']);
    expect(output.raw!.links.length, 1);
  });

  test('handles stage exceptions as warnings', () async {
    final pipeline = ExtractPipeline(stages: [
      _ThrowingStage(),
      const StandardMetaExtractor(),
    ]);
    final output = await pipeline.run(
      page: pageFromHtml('<title>Title</title>'),
      fetcher: FakeFetcher(),
      fetchOptions: const FetchOptions(),
      extractOptions: const ExtractOptions(),
    );
    expect(output.warnings, isNotEmpty);
    expect(output.metadata.title, 'Title');
  });

  test('adds oembed thumbnail as image', () async {
    final html = readFixture('html/link_rel.html');
    final oembedUrl = Uri.parse('https://example.com/oembed.json');
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

    final pipeline = ExtractPipeline(stages: const [LinkRelExtractor()]);
    final output = await pipeline.run(
      page: pageFromHtml(html),
      fetcher: fetcher,
      fetchOptions: const FetchOptions(),
      extractOptions: const ExtractOptions(enableOEmbed: true),
    );

    expect(output.metadata.images.first.url.toString(),
        'https://example.com/thumb.png');
  });
}

class _ThrowingStage implements HtmlMetadataExtractorStage {
  @override
  void extract(HtmlExtractContext context) {
    throw StateError('boom');
  }
}
