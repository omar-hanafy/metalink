/// @docImport 'package:metalink/src/model/link_metadata.dart';
library;

import 'package:convert_object/convert_object.dart';
import 'package:metalink/src/model/json_uri.dart';

/// The response format of an oEmbed endpoint.
enum OEmbedFormat {
  /// JSON response format (preferred).
  json,

  /// XML response format.
  xml,
}

/// Describes an oEmbed endpoint discovered via `<link rel="alternate">`.
///
/// oEmbed endpoints provide embeddable content metadata from providers
/// like YouTube, Twitter, and Vimeo.
///
/// ### Fields
/// * [url] - The endpoint URL to fetch oEmbed data.
/// * [format] - The response format ([OEmbedFormat.json] or [OEmbedFormat.xml]).
class OEmbedEndpoint {
  /// Creates an [OEmbedEndpoint].
  const OEmbedEndpoint({required this.url, required this.format});

  /// The oEmbed endpoint URL.
  final Uri url;

  /// The response format of the endpoint.
  final OEmbedFormat format;

  /// A JSON-compatible map of this endpoint.
  ///
  /// [url] is written as a string and [format] as its enum name.
  /// [OEmbedEndpoint.fromJson] reads this format back.
  Map<String, dynamic> toJson() {
    return <String, dynamic>{'url': url.toString(), 'format': format.name};
  }

  /// Creates an [OEmbedEndpoint] from a map produced by [toJson].
  ///
  /// Throws a `ConversionException` from `package:convert_object` when `url`
  /// is missing or is not a valid URI. A missing or unknown `format` falls
  /// back to [OEmbedFormat.json].
  factory OEmbedEndpoint.fromJson(Map<String, dynamic> json) {
    return OEmbedEndpoint(
      url: readJsonUri(json, 'url'),
      format: json.getEnum(
        'format',
        parser: EnumParsers.byName(OEmbedFormat.values),
        defaultValue: OEmbedFormat.json,
      ),
    );
  }
}

/// Data fetched from an oEmbed endpoint.
///
/// oEmbed provides rich embed information from content providers. This includes
/// thumbnail images, embed HTML, author information, and more.
///
/// ### When to Use
/// Access via [LinkMetadata.oembed] to get provider-specific embed data
/// for rich media content like videos, tweets, and articles.
///
/// ### Example
/// ```dart
/// final oembed = metadata.oembed;
/// if (oembed != null) {
///   print('Provider: ${oembed.providerName}');
///   print('Author: ${oembed.authorName}');
///   if (oembed.html != null) {
///     // Use oembed.html for embedding
///   }
/// }
/// ```
///
/// See also:
/// * [OEmbedEndpoint] for the endpoint discovery structure.
/// * `ExtractOptions.enableOEmbed` to enable or disable oEmbed fetching.
class OEmbedData {
  /// Creates an [OEmbedData].
  const OEmbedData({
    required this.endpoint,
    this.type,
    this.version,
    this.title,
    this.authorName,
    this.authorUrl,
    this.providerName,
    this.providerUrl,
    this.thumbnailUrl,
    this.thumbnailWidth,
    this.thumbnailHeight,
    this.html,
    this.width,
    this.height,
  });

  /// The endpoint URL this data was fetched from.
  final Uri endpoint;

  /// Content type (e.g., `video`, `photo`, `link`, `rich`).
  final String? type;

  /// oEmbed specification version (typically `1.0`).
  final String? version;

  /// The title of the content.
  final String? title;

  /// The author or creator name.
  final String? authorName;

  /// URL to the author's profile or page.
  final Uri? authorUrl;

  /// The name of the content provider (e.g., `YouTube`, `Twitter`).
  final String? providerName;

  /// URL to the provider's website.
  final Uri? providerUrl;

  /// Thumbnail image URL for the content.
  final Uri? thumbnailUrl;

  /// Thumbnail width in pixels.
  final int? thumbnailWidth;

  /// Thumbnail height in pixels.
  final int? thumbnailHeight;

  /// HTML snippet for embedding the content.
  final String? html;

  /// Embed width in pixels.
  final int? width;

  /// Embed height in pixels.
  final int? height;

  /// A JSON-compatible map of this oEmbed data.
  ///
  /// URLs are written as strings, and absent optional values as `null`. Keys
  /// use the Dart field names, such as `authorName`, not the oEmbed wire names
  /// such as `author_name`. [OEmbedData.fromJson] reads this format back.
  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'endpoint': endpoint.toString(),
      'type': type,
      'version': version,
      'title': title,
      'authorName': authorName,
      'authorUrl': authorUrl?.toString(),
      'providerName': providerName,
      'providerUrl': providerUrl?.toString(),
      'thumbnailUrl': thumbnailUrl?.toString(),
      'thumbnailWidth': thumbnailWidth,
      'thumbnailHeight': thumbnailHeight,
      'html': html,
      'width': width,
      'height': height,
    };
  }

  /// Creates an [OEmbedData] from a map produced by [toJson].
  ///
  /// This reads the serialized model format, not a raw oEmbed provider
  /// response. Throws a `ConversionException` from `package:convert_object`
  /// when `endpoint` is missing or is not a valid URI. Optional values that
  /// cannot be converted become `null`.
  factory OEmbedData.fromJson(Map<String, dynamic> json) {
    return OEmbedData(
      endpoint: readJsonUri(json, 'endpoint'),
      type: json.tryGetString('type'),
      version: json.tryGetString('version'),
      title: json.tryGetString('title'),
      authorName: json.tryGetString('authorName'),
      authorUrl: tryReadJsonUri(json, 'authorUrl'),
      providerName: json.tryGetString('providerName'),
      providerUrl: tryReadJsonUri(json, 'providerUrl'),
      thumbnailUrl: tryReadJsonUri(json, 'thumbnailUrl'),
      thumbnailWidth: json.tryGetInt('thumbnailWidth'),
      thumbnailHeight: json.tryGetInt('thumbnailHeight'),
      html: json.tryGetString('html'),
      width: json.tryGetInt('width'),
      height: json.tryGetInt('height'),
    );
  }
}
