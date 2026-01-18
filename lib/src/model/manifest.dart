import 'package:convert_object/convert_object.dart';

/// Represents an icon defined in a Web App Manifest.
///
/// Manifest icons are high-quality app icons intended for PWA installation
/// and home screen shortcuts.
///
/// ### Fields
/// * [src] - The absolute URL of the icon.
/// * [sizes] - Size hint (e.g., `192x192`, `512x512`).
/// * [type] - MIME type (e.g., `image/png`).
/// * [purpose] - Icon purpose (e.g., `any`, `maskable`).
///
/// See also:
/// * [WebAppManifestData] for the full manifest structure.
class ManifestIcon {
  /// Creates a [ManifestIcon].
  const ManifestIcon({
    required this.src,
    this.sizes,
    this.type,
    this.purpose,
  });

  /// The absolute URL of the icon image.
  final Uri src;

  /// Size hint (e.g., `192x192`), or `null` if not declared.
  final String? sizes;

  /// MIME type (e.g., `image/png`), or `null` if not declared.
  final String? type;

  /// Icon purpose (e.g., `any`, `maskable`), or `null` if not declared.
  final String? purpose;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'src': src.toString(),
      'sizes': sizes,
      'type': type,
      'purpose': purpose,
    };
  }

  factory ManifestIcon.fromJson(Map<String, dynamic> json) {
    return ManifestIcon(
      src: json.getUri('src'),
      sizes: json.tryGetString('sizes'),
      type: json.tryGetString('type'),
      purpose: json.tryGetString('purpose'),
    );
  }
}

/// Data extracted from a Web App Manifest (`manifest.json`).
///
/// Web App Manifests provide metadata for Progressive Web Apps, including
/// app name, icons, and theme colors.
///
/// ### When to Use
/// Access via [LinkMetadata.manifest] when you need PWA-specific data
/// like high-resolution icons or theme colors.
///
/// ### Example
/// ```dart
/// final manifest = metadata.manifest;
/// if (manifest != null) {
///   print('App name: ${manifest.name}');
///   print('Theme color: ${manifest.themeColor}');
///   for (final icon in manifest.icons) {
///     print('Icon: ${icon.src} (${icon.sizes})');
///   }
/// }
/// ```
///
/// See also:
/// * [ManifestIcon] for individual icon entries.
/// * [MetaLinkOptions.fetchManifest] to enable/disable manifest fetching.
class WebAppManifestData {
  /// Creates a [WebAppManifestData].
  const WebAppManifestData({
    required this.manifestUrl,
    this.name,
    this.shortName,
    this.startUrl,
    this.display,
    this.backgroundColor,
    this.themeColor,
    this.icons = const [],
  });

  /// The URL from which the manifest was fetched.
  final Uri manifestUrl;

  /// The full app name, or `null` if not declared.
  final String? name;

  /// A short app name for limited display contexts, or `null` if not declared.
  final String? shortName;

  /// The start URL when the app is launched, or `null` if not declared.
  final Uri? startUrl;

  /// Display mode (e.g., `standalone`, `fullscreen`), or `null` if not declared.
  final String? display;

  /// Background color (e.g., `#ffffff`), or `null` if not declared.
  final String? backgroundColor;

  /// Theme color for browser chrome (e.g., `#3b82f6`), or `null` if not declared.
  final String? themeColor;

  /// Icons declared in the manifest. Empty list if none declared.
  final List<ManifestIcon> icons;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'manifestUrl': manifestUrl.toString(),
      'name': name,
      'shortName': shortName,
      'startUrl': startUrl?.toString(),
      'display': display,
      'backgroundColor': backgroundColor,
      'themeColor': themeColor,
      'icons': icons.map((e) => e.toJson()).toList(growable: false),
    };
  }

  factory WebAppManifestData.fromJson(Map<String, dynamic> json) {
    final icons = <ManifestIcon>[];
    final rawIcons = json.tryGetList<dynamic>('icons');

    if (rawIcons != null) {
      for (final e in rawIcons) {
        final map = Convert.tryToMap<String, dynamic>(e);
        if (map != null) {
          try {
            icons.add(ManifestIcon.fromJson(map));
          } catch (_) {
            // Skip invalid icon entries so a bad icon does not break parsing.
          }
        }
      }
    }

    return WebAppManifestData(
      manifestUrl: json.getUri('manifestUrl'),
      name: json.tryGetString('name'),
      shortName: json.tryGetString('shortName'),
      startUrl: json.tryGetUri('startUrl'),
      display: json.tryGetString('display'),
      backgroundColor: json.tryGetString('backgroundColor'),
      themeColor: json.tryGetString('themeColor'),
      icons: icons,
    );
  }
}
