/// Deterministic timestamp parsing for page metadata.
///
/// Every extractor that reads publication or modification times uses
/// [DateUtils] so the same input produces the same instant on every host.
class DateUtils {
  // DateTime supports exactly 100,000,000 days on either side of the epoch.
  static const int _maxEpochMilliseconds = 8640000000000000;

  /// Parses a timestamp string from HTML metadata.
  ///
  /// Accepts the ISO 8601 and RFC 3339 forms that [DateTime.parse] accepts,
  /// including a space instead of `T` between the date and time and the
  /// compact form `20240115`. A value without a `Z` or numeric offset is read
  /// as UTC. The value is never interpreted in the host's local time zone, so
  /// the same input produces the same instant on every host, including wall
  /// times that a local daylight-saving transition skips.
  ///
  /// A string of exactly 10 digits is read as epoch seconds and a string of 13
  /// or more digits as epoch milliseconds.
  ///
  /// A leap second such as `23:59:60` rolls over into the next minute, and
  /// `24:00` (with zero minutes, seconds, and fraction) is the end of the day,
  /// that is, midnight of the next day.
  ///
  /// Returns `null` for empty or malformed input, for components outside
  /// their calendar range (such as month 13, February 30, or minute 61), and
  /// for instants outside years 1 through 9999.
  static DateTime? parseString(String? raw) {
    final s = raw?.trim();
    if (s == null || s.isEmpty) return null;

    if (_digitsOnly.hasMatch(s)) {
      if (s.length >= 13) {
        final milliseconds = int.tryParse(s);
        return milliseconds == null
            ? null
            : _fromEpochMilliseconds(milliseconds);
      }
      if (s.length == 10) {
        final seconds = int.tryParse(s);
        return seconds == null ? null : _fromEpochMilliseconds(seconds * 1000);
      }
    }

    final match = _isoDateTime.firstMatch(s);
    if (match == null) return null;

    final year = int.parse(match[1]!);
    final month = int.parse(match[2]!);
    final day = int.parse(match[3]!);
    final hour = _optionalInt(match[4]);
    final minute = _optionalInt(match[5]);
    final second = _optionalInt(match[6]);
    // DateTime keeps microsecond precision; further fraction digits are
    // dropped.
    final micros = int.parse((match[7] ?? '').padRight(6, '0').substring(0, 6));

    if (year < 1 || year > 9999) return null;
    if (month < 1 || month > 12) return null;
    if (day < 1 || day > _daysInMonth(year, month)) return null;
    // RFC 3339 allows a leap second, which rolls into the next minute as
    // DateTime.parse rolls it, and ISO 8601 writes the end of a day as 24:00.
    final endOfDay = hour == 24 && minute == 0 && second == 0 && micros == 0;
    if ((hour > 23 && !endOfDay) || minute > 59 || second > 60) return null;

    var offsetMinutes = 0;
    final sign = match[9];
    if (sign != null) {
      final offsetHours = int.parse(match[10]!);
      final offsetMinutesPart = _optionalInt(match[11]);
      if (offsetHours > 23 || offsetMinutesPart > 59) return null;
      offsetMinutes =
          (offsetHours * 60 + offsetMinutesPart) * (sign == '-' ? -1 : 1);
    }

    // Building the value directly in UTC never consults the local time zone,
    // which would otherwise move wall times that a daylight-saving transition
    // skips on the host.
    final utc = DateTime.utc(
      year,
      month,
      day,
      hour,
      minute,
      second,
      micros ~/ 1000,
      micros % 1000,
    ).subtract(Duration(minutes: offsetMinutes));
    return _plausible(utc);
  }

  /// Parses an integer epoch timestamp from structured data.
  ///
  /// Values of at least `1000000000000` are read as milliseconds and values of
  /// at least `1000000000` as seconds. Smaller values are too ambiguous to
  /// interpret and return `null`, as do instants outside years 1 through 9999.
  static DateTime? parseEpoch(int value) {
    if (value >= 1000000000000) return _fromEpochMilliseconds(value);
    if (value >= 1000000000) return _fromEpochMilliseconds(value * 1000);
    return null;
  }

  static final RegExp _digitsOnly = RegExp(r'^\d+$');

  // The grammar DateTime.parse accepts, with one group per component:
  // 1 year, 2 month, 3 day, 4 hour, 5 minute, 6 second, 7 fraction,
  // 8 zone designator, 9 offset sign, 10 offset hours, 11 offset minutes.
  static final RegExp _isoDateTime = RegExp(
    r'^([+-]?\d{4,6})-?(\d\d)-?(\d\d)'
    r'(?:[ T](\d\d)(?::?(\d\d)(?::?(\d\d)(?:[.,](\d+))?)?)?'
    r'( ?[zZ]| ?([-+])(\d\d)(?::?(\d\d))?)?)?$',
  );

  static int _optionalInt(String? digits) =>
      digits == null ? 0 : int.parse(digits);

  static int _daysInMonth(int year, int month) {
    if (month == 2) {
      final leap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0;
      return leap ? 29 : 28;
    }
    return const [31, 0, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][month - 1];
  }

  static DateTime? _fromEpochMilliseconds(int milliseconds) {
    if (milliseconds.abs() > _maxEpochMilliseconds) return null;
    return _plausible(
      DateTime.fromMillisecondsSinceEpoch(milliseconds, isUtc: true),
    );
  }

  // No page publishes content outside years 1 through 9999, so anything else,
  // including an offset that pushes a boundary date past them, is malformed.
  static DateTime? _plausible(DateTime value) {
    if (value.year < 1 || value.year > 9999) return null;
    return value;
  }
}
