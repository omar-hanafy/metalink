import 'package:convert_object/convert_object.dart';

/// Represents an image candidate extracted from the page.
///
/// Images are discovered from Open Graph (`og:image`), Twitter Cards
/// (`twitter:image`), JSON-LD, and other sources.
///
/// ### Fields
/// * [url] - The absolute URL of the image.
/// * [width], [height] - Dimensions in pixels, if declared.
/// * [mimeType] - Image format (e.g., `image/jpeg`), if declared.
/// * [alt] - Alt text for accessibility, if available.
/// * [byteSize] - File size in bytes, if known.
///
/// ### Example
/// ```dart
/// final image = metadata.images.firstOrNull;
/// if (image != null) {
///   print('Image: ${image.url}');
///   if (image.width != null) print('Size: ${image.width}x${image.height}');
/// }
/// ```
class ImageCandidate {
  /// Creates an [ImageCandidate].
  const ImageCandidate({
    required this.url,
    this.width,
    this.height,
    this.mimeType,
    this.alt,
    this.byteSize,
  });

  /// The absolute URL of the image.
  final Uri url;

  /// Image width in pixels, or `null` if not declared.
  final int? width;

  /// Image height in pixels, or `null` if not declared.
  final int? height;

  /// MIME type (e.g., `image/jpeg`, `image/png`), or `null` if not declared.
  final String? mimeType;

  /// Alt text for accessibility, or `null` if not available.
  final String? alt;

  /// File size in bytes, or `null` if not known.
  final int? byteSize;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'url': url.toString(),
      'width': width,
      'height': height,
      'mimeType': mimeType,
      'alt': alt,
      'byteSize': byteSize,
    };
  }

  factory ImageCandidate.fromJson(Map<String, dynamic> json) {
    return ImageCandidate(
      url: json.getUri('url'),
      width: json.tryGetInt('width'),
      height: json.tryGetInt('height'),
      mimeType: json.tryGetString('mimeType'),
      alt: json.tryGetString('alt'),
      byteSize: json.tryGetInt('byteSize'),
    );
  }
}

/// Represents a video candidate extracted from the page.
///
/// Videos are discovered from Open Graph (`og:video`), oEmbed, JSON-LD,
/// and other sources.
///
/// ### Fields
/// * [url] - The absolute URL of the video file or embed.
/// * [width], [height] - Dimensions in pixels, if declared.
/// * [mimeType] - Video format (e.g., `video/mp4`), if declared.
class VideoCandidate {
  /// Creates a [VideoCandidate].
  const VideoCandidate({
    required this.url,
    this.width,
    this.height,
    this.mimeType,
  });

  /// The absolute URL of the video.
  final Uri url;

  /// Video width in pixels, or `null` if not declared.
  final int? width;

  /// Video height in pixels, or `null` if not declared.
  final int? height;

  /// MIME type (e.g., `video/mp4`), or `null` if not declared.
  final String? mimeType;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'url': url.toString(),
      'width': width,
      'height': height,
      'mimeType': mimeType,
    };
  }

  factory VideoCandidate.fromJson(Map<String, dynamic> json) {
    return VideoCandidate(
      url: json.getUri('url'),
      width: json.tryGetInt('width'),
      height: json.tryGetInt('height'),
      mimeType: json.tryGetString('mimeType'),
    );
  }
}

/// Represents an audio candidate extracted from the page.
///
/// Audio files are discovered from Open Graph (`og:audio`), JSON-LD,
/// and other sources.
///
/// ### Fields
/// * [url] - The absolute URL of the audio file.
/// * [mimeType] - Audio format (e.g., `audio/mpeg`), if declared.
class AudioCandidate {
  /// Creates an [AudioCandidate].
  const AudioCandidate({
    required this.url,
    this.mimeType,
  });

  /// The absolute URL of the audio file.
  final Uri url;

  /// MIME type (e.g., `audio/mpeg`), or `null` if not declared.
  final String? mimeType;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'url': url.toString(),
      'mimeType': mimeType,
    };
  }

  factory AudioCandidate.fromJson(Map<String, dynamic> json) {
    return AudioCandidate(
      url: json.getUri('url'),
      mimeType: json.tryGetString('mimeType'),
    );
  }
}
