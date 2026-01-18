import 'package:convert_object/convert_object.dart';

/// Represents a favicon or icon candidate extracted from the page.
///
/// Icons are discovered from `<link rel="icon">`, `<link rel="apple-touch-icon">`,
/// Web App Manifest icons, and similar sources.
///
/// ### Fields
/// * [url] - The absolute URL of the icon image.
/// * [sizes] - Size hint (e.g., `32x32`, `180x180`), if declared.
/// * [type] - MIME type (e.g., `image/png`), if declared.
/// * [rel] - The `rel` attribute value (e.g., `icon`, `apple-touch-icon`).
///
/// ### Example
/// ```dart
/// for (final icon in metadata.icons) {
///   print('Icon: ${icon.url} (${icon.sizes ?? "unknown size"})');
/// }
/// ```
class IconCandidate {
  /// Creates an [IconCandidate].
  const IconCandidate({
    required this.url,
    this.sizes,
    this.type,
    this.rel,
  });

  /// The absolute URL of the icon image.
  final Uri url;

  /// Size hint (e.g., `32x32`, `180x180`), or `null` if not declared.
  final String? sizes;

  /// MIME type (e.g., `image/png`), or `null` if not declared.
  final String? type;

  /// The link `rel` value (e.g., `icon`, `apple-touch-icon`).
  final String? rel;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'url': url.toString(),
      'sizes': sizes,
      'type': type,
      'rel': rel,
    };
  }

  factory IconCandidate.fromJson(Map<String, dynamic> json) {
    return IconCandidate(
      url: json.getUri('url'),
      sizes: json.tryGetString('sizes'),
      type: json.tryGetString('type'),
      rel: json.tryGetString('rel'),
    );
  }
}
