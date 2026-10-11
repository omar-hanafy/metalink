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
    const html =
        '<meta property="og:type" content="website">'
        '<meta property="og:title" content="Home">';
    final metadata = await runPipeline(
      html: html,
      stages: const [OpenGraphExtractor()],
      originalUrl: Uri.parse('https://example.com/'),
    );
    expect(metadata.kind, LinkKind.homepage);
  });

  test('parses epoch timestamps', () async {
    const html =
        '<meta property="article:published_time" content="1700000000">'
        '<meta property="og:updated_time" content="1700000000000">';
    final metadata = await runPipeline(
      html: html,
      stages: const [OpenGraphExtractor()],
    );
    expect(metadata.publishedAt, isNotNull);
    expect(metadata.modifiedAt, isNotNull);
  });

  test('keeps og:image:secure_url attached to its root image', () async {
    const html =
        '<meta property="og:image" content="http://example.com/image.png">'
        '<meta property="og:image:secure_url" content="https://example.com/image.png">'
        '<meta property="og:image:width" content="1200">'
        '<meta property="og:image:height" content="630">'
        '<meta property="og:image:alt" content="Preview">';
    final metadata = await runPipeline(
      html: html,
      stages: const [OpenGraphExtractor()],
    );

    expect(metadata.images, hasLength(1));
    expect(metadata.images.single.url.scheme, 'https');
    expect(metadata.images.single.width, 1200);
    expect(metadata.images.single.height, 630);
    expect(metadata.images.single.alt, 'Preview');
  });

  test('an out-of-range epoch date does not abort the stage', () async {
    const html = '''
<html><head>
  <meta property="og:title" content="Title">
  <meta property="article:published_time" content="99999999999999999">
  <meta property="article:modified_time" content="2024-01-02T12:00:00Z">
  <meta property="article:tag" content="dart">
</head></html>
''';
    final metadata = await runPipeline(
      html: html,
      stages: const [OpenGraphExtractor()],
    );

    expect(metadata.publishedAt, isNull);
    expect(metadata.modifiedAt, DateTime.utc(2024, 1, 2, 12));
    expect(metadata.keywords, ['dart']);
  });

  group('rejected og:image roots', () {
    for (final rejected in <String>[
      'data:image/png;base64,AAAA',
      'javascript:alert(1)',
      '',
    ]) {
      test(
        '"$rejected" does not leak properties onto the previous image',
        () async {
          final html =
              '<meta property="og:image" content="https://example.com/a.jpg">'
              '<meta property="og:image:width" content="1200">'
              '<meta property="og:image:alt" content="A alt">'
              '<meta property="og:image" content="$rejected">'
              '<meta property="og:image:width" content="16">'
              '<meta property="og:image:height" content="16">'
              '<meta property="og:image:type" content="image/png">'
              '<meta property="og:image:alt" content="tiny inline">'
              '<meta property="og:image" content="https://example.com/b.jpg">'
              '<meta property="og:image:width" content="800">';
          final metadata = await runPipeline(
            html: html,
            stages: const [OpenGraphExtractor()],
          );

          expect(metadata.images, hasLength(2));
          final a = metadata.images.first;
          expect(a.url.toString(), 'https://example.com/a.jpg');
          expect(a.width, 1200);
          expect(a.height, isNull);
          expect(a.mimeType, isNull);
          expect(a.alt, 'A alt');
          final b = metadata.images.last;
          expect(b.url.toString(), 'https://example.com/b.jpg');
          expect(b.width, 800);
          expect(b.height, isNull);
          expect(b.alt, isNull);
        },
      );
    }

    test('a secure_url after a rejected root does not replace the previous '
        'image', () async {
      const html =
          '<meta property="og:image" content="https://example.com/a.jpg">'
          '<meta property="og:image" content="data:image/png;base64,AAAA">'
          '<meta property="og:image:secure_url" '
          'content="https://example.com/secure.jpg">'
          '<meta property="og:image:width" content="640">';
      final metadata = await runPipeline(
        html: html,
        stages: const [OpenGraphExtractor()],
      );

      expect(metadata.images.map((image) => image.url.toString()), [
        'https://example.com/a.jpg',
        'https://example.com/secure.jpg',
      ]);
      expect(metadata.images.first.width, isNull);
      expect(metadata.images.last.width, 640);
    });
  });

  test('non-positive og:image dimensions are treated as absent', () async {
    const html =
        '<meta property="og:image" content="https://example.com/a.jpg">'
        '<meta property="og:image:width" content="-1200">'
        '<meta property="og:image:height" content="0">'
        '<meta property="og:image" content="https://example.com/b.jpg">'
        '<meta property="og:image:width" content="800">'
        '<meta property="og:image:width" content="0">'
        '<meta property="og:image:height" content="600">';
    final metadata = await runPipeline(
      html: html,
      stages: const [OpenGraphExtractor()],
    );

    expect(metadata.images, hasLength(2));
    expect(metadata.images.first.width, isNull);
    expect(metadata.images.first.height, isNull);
    expect(metadata.images.last.width, 800);
    expect(metadata.images.last.height, 600);
  });

  group('structured og:video and og:audio', () {
    test('secure_url attaches to the root video with its properties', () async {
      const html =
          '<meta property="og:video" content="http://example.com/v.mp4">'
          '<meta property="og:video:secure_url" '
          'content="https://example.com/v.mp4">'
          '<meta property="og:video:type" content="video/mp4">'
          '<meta property="og:video:width" content="1280">'
          '<meta property="og:video:height" content="720">'
          '<meta property="og:video" content="https://example.com/w.webm">'
          '<meta property="og:video:type" content="video/webm">';
      final metadata = await runPipeline(
        html: html,
        stages: const [OpenGraphExtractor()],
      );

      expect(metadata.videos, hasLength(2));
      final first = metadata.videos.first;
      expect(first.url.toString(), 'https://example.com/v.mp4');
      expect(first.mimeType, 'video/mp4');
      expect(first.width, 1280);
      expect(first.height, 720);
      final second = metadata.videos.last;
      expect(second.url.toString(), 'https://example.com/w.webm');
      expect(second.mimeType, 'video/webm');
      expect(second.width, isNull);
      expect(second.height, isNull);
    });

    test('secure_url attaches to the root audio with its type', () async {
      const html =
          '<meta property="og:audio" content="http://example.com/a.mp3">'
          '<meta property="og:audio:secure_url" '
          'content="https://example.com/a.mp3">'
          '<meta property="og:audio:type" content="audio/mpeg">';
      final metadata = await runPipeline(
        html: html,
        stages: const [OpenGraphExtractor()],
      );

      expect(metadata.audios, hasLength(1));
      expect(
        metadata.audios.single.url.toString(),
        'https://example.com/a.mp3',
      );
      expect(metadata.audios.single.mimeType, 'audio/mpeg');
    });

    test('a rejected video root drops its properties', () async {
      const html =
          '<meta property="og:video" content="https://example.com/v.mp4">'
          '<meta property="og:video:type" content="video/mp4">'
          '<meta property="og:video" content="javascript:void(0)">'
          '<meta property="og:video:type" content="text/html">'
          '<meta property="og:video:width" content="1">'
          '<meta property="og:audio" content="https://example.com/a.mp3">'
          '<meta property="og:audio" content="">'
          '<meta property="og:audio:type" content="audio/ogg">';
      final metadata = await runPipeline(
        html: html,
        stages: const [OpenGraphExtractor()],
      );

      expect(metadata.videos, hasLength(1));
      expect(metadata.videos.single.mimeType, 'video/mp4');
      expect(metadata.videos.single.width, isNull);
      expect(metadata.audios, hasLength(1));
      expect(metadata.audios.single.mimeType, isNull);
    });

    test('non-positive video dimensions are treated as absent', () async {
      const html =
          '<meta property="og:video" content="https://example.com/v.mp4">'
          '<meta property="og:video:width" content="0">'
          '<meta property="og:video:height" content="-5">';
      final metadata = await runPipeline(
        html: html,
        stages: const [OpenGraphExtractor()],
      );

      expect(metadata.videos.single.width, isNull);
      expect(metadata.videos.single.height, isNull);
    });
  });

  test('matches Open Graph properties ASCII case-insensitively', () async {
    const html =
        '<meta property="OG:Title" content="Upper Title">'
        '<meta property="Og:Description" content="Upper Description">'
        '<meta name="OG:SITE_NAME" content="Upper Site">'
        '<meta property="OG:URL" content="https://example.com/canonical">'
        '<meta property="OG:TYPE" content="article">'
        '<meta property="OG:IMAGE" content="https://example.com/a.jpg">'
        '<meta property="OG:IMAGE:WIDTH" content="1200">'
        '<meta property="OG:VIDEO" content="https://example.com/v.mp4">'
        '<meta property="Article:Tag" content="dart">';
    final metadata = await runPipeline(
      html: html,
      stages: const [OpenGraphExtractor()],
    );

    expect(metadata.title, 'Upper Title');
    expect(metadata.description, 'Upper Description');
    expect(metadata.siteName, 'Upper Site');
    expect(metadata.canonicalUrl.toString(), 'https://example.com/canonical');
    expect(metadata.kind, LinkKind.article);
    expect(metadata.images.single.width, 1200);
    expect(metadata.videos, hasLength(1));
    expect(metadata.keywords, ['dart']);
  });

  test(
    'an empty first tag does not hide a later non-empty duplicate',
    () async {
      const html =
          '<meta property="og:title" content="">'
          '<meta property="og:title" content="Real OG">'
          '<meta property="og:description" content="   ">'
          '<meta name="og:description" content="Real description">'
          '<meta property="og:url" content="javascript:void(0)">'
          '<meta property="og:url" content="https://example.com/canonical">';
      final metadata = await runPipeline(
        html: html,
        stages: const [OpenGraphExtractor()],
      );

      expect(metadata.title, 'Real OG');
      expect(metadata.description, 'Real description');
      expect(metadata.canonicalUrl.toString(), 'https://example.com/canonical');
    },
  );

  group('EXT-R2-3 unparseable dates', () {
    test(
      'an unparseable article time falls back to og:published_time',
      () async {
        const html =
            '<meta property="article:published_time" content="not a date">'
            '<meta property="og:published_time" content="2024-05-01T10:00:00Z">'
            '<meta property="article:modified_time" content="soon">'
            '<meta property="og:updated_time" content="2024-05-02T10:00:00Z">';
        final metadata = await runPipeline(
          html: html,
          stages: const [OpenGraphExtractor()],
        );

        expect(metadata.publishedAt, DateTime.utc(2024, 5, 1, 10));
        expect(metadata.modifiedAt, DateTime.utc(2024, 5, 2, 10));
      },
    );

    test('a later duplicate of the same key is used', () async {
      const html =
          '<meta property="article:published_time" content="TBD">'
          '<meta property="article:published_time" '
          'content="2024-05-01T10:00:00Z">';
      final metadata = await runPipeline(
        html: html,
        stages: const [OpenGraphExtractor()],
      );

      expect(metadata.publishedAt, DateTime.utc(2024, 5, 1, 10));
    });
  });

  group('EXT-R2-5 tabs and newlines in URLs', () {
    test('are removed from og:image and og:url', () async {
      const html =
          '<meta property="og:image" content="https://example.com/a\n/b.jpg">'
          '<meta property="og:image:secure_url" '
          'content="https://example.com/secure\t/b.jpg">'
          '<meta property="og:url" content="https://example.com/\r\ncanonical">';
      final metadata = await runPipeline(
        html: html,
        stages: const [OpenGraphExtractor()],
      );

      expect(
        metadata.images.single.url.toString(),
        'https://example.com/secure/b.jpg',
      );
      expect(metadata.canonicalUrl.toString(), 'https://example.com/canonical');
    });

    test('are removed from an og:image root', () async {
      const html =
          '<meta property="og:image" content="https://example.com/a\n  /b.jpg">';
      final metadata = await runPipeline(
        html: html,
        stages: const [OpenGraphExtractor()],
      );

      // Spaces are kept (and percent-encoded); only tabs and newlines go.
      expect(
        metadata.images.single.url.toString(),
        'https://example.com/a%20%20/b.jpg',
      );
    });
  });
}
