import 'package:metalink/src/extract/extractors/json_ld_extractor.dart';
import 'package:metalink/src/model/link_metadata.dart';
import 'package:test/test.dart';

import '../../../support/fixture_loader.dart';
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
    expect(metadata.images.first.url.toString(),
        'https://example.com/img-json.png');
    expect(metadata.keywords, containsAll(['alpha', 'beta']));
  });

  test('handles @graph and arrays', () async {
    const html = '<script type="application/ld+json">'
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
  });

  test('ignores invalid JSON-LD', () async {
    const html = '<script type="application/ld+json">{bad</script>';
    final metadata = await runPipeline(
      html: html,
      stages: const [JsonLdExtractor()],
    );
    expect(metadata.isEmpty, isTrue);
  });
}
