import 'dart:convert';
import 'dart:typed_data';

import 'package:charset/charset.dart' as charset;
import 'package:html/parser.dart' as html_parser;
import 'package:metalink/src/model/diagnostics.dart';

part 'web_decoder_tables.dart';

/// The text decoded from web response bytes, with the encoding that produced
/// it and where that encoding came from.
///
/// [WebDecoder.decode] returns this. MetaLink copies [charset] and [source]
/// into the fetch diagnostics as `detectedCharset` and `charsetSource`, and
/// adds a `MetaLinkWarningCode.charsetFallback` warning when [source] is
/// [CharsetSource.fallback].
class WebDecodeResult {
  /// Creates a result for [text] decoded as [charset], chosen from [source].
  const WebDecodeResult({
    required this.text,
    required this.charset,
    required this.source,
  });

  /// The decoded document text.
  ///
  /// A byte-order mark is not included. Each invalid or incomplete byte
  /// sequence appears as one `U+FFFD`, and an ASCII byte that cannot continue
  /// a multibyte sequence is kept as itself, so markup such as `<` is never
  /// absorbed into a replacement.
  final String text;

  /// The lowercase canonical name of the encoding that actually produced
  /// [text], such as `utf-8`, `windows-1252`, `shift_jis`, or `gb18030`.
  ///
  /// This names the decoder, which can differ from the declared label:
  /// ISO-8859-1 and ASCII labels report `windows-1252`, a `utf-16` label
  /// reports `utf-16le`, and in an HTML `<meta>` tag a UTF-16 declaration
  /// reports `utf-8` and `x-user-defined` reports `windows-1252`. A byte-order
  /// mark reports `utf-8`, `utf-16`, or `utf-32`. A fallback always reports
  /// `utf-8`.
  final String charset;

  /// Where the encoding named by [charset] came from.
  ///
  /// [WebDecoder.decode] reports [CharsetSource.bom], [CharsetSource.header],
  /// [CharsetSource.meta], or [CharsetSource.fallback]. It never reports
  /// [CharsetSource.unknown].
  final CharsetSource source;

  /// Whether no usable encoding was found and the bytes were decoded as UTF-8
  /// by default.
  ///
  /// This is `true` exactly when [source] is [CharsetSource.fallback]: the
  /// bytes were empty, no encoding was declared, or every declared label was
  /// unrecognized or names an unsupported encoding. Malformed UTF-8 sequences
  /// in [text] are then replaced with `U+FFFD`.
  bool get usedFallback => source == CharsetSource.fallback;
}

/// A decoder that turns HTML response bytes into text using the charset
/// precedence and decoders that web browsers use.
///
/// [decode] uses the first usable encoding from this list:
///
/// 1. A UTF-8, UTF-16, or UTF-32 byte-order mark.
/// 2. The `charset` parameter of the `Content-Type` header.
/// 3. The first `<meta charset>` or `<meta http-equiv="Content-Type">`
///    declaration with a supported label in the first [metaProbeBytes] bytes.
/// 4. UTF-8, reported as [CharsetSource.fallback].
///
/// Labels are matched case-insensitively against the WHATWG Encoding Standard
/// label table, so `iso-8859-1`, `latin1`, and `us-ascii` decode as
/// windows-1252 the way browsers decode them. Supported encodings are UTF-8,
/// UTF-16LE, UTF-16BE, gb18030 and GBK, Shift_JIS, EUC-JP, and the WHATWG
/// single-byte encodings such as windows-1252, windows-1251, and ISO-8859-2.
/// Labels outside the WHATWG table that the `charset` package recognizes,
/// such as `cp437`, and UTF-32 labels are also accepted. A declaration moves
/// on to the next step when its label is unrecognized or names an
/// unsupported encoding, such as EUC-KR, Big5, KOI8-R, or ISO-2022-JP.
///
/// The supported encodings decode with the WHATWG decoder algorithms and
/// indexes (UTF-32 and the extra code pages use the `charset` package), so
/// malformed bytes do not reject the document. Each invalid sequence becomes
/// one `U+FFFD`, an ASCII byte that cannot continue a multibyte sequence is
/// decoded as itself, and a sequence cut off at the end, as happens when a
/// response is truncated at its byte limit, becomes one `U+FFFD`.
class WebDecoder {
  /// Creates a decoder that searches the first [metaProbeBytes] bytes for an
  /// HTML charset declaration.
  const WebDecoder({this.metaProbeBytes = 4096});

  /// The number of leading bytes searched for an HTML `<meta>` charset
  /// declaration. Defaults to `4096`.
  ///
  /// The probe is read as Latin-1, so only declarations written in
  /// ASCII-compatible bytes are found. A value of `0` or less skips the meta
  /// step.
  final int metaProbeBytes;

  /// Decodes [bytes] to text with the first usable encoding, as described on
  /// [WebDecoder].
  ///
  /// [headers] is searched case-insensitively for `Content-Type`; other
  /// headers are ignored. Empty [bytes] produce empty text reported as a
  /// `utf-8` fallback.
  ///
  /// The meta step only finds declarations in ASCII-compatible bytes, so, as
  /// the WHATWG prescan requires, a UTF-16 declaration found there decodes as
  /// UTF-8 and `x-user-defined` decodes as windows-1252. A `utf-16` label in
  /// [headers] without a byte-order mark decodes as little-endian.
  WebDecodeResult decode(
    List<int> bytes, {
    Map<String, String> headers = const <String, String>{},
  }) {
    if (bytes.isEmpty) {
      return const WebDecodeResult(
        text: '',
        charset: 'utf-8',
        source: CharsetSource.fallback,
      );
    }

    final bom = _decodeBom(bytes);
    if (bom != null) return bom;

    final header = _decodeWith(
      bytes,
      _resolveLabel(_charsetFromHeader(_headerValue(headers, 'content-type'))),
      CharsetSource.header,
    );
    if (header != null) return header;

    final meta = _decodeWith(
      bytes,
      _encodingFromMeta(bytes),
      CharsetSource.meta,
    );
    if (meta != null) return meta;

    return WebDecodeResult(
      text: utf8.decode(bytes, allowMalformed: true),
      charset: 'utf-8',
      source: CharsetSource.fallback,
    );
  }

  WebDecodeResult? _decodeBom(List<int> bytes) {
    // UTF-32 BOMs must be checked before UTF-16 because their prefixes overlap.
    if (_startsWith(bytes, const [0x00, 0x00, 0xFE, 0xFF]) ||
        _startsWith(bytes, const [0xFF, 0xFE, 0x00, 0x00])) {
      return WebDecodeResult(
        text: charset.utf32.decode(bytes),
        charset: 'utf-32',
        source: CharsetSource.bom,
      );
    }

    if (_startsWith(bytes, const [0xEF, 0xBB, 0xBF])) {
      return WebDecodeResult(
        text: utf8.decode(bytes.sublist(3), allowMalformed: true),
        charset: 'utf-8',
        source: CharsetSource.bom,
      );
    }

    final bigEndian = _startsWith(bytes, const [0xFE, 0xFF]);
    if (bigEndian || _startsWith(bytes, const [0xFF, 0xFE])) {
      return WebDecodeResult(
        text: _decodeUtf16(bytes, bigEndian: bigEndian, start: 2),
        charset: 'utf-16',
        source: CharsetSource.bom,
      );
    }

    return null;
  }

  static WebDecodeResult? _decodeWith(
    List<int> bytes,
    _WebEncoding? encoding,
    CharsetSource source,
  ) {
    if (encoding == null) return null;
    final String text;
    try {
      text = encoding.decode(bytes);
    } on Object {
      // The in-package decoders accept any byte sequence. The remaining
      // `charset` package decoders (UTF-32 and non-WHATWG code pages) may throw
      // on malformed input, which moves decoding on to the next step.
      return null;
    }
    return WebDecodeResult(text: text, charset: encoding.name, source: source);
  }

  String? _charsetFromHeader(String? contentType) {
    if (contentType == null || contentType.trim().isEmpty) return null;
    final match = RegExp(
      r'''charset\s*=\s*(?:"([^"]+)"|'([^']+)'|([^;\s]+))''',
      caseSensitive: false,
    ).firstMatch(contentType);
    return _firstNonEmptyGroup(match);
  }

  /// The encoding of the first `<meta>` declaration in the probe whose label
  /// resolves, skipping declarations with unknown or unsupported labels as
  /// the WHATWG prescan does.
  _WebEncoding? _encodingFromMeta(List<int> bytes) {
    final probeLength = bytes.length < metaProbeBytes
        ? bytes.length
        : metaProbeBytes;
    if (probeLength <= 0) return null;

    final probe = latin1.decode(bytes.sublist(0, probeLength));
    final document = html_parser.parse(probe);
    for (final meta in document.querySelectorAll('meta')) {
      final directLabel = meta.attributes['charset']?.trim();
      if (directLabel != null && directLabel.isNotEmpty) {
        final encoding = _resolveMetaLabel(directLabel);
        if (encoding != null) return encoding;
        continue;
      }

      final httpEquiv = meta.attributes['http-equiv']?.trim().toLowerCase();
      if (httpEquiv != 'content-type') continue;

      final encoding = _resolveMetaLabel(
        _charsetFromHeader(meta.attributes['content']),
      );
      if (encoding != null) return encoding;
    }
    return null;
  }

  /// Resolves a label found by the meta prescan.
  ///
  /// The prescan only reads ASCII-compatible bytes, so a UTF-16 (or UTF-32)
  /// declaration cannot describe the document and WHATWG treats it as UTF-8.
  /// WHATWG also maps `x-user-defined` to windows-1252 here.
  static _WebEncoding? _resolveMetaLabel(String? label) {
    if (label?.trim().toLowerCase() == 'x-user-defined') {
      return _encodingFor('windows-1252');
    }
    final encoding = _resolveLabel(label);
    if (encoding != null &&
        _asciiIncompatibleEncodings.contains(encoding.name)) {
      return _encodingFor('utf-8');
    }
    return encoding;
  }

  /// The encoding for [raw], or `null` when the label is missing, unknown, or
  /// names an encoding that cannot be decoded correctly.
  static _WebEncoding? _resolveLabel(String? raw) {
    final label = raw?.trim().toLowerCase();
    if (label == null || label.isEmpty) return null;

    final canonical = _canonicalByLabel[label];
    if (canonical != null) return _encodingFor(canonical);
    return _dependencyEncoding(label);
  }

  static _WebEncoding? _encodingFor(String canonical) {
    switch (canonical) {
      case 'utf-8':
        return (
          name: canonical,
          decode: (bytes) => utf8.decode(bytes, allowMalformed: true),
        );
      case 'utf-16le':
        return (
          name: canonical,
          decode: (bytes) => _decodeUtf16(bytes, bigEndian: false),
        );
      case 'utf-16be':
        return (
          name: canonical,
          decode: (bytes) => _decodeUtf16(bytes, bigEndian: true),
        );
      case 'utf-32':
        return (name: canonical, decode: charset.utf32.decode);
      case 'utf-32le':
        return (
          name: canonical,
          decode: const charset.Utf32Decoder().decodeUtf32Le,
        );
      case 'utf-32be':
        return (
          name: canonical,
          decode: const charset.Utf32Decoder().decodeUtf32Be,
        );
      case 'gbk':
      case 'gb18030':
        // WHATWG decodes GBK with the gb18030 decoder.
        return (name: canonical, decode: _decodeGb18030);
      case 'shift_jis':
        return (name: canonical, decode: _decodeShiftJis);
      case 'euc-jp':
        return (name: canonical, decode: _decodeEucJp);
    }

    final table =
        _singleByteTables[canonical == 'iso-8859-8-i'
            ? 'iso-8859-8'
            : canonical];
    if (table == null) return null;
    return (
      name: canonical,
      decode: (bytes) => _decodeSingleByte(bytes, table),
    );
  }

  /// Resolves a label that is not in the WHATWG table through the `charset`
  /// package, keeping support for labels such as `cp437` and `cp936` while
  /// reporting the canonical name of the decoder that is actually used.
  static _WebEncoding? _dependencyEncoding(String label) {
    final encoding = charset.Charset.getByName(label);
    return switch (encoding) {
      final charset.CodePage page => switch (_dependencyPageNames[page]) {
        final String canonical => _encodingFor(canonical),
        null => (
          name: page.name,
          decode: (bytes) => _decodeSingleByte(bytes, _upperHalf(page)),
        ),
      },
      charset.GbkCodec() => _encodingFor('gbk'),
      charset.ShiftJISCodec() => _encodingFor('shift_jis'),
      charset.EucJPCodec() => _encodingFor('euc-jp'),
      Utf8Codec() => _encodingFor('utf-8'),
      Latin1Codec() || AsciiCodec() => _encodingFor('windows-1252'),
      // charset 2.0.1's EUC-KR decoder silently produces the wrong text, so
      // EUC-KR is unsupported. UTF-16 and UTF-32 aliases are in the table.
      _ => null,
    };
  }

  /// The characters a dependency code [page] assigns to bytes 0x80 to 0xFF.
  ///
  /// Every code page the `charset` package provides is ASCII-compatible, but
  /// its tables map DEL (0x7F) to `U+FFFD`, so only the upper half comes from
  /// the dependency and [_decodeSingleByte] decodes ASCII bytes as themselves.
  static String _upperHalf(charset.CodePage page) {
    return _dependencyUpperHalves[page] ??= String.fromCharCodes([
      for (var byte = 0x80; byte <= 0xFF; byte++)
        switch (page.decode([byte], allowInvalid: true)) {
          final decoded when decoded.length == 1 => decoded.codeUnitAt(0),
          _ => 0xFFFD,
        },
    ]);
  }

  static final Map<charset.CodePage, String> _dependencyUpperHalves =
      Map<charset.CodePage, String>.identity();

  /// Decodes a single-byte encoding from its WHATWG index [table], which
  /// holds the code points for bytes 0x80 to 0xFF (`U+FFFD` where unmapped).
  static String _decodeSingleByte(List<int> bytes, String table) {
    final codeUnits = Uint16List(bytes.length);
    for (var index = 0; index < bytes.length; index++) {
      final byte = bytes[index];
      codeUnits[index] = byte < 0x80 ? byte : table.codeUnitAt(byte - 0x80);
    }
    return String.fromCharCodes(codeUnits);
  }

  /// Decodes UTF-16 per the WHATWG shared UTF-16 decoder, from byte [start].
  ///
  /// An unpaired surrogate becomes `U+FFFD` without consuming the code unit
  /// after it, and a dangling byte or lead surrogate at the end becomes one
  /// `U+FFFD`.
  static String _decodeUtf16(
    List<int> bytes, {
    required bool bigEndian,
    int start = 0,
  }) {
    final out = _CodePointBuffer((bytes.length - start) ~/ 2 + 1);
    int? leadSurrogate;
    var index = start;
    for (; index + 1 < bytes.length; index += 2) {
      final unit = bigEndian
          ? (bytes[index] << 8) | bytes[index + 1]
          : (bytes[index + 1] << 8) | bytes[index];
      if (leadSurrogate != null) {
        final lead = leadSurrogate;
        leadSurrogate = null;
        if (unit >= 0xDC00 && unit <= 0xDFFF) {
          out.add(0x10000 + ((lead - 0xD800) << 10) + (unit - 0xDC00));
          continue;
        }
        out.add(_replacement);
      }
      if (unit >= 0xD800 && unit <= 0xDBFF) {
        leadSurrogate = unit;
      } else if (unit >= 0xDC00 && unit <= 0xDFFF) {
        out.add(_replacement);
      } else {
        out.add(unit);
      }
    }
    if (leadSurrogate != null || index < bytes.length) out.add(_replacement);
    return out.toString();
  }

  /// Decodes gb18030 (and GBK) per the WHATWG gb18030 decoder.
  ///
  /// Rewinding `index` is how the algorithm's "prepend to the stream" steps
  /// return bytes that did not belong to a failed sequence.
  static String _decodeGb18030(List<int> bytes) {
    final out = _CodePointBuffer(bytes.length + 1);
    var first = 0;
    var second = 0;
    var third = 0;
    var index = 0;
    while (index < bytes.length) {
      final byte = bytes[index++];
      if (third != 0) {
        if (byte < 0x30 || byte > 0x39) {
          index -= 3;
          first = second = third = 0;
          out.add(_replacement);
          continue;
        }
        final codePoint = _gb18030RangesCodePoint(
          (((first - 0x81) * 10 + second - 0x30) * 126 + third - 0x81) * 10 +
              byte -
              0x30,
        );
        first = second = third = 0;
        out.add(codePoint ?? _replacement);
        continue;
      }
      if (second != 0) {
        if (byte >= 0x81 && byte <= 0xFE) {
          third = byte;
          continue;
        }
        index -= 2;
        first = second = 0;
        out.add(_replacement);
        continue;
      }
      if (first != 0) {
        if (byte >= 0x30 && byte <= 0x39) {
          second = byte;
          continue;
        }
        final lead = first;
        first = 0;
        final offset = byte < 0x7F ? 0x40 : 0x41;
        final codePoint =
            (byte >= 0x40 && byte <= 0x7E) || (byte >= 0x80 && byte <= 0xFE)
            ? _gb18030Index[(lead - 0x81) * 190 + byte - offset]
            : null;
        if (codePoint != null) {
          out.add(codePoint);
          continue;
        }
        if (byte < 0x80) index--;
        out.add(_replacement);
        continue;
      }
      if (byte < 0x80) {
        out.add(byte);
      } else if (byte == 0x80) {
        out.add(0x20AC);
      } else if (byte <= 0xFE) {
        first = byte;
      } else {
        out.add(_replacement);
      }
    }
    if (first != 0 || second != 0 || third != 0) out.add(_replacement);
    return out.toString();
  }

  /// Decodes Shift_JIS per the WHATWG Shift_JIS decoder.
  static String _decodeShiftJis(List<int> bytes) {
    final out = _CodePointBuffer(bytes.length + 1);
    var lead = 0;
    var index = 0;
    while (index < bytes.length) {
      final byte = bytes[index++];
      if (lead != 0) {
        final leadOffset = lead < 0xA0 ? 0x81 : 0xC1;
        final offset = byte < 0x7F ? 0x40 : 0x41;
        final pointer =
            (byte >= 0x40 && byte <= 0x7E) || (byte >= 0x80 && byte <= 0xFC)
            ? (lead - leadOffset) * 188 + byte - offset
            : null;
        lead = 0;
        if (pointer != null && pointer >= 8836 && pointer <= 10715) {
          out.add(0xE000 - 8836 + pointer);
          continue;
        }
        final codePoint = pointer == null ? null : _jis0208Index[pointer];
        if (codePoint != null) {
          out.add(codePoint);
          continue;
        }
        if (byte < 0x80) index--;
        out.add(_replacement);
        continue;
      }
      if (byte <= 0x80) {
        out.add(byte);
      } else if (byte >= 0xA1 && byte <= 0xDF) {
        out.add(0xFF61 - 0xA1 + byte);
      } else if ((byte >= 0x81 && byte <= 0x9F) ||
          (byte >= 0xE0 && byte <= 0xFC)) {
        lead = byte;
      } else {
        out.add(_replacement);
      }
    }
    if (lead != 0) out.add(_replacement);
    return out.toString();
  }

  /// Decodes EUC-JP per the WHATWG EUC-JP decoder.
  static String _decodeEucJp(List<int> bytes) {
    final out = _CodePointBuffer(bytes.length + 1);
    var lead = 0;
    var jis0212 = false;
    var index = 0;
    while (index < bytes.length) {
      final byte = bytes[index++];
      if (lead == 0x8E && byte >= 0xA1 && byte <= 0xDF) {
        lead = 0;
        out.add(0xFF61 - 0xA1 + byte);
        continue;
      }
      if (lead == 0x8F && byte >= 0xA1 && byte <= 0xFE) {
        jis0212 = true;
        lead = byte;
        continue;
      }
      if (lead != 0) {
        final previous = lead;
        lead = 0;
        int? codePoint;
        if (previous >= 0xA1 &&
            previous <= 0xFE &&
            byte >= 0xA1 &&
            byte <= 0xFE) {
          final pointer = (previous - 0xA1) * 94 + byte - 0xA1;
          codePoint = jis0212 ? _jis0212Index[pointer] : _jis0208Index[pointer];
        }
        jis0212 = false;
        if (codePoint != null) {
          out.add(codePoint);
          continue;
        }
        if (byte < 0x80) index--;
        out.add(_replacement);
        continue;
      }
      if (byte < 0x80) {
        out.add(byte);
      } else if (byte == 0x8E ||
          byte == 0x8F ||
          (byte >= 0xA1 && byte <= 0xFE)) {
        lead = byte;
      } else {
        out.add(_replacement);
      }
    }
    if (lead != 0) out.add(_replacement);
    return out.toString();
  }

  /// The code point for a gb18030 four-byte [pointer], per the WHATWG index
  /// gb18030 ranges code point algorithm, or `null` when it has none.
  static int? _gb18030RangesCodePoint(int pointer) {
    if ((pointer > 39419 && pointer < 189000) || pointer > 1237575) {
      return null;
    }
    if (pointer == 7457) return 0xE7C7;
    var low = 0;
    var high = _gb18030Ranges.length ~/ 2 - 1;
    while (low < high) {
      final middle = (low + high + 1) >> 1;
      if (_gb18030Ranges[middle * 2] <= pointer) {
        low = middle;
      } else {
        high = middle - 1;
      }
    }
    return _gb18030Ranges[low * 2 + 1] + pointer - _gb18030Ranges[low * 2];
  }

  static String? _headerValue(Map<String, String> headers, String name) {
    final normalizedName = name.toLowerCase();
    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() == normalizedName) return entry.value;
    }
    return null;
  }

  static String? _firstNonEmptyGroup(RegExpMatch? match) {
    if (match == null) return null;
    for (var index = 1; index <= match.groupCount; index++) {
      final value = match.group(index)?.trim();
      if (value != null && value.isNotEmpty) return value;
    }
    return null;
  }

  static bool _startsWith(List<int> bytes, List<int> prefix) {
    if (bytes.length < prefix.length) return false;
    for (var index = 0; index < prefix.length; index++) {
      if (bytes[index] != prefix[index]) return false;
    }
    return true;
  }
}

/// A resolved encoding: the canonical name reported in
/// [WebDecodeResult.charset] and the function that decodes bytes with it.
typedef _WebEncoding = ({String name, String Function(List<int> bytes) decode});

const _replacement = 0xFFFD;

/// Canonical encodings that a document found by the ASCII-compatible meta
/// prescan cannot actually use.
const _asciiIncompatibleEncodings = <String>{
  'utf-16le',
  'utf-16be',
  'utf-32',
  'utf-32le',
  'utf-32be',
};

/// Canonical names for the `charset` package code pages that reach a WHATWG
/// single-byte encoding through a label outside the WHATWG table, such as
/// `latin-9` or `cstis620`. Like WHATWG, ISO-8859-9 and TIS-620 decode as
/// their windows-1254 and windows-874 supersets.
final _dependencyPageNames = <charset.CodePage, String>{
  charset.cp866: 'ibm866',
  charset.latin2: 'iso-8859-2',
  charset.latin3: 'iso-8859-3',
  charset.latin4: 'iso-8859-4',
  charset.latinCyrillic: 'iso-8859-5',
  charset.latinArabic: 'iso-8859-6',
  charset.latinGreek: 'iso-8859-7',
  charset.latinHebrew: 'iso-8859-8',
  charset.latin5: 'windows-1254',
  charset.latin6: 'iso-8859-10',
  charset.latinThai: 'windows-874',
  charset.latin7: 'iso-8859-13',
  charset.latin8: 'iso-8859-14',
  charset.latin9: 'iso-8859-15',
  charset.latin10: 'iso-8859-16',
  charset.windows874: 'windows-874',
  charset.windows1250: 'windows-1250',
  charset.windows1251: 'windows-1251',
  charset.windows1252: 'windows-1252',
  charset.windows1253: 'windows-1253',
  charset.windows1254: 'windows-1254',
  charset.windows1255: 'windows-1255',
  charset.windows1256: 'windows-1256',
  charset.windows1257: 'windows-1257',
  charset.windows1258: 'windows-1258',
};

/// The output of a decoder loop, as code points.
final class _CodePointBuffer {
  _CodePointBuffer(int capacity) : _codePoints = Uint32List(capacity);

  final Uint32List _codePoints;
  var _length = 0;

  void add(int codePoint) => _codePoints[_length++] = codePoint;

  @override
  String toString() => String.fromCharCodes(_codePoints, 0, _length);
}

/// A WHATWG index whose entries are computed on first use and then cached.
///
/// Entries come from the `charset` package's strict decoders, applied to the
/// one byte sequence for a pointer, corrected by the generated tables. The
/// generator verifies that the result matches the WHATWG index exactly.
final class _LazyIndex {
  _LazyIndex(int length, this._lookup)
    : _entries = Int32List(length)..fillRange(0, length, _unknown);

  static const _unknown = -2;
  static const _unmapped = -1;

  final Int32List _entries;
  final int? Function(int pointer) _lookup;

  /// The code point for [pointer], or `null` when the index has none.
  int? operator [](int pointer) {
    if (pointer < 0 || pointer >= _entries.length) return null;
    var entry = _entries[pointer];
    if (entry == _unknown) {
      entry = _lookup(pointer) ?? _unmapped;
      _entries[pointer] = entry;
    }
    return entry == _unmapped ? null : entry;
  }
}

/// WHATWG index jis0208. The `charset` Shift_JIS table matches it except for
/// the Windows-31J extension rows, which are embedded.
final _jis0208Index = _LazyIndex(11104, (pointer) {
  for (final (start, codeUnits) in _jis0208Extensions) {
    if (pointer >= start && pointer < start + codeUnits.length) {
      final codeUnit = codeUnits.codeUnitAt(pointer - start);
      return codeUnit == _replacement ? null : codeUnit;
    }
  }
  final lead = pointer ~/ 188;
  final trail = pointer % 188;
  return _singleCodePoint(const charset.ShiftJISDecoder(), [
    lead < 0x1F ? lead + 0x81 : lead + 0xC1,
    trail < 0x3F ? trail + 0x40 : trail + 0x41,
  ]);
});

/// WHATWG index jis0212, from the `charset` EUC-JP table with corrections.
final _jis0212Index = _LazyIndex(8836, (pointer) {
  final override = _jis0212Overrides[pointer];
  if (override != null) return override == _replacement ? null : override;
  return _singleCodePoint(const charset.EucJPDecoder(), [
    0x8F,
    pointer ~/ 94 + 0xA1,
    pointer % 94 + 0xA1,
  ]);
});

/// WHATWG index gb18030, from the `charset` GBK table with corrections.
final _gb18030Index = _LazyIndex(23940, (pointer) {
  final override = _gb18030Overrides[pointer];
  if (override != null) return override == _replacement ? null : override;
  final trail = pointer % 190;
  return _singleCodePoint(const charset.GbkDecoder(), [
    pointer ~/ 190 + 0x81,
    trail < 0x3F ? trail + 0x40 : trail + 0x41,
  ]);
});

/// The one code point that [decoder] strictly decodes from [bytes], or `null`
/// when it rejects them or produces anything else.
int? _singleCodePoint(Converter<List<int>, String> decoder, List<int> bytes) {
  try {
    final runes = decoder.convert(bytes).runes.iterator;
    if (!runes.moveNext()) return null;
    final codePoint = runes.current;
    return runes.moveNext() ? null : codePoint;
  } on Object {
    // The strict decoders signal an unmapped sequence with FormatException,
    // or with RangeError for a lead byte they do not recognize.
    return null;
  }
}

/// Lowercase labels mapped to the canonical name of the encoding they select.
final _canonicalByLabel = <String, String>{
  for (final MapEntry(key: canonical, value: labels)
      in _labelsByEncoding.entries)
    for (final label in labels) label: canonical,
};

/// Labels for each supported encoding, from the WHATWG Encoding Standard,
/// plus the UTF-16, UTF-32, and `latin-1` labels earlier releases accepted.
///
/// EUC-KR labels are deliberately absent; see [WebDecoder._dependencyEncoding].
const _labelsByEncoding = <String, List<String>>{
  'utf-8': [
    'unicode-1-1-utf-8',
    'unicode11utf8',
    'unicode20utf8',
    'utf-8',
    'utf8',
    'x-unicode20utf8',
  ],
  'utf-16be': ['unicodefffe', 'utf-16be', 'csutf16be'],
  'utf-16le': [
    'csunicode',
    'iso-10646-ucs-2',
    'ucs-2',
    'unicode',
    'unicodefeff',
    'utf-16',
    'utf-16le',
    'utf16',
    'utf_16',
    'csutf16',
    'csutf16le',
  ],
  'utf-32': ['utf-32', 'utf32', 'utf_32', 'csutf32'],
  'utf-32le': ['utf-32le', 'csutf32le'],
  'utf-32be': ['utf-32be', 'csutf32be'],
  'windows-1252': [
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
    'latin-1',
  ],
  'gbk': [
    'chinese',
    'csgb2312',
    'csiso58gb231280',
    'gb2312',
    'gb_2312',
    'gb_2312-80',
    'gbk',
    'iso-ir-58',
    'x-gbk',
  ],
  'gb18030': ['gb18030'],
  'shift_jis': [
    'csshiftjis',
    'ms932',
    'ms_kanji',
    'shift-jis',
    'shift_jis',
    'sjis',
    'windows-31j',
    'x-sjis',
  ],
  'euc-jp': ['cseucpkdfmtjapanese', 'euc-jp', 'x-euc-jp'],
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
