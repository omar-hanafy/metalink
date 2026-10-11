/// @docImport 'package:metalink/src/result.dart';
library;

import 'package:convert_object/convert_object.dart';
import 'package:metalink/src/model/json_uri.dart';

/// Categorizes the type of failure that occurred during extraction.
///
/// Use [MetaLinkError.code] to determine why extraction failed and decide
/// whether to retry, show a fallback, or surface the error to users. Some
/// codes are intentionally broad; [MetaLinkError.reason] narrows them, and
/// [MetaLinkError.isRetryable] combines both into a retry decision.
///
/// ### Usually Retryable
/// * [network], [timeout] - Transient network issues; retry with backoff,
///   unless [MetaLinkError.reason] is set.
/// * [httpStatus] - Retryable only for status `408`, `425`, `429`, or `5xx`.
///
/// ### Non-Retryable
/// * [invalidUrl] - Malformed URL; fix the input.
/// * [nonHtmlContent] - URL points to non-HTML (PDF, image, etc.).
/// * [decode], [parse] - Corrupt or malformed HTML.
///
/// [oembed], [manifest], and [cache] remain for compatibility with exhaustive
/// switches, but the built-in client reports those failures as
/// [MetaLinkWarning]s instead.
enum MetaLinkErrorCode {
  /// The provided URL is malformed or unsupported.
  invalidUrl,

  /// Network or request failure (DNS, TCP, TLS, proxy, etc.).
  ///
  /// Request policy rejections, redirect failures, and cancellations also use
  /// this code, with [MetaLinkError.reason] set to a [MetaLinkErrorReason].
  network,

  /// The request exceeded the configured timeout.
  timeout,

  /// The server returned a final HTTP status outside the `2xx` range.
  ///
  /// [MetaLinkError.statusCode] holds the status.
  httpStatus,

  /// The response content is not HTML (e.g., PDF, image, JSON).
  nonHtmlContent,

  /// Failed to decode the response body (charset issues).
  decode,

  /// Failed to parse the HTML document.
  parse,

  /// Reserved for oEmbed failures.
  ///
  /// The built-in client does not emit this code. oEmbed fetch and parse
  /// failures are non-fatal and surface as a [MetaLinkWarningCode.oembedFailed]
  /// warning.
  oembed,

  /// Reserved for Web App Manifest failures.
  ///
  /// The built-in client does not emit this code. Manifest fetch and parse
  /// failures are non-fatal and surface as a
  /// [MetaLinkWarningCode.manifestFailed] warning.
  manifest,

  /// Reserved for cache failures.
  ///
  /// The built-in client does not emit this code. Cache failures are
  /// non-fatal and surface as a [MetaLinkWarningCode.cacheReadFailed] or
  /// [MetaLinkWarningCode.cacheWriteFailed] warning.
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
/// Check [ExtractionResult.primaryError] to inspect the first failure, or use
/// [ExtractionResult.errors] when every reported error matters.
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
  bool get isRetryable =>
      reason == null &&
      switch (code) {
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

  /// A JSON-compatible map of this error.
  ///
  /// [code] and [reason] are written as enum names, and [uri] as a string.
  /// [cause] and [stackTrace] are written with `toString()`, so the original
  /// objects are not preserved. [MetaLinkError.fromJson] reads this format
  /// back.
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

  /// Creates a [MetaLinkError] from a map produced by [toJson].
  ///
  /// Parsing is lenient and does not throw for missing or malformed values: an
  /// unknown `code` falls back to [MetaLinkErrorCode.unknown], a missing
  /// `message` becomes an empty string, and an unrecognized `reason` becomes
  /// `null`.
  ///
  /// [cause] is the stored value as is, which is a [String] for maps written by
  /// [toJson]. A non-empty `stackTrace` string is restored with
  /// [StackTrace.fromString].
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
      uri: tryReadJsonUri(json, 'uri'),
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
/// Warnings describe degraded behavior. They can accompany a usable result or
/// a failed one. Check [ExtractionResult.warnings] to surface potential
/// quality issues; [ExtractionResult.inferStatus] treats some codes as a
/// [ExtractionStatus.partial] result.
enum MetaLinkWarningCode {
  /// Cache was intentionally bypassed due to options or policy.
  cacheBypassed,

  /// Failed to read from cache; proceeded without cached data.
  cacheReadFailed,

  /// Failed to write to cache; result was not cached.
  cacheWriteFailed,

  /// Reserved for redirect-limit failures.
  ///
  /// Not emitted by the built-in client since 2.1.0. Exceeding the redirect
  /// limit, a redirect loop, or an invalid redirect target now fails the
  /// request with a [MetaLinkErrorCode.network] error whose reason is
  /// [MetaLinkErrorReason.redirectsExceeded]. [ExtractionResult.inferStatus]
  /// still treats this code as a degraded, partial result.
  redirectedTooMuch,

  /// The HTML was truncated due to size limits.
  truncatedHtml,

  /// No charset was detected; defaulted to UTF-8.
  charsetFallback,

  /// The response was not HTML.
  ///
  /// The client reports this together with a
  /// [MetaLinkErrorCode.nonHtmlContent] error and returns minimal metadata.
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

  /// A JSON-compatible map of this warning.
  ///
  /// [code] is written as its enum name, and [uri] as a string. [cause] is
  /// written with `toString()`, so the original object is not preserved.
  /// [MetaLinkWarning.fromJson] reads this format back.
  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'code': code.name,
      'message': message,
      'uri': uri?.toString(),
      'cause': cause?.toString(),
    };
  }

  /// Creates a [MetaLinkWarning] from a map produced by [toJson].
  ///
  /// Parsing is lenient and does not throw for missing or malformed values: an
  /// unknown `code` falls back to [MetaLinkWarningCode.partialParse], and a
  /// missing `message` becomes an empty string. [cause] is the stored value as
  /// is, which is a [String] for maps written by [toJson].
  factory MetaLinkWarning.fromJson(Map<String, dynamic> json) {
    return MetaLinkWarning(
      code: json.getEnum(
        'code',
        parser: EnumParsers.byName(MetaLinkWarningCode.values),
        defaultValue: MetaLinkWarningCode.partialParse,
      ),
      message: json.getString('message', defaultValue: ''),
      uri: tryReadJsonUri(json, 'uri'),
      cause: json['cause'],
    );
  }
}
