import 'dart:convert';

import 'package:metalink/src/model/diagnostics.dart';
import 'package:metalink/src/parse/web_decoder.dart';
import 'package:test/test.dart';

void main() {
  const decoder = WebDecoder();

  test('decodes Windows-1252 distinctly from Latin-1', () {
    final result = decoder.decode(
      const <int>[0x50, 0x72, 0x69, 0x63, 0x65, 0x3A, 0x20, 0x80],
      headers: const {'content-type': 'text/html; charset=windows-1252'},
    );

    expect(result.text, 'Price: €');
    expect(result.charset, 'windows-1252');
    expect(result.source, CharsetSource.header);
  });

  test('maps ISO-8859-1 web labels to Windows-1252', () {
    final result = decoder.decode(
      const <int>[0x80],
      headers: const {'content-type': 'text/html; charset=iso-8859-1'},
    );

    expect(result.text, '€');
    expect(result.charset, 'windows-1252');
  });

  test(
    'BOM takes precedence over conflicting header and meta declarations',
    () {
      final body = utf8.encode('<meta charset="windows-1252">€');
      final result = decoder.decode(
        <int>[0xEF, 0xBB, 0xBF, ...body],
        headers: const {'content-type': 'text/html; charset=windows-1252'},
      );

      expect(result.text, '<meta charset="windows-1252">€');
      expect(result.charset, 'utf-8');
      expect(result.source, CharsetSource.bom);
    },
  );

  test('HTTP header takes precedence over a conflicting meta declaration', () {
    final asciiPrefix = ascii.encode('<meta charset="utf-8">');
    final result = decoder.decode(
      <int>[...asciiPrefix, 0x80],
      headers: const {'content-type': 'text/html; charset=windows-1252'},
    );

    expect(result.text, '<meta charset="utf-8">€');
    expect(result.source, CharsetSource.header);
  });

  test('uses a supported meta charset when the header omits one', () {
    final prefix = ascii.encode(
      '<meta content="ignored" charset="windows-1252">',
    );
    final result = decoder.decode(
      <int>[...prefix, 0x80],
      headers: const {'content-type': 'text/html'},
    );

    expect(result.text, '<meta content="ignored" charset="windows-1252">€');
    expect(result.source, CharsetSource.meta);
  });

  test('accepts content-type http-equiv regardless of attribute order', () {
    final prefix = ascii.encode(
      '<meta content="text/html; charset=windows-1252" '
      'http-equiv="Content-Type">',
    );
    final result = decoder.decode(
      <int>[...prefix, 0x80],
      headers: const {'content-type': 'text/html'},
    );

    expect(result.text, endsWith('€'));
    expect(result.charset, 'windows-1252');
    expect(result.source, CharsetSource.meta);
  });

  test('ignores charset text in unrelated meta content attributes', () {
    const html =
        '<meta name="description" '
        'content="text/html; charset=windows-1252">€';
    final result = decoder.decode(
      utf8.encode(html),
      headers: const {'content-type': 'text/html'},
    );

    expect(result.text, html);
    expect(result.charset, 'utf-8');
    expect(result.source, CharsetSource.fallback);
  });
}
