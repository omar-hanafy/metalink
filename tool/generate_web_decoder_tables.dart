// Generates lib/src/parse/web_decoder_tables.dart from the WHATWG Encoding
// Standard index files.
//
// Usage, from the package root:
//
//   1. Download https://encoding.spec.whatwg.org/index-<name>.txt for every
//      name in `_singleByteEncodings` plus `jis0208`, `jis0212`, `gb18030`,
//      and `gb18030-ranges` into one directory.
//   2. dart run tool/generate_web_decoder_tables.dart <directory>
//   3. dart format lib/src/parse/web_decoder_tables.dart
//
// The multibyte decoders look up most sequences through the strict decoders of
// the `charset` package. This script verifies that, with the ranges and
// overrides it emits, those lookups reproduce each WHATWG index exactly, and
// fails otherwise.

import 'dart:io';

import 'package:charset/charset.dart' as charset;

const _singleByteEncodings = [
  'ibm866',
  'iso-8859-2',
  'iso-8859-3',
  'iso-8859-4',
  'iso-8859-5',
  'iso-8859-6',
  'iso-8859-7',
  'iso-8859-8',
  'iso-8859-10',
  'iso-8859-13',
  'iso-8859-14',
  'iso-8859-15',
  'iso-8859-16',
  'windows-874',
  'windows-1250',
  'windows-1251',
  'windows-1252',
  'windows-1253',
  'windows-1254',
  'windows-1255',
  'windows-1256',
  'windows-1257',
  'windows-1258',
];

/// jis0208 pointer ranges (start inclusive, end exclusive) that the `charset`
/// Shift_JIS table lacks: the NEC-selected IBM extensions (Shift_JIS lead
/// bytes 0xED and 0xEE) and the IBM extensions (lead bytes 0xFA to 0xFC).
const _jis0208Ranges = [(8272, 8648), (10716, 11104)];

void main(List<String> args) {
  if (args.length != 1) {
    stderr.writeln('usage: generate_web_decoder_tables.dart <index-directory>');
    exit(64);
  }
  final directory = args.single;
  final dates = <String>{};

  Map<int, int> load(String name) {
    final index = <int, int>{};
    final file = File('$directory/index-$name.txt');
    for (final line in file.readAsLinesSync()) {
      if (line.startsWith('# Date:')) dates.add(line.substring(7).trim());
      if (line.startsWith('#') || line.trim().isEmpty) continue;
      final fields = line.trim().split(RegExp(r'\s+'));
      index[int.parse(fields[0])] = int.parse(
        fields[1].substring(2),
        radix: 16,
      );
    }
    return index;
  }

  final out = StringBuffer();

  out.writeln('// Single-byte encodings: code points for bytes 0x80 to 0xFF.');
  out.writeln('const _singleByteTables = <String, String>{');
  for (final name in _singleByteEncodings) {
    final index = load(name);
    final units = [for (var p = 0; p < 128; p++) index[p] ?? 0xFFFD];
    out.writeln("  '$name':");
    _writeString(out, units);
    out.writeln(',');
  }
  out.writeln('};');
  out.writeln();

  // jis0208: the charset Shift_JIS table plus the embedded ranges.
  final jis0208 = load('jis0208');
  out.writeln('// jis0208 code points for pointers missing from the `charset`');
  out.writeln('// Shift_JIS table, as (first pointer, code points) pairs.');
  out.writeln('const _jis0208Extensions = <(int, String)>[');
  for (final (start, end) in _jis0208Ranges) {
    final units = [for (var p = start; p < end; p++) jis0208[p] ?? 0xFFFD];
    if (units.any((unit) => unit > 0xFFFF)) throw StateError('non-BMP');
    out.writeln('  (');
    out.writeln('    $start,');
    _writeString(out, units, indent: '    ');
    out.writeln(',');
    out.writeln('  ),');
  }
  out.writeln('];');
  out.writeln();
  for (var pointer = 0; pointer < 11280; pointer++) {
    final embedded = _jis0208Ranges.any(
      (r) => pointer >= r.$1 && pointer < r.$2,
    );
    if (embedded) continue;
    final lead = pointer ~/ 188;
    final trail = pointer % 188;
    final actual = _single(const charset.ShiftJISDecoder().convert, [
      lead < 0x1F ? lead + 0x81 : lead + 0xC1,
      trail < 0x3F ? trail + 0x40 : trail + 0x41,
    ]);
    if (actual != jis0208[pointer]) {
      throw StateError('jis0208 pointer $pointer differs; widen the ranges');
    }
  }

  final jis0212 = load('jis0212');
  _writeOverrides(out, '_jis0212Overrides', jis0212, 8836, (pointer) {
    return [0x8F, pointer ~/ 94 + 0xA1, pointer % 94 + 0xA1];
  }, const charset.EucJPDecoder().convert);

  final gb18030 = load('gb18030');
  _writeOverrides(out, '_gb18030Overrides', gb18030, 23940, (pointer) {
    final trail = pointer % 190;
    return [pointer ~/ 190 + 0x81, trail < 0x3F ? trail + 0x40 : trail + 0x41];
  }, const charset.GbkDecoder().convert);

  final ranges = load('gb18030-ranges');
  out.writeln('// gb18030 four-byte ranges as (pointer, code point) pairs.');
  out.writeln('const _gb18030Ranges = <int>[');
  for (final entry in ranges.entries) {
    out.writeln('  ${entry.key}, 0x${_hex(entry.value)},');
  }
  out.writeln('];');

  final header = StringBuffer()
    ..writeln('// GENERATED FILE. Do not edit by hand.')
    ..writeln('//')
    ..writeln('// Source: the WHATWG Encoding Standard index files at')
    ..writeln('// https://encoding.spec.whatwg.org/index-<name>.txt')
    ..writeln(
      '// (index date ${dates.join(', ')}), generated '
      '${DateTime.now().toIso8601String().substring(0, 10)}.',
    )
    ..writeln('//')
    ..writeln('// Regenerate with tool/generate_web_decoder_tables.dart;')
    ..writeln('// its header lists the steps.')
    ..writeln()
    ..writeln("part of 'web_decoder.dart';")
    ..writeln();
  File('lib/src/parse/web_decoder_tables.dart')
      .writeAsStringSync('$header$out');
}

void _writeOverrides(
  StringBuffer out,
  String name,
  Map<int, int> index,
  int size,
  List<int> Function(int pointer) bytesFor,
  String Function(List<int> bytes) decode,
) {
  out.writeln('// Pointers where the `charset` strict decoder disagrees with');
  out.writeln('// the WHATWG index; `0xFFFD` marks a pointer WHATWG leaves');
  out.writeln('// unmapped.');
  out.writeln('const $name = <int, int>{');
  for (var pointer = 0; pointer < size; pointer++) {
    final actual = _single(decode, bytesFor(pointer));
    final expected = index[pointer];
    if (actual == expected) continue;
    out.writeln('  $pointer: 0x${_hex(expected ?? 0xFFFD)},');
  }
  out.writeln('};');
  out.writeln();
}

int? _single(String Function(List<int> bytes) decode, List<int> bytes) {
  try {
    final runes = decode(bytes).runes.toList();
    return runes.length == 1 ? runes.single : null;
  } on Object {
    return null;
  }
}

void _writeString(StringBuffer out, List<int> units, {String indent = '    '}) {
  for (var start = 0; start < units.length; start += 8) {
    final end = start + 8 < units.length ? start + 8 : units.length;
    final chunk = units.sublist(start, end).map((u) => '\\u${_hex(u)}').join();
    out.write("$indent'$chunk'");
    if (end < units.length) out.writeln();
  }
}

String _hex(int value) => value.toRadixString(16).toUpperCase().padLeft(4, '0');
