import 'package:convert_object/convert_object.dart';

/// Represents a single redirect step during URL resolution.
///
/// When following redirects, each hop is recorded with the source URL,
/// destination URL, and the HTTP status code that triggered the redirect.
///
/// ### Example
/// ```dart
/// for (final hop in result.redirects) {
///   print('${hop.statusCode}: ${hop.from} -> ${hop.to}');
/// }
/// ```
class RedirectHop {
  /// Creates a [RedirectHop].
  const RedirectHop({
    required this.from,
    required this.to,
    required this.statusCode,
    this.location,
  });

  /// The URL that was requested.
  final Uri from;

  /// The URL that was redirected to.
  final Uri to;

  /// The HTTP status code (e.g., `301`, `302`, `307`, `308`).
  final int statusCode;

  /// The raw `Location` header value, or `null` if not present.
  final String? location;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'from': from.toString(),
      'to': to.toString(),
      'statusCode': statusCode,
      'location': location,
    };
  }

  factory RedirectHop.fromJson(Map<String, dynamic> json) {
    return RedirectHop(
      from: json.getUri('from', defaultValue: Uri()),
      to: json.getUri('to', defaultValue: Uri()),
      statusCode: json.tryGetInt('statusCode') ?? 0,
      location: json.tryGetString('location'),
    );
  }
}

/// The result of optimizing/resolving a URL by following redirects.
///
/// [UrlOptimizationResult] captures the redirect chain from the original
/// URL to the final destination, including timing and any errors.
///
/// ### When to Use
/// Use [MetaLinkClient.optimizeUrl] to resolve shortened URLs (e.g., bit.ly)
/// or discover the canonical destination of a link.
///
/// ### Example
/// ```dart
/// final result = await client.optimizeUrl(Uri.parse('https://bit.ly/xyz'));
/// if (result.isOk) {
///   print('Final URL: ${result.finalUrl}');
///   print('Redirects: ${result.redirects.length}');
/// }
/// ```
class UrlOptimizationResult {
  /// Creates a [UrlOptimizationResult].
  const UrlOptimizationResult({
    required this.originalUrl,
    required this.finalUrl,
    required this.redirects,
    required this.statusCode,
    required this.duration,
    this.error,
    this.stackTrace,
  });

  /// The URL that was originally requested.
  final Uri originalUrl;

  /// The final URL after following all redirects.
  final Uri finalUrl;

  /// The sequence of redirects from [originalUrl] to [finalUrl].
  final List<RedirectHop> redirects;

  /// The final HTTP status code, or `null` if the request failed.
  final int? statusCode;

  /// Total time spent resolving the URL.
  final Duration duration;

  /// The error that occurred, if any.
  final Object? error;

  /// Stack trace for [error], if available.
  final StackTrace? stackTrace;

  /// Returns `true` if the resolution succeeded with a 2xx or 3xx status.
  bool get isOk =>
      error == null &&
      statusCode != null &&
      statusCode! >= 200 &&
      statusCode! < 400;
}
