import 'dart:convert';

import 'package:metalink/src/model/diagnostics.dart';
import 'package:metalink/src/options.dart';
import 'package:metalink/src/parse/metalink_parser.dart';
import 'package:metalink/src/result.dart';
import 'package:test/test.dart';

void main() {
  late MetaLinkParser parser;

  setUp(() {
    parser = MetaLinkParser();
  });

  test('parseHtml extracts metadata without a network client', () async {
    final result = await parser.parseHtml(
      '<title>Pure title</title>'
      '<meta property="og:image" content="/preview.png">',
      documentUrl: Uri.parse('https://example.com/article'),
    );

    expect(result.isSuccess, isTrue);
    expect(result.metadata.title, 'Pure title');
    expect(
      result.metadata.images.single.url,
      Uri.parse('https://example.com/preview.png'),
    );
    expect(result.diagnostics.fetch, isNull);
  });

  test('document identity remains separate from base URL resolution', () async {
    final result = await parser.parseHtml(
      '<base href="https://cdn.example.com/assets/">'
      '<meta property="og:type" content="website">'
      '<meta property="og:image" content="preview.png">',
      documentUrl: Uri.parse('https://example.com/'),
    );

    expect(result.metadata.kind.name, 'homepage');
    expect(
      result.metadata.images.single.url,
      Uri.parse('https://cdn.example.com/assets/preview.png'),
    );
  });

  test(
    'parseResponse uses web decoding and exposes decode diagnostics',
    () async {
      final prefix = ascii.encode(
        '<meta charset="windows-1252"><title>Price 10',
      );
      final suffix = ascii.encode('</title>');
      final result = await parser.parseResponse(
        <int>[...prefix, 0x80, ...suffix],
        requestedUrl: Uri.parse('https://example.com/start'),
        finalUrl: Uri.parse('https://example.com/final'),
        headers: const {'content-type': 'text/html'},
      );

      expect(result.metadata.title, 'Price 10€');
      expect(result.metadata.originalUrl.path, '/start');
      expect(result.metadata.resolvedUrl.path, '/final');
      expect(result.diagnostics.fetch?.detectedCharset, 'windows-1252');
      expect(result.diagnostics.fetch?.charsetSource, CharsetSource.meta);
    },
  );

  test('pure parser reports skipped remote enrichment explicitly', () async {
    final result = await parser.parseHtml(
      '<title>Local</title>',
      documentUrl: Uri.parse('https://example.com/'),
      options: const ExtractOptions(enableOEmbed: true, enableManifest: true),
    );

    expect(
      result.warnings.any(
        (warning) => warning.message.contains('skipped remote'),
      ),
      isTrue,
    );
    expect(result.status, ExtractionStatus.partial);
    expect(result.isSuccess, isTrue);
  });

  test('malformed structured data produces a partial parse result', () async {
    final result = await parser.parseHtml(
      '<title>Usable</title>'
      '<script type="application/ld+json">{bad</script>',
      documentUrl: Uri.parse('https://example.com/'),
    );

    expect(result.metadata.title, 'Usable');
    expect(result.status, ExtractionStatus.partial);
    expect(result.isSuccess, isTrue);
  });
}
