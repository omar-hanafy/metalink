import 'package:metalink/src/extract/candidate.dart';
import 'package:metalink/src/extract/extractors/link_rel_extractor.dart';
import 'package:metalink/src/extract/extractors/open_graph_extractor.dart';
import 'package:metalink/src/extract/extractors/standard_meta_extractor.dart';
import 'package:metalink/src/extract/pipeline.dart';
import 'package:metalink/src/extract/ranking.dart';
import 'package:metalink/src/fetch/html_snippet_fetcher.dart';
import 'package:metalink/src/model/diagnostics.dart';
import 'package:metalink/src/model/media.dart';
import 'package:metalink/src/model/structured_data.dart';
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
    const html =
        '<title>Standard</title>'
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
    expect(
      output.metadata.images.first.url.toString(),
      'https://example.com/a.png',
    );
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
    expect(
      output.metadata.images.first.url.toString(),
      'https://example.com/base/images/relative.png',
    );
  });

  test('captures raw metadata when enabled', () async {
    const html =
        '<meta name="description" content="desc">'
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
    final pipeline = ExtractPipeline(
      stages: [_ThrowingStage(), const StandardMetaExtractor()],
    );
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

    expect(
      output.metadata.images.first.url.toString(),
      'https://example.com/thumb.png',
    );
    expect(
      output.itemProvenance[MetaField.images]?.first.provenance.source,
      CandidateSource.oEmbed,
    );
  });

  test('remote enrichment participates in the same ranking policy', () async {
    const html =
        '<title>Standard title</title>'
        '<link rel="alternate" type="application/json+oembed" '
        'href="https://example.com/oembed.json">';
    final oembedUrl = Uri.parse('https://example.com/oembed.json');
    final fetcher = FakeFetcher();
    fetcher.registerGetResponse(
      oembedUrl,
      FakeFetcher.buildResponse(
        url: oembedUrl,
        statusCode: 200,
        headers: const {'content-type': 'application/json'},
        bodyText: '{"title":"Provider title"}',
      ),
    );

    final pipeline = ExtractPipeline(
      stages: const [StandardMetaExtractor(), LinkRelExtractor()],
    );
    final output = await pipeline.run(
      page: pageFromHtml(html),
      fetcher: fetcher,
      fetchOptions: const FetchOptions(),
      extractOptions: const ExtractOptions(enableOEmbed: true),
    );

    expect(output.metadata.title, 'Provider title');
    expect(
      output.fieldProvenance[MetaField.title]?.source,
      CandidateSource.oEmbed,
    );
  });

  test('equal scores use explicit stage and document order', () async {
    final pipeline = ExtractPipeline(stages: [_EqualTitleStage()]);
    final output = await pipeline.runLocal(
      page: pageFromHtml('<html></html>'),
      extractOptions: const ExtractOptions(),
    );

    expect(output.metadata.title, 'First');
    final decisions = output.candidateDecisions[MetaField.title]!;
    expect(decisions, hasLength(2));
    expect(decisions.first.selected, isTrue);
    expect(decisions.last.selected, isFalse);
  });

  test(
    'structured data uses the ranking policy and records decisions',
    () async {
      final pipeline = ExtractPipeline(
        stages: [_StructuredDataStage()],
        rankingPolicy: const _LastCandidatePolicy(),
      );
      final output = await pipeline.runLocal(
        page: pageFromHtml('<html></html>'),
        extractOptions: const ExtractOptions(),
      );

      expect(output.metadata.structuredData?.nodes.single['@id'], 'second');
      expect(
        output.fieldProvenance[MetaField.structuredData]?.source,
        CandidateSource.heuristic,
      );
      final decisions = output.candidateDecisions[MetaField.structuredData]!;
      expect(decisions, hasLength(2));
      expect(decisions.first.valueKey, contains('second'));
      expect(decisions.map((decision) => decision.selected), <bool>[
        true,
        false,
      ]);
    },
  );

  test('same URL image candidates merge complementary attributes', () async {
    final pipeline = ExtractPipeline(stages: [_ComplementaryImageStage()]);
    final output = await pipeline.runLocal(
      page: pageFromHtml('<html></html>'),
      extractOptions: const ExtractOptions(),
    );

    expect(output.metadata.images, hasLength(1));
    expect(output.metadata.images.single.width, 1200);
    expect(output.metadata.images.single.height, 630);
    expect(output.metadata.images.single.alt, 'Preview');
    expect(output.itemProvenance[MetaField.images], hasLength(1));
    expect(
      output.itemProvenance[MetaField.images]!.single.contributors.map(
        (contributor) => contributor.source,
      ),
      <CandidateSource>[CandidateSource.openGraph, CandidateSource.twitterCard],
    );

    final decisions = output.candidateDecisions[MetaField.images]!;
    expect(decisions.map((decision) => decision.source), <CandidateSource>[
      CandidateSource.openGraph,
      CandidateSource.twitterCard,
      CandidateSource.standardMeta,
    ]);
    expect(decisions.map((decision) => decision.selected), <bool>[
      true,
      true,
      false,
    ]);
  });

  test(
    'rejects hostless HTTP metadata candidates from custom stages',
    () async {
      final pipeline = ExtractPipeline(stages: [_HostlessImageStage()]);
      final output = await pipeline.runLocal(
        page: pageFromHtml('<html></html>'),
        extractOptions: const ExtractOptions(),
      );

      expect(output.metadata.images, isEmpty);
    },
  );
}

class _ThrowingStage implements HtmlMetadataExtractorStage {
  @override
  void extract(HtmlExtractContext context) {
    throw StateError('boom');
  }
}

class _EqualTitleStage implements HtmlMetadataExtractorStage {
  @override
  void extract(HtmlExtractContext context) {
    context.addTitle('First', source: CandidateSource.heuristic, score: 0.5);
    context.addTitle('Second', source: CandidateSource.heuristic, score: 0.5);
  }
}

class _ComplementaryImageStage implements HtmlMetadataExtractorStage {
  @override
  void extract(HtmlExtractContext context) {
    final url = Uri.parse('https://example.com/image.png');
    context.addImageCandidate(
      ImageCandidate(url: url, width: 1200),
      source: CandidateSource.openGraph,
      score: 0.8,
    );
    context.addImageCandidate(
      ImageCandidate(url: url, height: 630, alt: 'Preview'),
      source: CandidateSource.twitterCard,
      score: 0.8,
    );
    context.addImageCandidate(
      ImageCandidate(url: url, width: 640, alt: 'Ignored duplicate'),
      source: CandidateSource.standardMeta,
      score: 0.8,
    );
  }
}

class _HostlessImageStage implements HtmlMetadataExtractorStage {
  @override
  void extract(HtmlExtractContext context) {
    context.addImageCandidate(
      ImageCandidate(url: Uri.parse('http:relative')),
      source: CandidateSource.heuristic,
      score: 1,
    );
  }
}

class _StructuredDataStage implements HtmlMetadataExtractorStage {
  @override
  void extract(HtmlExtractContext context) {
    context.setStructuredData(
      const StructuredDataGraph(
        nodes: [
          <String, dynamic>{'@id': 'first'},
        ],
      ),
      source: CandidateSource.jsonLd,
      score: 0.9,
    );
    context.setStructuredData(
      const StructuredDataGraph(
        nodes: [
          <String, dynamic>{'@id': 'second'},
        ],
      ),
      source: CandidateSource.heuristic,
      score: 0.1,
    );
  }
}

class _LastCandidatePolicy implements RankingPolicy {
  const _LastCandidatePolicy();

  @override
  RankingDecision<T> rank<T>({
    required MetaField field,
    required List<Candidate<T>> candidates,
    required Uri documentUrl,
  }) {
    return RankingDecision<T>(
      ranked: <RankedCandidate<T>>[
        for (var index = candidates.length - 1; index >= 0; index--)
          RankedCandidate<T>(
            candidate: candidates[index],
            effectiveScore: candidates[index].score,
            originalIndex: index,
          ),
      ],
    );
  }
}
