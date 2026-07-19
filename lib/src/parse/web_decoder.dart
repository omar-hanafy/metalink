import 'dart:convert';

import 'package:charset/charset.dart' as charset;
import 'package:html/parser.dart' as html_parser;
import 'package:metalink/src/model/diagnostics.dart';

/// Result of decoding web response bytes.
class WebDecodeResult {
  const WebDecodeResult({
    required this.text,
    required this.charset,
    required this.source,
  });

  final String text;
  final String charset;
  final CharsetSource source;

  bool get usedFallback => source == CharsetSource.fallback;
}

/// Decodes HTML response bytes using deterministic web charset precedence.
///
/// Precedence is byte-order mark, HTTP `Content-Type`, HTML meta declaration,
/// then a forgiving UTF-8 fallback. ISO-8859-1 and ASCII labels intentionally
/// use Windows-1252, matching browser behavior for legacy web content.
class WebDecoder {
  const WebDecoder({this.metaProbeBytes = 4096});

  final int metaProbeBytes;

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

    final headerLabel = _charsetFromHeader(
      _headerValue(headers, 'content-type'),
    );
    final header = _decodeLabel(bytes, headerLabel, CharsetSource.header);
    if (header != null) return header;

    final metaLabel = _charsetFromMeta(bytes);
    final meta = _decodeLabel(bytes, metaLabel, CharsetSource.meta);
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

    if (_startsWith(bytes, const [0xFE, 0xFF]) ||
        _startsWith(bytes, const [0xFF, 0xFE])) {
      return WebDecodeResult(
        text: charset.utf16.decode(bytes),
        charset: 'utf-16',
        source: CharsetSource.bom,
      );
    }

    return null;
  }

  WebDecodeResult? _decodeLabel(
    List<int> bytes,
    String? rawLabel,
    CharsetSource source,
  ) {
    if (rawLabel == null) return null;
    final label = _canonicalLabel(rawLabel);
    if (label == null) return null;

    try {
      final String text;
      switch (label) {
        case 'utf-8':
          text = utf8.decode(bytes, allowMalformed: true);
        case 'utf-16le':
          text = const charset.Utf16Decoder().decodeUtf16Le(bytes);
        case 'utf-16be':
          text = const charset.Utf16Decoder().decodeUtf16Be(bytes);
        case 'utf-32le':
          text = const charset.Utf32Decoder().decodeUtf32Le(bytes);
        case 'utf-32be':
          text = const charset.Utf32Decoder().decodeUtf32Be(bytes);
        default:
          final encoding = charset.Charset.getByName(label);
          if (encoding == null) return null;
          text = encoding.decode(bytes);
      }

      return WebDecodeResult(text: text, charset: label, source: source);
    } on Object {
      return null;
    }
  }

  String? _charsetFromHeader(String? contentType) {
    if (contentType == null || contentType.trim().isEmpty) return null;
    final match = RegExp(
      r'''charset\s*=\s*(?:"([^"]+)"|'([^']+)'|([^;\s]+))''',
      caseSensitive: false,
    ).firstMatch(contentType);
    return _firstNonEmptyGroup(match);
  }

  String? _charsetFromMeta(List<int> bytes) {
    final probeLength = bytes.length < metaProbeBytes
        ? bytes.length
        : metaProbeBytes;
    if (probeLength <= 0) return null;

    final probe = latin1.decode(bytes.sublist(0, probeLength));
    final document = html_parser.parse(probe);
    for (final meta in document.querySelectorAll('meta')) {
      final directLabel = meta.attributes['charset']?.trim();
      if (directLabel != null && directLabel.isNotEmpty) return directLabel;

      final httpEquiv = meta.attributes['http-equiv']?.trim().toLowerCase();
      if (httpEquiv != 'content-type') continue;

      final contentLabel = _charsetFromHeader(meta.attributes['content']);
      if (contentLabel != null) return contentLabel;
    }
    return null;
  }

  String? _canonicalLabel(String raw) {
    final label = raw.trim().toLowerCase();
    if (label.isEmpty) return null;

    switch (label) {
      case 'utf8':
        return 'utf-8';
      case 'latin1':
      case 'latin-1':
      case 'iso-8859-1':
      case 'iso_8859-1':
      case 'iso8859-1':
      case 'us-ascii':
      case 'ascii':
        return 'windows-1252';
      case 'cp1252':
      case 'cp-1252':
      case 'windows1252':
        return 'windows-1252';
      case 'sjis':
      case 'x-sjis':
      case 'shift-jis':
      case 'shiftjis':
        return 'shift_jis';
      default:
        return charset.Charset.getByName(label) == null ? null : label;
    }
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
