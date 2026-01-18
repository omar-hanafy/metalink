import 'dart:convert';

/// Utility functions for safe JSON parsing.
///
/// [JsonUtils] provides null-safe JSON decoding methods that return `null`
/// on parse errors instead of throwing exceptions.
class JsonUtils {
  /// Attempts to decode [input] as a JSON object.
  ///
  /// Returns `null` if decoding fails or the result is not a [Map].
  static Map<String, dynamic>? tryDecodeObject(String input) {
    final dynamic decoded = tryDecodeAny(input);
    if (decoded is Map) {
      return decoded.map<String, dynamic>(
        (key, value) => MapEntry(key.toString(), value),
      );
    }
    return null;
  }

  /// Attempts to decode [input] as a JSON array.
  ///
  /// Returns `null` if decoding fails or the result is not a [List].
  static List<dynamic>? tryDecodeList(String input) {
    final dynamic decoded = tryDecodeAny(input);
    return decoded is List ? decoded : null;
  }

  /// Attempts to decode [input] as any JSON value.
  ///
  /// Returns `null` if decoding fails.
  static dynamic tryDecodeAny(String input) {
    try {
      return json.decode(input);
    } catch (_) {
      return null;
    }
  }
}
