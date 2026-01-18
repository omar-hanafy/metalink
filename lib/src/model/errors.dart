import 'package:convert_object/convert_object.dart';

/// Categorizes the type of failure that occurred during extraction.
///
/// Use [MetaLinkError.code] to determine why extraction failed and decide
/// whether to retry, show a fallback, or surface the error to users.
///
/// ### Retryable Errors
/// * [network], [timeout] - Transient network issues; retry with backoff.
/// * [httpStatus] - Server error (5xx); may succeed on retry.
///
/// ### Non-Retryable Errors
/// * [invalidUrl] - Malformed URL; fix the input.
/// * [nonHtmlContent] - URL points to non-HTML (PDF, image, etc.).
/// * [decode], [parse] - Corrupt or malformed HTML.
enum MetaLinkErrorCode {
  /// The provided URL is malformed or unsupported.
  invalidUrl,

  /// Network connectivity failure (DNS, TCP, TLS, etc.).
  network,

  /// The request exceeded the configured timeout.
  timeout,

  /// The server returned a non-success HTTP status (4xx or 5xx).
  httpStatus,

  /// The response content is not HTML (e.g., PDF, image, JSON).
  nonHtmlContent,

  /// Failed to decode the response body (charset issues).
  decode,

  /// Failed to parse the HTML document.
  parse,

  /// Failed to fetch or parse the oEmbed endpoint.
  oembed,

  /// Failed to fetch or parse the Web App Manifest.
  manifest,

  /// Cache read or write operation failed.
  cache,

  /// An unexpected error occurred.
  unknown,
}

/// Represents a fatal error that prevented metadata extraction.
///
/// [MetaLinkError] provides structured error information including an error
/// code, human-readable message, and optional context like the failing URL
/// or HTTP status code.
///
/// ### When to Use
/// Check [ExtractionResult.error] to determine if extraction failed, then
/// inspect [code] to categorize the failure.
///
/// ### Example
/// ```dart
/// final result = await MetaLink.extract(url);
/// if (result.error != null) {
///   switch (result.error!.code) {
///     case MetaLinkErrorCode.timeout:
///       print('Request timed out');
///       break;
///     case MetaLinkErrorCode.httpStatus:
///       print('HTTP ${result.error!.statusCode}');
///       break;
///     default:
///       print(result.error!.message);
///   }
/// }
/// ```
class MetaLinkError {
  /// Creates a [MetaLinkError].
  const MetaLinkError({
    required this.code,
    required this.message,
    this.uri,
    this.statusCode,
    this.cause,
    this.stackTrace,
  });

  /// The category of error. See [MetaLinkErrorCode].
  final MetaLinkErrorCode code;

  /// Human-readable description of what went wrong.
  final String message;

  /// The URL that caused the error, if applicable.
  final Uri? uri;

  /// The HTTP status code, if the error is [MetaLinkErrorCode.httpStatus].
  final int? statusCode;

  /// The underlying exception that caused this error, if any.
  final Object? cause;

  /// Stack trace for [cause], if available.
  final StackTrace? stackTrace;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'code': code.name,
      'message': message,
      'uri': uri?.toString(),
      'statusCode': statusCode,
      'cause': cause?.toString(),
      'stackTrace': stackTrace?.toString(),
    };
  }

  factory MetaLinkError.fromJson(Map<String, dynamic> json) {
    final st = json.tryGetString('stackTrace');
    return MetaLinkError(
      code: json.getEnum(
        'code',
        parser: EnumParsers.byName(MetaLinkErrorCode.values),
        defaultValue: MetaLinkErrorCode.unknown,
      ),
      message: json.getString('message', defaultValue: ''),
      uri: json.tryGetUri('uri'),
      statusCode: json.tryGetInt('statusCode'),
      cause: json['cause'],
      stackTrace:
          (st != null && st.isNotEmpty) ? StackTrace.fromString(st) : null,
    );
  }
}

/// Categorizes non-fatal issues that occurred during extraction.
///
/// Warnings indicate degraded behavior but extraction still succeeded.
/// Check [ExtractionResult.warnings] to surface potential quality issues.
enum MetaLinkWarningCode {
  /// Cache was intentionally bypassed due to options or policy.
  cacheBypassed,

  /// Failed to read from cache; proceeded without cached data.
  cacheReadFailed,

  /// Failed to write to cache; result was not cached.
  cacheWriteFailed,

  /// Exceeded the maximum redirect limit; stopped following redirects.
  redirectedTooMuch,

  /// The HTML was truncated due to size limits.
  truncatedHtml,

  /// No charset was detected; defaulted to UTF-8.
  charsetFallback,

  /// The response was not HTML; extracted minimal metadata.
  nonHtmlResponse,

  /// oEmbed endpoint fetch or parsing failed.
  oembedFailed,

  /// Web App Manifest fetch or parsing failed.
  manifestFailed,

  /// Some metadata fields could not be extracted due to parsing issues.
  partialParse,
}

/// Represents a non-fatal issue that occurred during extraction.
///
/// Warnings do not prevent extraction from succeeding, but may indicate
/// degraded quality or incomplete results.
///
/// ### Example
/// ```dart
/// final result = await MetaLink.extract(url);
/// for (final warning in result.warnings) {
///   print('[${warning.code.name}] ${warning.message}');
/// }
/// ```
class MetaLinkWarning {
  /// Creates a [MetaLinkWarning].
  const MetaLinkWarning({
    required this.code,
    required this.message,
    this.uri,
    this.cause,
  });

  /// The category of warning. See [MetaLinkWarningCode].
  final MetaLinkWarningCode code;

  /// Human-readable description of the issue.
  final String message;

  /// The URL that triggered the warning, if applicable.
  final Uri? uri;

  /// The underlying exception that caused this warning, if any.
  final Object? cause;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'code': code.name,
      'message': message,
      'uri': uri?.toString(),
      'cause': cause?.toString(),
    };
  }

  factory MetaLinkWarning.fromJson(Map<String, dynamic> json) {
    return MetaLinkWarning(
      code: json.getEnum(
        'code',
        parser: EnumParsers.byName(MetaLinkWarningCode.values),
        defaultValue: MetaLinkWarningCode.partialParse,
      ),
      message: json.getString('message', defaultValue: ''),
      uri: json.tryGetUri('uri'),
      cause: json['cause'],
    );
  }
}
