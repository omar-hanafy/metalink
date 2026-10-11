import 'package:metalink/src/extract/extractors/twitter_card_extractor.dart';
import 'package:test/test.dart';

import '../../../support/fixture_loader.dart';
import '../../../support/test_helpers.dart';

void main() {
  test('extracts Twitter card fields', () async {
    final html = readFixture('html/twitter_card.html');
    final metadata = await runPipeline(
      html: html,
      stages: const [TwitterCardExtractor()],
    );

    expect(metadata.title, 'Twitter Title');
    expect(metadata.description, 'Twitter Description');
    expect(metadata.author, '@creator');
    expect(metadata.images.length, 1);
    expect(metadata.images.first.url.toString(), 'https://example.com/tw.png');
    expect(metadata.videos.length, 1);
    expect(metadata.videos.first.url.toString(), 'https://example.com/player');
  });

  test('matches Twitter names ASCII case-insensitively', () async {
    const html =
        '<meta name="Twitter:Title" content="Mixed Title">'
        '<meta name="TWITTER:DESCRIPTION" content="Mixed Description">'
        '<meta property="Twitter:Image" content="https://example.com/tw.png">';
    final metadata = await runPipeline(
      html: html,
      stages: const [TwitterCardExtractor()],
    );

    expect(metadata.title, 'Mixed Title');
    expect(metadata.description, 'Mixed Description');
    expect(metadata.images.single.url.toString(), 'https://example.com/tw.png');
  });

  test(
    'an empty first tag does not hide a later non-empty duplicate',
    () async {
      const html =
          '<meta name="twitter:title" content="">'
          '<meta name="twitter:title" content="Second Title">';
      final metadata = await runPipeline(
        html: html,
        stages: const [TwitterCardExtractor()],
      );

      expect(metadata.title, 'Second Title');
    },
  );

  test('an unresolvable twitter:image falls back to twitter:image:src', () async {
    const html =
        '<meta name="twitter:image" content="data:image/png;base64,AAAA">'
        '<meta name="twitter:image:src" content="https://example.com/src.png">';
    final metadata = await runPipeline(
      html: html,
      stages: const [TwitterCardExtractor()],
    );

    expect(
      metadata.images.single.url.toString(),
      'https://example.com/src.png',
    );
  });

  test('EXT-R2-5 removes newlines from twitter:image', () async {
    const html =
        '<meta name="twitter:image" content="https://example.com/\ntw.png">';
    final metadata = await runPipeline(
      html: html,
      stages: const [TwitterCardExtractor()],
    );

    expect(metadata.images.single.url.toString(), 'https://example.com/tw.png');
  });
}
