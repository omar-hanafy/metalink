import 'package:metalink/src/options.dart';

/// The result of an HTTP fetch operation.
///
/// [FetchResponse] encapsulates the HTTP response including status code,
/// headers, and body bytes. It uses a non-throwing pattern where errors
/// are captured in the [error] field rather than thrown.
///
/// ### Fields
/// * [url] - The URL that was fetched.
/// * [statusCode] - HTTP status code, or `null` if the request failed.
/// * [headers] - Response headers (keys are lowercase).
/// * [bodyBytes] - Raw response body bytes.
/// * [truncated] - `true` if the body was truncated due to size limits.
/// * [duration] - Time spent on the fetch operation.
/// * [error] - The error that occurred, if any.
class FetchResponse {
  /// Creates a [FetchResponse].
  const FetchResponse({
    required this.url,
    required this.statusCode,
    required this.headers,
    required this.bodyBytes,
    required this.truncated,
    required this.duration,
    this.error,
    this.stackTrace,
  });

  /// The URL that was fetched.
  final Uri url;

  /// HTTP status code, or `null` if the request failed before receiving a response.
  final int? statusCode;

  /// Response headers with lowercase keys.
  final Map<String, String> headers;

  /// Raw response body bytes.
  final List<int> bodyBytes;

  /// Whether the body was truncated due to [FetchOptions.maxBytes].
  final bool truncated;

  /// Time spent on the fetch operation.
  final Duration duration;

  /// The error that occurred, if any.
  final Object? error;

  /// Stack trace for [error], if available.
  final StackTrace? stackTrace;

  /// Returns `true` if the fetch succeeded with a 2xx status code.
  bool get isOk =>
      error == null &&
      statusCode != null &&
      statusCode! >= 200 &&
      statusCode! < 300;
}

/// Interface for making HTTP requests.
///
/// [Fetcher] is the low-level HTTP abstraction used internally by MetaLink.
/// It provides GET and HEAD methods with timeout and size limiting.
///
/// ### Implementations
/// * [HttpFetcher] - The default implementation using the `http` package.
///
/// ### Contract
/// * Methods must not throw; errors are captured in [FetchResponse.error].
/// * Redirects are **not** followed automatically (callers handle redirects).
/// * The [close] method must be called when done to release resources.
abstract interface class Fetcher {
  /// Performs an HTTP GET request.
  ///
  /// ### Parameters
  /// * [url] - The URL to fetch.
  /// * [options] - Fetch configuration (timeout, headers, etc.).
  /// * [headers] - Additional per-request headers (merged with [options]).
  /// * [maxBytes] - Maximum bytes to read; overrides [FetchOptions.maxBytes].
  Future<FetchResponse> get(
    Uri url, {
    required FetchOptions options,
    Map<String, String>? headers,
    int? maxBytes,
  });

  /// Performs an HTTP HEAD request.
  ///
  /// HEAD requests retrieve headers without the body, useful for redirect
  /// resolution and content-type detection.
  ///
  /// ### Parameters
  /// * [url] - The URL to fetch.
  /// * [options] - Fetch configuration (timeout, headers, etc.).
  /// * [headers] - Additional per-request headers.
  Future<FetchResponse> head(
    Uri url, {
    required FetchOptions options,
    Map<String, String>? headers,
  });

  /// Closes the fetcher and releases resources.
  ///
  /// After calling [close], the fetcher must not be used.
  void close();
}
