import 'package:metalink/src/extract/extractors/standard_meta_extractor.dart';
import 'package:test/test.dart';

import '../../../support/fixture_loader.dart';
import '../../../support/test_helpers.dart';

void main() {
  test('extracts standard meta fields', () async {
    final html = readFixture('html/standard_meta.html');
    final metadata = await runPipeline(
      html: html,
      stages: const [StandardMetaExtractor()],
    );

    expect(metadata.title, 'Standard Title');
    expect(metadata.description, 'Standard Description');
    expect(metadata.siteName, 'Standard App');
    expect(metadata.locale, 'en');
    expect(metadata.author, 'Author Name');
    expect(metadata.keywords, ['alpha', 'beta', 'gamma']);
    // The fixture's published time has no zone designator, so it is read as
    // UTC regardless of the host time zone.
    expect(metadata.publishedAt, DateTime.utc(2024, 1, 3, 10));
    expect(metadata.modifiedAt, DateTime.parse('2024-01-04T10:00:00Z'));
  });

  test('uses h1 as fallback title', () async {
    const html = '<h1>Heading Title</h1>';
    final metadata = await runPipeline(
      html: html,
      stages: const [StandardMetaExtractor()],
    );
    expect(metadata.title, 'Heading Title');
  });

  test('matches name and http-equiv ASCII case-insensitively', () async {
    const html =
        '<meta name="Description" content="Mixed Description">'
        '<meta http-equiv="Content-Language" content="fr">'
        '<meta name="Keywords" content="alpha, beta">'
        '<meta name="Author" content="Mixed Author">'
        '<meta name="APPLICATION-NAME" content="Mixed App">';
    final metadata = await runPipeline(
      html: html,
      stages: const [StandardMetaExtractor()],
    );

    expect(metadata.description, 'Mixed Description');
    expect(metadata.locale, 'fr');
    expect(metadata.keywords, ['alpha', 'beta']);
    expect(metadata.author, 'Mixed Author');
    expect(metadata.siteName, 'Mixed App');
  });

  test(
    'an empty first tag does not hide a later non-empty duplicate',
    () async {
      const html =
          '<meta name="description" content="">'
          '<meta name="description" content="Second Description">'
          '<meta name="author" content=" ">'
          '<meta name="author" content="Second Author">';
      final metadata = await runPipeline(
        html: html,
        stages: const [StandardMetaExtractor()],
      );

      expect(metadata.description, 'Second Description');
      expect(metadata.author, 'Second Author');
    },
  );

  test(
    'EXT-R2-3 an unparseable date falls back to a lower-priority key',
    () async {
      const html =
          '<meta name="date" content="Monday">'
          '<meta itemprop="datePublished" content="2024-05-01">'
          '<meta name="last-modified" content="yesterday">'
          '<meta name="last-modified" content="2024-05-02T00:00:00Z">';
      final metadata = await runPipeline(
        html: html,
        stages: const [StandardMetaExtractor()],
      );

      expect(metadata.publishedAt, DateTime.utc(2024, 5, 1));
      expect(metadata.modifiedAt, DateTime.utc(2024, 5, 2));
    },
  );

  test('EXT-R2-3 key priority still wins over document order', () async {
    const html =
        '<meta property="article:published_time" content="2023-01-01">'
        '<meta name="pubdate" content="2024-05-01">';
    final metadata = await runPipeline(
      html: html,
      stages: const [StandardMetaExtractor()],
    );

    expect(metadata.publishedAt, DateTime.utc(2024, 5, 1));
  });

  group('EXT-R2-4 document title', () {
    test('ignores an inline SVG title', () async {
      const html =
          '<body><svg><title>Close icon</title></svg>'
          '<h1>Real Heading</h1></body>';
      final metadata = await runPipeline(
        html: html,
        stages: const [StandardMetaExtractor()],
      );

      expect(metadata.title, 'Real Heading');
    });

    test('an HTML title still wins after an SVG title', () async {
      const html =
          '<html><body><svg><title>Close icon</title></svg>'
          '<title>Page Title</title><h1>Heading</h1></body></html>';
      final metadata = await runPipeline(
        html: html,
        stages: const [StandardMetaExtractor()],
      );

      expect(metadata.title, 'Page Title');
    });
  });
}
