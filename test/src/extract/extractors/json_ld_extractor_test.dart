import 'package:metalink/src/extract/extractors/json_ld_extractor.dart';
import 'package:metalink/src/extract/pipeline.dart';
import 'package:metalink/src/model/errors.dart';
import 'package:metalink/src/model/link_metadata.dart';
import 'package:metalink/src/options.dart';
import 'package:test/test.dart';

import '../../../support/fixture_loader.dart';
import '../../../support/html_fetch_result.dart';
import '../../../support/test_helpers.dart';

void main() {
  test('extracts JSON-LD fields', () async {
    final html = readFixture('html/json_ld_article.html');
    final metadata = await runPipeline(
      html: html,
      stages: const [JsonLdExtractor()],
    );

    expect(metadata.title, 'JSON LD Title');
    expect(metadata.description, 'JSON LD Description');
    expect(metadata.author, 'Json Author');
    expect(metadata.siteName, 'Json Publisher');
    expect(metadata.kind, LinkKind.article);
    expect(metadata.images.length, 1);
    expect(
      metadata.images.first.url.toString(),
      'https://example.com/img-json.png',
    );
    expect(metadata.keywords, containsAll(['alpha', 'beta']));
  });

  test('handles @graph and arrays', () async {
    const html =
        '<script type="application/ld+json">'
        '{"@graph": ['
        '{"@type": "WebSite", "name": "Site"},'
        '{"@type": "Article", "headline": "Head"}'
        ']}'
        '</script>';
    final metadata = await runPipeline(
      html: html,
      stages: const [JsonLdExtractor()],
    );
    expect(metadata.title, 'Head');
    expect(metadata.siteName, 'Site');
    expect(metadata.structuredData?.nodes, hasLength(2));
  });

  test('ignores invalid JSON-LD', () async {
    const html = '<script type="application/ld+json">{bad</script>';
    final metadata = await runPipeline(
      html: html,
      stages: const [JsonLdExtractor()],
    );
    expect(metadata.isEmpty, isTrue);
  });

  test('reports malformed JSON-LD as an observable warning', () async {
    const html = '<script type="application/ld+json">{bad</script>';
    final pipeline = ExtractPipeline(stages: const [JsonLdExtractor()]);
    final output = await pipeline.runLocal(
      page: buildHtmlFetchResult(
        originalUrl: testBaseUrl,
        statusCode: 200,
        bodyText: html,
      ),
      extractOptions: const ExtractOptions(),
    );

    expect(
      output.warnings.any(
        (warning) => warning.code == MetaLinkWarningCode.partialParse,
      ),
      isTrue,
    );
  });

  test('enforces finite JSON-LD visit and depth budgets', () async {
    const html =
        '<script type="application/ld+json">'
        '{"outer":{"middle":{"inner":{"@type":"Article","name":"Deep"}}}}'
        '</script>';
    final pipeline = ExtractPipeline(
      stages: const [
        JsonLdExtractor(
          limits: JsonLdTraversalLimits(
            maxNodes: 10,
            maxVisitedValues: 10,
            maxDepth: 1,
          ),
        ),
      ],
    );
    final output = await pipeline.runLocal(
      page: buildHtmlFetchResult(
        originalUrl: testBaseUrl,
        statusCode: 200,
        bodyText: html,
      ),
      extractOptions: const ExtractOptions(),
    );

    expect(output.metadata.title, isNull);
    expect(
      output.warnings.any(
        (warning) =>
            warning.message.contains('configured node, visit, or depth'),
      ),
      isTrue,
    );
  });

  test('bounds queued JSON-LD collection entries by visit budget', () async {
    const html =
        '<script type="application/ld+json">'
        '[{"@type":"Article","name":"A"},'
        '{"@type":"Article","name":"B"},'
        '{"@type":"Article","name":"C"}]'
        '</script>';
    final pipeline = ExtractPipeline(
      stages: const [
        JsonLdExtractor(
          limits: JsonLdTraversalLimits(
            maxNodes: 10,
            maxVisitedValues: 2,
            maxDepth: 10,
          ),
        ),
      ],
    );
    final output = await pipeline.runLocal(
      page: buildHtmlFetchResult(
        originalUrl: testBaseUrl,
        statusCode: 200,
        bodyText: html,
      ),
      extractOptions: const ExtractOptions(),
    );

    expect(output.metadata.structuredData?.nodes.length, lessThanOrEqualTo(1));
    expect(
      output.warnings.any(
        (warning) =>
            warning.message.contains('configured node, visit, or depth'),
      ),
      isTrue,
    );
  });

  test('skips JSON-LD scripts beyond the aggregate decode budget', () async {
    const html =
        '<script type="application/ld+json">'
        '{"@type":"Article","headline":"Too large"}'
        '</script>';
    final pipeline = ExtractPipeline(
      stages: const [
        JsonLdExtractor(limits: JsonLdTraversalLimits(maxJsonCharacters: 16)),
      ],
    );

    final output = await pipeline.runLocal(
      page: buildHtmlFetchResult(
        originalUrl: testBaseUrl,
        statusCode: 200,
        bodyText: html,
      ),
      extractOptions: const ExtractOptions(),
    );

    expect(output.metadata.title, isNull);
    expect(
      output.warnings.any((warning) => warning.message.contains('JSON size')),
      isTrue,
    );
  });

  test(
    'bounds nested derived-field walks independently of node collection',
    () async {
      const html =
          '<script type="application/ld+json">'
          '{"@type":"Article","headline":"Bounded",'
          '"author":[[[{"name":"Too deep"}]]]}'
          '</script>';
      final pipeline = ExtractPipeline(
        stages: const [
          JsonLdExtractor(
            limits: JsonLdTraversalLimits(maxDepth: 1, maxDerivedValues: 100),
          ),
        ],
      );

      final output = await pipeline.runLocal(
        page: buildHtmlFetchResult(
          originalUrl: testBaseUrl,
          statusCode: 200,
          bodyText: html,
        ),
        extractOptions: const ExtractOptions(),
      );

      expect(output.metadata.title, 'Bounded');
      expect(output.metadata.author, isNull);
      expect(
        output.warnings.any(
          (warning) => warning.message.contains('derived-field traversal'),
        ),
        isTrue,
      );
    },
  );

  test('equal-relevance JSON-LD nodes retain document order', () async {
    const html =
        '<script type="application/ld+json">'
        '[{"@type":"Article","headline":"First"},'
        '{"@type":"Article","headline":"Second"}]'
        '</script>';

    final metadata = await runPipeline(
      html: html,
      stages: const [JsonLdExtractor()],
    );

    expect(metadata.title, 'First');
  });

  test('rejects hostless HTTP URLs from JSON-LD', () async {
    const html =
        '<script type="application/ld+json">'
        '{"@type":"Article","headline":"Hostless",'
        '"url":"https:/canonical","image":"http:image.png"}'
        '</script>';

    final metadata = await runPipeline(
      html: html,
      stages: const [JsonLdExtractor()],
    );

    expect(metadata.title, 'Hostless');
    expect(metadata.canonicalUrl, isNull);
    expect(metadata.images, isEmpty);
  });
}
