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
    expect(
      metadata.publishedAt!.toUtc(),
      DateTime.parse('2024-01-03T10:00:00').toUtc(),
    );
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
}
