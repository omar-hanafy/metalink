/// URI decoding shared by the model `fromJson` factories.
///
/// convert_object's `getUri` and `tryGetUri` coerce email-shaped and
/// phone-shaped strings into `mailto:` and `tel:` URIs, which rewrites real
/// URLs such as `https://medium.com/@john.doe`. These helpers parse the stored
/// string as written instead. This library is internal and not exported.
library;

import 'package:convert_object/convert_object.dart';

/// The URI stored under [key] in [json], or `null` when it is missing or
/// invalid.
///
/// A [Uri] value is returned as is. A [String] value is trimmed and parsed
/// with [Uri.tryParse]; an empty string counts as missing. Any other value
/// type is treated as invalid.
Uri? tryReadJsonUri(Map<String, dynamic> json, String key) {
  return _parseJsonUri(json[key]);
}

/// The URI stored under [key] in [json], parsed like [tryReadJsonUri].
///
/// Returns [defaultValue] when the value is missing or invalid and a default
/// is given. Otherwise throws a [ConversionException], matching the failure
/// type of convert_object's `getUri` so existing catch clauses keep working.
Uri readJsonUri(Map<String, dynamic> json, String key, {Uri? defaultValue}) {
  final value = json[key];
  final uri = _parseJsonUri(value);
  if (uri != null) return uri;
  if (defaultValue != null) return defaultValue;
  throw ConversionException(
    error: value == null
        ? 'object is unsupported or null'
        : FormatException('Invalid URI', value),
    context: <String, dynamic>{
      'method': 'readJsonUri',
      'key': key,
      'object': value,
      'objectType': value.runtimeType.toString(),
      'targetType': 'Uri',
    },
  );
}

Uri? _parseJsonUri(Object? value) {
  if (value is Uri) return value;
  if (value is! String) return null;
  final trimmed = value.trim();
  if (trimmed.isEmpty) return null;
  return Uri.tryParse(trimmed);
}
