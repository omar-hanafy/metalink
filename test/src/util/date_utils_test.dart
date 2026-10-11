import 'dart:io';
import 'dart:isolate';

import 'package:metalink/src/util/date_utils.dart';
import 'package:test/test.dart';

void main() {
  group('DateUtils.parseString', () {
    test('reads zone-less timestamps as UTC on every host', () {
      final dateOnly = DateUtils.parseString('2024-01-15');
      expect(dateOnly, DateTime.utc(2024, 1, 15));
      expect(dateOnly!.isUtc, isTrue);

      final dateTime = DateUtils.parseString('2024-01-15T10:30:00');
      expect(dateTime, DateTime.utc(2024, 1, 15, 10, 30));
      expect(dateTime!.isUtc, isTrue);

      expect(
        DateUtils.parseString('2024-01-15 10:30:00'),
        DateTime.utc(2024, 1, 15, 10, 30),
      );
    });

    test('keeps explicit zone designators', () {
      expect(
        DateUtils.parseString('2024-01-15T10:00:00Z'),
        DateTime.utc(2024, 1, 15, 10),
      );
      expect(
        DateUtils.parseString('2024-01-15T10:00:00+02:00'),
        DateTime.utc(2024, 1, 15, 8),
      );
    });

    test('reads digit-only epochs by length', () {
      expect(
        DateUtils.parseString('1705312800'),
        DateTime.utc(2024, 1, 15, 10),
      );
      expect(
        DateUtils.parseString('1705312800000'),
        DateTime.utc(2024, 1, 15, 10),
      );
      expect(DateUtils.parseString('20240115'), DateTime.utc(2024, 1, 15));
    });

    test('returns null instead of throwing for out-of-range epochs', () {
      expect(DateUtils.parseString('99999999999999999'), isNull);
      expect(DateUtils.parseString('1705296000000000000'), isNull);
      expect(DateUtils.parseString('99999999999999999999999'), isNull);
    });

    test('returns null for empty and malformed input', () {
      expect(DateUtils.parseString(null), isNull);
      expect(DateUtils.parseString('   '), isNull);
      expect(DateUtils.parseString('yesterday'), isNull);
      expect(DateUtils.parseString('+275760-09-13T23:00:00'), isNull);
      // DateTime.tryParse wraps this year instead of rejecting it.
      expect(DateUtils.parseString('+999999-01-01'), isNull);
      expect(DateUtils.parseString('-0050-01-01'), isNull);
    });
  });

  group('DateUtils.parseString calendar validation', () {
    test('rejects components outside their calendar range', () {
      for (final input in const [
        '2024-13-45T00:00:00Z',
        '2024-02-30',
        '2023-02-29',
        '2024-00-00',
        '2024-04-31',
        '2024-01-01T25:61:00',
        '2024-01-01T24:00:01',
        '2024-01-01T24:01',
        '2024-01-01T24:00:00.5',
        '2024-01-01T10:00:61Z',
        '2024-01-01T10:00:00+24:00',
      ]) {
        expect(DateUtils.parseString(input), isNull, reason: input);
      }
    });

    test('accepts the RFC 3339 leap second and the ISO 8601 end of day', () {
      // Both forms are valid, and 2.1.0 accepted them through DateTime.parse.
      expect(DateUtils.parseString('2016-12-31T23:59:60Z'), DateTime.utc(2017));
      expect(
        DateUtils.parseString('2016-12-31T15:59:60.5-08:00'),
        DateTime.utc(2017, 1, 1, 0, 0, 0, 500),
      );
      expect(
        DateUtils.parseString('2024-01-15T24:00:00Z'),
        DateTime.utc(2024, 1, 16),
      );
      expect(DateUtils.parseString('2024-12-31T24:00'), DateTime.utc(2025));
      expect(
        DateUtils.parseString('2024-01-15T24:00:00.000+02:00'),
        DateTime.utc(2024, 1, 15, 22),
      );
    });

    test('accepts leap days, fractions, and compact offsets', () {
      expect(DateUtils.parseString('2024-02-29'), DateTime.utc(2024, 2, 29));
      expect(
        DateUtils.parseString('2024-01-15T10:30:00.123456789Z'),
        DateTime.utc(2024, 1, 15, 10, 30, 0, 123, 456),
      );
      expect(
        DateUtils.parseString('2024-01-15T10:30:00+0530'),
        DateTime.utc(2024, 1, 15, 5),
      );
      expect(
        DateUtils.parseString('2024-01-15T10:30-02'),
        DateTime.utc(2024, 1, 15, 12, 30),
      );
    });
  });

  test(
    'zone-less values give the same instant in every host time zone',
    () async {
      // Run the parser in child VMs whose local time zone skips the wall time
      // being parsed. In-process tests cannot change the host zone, and a UTC
      // CI host would hide a regression.
      final packageConfig =
          await Isolate.packageConfig ??
          File('.dart_tool/package_config.json').absolute.uri;
      final tempDir = Directory.systemTemp.createTempSync('metalink_tz_');
      addTearDown(() => tempDir.deleteSync(recursive: true));
      final probe = File('${tempDir.path}/tz_probe.dart')
        ..writeAsStringSync(_timeZoneProbe);

      const expected = <String>[
        '2024-03-10T02:30:00.000Z',
        '2024-09-08T00:00:00.000Z',
        '2024-03-31T02:30:00.000Z',
        '2011-12-30T00:00:00.000Z',
      ];
      for (final zone in const [
        'UTC',
        'America/New_York',
        'America/Santiago',
        'Europe/Berlin',
        'Pacific/Apia',
      ]) {
        final run = await Process.run(
          Platform.resolvedExecutable,
          ['--packages=${packageConfig.toFilePath()}', probe.path],
          environment: {'TZ': zone},
        );
        expect(run.exitCode, 0, reason: '$zone: ${run.stderr}');
        expect(
          (run.stdout as String).trim().split('\n'),
          expected,
          reason: 'TZ=$zone',
        );
      }
    },
    testOn: '!windows',
    timeout: const Timeout(Duration(minutes: 2)),
  );

  group('DateUtils.parseEpoch', () {
    test('reads milliseconds and seconds by magnitude', () {
      expect(
        DateUtils.parseEpoch(1705312800000),
        DateTime.utc(2024, 1, 15, 10),
      );
      expect(DateUtils.parseEpoch(1705312800), DateTime.utc(2024, 1, 15, 10));
    });

    test('rejects ambiguous and out-of-range values', () {
      expect(DateUtils.parseEpoch(20240115), isNull);
      expect(DateUtils.parseEpoch(-5), isNull);
      expect(DateUtils.parseEpoch(99999999999999999), isNull);
      // Within DateTime's range but far beyond any publication year.
      expect(DateUtils.parseEpoch(900000000000000), isNull);
    });
  });
}

/// Parses wall times that a daylight-saving transition skips in at least one
/// of the time zones the test runs it under.
const _timeZoneProbe = r'''
import 'package:metalink/src/util/date_utils.dart';

void main() {
  for (final input in const [
    '2024-03-10T02:30:00',
    '2024-09-08',
    '2024-03-31T02:30:00',
    '2011-12-30',
  ]) {
    print(DateUtils.parseString(input)?.toIso8601String());
  }
}
''';
