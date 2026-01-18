import 'package:metalink/src/extract/extractors/open_graph_extractor.dart';
import 'package:metalink/src/model/link_metadata.dart';
import 'package:test/test.dart';

import '../../../support/fixture_loader.dart';
import '../../../support/test_helpers.dart';

void main() {
  test('extracts OpenGraph fields', () async {
    final html = readFixture('html/basic_og.html');
    final metadata = await runPipeline(
      html: html,
      stages: const [OpenGraphExtractor()],
    );

    expect(metadata.title, 'OG Title');
    expect(metadata.description, 'OG Description');
    expect(metadata.siteName, 'OG Site');
    expect(metadata.locale, 'en_US');
    expect(metadata.canonicalUrl.toString(), 'https://example.com/canonical');
    expect(metadata.kind, LinkKind.article);
    expect(metadata.images.length, 1);
    expect(metadata.images.first.width, 1200);
    expect(metadata.images.first.height, 630);
    expect(metadata.images.first.alt, 'Alt Text');
    expect(metadata.videos.length, 1);
    expect(metadata.audios.length, 1);
    expect(metadata.publishedAt, DateTime.parse('2024-01-01T12:00:00Z'));
    expect(metadata.modifiedAt, DateTime.parse('2024-01-02T12:00:00Z'));
    expect(metadata.keywords, containsAll(['Tag One', 'Tag Two']));
  });

  test('maps og:type website to homepage for root url', () async {
    const html = '<meta property="og:type" content="website">'
        '<meta property="og:title" content="Home">';
    final metadata = await runPipeline(
      html: html,
      stages: const [OpenGraphExtractor()],
      originalUrl: Uri.parse('https://example.com/'),
    );
    expect(metadata.kind, LinkKind.homepage);
  });

  test('parses epoch timestamps', () async {
    const html = '<meta property="article:published_time" content="1700000000">'
        '<meta property="og:updated_time" content="1700000000000">';
    final metadata = await runPipeline(
      html: html,
      stages: const [OpenGraphExtractor()],
    );
    expect(metadata.publishedAt, isNotNull);
    expect(metadata.modifiedAt, isNotNull);
  });
}
