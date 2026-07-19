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

/// A precise reason attached to an existing broad [MetaLinkErrorCode].
///
/// This additive detail preserves exhaustive switches over the v2 error-code
/// enum while letting callers distinguish cancellation, policy rejection, and
/// redirect failures.
enum MetaLinkErrorReason {
  /// The caller cancelled the request before completion.
  cancelled,

  /// The configured request policy rejected the target or transport.
  policyRejected,

  /// Redirect processing exceeded its limit, found a loop, or found an invalid
  /// destination.
  redirectsExceeded,
}

/// Represents a fatal error that prevented metadata extraction.
///
/// [MetaLinkError] provides structured error information including an error
/// code, human-readable message, and optional context like the failing URL
/// or HTTP status code.
///
/// ### When to Use
/// Check `ExtractionResult.primaryError` to inspect the first failure, or use
/// `ExtractionResult.errors` when every reported error matters.
///
/// ### Example
/// ```dart
/// final result = await MetaLink.extract(url);
/// if (result.primaryError != null) {
///   switch (result.primaryError!.code) {
///     case MetaLinkErrorCode.timeout:
///       print('Request timed out');
///       break;
///     case MetaLinkErrorCode.httpStatus:
///       print('HTTP ${result.primaryError!.statusCode}');
///       break;
///     default:
///       print(result.primaryError!.message);
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
    this.reason,
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

  /// Precise failure reason when [code] alone is intentionally broad.
  final MetaLinkErrorReason? reason;

  /// The underlying exception that caused this error, if any.
  final Object? cause;

  /// Stack trace for [cause], if available.
  final StackTrace? stackTrace;

  /// Whether retrying the same operation may succeed without changing input.
  bool get isRetryable => reason != null
      ? false
      : switch (code) {
          MetaLinkErrorCode.network || MetaLinkErrorCode.timeout => true,
          MetaLinkErrorCode.httpStatus =>
            statusCode == 408 ||
                statusCode == 425 ||
                statusCode == 429 ||
                (statusCode != null && statusCode! >= 500),
          MetaLinkErrorCode.invalidUrl ||
          MetaLinkErrorCode.nonHtmlContent ||
          MetaLinkErrorCode.decode ||
          MetaLinkErrorCode.parse ||
          MetaLinkErrorCode.oembed ||
          MetaLinkErrorCode.manifest ||
          MetaLinkErrorCode.cache ||
          MetaLinkErrorCode.unknown => false,
        };

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'code': code.name,
      'message': message,
      'uri': uri?.toString(),
      'statusCode': statusCode,
      'reason': reason?.name,
      'cause': cause?.toString(),
      'stackTrace': stackTrace?.toString(),
    };
  }

  factory MetaLinkError.fromJson(Map<String, dynamic> json) {
    final st = json.tryGetString('stackTrace');
    final reasonRaw = json['reason'];
    final reason = reasonRaw is String
        ? MetaLinkErrorReason.values
              .where((value) => value.name == reasonRaw)
              .firstOrNull
        : null;
    return MetaLinkError(
      code: json.getEnum(
        'code',
        parser: EnumParsers.byName(MetaLinkErrorCode.values),
        defaultValue: MetaLinkErrorCode.unknown,
      ),
      message: json.getString('message', defaultValue: ''),
      uri: json.tryGetUri('uri'),
      statusCode: json.tryGetInt('statusCode'),
      reason: reason,
      cause: json['cause'],
      stackTrace: (st != null && st.isNotEmpty)
          ? StackTrace.fromString(st)
          : null,
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
