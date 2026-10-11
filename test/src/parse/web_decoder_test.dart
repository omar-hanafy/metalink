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

  group('replacement decoding instead of a whole-document fallback', () {
    test('windows-1252 decodes every byte per the WHATWG index', () {
      final result = _decodeWithHeader(
        List<int>.generate(256, (byte) => byte),
        'windows-1252',
      );

      _expectDecoded(
        result,
        text: String.fromCharCodes(<int>[
          for (var byte = 0x00; byte < 0x80; byte++) byte,
          ..._whatwgWindows1252C1,
          for (var byte = 0xA0; byte <= 0xFF; byte++) byte,
        ]),
        charset: 'windows-1252',
      );
    });

    for (final label in const [
      'windows-1252',
      'iso-8859-1',
      'latin1',
      'ascii',
      'us-ascii',
    ]) {
      test('$label keeps bytes undefined in windows-1252 as C1 controls', () {
        final result = _decodeWithHeader(const <int>[
          0x41,
          0x81,
          0x8D,
          0x8F,
          0x90,
          0x9D,
          0x80,
        ], label);

        _expectDecoded(
          result,
          text: 'A\u0081\u008D\u008F\u0090\u009D€',
          charset: 'windows-1252',
        );
      });
    }

    test('meta-declared windows-1252 keeps undefined bytes', () {
      final result = const WebDecoder().decode(
        _withMeta('windows-1252', const <int>[0x81, 0x80]),
      );

      _expectDecoded(
        result,
        text: '<meta charset="windows-1252">\u0081€',
        charset: 'windows-1252',
        source: CharsetSource.meta,
      );
    });

    test('other single-byte code pages replace undefined bytes', () {
      final result = _decodeWithHeader(const <int>[
        0x41,
        0xAA,
        0xE1,
      ], 'windows-1253');

      _expectDecoded(result, text: 'A\uFFFDα', charset: 'windows-1253');
    });

    test('Shift_JIS truncated mid-character keeps its encoding', () {
      final result = _decodeWithHeader(const <int>[
        0x41,
        0x93,
        0xFA,
        0x96,
        0x7B,
        0x93,
      ], 'shift_jis');

      _expectDecoded(result, text: 'A日本\uFFFD', charset: 'shift_jis');
    });

    test('GBK truncated mid-character keeps its encoding', () {
      final result = _decodeWithHeader(const <int>[
        0x41,
        0xD6,
        0xD0,
        0xCE,
        0xC4,
        0xD6,
      ], 'gbk');

      _expectDecoded(result, text: 'A中文\uFFFD', charset: 'gbk');
    });

    test('EUC-JP truncated mid-character keeps its encoding', () {
      final result = _decodeWithHeader(const <int>[
        0x41,
        0xC6,
        0xFC,
        0xCB,
        0xDC,
        0xC6,
      ], 'euc-jp');

      _expectDecoded(result, text: 'A日本\uFFFD', charset: 'euc-jp');
    });

    test('EUC-JP three-byte sequence truncated after its lead byte', () {
      final result = _decodeWithHeader(const <int>[0x41, 0x8F, 0xA2], 'euc-jp');

      _expectDecoded(result, text: 'A\uFFFD', charset: 'euc-jp');
    });

    test('meta-declared Shift_JIS truncated mid-character keeps it', () {
      final result = const WebDecoder().decode(
        _withMeta('shift_jis', const <int>[0x93, 0xFA, 0x96]),
      );

      _expectDecoded(
        result,
        text: '<meta charset="shift_jis">日\uFFFD',
        charset: 'shift_jis',
        source: CharsetSource.meta,
      );
    });

    test('an invalid GBK sequence mid-document is replaced', () {
      final result = _decodeWithHeader(const <int>[
        0xD6,
        0xD0,
        0xFF,
        0xFF,
        0xCE,
        0xC4,
      ], 'gbk');

      _expectDecoded(result, text: '中\uFFFD\uFFFD文', charset: 'gbk');
    });

    test('an invalid Shift_JIS byte mid-document is replaced', () {
      final result = _decodeWithHeader(const <int>[
        0x41,
        0x80,
        0x93,
        0xFA,
      ], 'shift_jis');

      _expectDecoded(result, text: 'A\u0080日', charset: 'shift_jis');
    });

    test('an invalid EUC-JP sequence mid-document is replaced', () {
      final result = _decodeWithHeader(const <int>[
        0xC6,
        0xFC,
        0xA1,
        0x20,
        0xCB,
        0xDC,
      ], 'euc-jp');

      _expectDecoded(result, text: '日\uFFFD 本', charset: 'euc-jp');
    });

    test('an invalid byte near the end keeps the characters after it', () {
      final result = _decodeWithHeader(const <int>[
        0xC6,
        0xFC,
        0xA1,
        0x20,
        0x42,
      ], 'euc-jp');

      _expectDecoded(result, text: '日\uFFFD B', charset: 'euc-jp');
    });
  });

  group('EUC-KR', () {
    const eucKrHangul = <int>[0xC7, 0xD1, 0xB1, 0xB9, 0xBE, 0xEE];

    for (final label in const [
      'euc-kr',
      'cseuckr',
      'csksc56011987',
      'iso-ir-149',
      'korean',
      'ks_c_5601-1987',
      'ks_c_5601-1989',
      'ksc5601',
      'ksc_5601',
      'windows-949',
      'cp949',
    ]) {
      test('$label header is unsupported instead of decoding mojibake', () {
        final result = _decodeWithHeader(eucKrHangul, label);

        expect(result.text, isNot(contains('ꁐ蝡陳')));
        _expectDecoded(
          result,
          text: utf8.decode(eucKrHangul, allowMalformed: true),
          charset: 'utf-8',
          source: CharsetSource.fallback,
        );
        expect(result.usedFallback, isTrue);
      });
    }

    test('meta-declared EUC-KR is unsupported instead of mojibake', () {
      final bytes = _withMeta('euc-kr', eucKrHangul);
      final result = const WebDecoder().decode(bytes);

      expect(result.charset, 'utf-8');
      expect(result.source, CharsetSource.fallback);
      expect(result.text, isNot(contains('ꁐ蝡陳')));
    });
  });

  group('UTF-16 labels', () {
    for (final label in const ['utf-16', 'utf-16le', 'utf-16be']) {
      test('meta-declared $label is treated as UTF-8', () {
        final bytes = <int>[
          ...ascii.encode('<meta charset="$label"><title>'),
          ...utf8.encode('Café'),
        ];
        final result = const WebDecoder().decode(bytes);

        _expectDecoded(
          result,
          text: '<meta charset="$label"><title>Café',
          charset: 'utf-8',
          source: CharsetSource.meta,
        );
      });
    }

    for (final label in const [
      'utf-16',
      'utf-16le',
      'unicode',
      'unicodefeff',
      'ucs-2',
      'csunicode',
      'iso-10646-ucs-2',
    ]) {
      test('$label header without a BOM is little-endian', () {
        final result = _decodeWithHeader(const <int>[
          0x48,
          0x00,
          0x69,
          0x00,
        ], label);

        _expectDecoded(result, text: 'Hi', charset: 'utf-16le');
      });
    }

    for (final label in const ['utf-16be', 'unicodefffe']) {
      test('$label header without a BOM is big-endian', () {
        final result = _decodeWithHeader(const <int>[
          0x00,
          0x48,
          0x00,
          0x69,
        ], label);

        _expectDecoded(result, text: 'Hi', charset: 'utf-16be');
      });
    }
  });

  group('WHATWG label resolution', () {
    for (final label in const [
      'utf-8',
      'utf8',
      'unicode-1-1-utf-8',
      'unicode11utf8',
      'unicode20utf8',
      'x-unicode20utf8',
    ]) {
      test('$label resolves to utf-8', () {
        final result = _decodeWithHeader(utf8.encode('Café'), label);

        _expectDecoded(result, text: 'Café', charset: 'utf-8');
      });
    }

    for (final label in const [
      'ansi_x3.4-1968',
      'ascii',
      'cp1252',
      'cp819',
      'csisolatin1',
      'ibm819',
      'iso-8859-1',
      'iso-ir-100',
      'iso8859-1',
      'iso88591',
      'iso_8859-1',
      'iso_8859-1:1987',
      'l1',
      'latin1',
      'us-ascii',
      'windows-1252',
      'x-cp1252',
    ]) {
      test('$label resolves to windows-1252', () {
        final result = _decodeWithHeader(const <int>[0x80, 0x9F], label);

        _expectDecoded(result, text: '€Ÿ', charset: 'windows-1252');
      });
    }

    for (final label in const [
      'chinese',
      'csgb2312',
      'csiso58gb231280',
      'gb2312',
      'gb_2312',
      'gb_2312-80',
      'gbk',
      'iso-ir-58',
      'x-gbk',
    ]) {
      test('$label decodes through gbk', () {
        final result = _decodeWithHeader(const <int>[0xD6, 0xD0], label);

        _expectDecoded(result, text: '中', charset: 'gbk');
      });
    }

    test('gb18030 resolves to gb18030', () {
      final result = _decodeWithHeader(const <int>[
        0xD6,
        0xD0,
        0x81,
        0x30,
        0x81,
        0x30,
      ], 'gb18030');

      _expectDecoded(result, text: '中\u0080', charset: 'gb18030');
    });

    for (final label in const [
      'csshiftjis',
      'ms932',
      'ms_kanji',
      'shift-jis',
      'shift_jis',
      'sjis',
      'windows-31j',
      'x-sjis',
    ]) {
      test('$label resolves to shift_jis', () {
        final result = _decodeWithHeader(const <int>[0x93, 0xFA], label);

        _expectDecoded(result, text: '日', charset: 'shift_jis');
      });
    }

    for (final label in const ['cseucpkdfmtjapanese', 'euc-jp', 'x-euc-jp']) {
      test('$label resolves to euc-jp', () {
        final result = _decodeWithHeader(const <int>[0xC6, 0xFC], label);

        _expectDecoded(result, text: '日', charset: 'euc-jp');
      });
    }

    _singleByteLabels.forEach((canonical, labels) {
      for (final label in labels) {
        test('$label resolves to $canonical', () {
          _expectDecoded(
            _decodeWithHeader(const <int>[0x41], label),
            text: 'A',
            charset: canonical,
          );
        });
      }
    });

    for (final label in const ['koi8-r', 'big5', 'iso-2022-jp', 'euc-kr']) {
      test('unsupported $label takes the fallback path', () {
        final result = _decodeWithHeader(ascii.encode('Hi'), label);

        _expectDecoded(
          result,
          text: 'Hi',
          charset: 'utf-8',
          source: CharsetSource.fallback,
        );
      });
    }

    test('non-WHATWG code pages supported by the dependency still decode', () {
      _expectDecoded(
        _decodeWithHeader(const <int>[0x80], 'cp437'),
        text: 'Ç',
        charset: 'cp437',
      );
      _expectDecoded(
        _decodeWithHeader(const <int>[0xD6, 0xD0], 'cp936'),
        text: '中',
        charset: 'gbk',
      );
    });

    test('dependency code pages decode every ASCII byte as itself', () {
      // The dependency's tables map DEL (0x7F) to U+FFFD.
      final ascii = <int>[for (var byte = 0; byte < 0x80; byte++) byte];
      for (final label in const ['cp437', 'cp850', 'ibm852', 'cp1125']) {
        final result = _decodeWithHeader(<int>[...ascii, 0x80], label);
        expect(result.text.codeUnits.take(0x80), ascii, reason: label);
        expect(result.text.codeUnitAt(0x80), isNot(0xFFFD), reason: label);
        expect(result.charset, isNot('utf-8'), reason: label);
      }
    });

    test('labels are matched case-insensitively', () {
      _expectDecoded(
        _decodeWithHeader(const <int>[0x93, 0xFA], 'Windows-31J'),
        text: '日',
        charset: 'shift_jis',
      );
    });
  });

  group('WHATWG GBK and gb18030 decoding', () {
    test('0x80 decodes as the euro sign without swallowing markup', () {
      final bytes = <int>[
        ...ascii.encode('<title>100'),
        0x80,
        ...ascii.encode('</title><meta name="a">'),
      ];

      _expectDecoded(
        _decodeWithHeader(bytes, 'gbk'),
        text: '<title>100€</title><meta name="a">',
        charset: 'gbk',
      );
    });

    test('an invalid lead byte keeps the ASCII byte after it', () {
      _expectDecoded(
        _decodeWithHeader(const <int>[0xD6, 0xD0, 0xFF, 0x3C, 0x62], 'gbk'),
        text: '中\uFFFD<b',
        charset: 'gbk',
      );
    });

    test('a lead byte followed by ASCII keeps that ASCII byte', () {
      _expectDecoded(
        _decodeWithHeader(const <int>[0x81, 0x3C, 0x62], 'gbk'),
        text: '\uFFFD<b',
        charset: 'gbk',
      );
    });

    for (final label in const ['gbk', 'gb18030']) {
      test('$label decodes four-byte sequences', () {
        _expectDecoded(
          _decodeWithHeader(const <int>[
            ...[0x81, 0x30, 0x81, 0x30],
            ...[0x84, 0x31, 0xA4, 0x39],
            ...[0x90, 0x30, 0x81, 0x30],
            ...[0xE3, 0x32, 0x9A, 0x35],
            ...[0x81, 0x35, 0xF4, 0x37],
          ], label),
          text: '\u0080\uFFFF\u{10000}\u{10FFFF}\uE7C7',
          charset: label,
        );
      });
    }

    test('a four-byte pointer outside the ranges is one replacement', () {
      _expectDecoded(
        _decodeWithHeader(const <int>[0xFE, 0x39, 0xFE, 0x39, 0x41], 'gbk'),
        text: '\uFFFDA',
        charset: 'gbk',
      );
    });

    test('a broken four-byte sequence restores its bytes', () {
      _expectDecoded(
        _decodeWithHeader(const <int>[0x81, 0x30, 0x41], 'gbk'),
        text: '\uFFFD0A',
        charset: 'gbk',
      );
    });

    test('uses the WHATWG index where the dependency table differs', () {
      _expectDecoded(
        _decodeWithHeader(const <int>[0xA6, 0xD9, 0xA3, 0xA0], 'gbk'),
        text: '\uFE10\u3000',
        charset: 'gbk',
      );
    });

    test('a truncated lead byte at the end keeps the ASCII before it', () {
      _expectDecoded(
        _decodeWithHeader(<int>[...ascii.encode('<b>x'), 0x81], 'gbk'),
        text: '<b>x\uFFFD',
        charset: 'gbk',
      );
    });
  });

  group('WHATWG Shift_JIS decoding', () {
    test('an invalid lead byte keeps the ASCII byte after it', () {
      _expectDecoded(
        _decodeWithHeader(const <int>[0x93, 0x3C, 0x62], 'shift_jis'),
        text: '\uFFFD<b',
        charset: 'shift_jis',
      );
    });

    test('single bytes outside the lead ranges follow WHATWG', () {
      _expectDecoded(
        _decodeWithHeader(const <int>[0x80, 0xA0, 0xFD, 0xB1], 'shift_jis'),
        text: '\u0080\uFFFD\uFFFD\uFF71',
        charset: 'shift_jis',
      );
    });

    test('private-use lead bytes map to U+E000 onward', () {
      _expectDecoded(
        _decodeWithHeader(const <int>[0xF0, 0x40, 0xF9, 0xFC], 'shift_jis'),
        text: '\uE000\uE757',
        charset: 'shift_jis',
      );
    });

    test('decodes the Windows-31J extension rows', () {
      _expectDecoded(
        _decodeWithHeader(const <int>[
          ...[0xED, 0x40],
          ...[0xFA, 0x40],
          ...[0xFC, 0x4B],
        ], 'shift_jis'),
        text: '\u7E8A\u2170\u9ED1',
        charset: 'shift_jis',
      );
    });

    test('a truncated lead byte before ASCII keeps that ASCII byte', () {
      _expectDecoded(
        _decodeWithHeader(<int>[...ascii.encode('<b>'), 0x93, 0x3E], 'sjis'),
        text: '<b>\uFFFD>',
        charset: 'shift_jis',
      );
    });
  });

  group('WHATWG EUC-JP decoding', () {
    test('an invalid sequence keeps the ASCII byte after it', () {
      _expectDecoded(
        _decodeWithHeader(const <int>[0xA1, 0x3C, 0x62], 'euc-jp'),
        text: '\uFFFD<b',
        charset: 'euc-jp',
      );
    });

    test('a final ASCII byte after a three-byte lead is kept', () {
      _expectDecoded(
        _decodeWithHeader(<int>[
          ...ascii.encode('<b>x'),
          0x8F,
          ...ascii.encode('>'),
        ], 'euc-jp'),
        text: '<b>x\uFFFD>',
        charset: 'euc-jp',
      );
    });

    test('uses the WHATWG jis0208 and jis0212 indexes', () {
      _expectDecoded(
        _decodeWithHeader(const <int>[
          ...[0xA1, 0xBD],
          ...[0xAD, 0xA1],
          ...[0xF9, 0xA1],
          ...[0x8F, 0xA2, 0xB7],
          ...[0x8E, 0xB1],
          0x7F,
        ], 'euc-jp'),
        text: '\u2015\u2460\u7E8A\uFF5E\uFF71\u007F',
        charset: 'euc-jp',
      );
    });
  });

  group('WHATWG single-byte indexes', () {
    test('windows-874 decodes 0x91 through 0x98 without a shift', () {
      _expectDecoded(
        _decodeWithHeader(
          List<int>.generate(8, (index) => 0x91 + index),
          'windows-874',
        ),
        text: '\u2018\u2019\u201C\u201D\u2022\u2013\u2014\u0098',
        charset: 'windows-874',
      );
    });

    test('iso-8859-3 decodes 0xA4 and leaves 0xA5 unmapped', () {
      _expectDecoded(
        _decodeWithHeader(const <int>[0xA4, 0xA5], 'iso-8859-3'),
        text: '\u00A4\uFFFD',
        charset: 'iso-8859-3',
      );
    });

    _singleByteSpotChecks.forEach((encoding, expected) {
      test('$encoding matches the WHATWG index', () {
        final bytes = <int>[0x7F, ...expected.keys];

        _expectDecoded(
          _decodeWithHeader(bytes, encoding),
          text: String.fromCharCodes(<int>[0x7F, ...expected.values]),
          charset: encoding,
        );
      });
    });
  });

  group('meta prescan', () {
    test('skips a meta charset whose label does not resolve', () {
      final bytes = <int>[
        ...ascii.encode(
          '<meta charset="utf8mb4"><meta charset="windows-1251">',
        ),
        0xC0,
        0xE1,
      ];

      _expectDecoded(
        const WebDecoder().decode(bytes),
        text: '<meta charset="utf8mb4"><meta charset="windows-1251">Аб',
        charset: 'windows-1251',
        source: CharsetSource.meta,
      );
    });

    test('skips an http-equiv whose label does not resolve', () {
      const prefix =
          '<meta http-equiv="Content-Type" content="text/html; charset=bogus">'
          '<meta charset="windows-1251">';
      final result = const WebDecoder().decode(<int>[
        ...ascii.encode(prefix),
        0xC0,
      ]);

      _expectDecoded(
        result,
        text: '$prefixА',
        charset: 'windows-1251',
        source: CharsetSource.meta,
      );
    });

    test('maps x-user-defined to windows-1252', () {
      _expectDecoded(
        const WebDecoder().decode(_withMeta('x-user-defined', const [0x80])),
        text: '<meta charset="x-user-defined">€',
        charset: 'windows-1252',
        source: CharsetSource.meta,
      );
    });

    test('x-user-defined in the header remains unsupported', () {
      _expectDecoded(
        _decodeWithHeader(ascii.encode('Hi'), 'x-user-defined'),
        text: 'Hi',
        charset: 'utf-8',
        source: CharsetSource.fallback,
      );
    });
  });

  group('WHATWG UTF-16 decoding', () {
    test('an unpaired lead surrogate keeps the next code unit (LE)', () {
      _expectDecoded(
        _decodeWithHeader(const <int>[
          ...[0x61, 0x00, 0x00, 0xD8, 0x3C, 0x00, 0x62, 0x00],
        ], 'utf-16le'),
        text: 'a\uFFFD<b',
        charset: 'utf-16le',
      );
    });

    test('an unpaired lead surrogate keeps the next code unit (BE)', () {
      _expectDecoded(
        _decodeWithHeader(const <int>[
          ...[0x00, 0x61, 0xD8, 0x00, 0x00, 0x3C, 0x00, 0x62],
        ], 'utf-16be'),
        text: 'a\uFFFD<b',
        charset: 'utf-16be',
      );
    });

    test('the BOM path uses the same decoder', () {
      final little = const WebDecoder().decode(const <int>[
        ...[0xFF, 0xFE, 0x61, 0x00, 0x00, 0xD8, 0x3C, 0x00],
      ]);
      final big = const WebDecoder().decode(const <int>[
        ...[0xFE, 0xFF, 0x00, 0x61, 0xD8, 0x00, 0x00, 0x3C],
      ]);

      _expectDecoded(
        little,
        text: 'a\uFFFD<',
        charset: 'utf-16',
        source: CharsetSource.bom,
      );
      _expectDecoded(
        big,
        text: 'a\uFFFD<',
        charset: 'utf-16',
        source: CharsetSource.bom,
      );
    });

    test('a lone trail surrogate is one replacement', () {
      _expectDecoded(
        _decodeWithHeader(const <int>[0x00, 0xDC, 0x41, 0x00], 'utf-16le'),
        text: '\uFFFDA',
        charset: 'utf-16le',
      );
    });

    test('an odd trailing byte or final lead surrogate is a replacement', () {
      _expectDecoded(
        _decodeWithHeader(const <int>[0x41, 0x00, 0x42], 'utf-16le'),
        text: 'A\uFFFD',
        charset: 'utf-16le',
      );
      _expectDecoded(
        _decodeWithHeader(const <int>[0x41, 0x00, 0x00, 0xD8], 'utf-16le'),
        text: 'A\uFFFD',
        charset: 'utf-16le',
      );
    });

    test('a surrogate pair decodes to one supplementary character', () {
      _expectDecoded(
        _decodeWithHeader(const <int>[0x3D, 0xD8, 0x00, 0xDE], 'utf-16le'),
        text: '\u{1F600}',
        charset: 'utf-16le',
      );
    });
  });
}

/// WHATWG index-windows-1252 code points for bytes `0x80` through `0x9F`.
const _whatwgWindows1252C1 = <int>[
  0x20AC, 0x0081, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021, //
  0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0x008D, 0x017D, 0x008F, //
  0x0090, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014, //
  0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0x009D, 0x017E, 0x0178, //
];

/// WHATWG single-byte encodings, keyed by the canonical name the decoder
/// reports, with their WHATWG labels.
const _singleByteLabels = <String, List<String>>{
  'ibm866': ['866', 'cp866', 'csibm866', 'ibm866'],
  'iso-8859-2': [
    'csisolatin2',
    'iso-8859-2',
    'iso-ir-101',
    'iso8859-2',
    'iso88592',
    'iso_8859-2',
    'iso_8859-2:1987',
    'l2',
    'latin2',
  ],
  'iso-8859-3': [
    'csisolatin3',
    'iso-8859-3',
    'iso-ir-109',
    'iso8859-3',
    'iso88593',
    'iso_8859-3',
    'iso_8859-3:1988',
    'l3',
    'latin3',
  ],
  'iso-8859-4': [
    'csisolatin4',
    'iso-8859-4',
    'iso-ir-110',
    'iso8859-4',
    'iso88594',
    'iso_8859-4',
    'iso_8859-4:1988',
    'l4',
    'latin4',
  ],
  'iso-8859-5': [
    'csisolatincyrillic',
    'cyrillic',
    'iso-8859-5',
    'iso-ir-144',
    'iso8859-5',
    'iso88595',
    'iso_8859-5',
    'iso_8859-5:1988',
  ],
  'iso-8859-6': [
    'arabic',
    'asmo-708',
    'csiso88596e',
    'csiso88596i',
    'csisolatinarabic',
    'ecma-114',
    'iso-8859-6',
    'iso-8859-6-e',
    'iso-8859-6-i',
    'iso-ir-127',
    'iso8859-6',
    'iso88596',
    'iso_8859-6',
    'iso_8859-6:1987',
  ],
  'iso-8859-7': [
    'csisolatingreek',
    'ecma-118',
    'elot_928',
    'greek',
    'greek8',
    'iso-8859-7',
    'iso-ir-126',
    'iso8859-7',
    'iso88597',
    'iso_8859-7',
    'iso_8859-7:1987',
    'sun_eu_greek',
  ],
  'iso-8859-8': [
    'csiso88598e',
    'csisolatinhebrew',
    'hebrew',
    'iso-8859-8',
    'iso-8859-8-e',
    'iso-ir-138',
    'iso8859-8',
    'iso88598',
    'iso_8859-8',
    'iso_8859-8:1988',
    'visual',
  ],
  'iso-8859-8-i': ['csiso88598i', 'iso-8859-8-i', 'logical'],
  'iso-8859-10': [
    'csisolatin6',
    'iso-8859-10',
    'iso-ir-157',
    'iso8859-10',
    'iso885910',
    'l6',
    'latin6',
  ],
  'iso-8859-13': ['iso-8859-13', 'iso8859-13', 'iso885913'],
  'iso-8859-14': ['iso-8859-14', 'iso8859-14', 'iso885914'],
  'iso-8859-15': [
    'csisolatin9',
    'iso-8859-15',
    'iso8859-15',
    'iso885915',
    'iso_8859-15',
    'l9',
  ],
  'iso-8859-16': ['iso-8859-16'],
  'windows-874': [
    'dos-874',
    'iso-8859-11',
    'iso8859-11',
    'iso885911',
    'tis-620',
    'windows-874',
  ],
  'windows-1250': ['cp1250', 'windows-1250', 'x-cp1250'],
  'windows-1251': ['cp1251', 'windows-1251', 'x-cp1251'],
  'windows-1253': ['cp1253', 'windows-1253', 'x-cp1253'],
  'windows-1254': [
    'cp1254',
    'csisolatin5',
    'iso-8859-9',
    'iso-ir-148',
    'iso8859-9',
    'iso88599',
    'iso_8859-9',
    'iso_8859-9:1989',
    'l5',
    'latin5',
    'windows-1254',
    'x-cp1254',
  ],
  'windows-1255': ['cp1255', 'windows-1255', 'x-cp1255'],
  'windows-1256': ['cp1256', 'windows-1256', 'x-cp1256'],
  'windows-1257': ['cp1257', 'windows-1257', 'x-cp1257'],
  'windows-1258': ['cp1258', 'windows-1258', 'x-cp1258'],
};

WebDecodeResult _decodeWithHeader(List<int> bytes, String label) {
  return const WebDecoder().decode(
    bytes,
    headers: {'content-type': 'text/html; charset=$label'},
  );
}

List<int> _withMeta(String label, List<int> body) {
  return <int>[...ascii.encode('<meta charset="$label">'), ...body];
}

void _expectDecoded(
  WebDecodeResult result, {
  required String text,
  required String charset,
  CharsetSource source = CharsetSource.header,
}) {
  expect(result.text, text);
  expect(result.charset, charset);
  expect(result.source, source);
}

/// Code points from the WHATWG index files (dated 2024-09-18) for a few bytes
/// of each single-byte encoding. `U+FFFD` marks a byte the index leaves
/// unmapped.
const _singleByteSpotChecks = <String, Map<int, int>>{
  'ibm866': {0x80: 0x0410, 0xA4: 0x0434, 0xC5: 0x253C, 0xFF: 0x00A0},
  'iso-8859-2': {0x80: 0x0080, 0xA4: 0x00A4, 0xC5: 0x0139, 0xFF: 0x02D9},
  'iso-8859-3': {
    0x80: 0x0080,
    0xA4: 0x00A4,
    0xC5: 0x010A,
    0xFF: 0x02D9,
    0xA5: 0xFFFD,
  },
  'iso-8859-4': {0x80: 0x0080, 0xA4: 0x00A4, 0xC5: 0x00C5, 0xFF: 0x02D9},
  'iso-8859-5': {0x80: 0x0080, 0xA4: 0x0404, 0xC5: 0x0425, 0xFF: 0x045F},
  'iso-8859-6': {
    0x80: 0x0080,
    0xA4: 0x00A4,
    0xC5: 0x0625,
    0xFF: 0xFFFD,
    0xA1: 0xFFFD,
  },
  'iso-8859-7': {
    0x80: 0x0080,
    0xA4: 0x20AC,
    0xC5: 0x0395,
    0xFF: 0xFFFD,
    0xAE: 0xFFFD,
  },
  'iso-8859-8': {
    0x80: 0x0080,
    0xA4: 0x00A4,
    0xC5: 0xFFFD,
    0xFF: 0xFFFD,
    0xA1: 0xFFFD,
  },
  'iso-8859-10': {0x80: 0x0080, 0xA4: 0x012A, 0xC5: 0x00C5, 0xFF: 0x0138},
  'iso-8859-13': {0x80: 0x0080, 0xA4: 0x00A4, 0xC5: 0x00C5, 0xFF: 0x2019},
  'iso-8859-14': {0x80: 0x0080, 0xA4: 0x010A, 0xC5: 0x00C5, 0xFF: 0x00FF},
  'iso-8859-15': {0x80: 0x0080, 0xA4: 0x20AC, 0xC5: 0x00C5, 0xFF: 0x00FF},
  'iso-8859-16': {0x80: 0x0080, 0xA4: 0x20AC, 0xC5: 0x0106, 0xFF: 0x00FF},
  'windows-874': {
    0x80: 0x20AC,
    0xA4: 0x0E04,
    0xC5: 0x0E25,
    0xFF: 0xFFFD,
    0xDB: 0xFFFD,
  },
  'windows-1250': {0x80: 0x20AC, 0xA4: 0x00A4, 0xC5: 0x0139, 0xFF: 0x02D9},
  'windows-1251': {0x80: 0x0402, 0xA4: 0x00A4, 0xC5: 0x0415, 0xFF: 0x044F},
  'windows-1252': {0x80: 0x20AC, 0xA4: 0x00A4, 0xC5: 0x00C5, 0xFF: 0x00FF},
  'windows-1253': {
    0x80: 0x20AC,
    0xA4: 0x00A4,
    0xC5: 0x0395,
    0xFF: 0xFFFD,
    0xAA: 0xFFFD,
  },
  'windows-1254': {0x80: 0x20AC, 0xA4: 0x00A4, 0xC5: 0x00C5, 0xFF: 0x00FF},
  'windows-1255': {
    0x80: 0x20AC,
    0xA4: 0x20AA,
    0xC5: 0x05B5,
    0xFF: 0xFFFD,
    0xD9: 0xFFFD,
  },
  'windows-1256': {0x80: 0x20AC, 0xA4: 0x00A4, 0xC5: 0x0625, 0xFF: 0x06D2},
  'windows-1257': {
    0x80: 0x20AC,
    0xA4: 0x00A4,
    0xC5: 0x00C5,
    0xFF: 0x02D9,
    0xA1: 0xFFFD,
  },
  'windows-1258': {0x80: 0x20AC, 0xA4: 0x00A4, 0xC5: 0x00C5, 0xFF: 0x00FF},
};
