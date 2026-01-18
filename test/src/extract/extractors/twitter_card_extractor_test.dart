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
}
