import 'package:metalink/src/options.dart';

/// Describes whether a fetcher can expose redirect responses to MetaLink.
enum RedirectHandlingCapability {
  /// Redirect responses are returned without being followed by the transport.
  inspectable,

  /// The transport cannot return redirect responses for manual processing.
  unavailable,

  /// The transport's redirect behavior cannot be determined in advance.
  unknown,
}

/// Capabilities exposed by an optional [Fetcher] implementation.
class FetcherCapabilities {
  /// Creates a capability description.
  const FetcherCapabilities({
    required this.supportsAbort,
    required this.redirectHandling,
    this.limitation,
  });

  /// Capabilities assumed for legacy [Fetcher] implementations.
  ///
  /// The [Fetcher] contract requires redirects to remain unfollowed, but the
  /// legacy API has no cancellation signal.
  const FetcherCapabilities.legacy()
    : supportsAbort = false,
      redirectHandling = RedirectHandlingCapability.inspectable,
      limitation = 'Legacy Fetcher requests cannot be actively aborted.';

  /// Whether a request can be actively cancelled after it starts.
  final bool supportsAbort;

  /// Whether redirect responses can be inspected one hop at a time.
  final RedirectHandlingCapability redirectHandling;

  /// A human-readable description of any relevant platform limitation.
  final String? limitation;
}

/// Optional interface for fetchers that report transport capabilities.
abstract interface class CapabilityAwareFetcher {
  /// Capabilities of this fetcher on the current platform.
  FetcherCapabilities get capabilities;
}

/// Error returned when an in-flight fetch is cancelled by its caller.
class FetchCancellationException implements Exception {
  /// Creates a cancellation error for [uri].
  const FetchCancellationException(this.uri);

  /// The request that was cancelled.
  final Uri uri;

  @override
  String toString() => 'FetchCancellationException: Request cancelled for $uri';
}

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
/// * Inspectable transports return redirects without following them.
/// * A [CapabilityAwareFetcher] with
///   [RedirectHandlingCapability.unavailable] may follow redirects only when
///   [FetchOptions.followRedirects] allows it, and must report the final URL in
///   [FetchResponse.url]. Intermediate hops remain unavailable.
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

/// Optional extension of [Fetcher] that accepts an active cancellation signal.
///
/// Existing [Fetcher] implementations remain source-compatible. Callers should
/// check for this interface before passing an [abortTrigger].
abstract interface class AbortableFetcher implements Fetcher {
  @override
  Future<FetchResponse> get(
    Uri url, {
    required FetchOptions options,
    Map<String, String>? headers,
    int? maxBytes,
    Future<void>? abortTrigger,
  });

  @override
  Future<FetchResponse> head(
    Uri url, {
    required FetchOptions options,
    Map<String, String>? headers,
    Future<void>? abortTrigger,
  });
}
