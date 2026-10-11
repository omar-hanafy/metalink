import 'dart:async';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'package:metalink/src/fetch/fetcher.dart';
import 'package:metalink/src/fetch/http_fetcher_capabilities_io.dart'
    if (dart.library.js_interop) 'package:metalink/src/fetch/http_fetcher_capabilities_web.dart'
    as platform_capabilities;
import 'package:metalink/src/model/diagnostics.dart';
import 'package:metalink/src/network/deadline_timer.dart';
import 'package:metalink/src/options.dart';

/// Default [Fetcher] implementation using the `http` package.
///
/// [HttpFetcher] performs HTTP requests with configurable timeouts and
/// size limits. It captures errors rather than throwing to provide a
/// consistent non-throwing API.
///
/// ### Connection Reuse
/// When constructed with an external [http.Client], connections are reused
/// across requests for better performance. The external client is **not**
/// closed when [close] is called.
///
/// On browsers, `window.fetch` cannot expose redirect responses. Compatible
/// policies therefore delegate enabled redirects to the browser and preserve
/// the final response URL. Intermediate hops, the configured redirect count,
/// per-hop target validation, and MetaLink's cross-origin header stripping
/// cannot be observed or enforced. Policies that require inspectable hops are
/// rejected by the unified request engine before transport.
///
/// With redirects disabled on the web, through [FetchOptions.followRedirects]
/// set to `false` or a [FetchOptions.maxRedirects] of `0`, the browser rejects
/// any redirect response. It is then reported as a retryable transport error
/// (`RequestFailureCode.transport`), not as `RequestFailureCode.redirectLimit`
/// as on native platforms.
///
/// ### Example
/// ```dart
/// final fetcher = HttpFetcher();
/// final response = await fetcher.get(
///   Uri.parse('https://example.com'),
///   options: FetchOptions(),
/// );
/// fetcher.close();
/// ```
class HttpFetcher implements AbortableFetcher, CapabilityAwareFetcher {
  /// Creates an [HttpFetcher].
  ///
  /// ### Parameters
  /// * [client] - Optional pre-configured HTTP client. If provided, it will
  ///   **not** be closed when [close] is called (caller manages lifecycle).
  /// * [clientFactory] - Optional factory used to create an owned HTTP client.
  ///   Factory-created clients are closed by [close].
  /// * [capabilities] - Optional truthful capability description for an
  ///   injected client or factory. Custom clients default to unknown
  ///   capabilities when this is omitted.
  /// * `logSink` - Optional callback to receive internal log messages.
  HttpFetcher({
    http.Client? client,
    http.Client Function()? clientFactory,
    FetcherCapabilities? capabilities,
    this._logSink,
  }) : assert(
         client == null || clientFactory == null,
         'client and clientFactory cannot both be provided',
       ),
       _client = client ?? (clientFactory ?? _createDefaultClient)(),
       _ownsClient = client == null,
       _capabilities =
           capabilities ??
           (client == null && clientFactory == null
               ? platform_capabilities.defaultHttpFetcherCapabilities()
               : const FetcherCapabilities(
                   supportsAbort: false,
                   redirectHandling: RedirectHandlingCapability.unknown,
                   limitation:
                       'Capabilities of the injected HTTP client are '
                       'unknown. Pass an explicit capability description when '
                       'the client guarantees abort and manual redirects.',
                 ));

  static http.Client _createDefaultClient() => http.Client();

  final http.Client _client;
  final bool _ownsClient;
  final FetcherCapabilities _capabilities;
  final MetaLinkLogSink? _logSink;

  bool _closed = false;

  @override
  FetcherCapabilities get capabilities => _capabilities;

  @override
  Future<FetchResponse> get(
    Uri url, {
    required FetchOptions options,
    Map<String, String>? headers,
    int? maxBytes,
    Future<void>? abortTrigger,
  }) async {
    final sw = Stopwatch()..start();
    final abort = _RequestAbortController(
      url: url,
      timeout: options.timeout,
      externalTrigger: abortTrigger,
    );

    int? statusCode;
    Map<String, String> responseHeaders = const <String, String>{};
    List<int> body = const <int>[];
    bool truncated = false;

    try {
      _throwIfClosed();

      final followRedirects = _allowsAutomaticRedirects(options);
      final request =
          http.AbortableRequest('GET', url, abortTrigger: abort.trigger)
            ..followRedirects = followRedirects
            ..maxRedirects = followRedirects ? options.maxRedirects : 0;

      request.headers.addAll(_buildRequestHeaders(options, headers));

      final response = await abort.wait(_client.send(request));
      statusCode = response.statusCode;
      responseHeaders = Map<String, String>.from(response.headers);

      final limit = maxBytes ?? options.maxBytes;

      final readResult = await abort.wait(
        _readStreamWithLimit(response.stream, limit),
      );

      body = readResult.bytes;
      truncated = readResult.truncated;

      return FetchResponse(
        url: _responseUrl(response, url),
        statusCode: statusCode,
        headers: responseHeaders,
        bodyBytes: body,
        truncated: truncated,
        duration: sw.elapsed,
      );
    } on TimeoutException catch (e, st) {
      _safeLog(
        MetaLinkLogLevel.warning,
        'HTTP GET timeout',
        error: e,
        stackTrace: st,
        context: {'url': url.toString()},
      );
      // Return partial response so callers can inspect headers even on timeout.
      return FetchResponse(
        url: url,
        statusCode: statusCode,
        headers: responseHeaders,
        bodyBytes: body,
        truncated: truncated,
        duration: sw.elapsed,
        error: e,
        stackTrace: st,
      );
    } on FetchCancellationException catch (e, st) {
      _safeLog(
        MetaLinkLogLevel.info,
        'HTTP GET cancelled',
        error: e,
        stackTrace: st,
        context: {'url': url.toString()},
      );
      return FetchResponse(
        url: url,
        statusCode: statusCode,
        headers: responseHeaders,
        bodyBytes: body,
        truncated: truncated,
        duration: sw.elapsed,
        error: e,
        stackTrace: st,
      );
    } catch (e, st) {
      _safeLog(
        MetaLinkLogLevel.error,
        'HTTP GET failed',
        error: e,
        stackTrace: st,
        context: {'url': url.toString()},
      );
      return FetchResponse(
        url: url,
        statusCode: statusCode,
        headers: responseHeaders,
        bodyBytes: body,
        truncated: truncated,
        duration: sw.elapsed,
        error: e,
        stackTrace: st,
      );
    } finally {
      abort.dispose();
    }
  }

  @override
  Future<FetchResponse> head(
    Uri url, {
    required FetchOptions options,
    Map<String, String>? headers,
    Future<void>? abortTrigger,
  }) async {
    final sw = Stopwatch()..start();
    final abort = _RequestAbortController(
      url: url,
      timeout: options.timeout,
      externalTrigger: abortTrigger,
    );

    int? statusCode;
    Map<String, String> responseHeaders = const <String, String>{};

    try {
      _throwIfClosed();

      final followRedirects = _allowsAutomaticRedirects(options);
      final request =
          http.AbortableRequest('HEAD', url, abortTrigger: abort.trigger)
            ..followRedirects = followRedirects
            ..maxRedirects = followRedirects ? options.maxRedirects : 0;

      request.headers.addAll(_buildRequestHeaders(options, headers));

      final response = await abort.wait(_client.send(request));
      statusCode = response.statusCode;
      responseHeaders = Map<String, String>.from(response.headers);

      // HEAD should have no body, so cancel quickly to avoid hanging on drain.
      await abort.wait(_cancelStream(response.stream));

      return FetchResponse(
        url: _responseUrl(response, url),
        statusCode: statusCode,
        headers: responseHeaders,
        bodyBytes: const <int>[],
        truncated: false,
        duration: sw.elapsed,
      );
    } on TimeoutException catch (e, st) {
      _safeLog(
        MetaLinkLogLevel.warning,
        'HTTP HEAD timeout',
        error: e,
        stackTrace: st,
        context: {'url': url.toString()},
      );
      return FetchResponse(
        url: url,
        statusCode: statusCode,
        headers: responseHeaders,
        bodyBytes: const <int>[],
        truncated: false,
        duration: sw.elapsed,
        error: e,
        stackTrace: st,
      );
    } on FetchCancellationException catch (e, st) {
      _safeLog(
        MetaLinkLogLevel.info,
        'HTTP HEAD cancelled',
        error: e,
        stackTrace: st,
        context: {'url': url.toString()},
      );
      return FetchResponse(
        url: url,
        statusCode: statusCode,
        headers: responseHeaders,
        bodyBytes: const <int>[],
        truncated: false,
        duration: sw.elapsed,
        error: e,
        stackTrace: st,
      );
    } catch (e, st) {
      _safeLog(
        MetaLinkLogLevel.error,
        'HTTP HEAD failed',
        error: e,
        stackTrace: st,
        context: {'url': url.toString()},
      );
      return FetchResponse(
        url: url,
        statusCode: statusCode,
        headers: responseHeaders,
        bodyBytes: const <int>[],
        truncated: false,
        duration: sw.elapsed,
        error: e,
        stackTrace: st,
      );
    } finally {
      abort.dispose();
    }
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    if (_ownsClient) {
      try {
        _client.close();
      } catch (_) {
        // Best-effort close so shutdown does not throw.
      }
    }
  }

  void _throwIfClosed() {
    if (_closed) {
      throw StateError('HttpFetcher is closed');
    }
  }

  bool _allowsAutomaticRedirects(FetchOptions options) {
    return _capabilities.redirectHandling ==
            RedirectHandlingCapability.unavailable &&
        options.followRedirects &&
        options.maxRedirects > 0;
  }

  static Uri _responseUrl(http.StreamedResponse response, Uri requestUrl) {
    return switch (response) {
      http.BaseResponseWithUrl(:final url) => url,
      _ => requestUrl,
    };
  }

  void _safeLog(
    MetaLinkLogLevel level,
    String message, {
    Object? error,
    StackTrace? stackTrace,
    Map<String, Object?>? context,
  }) {
    final sink = _logSink;
    if (sink == null) return;
    try {
      sink(
        MetaLinkLogRecord(
          level: level,
          message: message,
          timestamp: DateTime.now().toUtc(),
          error: error,
          stackTrace: stackTrace,
          context: context,
        ),
      );
    } catch (_) {
      // Logging must never throw so fetch failures do not cascade.
    }
  }

  Map<String, String> _buildRequestHeaders(
    FetchOptions options,
    Map<String, String>? perCall,
  ) {
    // Normalize header keys to lower case to avoid duplicates that differ by case.
    final out = <String, String>{};

    void addAllNormalized(Map<String, String> input) {
      input.forEach((k, v) {
        out[k.toLowerCase()] = v;
      });
    }

    addAllNormalized(options.headers);

    // Apply user-agent unless explicitly set so callers can override per request.
    final uaKey = 'user-agent';
    if (options.userAgent != null) {
      final hasUaInOptions = out.containsKey(uaKey);
      final hasUaInPerCall =
          perCall != null && perCall.keys.any((k) => k.toLowerCase() == uaKey);
      if (!hasUaInOptions && !hasUaInPerCall) {
        out[uaKey] = options.userAgent!;
      }
    }

    if (perCall != null && perCall.isNotEmpty) {
      addAllNormalized(perCall);
    }

    return out;
  }
}

enum _AbortReason { timeout, cancellation }

class _RequestAbortController {
  _RequestAbortController({
    required this.url,
    required this.timeout,
    Future<void>? externalTrigger,
  }) {
    _timer = startDeadlineTimer(timeout, () => _abort(_AbortReason.timeout));
    if (externalTrigger != null) {
      _externalRelay = _AbortSignalRelay(this).._listen(externalTrigger);
    }
  }

  final Uri url;
  final Duration timeout;
  final Completer<void> _trigger = Completer<void>();
  final Completer<_AbortReason> _reason = Completer<_AbortReason>();

  Timer? _timer;
  _AbortSignalRelay? _externalRelay;
  bool _active = true;

  Future<void> get trigger => _trigger.future;

  Future<T> wait<T>(Future<T> operation) {
    final interrupted = _reason.future.then<T>((reason) {
      switch (reason) {
        case _AbortReason.timeout:
          throw TimeoutException('Request timed out', timeout);
        case _AbortReason.cancellation:
          throw FetchCancellationException(url);
      }
    });
    return Future.any<T>(<Future<T>>[operation, interrupted]);
  }

  void _abort(_AbortReason reason) {
    if (!_active || _reason.isCompleted) return;
    _reason.complete(reason);
    if (!_trigger.isCompleted) {
      _trigger.complete();
    }
  }

  void dispose() {
    if (!_active) return;
    _active = false;
    _timer?.cancel();
    _timer = null;
    // The caller's trigger keeps its listener until it completes. Releasing
    // the relay leaves that listener holding an empty relay instead of this
    // controller and the response it guarded.
    _externalRelay?.release();
    _externalRelay = null;
  }
}

/// Forwards a caller-owned abort trigger to one request's controller.
///
/// A [Future] cannot drop a listener before it completes, so a listener on a
/// long-lived trigger outlives the request that registered it. The listener
/// closures are created in [_listen] and capture only this relay, and
/// [release] drops the controller when the request ends. A trigger that never
/// completes therefore retains this small object rather than the controller
/// and the response it guarded.
final class _AbortSignalRelay {
  _AbortSignalRelay(this._controller);

  _RequestAbortController? _controller;

  /// Treats completion of [trigger] with a value or an error as cancellation.
  void _listen(Future<void> trigger) {
    trigger
        .then<void>(
          (_) => _cancel(),
          onError: (Object _, StackTrace _) => _cancel(),
        )
        .ignore();
  }

  void _cancel() {
    _controller?._abort(_AbortReason.cancellation);
  }

  /// Detaches the controller; a later trigger completion does nothing.
  void release() {
    _controller = null;
  }
}

class _ReadResult {
  const _ReadResult(this.bytes, {required this.truncated});

  final List<int> bytes;
  final bool truncated;
}

/// Reads at most [maxBytes] bytes from [stream].
///
/// Implementation reads up to `maxBytes + 1` bytes to accurately detect truncation.
Future<_ReadResult> _readStreamWithLimit(
  Stream<List<int>> stream,
  int maxBytes,
) async {
  if (maxBytes <= 0) {
    // Do not read when maxBytes <= 0; cancel to free the connection.
    await _cancelStream(stream);
    return const _ReadResult(<int>[], truncated: false);
  }

  final builder = BytesBuilder(copy: false);

  // Reading one byte past maxBytes tells a body of exactly maxBytes apart from
  // a truncated one. A limit too large to increment, such as the largest int,
  // cannot be exceeded by any body, so read everything instead of overflowing.
  final int hardLimit = maxBytes + 1;
  if (hardLimit <= maxBytes) {
    await for (final chunk in stream) {
      builder.add(chunk);
    }
    return _ReadResult(builder.takeBytes(), truncated: false);
  }

  int remaining = hardLimit;
  bool stoppedEarly = false;

  await for (final chunk in stream) {
    if (chunk.isEmpty) continue;

    if (remaining <= 0) {
      stoppedEarly = true;
      break;
    }

    if (chunk.length <= remaining) {
      builder.add(chunk);
      remaining -= chunk.length;

      if (remaining == 0) {
        // We hit the hard limit exactly, so stop to avoid over-reading.
        stoppedEarly = true;
        break;
      }
    } else {
      builder.add(chunk.sublist(0, remaining));
      stoppedEarly = true;
      break;
    }
  }

  final bytes = builder.takeBytes();

  // If we stopped early due to the hard limit, we may have read maxBytes+1.
  if (stoppedEarly && bytes.length >= hardLimit) {
    // We read one extra byte, which confirms truncation.
    return _ReadResult(
      Uint8List.sublistView(bytes, 0, maxBytes),
      truncated: true,
    );
  }

  // Not truncated: stream ended or we never reached the hard limit.
  return _ReadResult(bytes, truncated: false);
}

/// Cancels a stream subscription as quickly as possible.
Future<void> _cancelStream(Stream<List<int>> stream) async {
  final sub = stream.listen((_) {});
  await sub.cancel();
}
