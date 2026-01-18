import 'dart:async';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'package:metalink/src/model/diagnostics.dart';
import 'package:metalink/src/options.dart';
import 'package:metalink/src/fetch/fetcher.dart';

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
/// ### Example
/// ```dart
/// final fetcher = HttpFetcher();
/// final response = await fetcher.get(
///   Uri.parse('https://example.com'),
///   options: FetchOptions(),
/// );
/// fetcher.close();
/// ```
class HttpFetcher implements Fetcher {
  /// Creates an [HttpFetcher].
  ///
  /// ### Parameters
  /// * [client] - Optional pre-configured HTTP client. If provided, it will
  ///   **not** be closed when [close] is called (caller manages lifecycle).
  /// * [logSink] - Optional callback to receive internal log messages.
  HttpFetcher({
    http.Client? client,
    MetaLinkLogSink? logSink,
  })  : _client = client ?? http.Client(),
        _ownsClient = client == null,
        _logSink = logSink;

  final http.Client _client;
  final bool _ownsClient;
  final MetaLinkLogSink? _logSink;

  bool _closed = false;

  @override
  Future<FetchResponse> get(
    Uri url, {
    required FetchOptions options,
    Map<String, String>? headers,
    int? maxBytes,
  }) async {
    final sw = Stopwatch()..start();

    http.StreamedResponse? streamed;
    int? statusCode;
    Map<String, String> responseHeaders = const <String, String>{};
    List<int> body = const <int>[];
    bool truncated = false;

    try {
      _throwIfClosed();

      final request = http.Request('GET', url)
        ..followRedirects = false
        ..maxRedirects = 0;

      request.headers.addAll(_buildRequestHeaders(options, headers));

      streamed = await _client.send(request).timeout(options.timeout);
      statusCode = streamed.statusCode;
      responseHeaders = Map<String, String>.from(streamed.headers);

      final remaining = _remainingTimeout(options.timeout, sw.elapsed);
      final limit = maxBytes ?? options.maxBytes;

      final readResult = await _readStreamWithLimit(
        streamed.stream,
        limit,
      ).timeout(remaining);

      body = readResult.bytes;
      truncated = readResult.truncated;

      return FetchResponse(
        url: url,
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
    }
  }

  @override
  Future<FetchResponse> head(
    Uri url, {
    required FetchOptions options,
    Map<String, String>? headers,
  }) async {
    final sw = Stopwatch()..start();

    http.StreamedResponse? streamed;
    int? statusCode;
    Map<String, String> responseHeaders = const <String, String>{};

    try {
      _throwIfClosed();

      final request = http.Request('HEAD', url)
        ..followRedirects = false
        ..maxRedirects = 0;

      request.headers.addAll(_buildRequestHeaders(options, headers));

      streamed = await _client.send(request).timeout(options.timeout);
      statusCode = streamed.statusCode;
      responseHeaders = Map<String, String>.from(streamed.headers);

      final remaining = _remainingTimeout(options.timeout, sw.elapsed);

      // HEAD should have no body, so cancel quickly to avoid hanging on drain.
      await _cancelStream(streamed.stream).timeout(remaining);

      return FetchResponse(
        url: url,
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

  Duration _remainingTimeout(Duration total, Duration elapsed) {
    final remainingMs = total.inMilliseconds - elapsed.inMilliseconds;
    if (remainingMs <= 0) {
      throw TimeoutException('Request timed out');
    }
    return Duration(milliseconds: remainingMs);
  }
}

class _ReadResult {
  const _ReadResult(this.bytes, this.truncated);

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
    return const _ReadResult(<int>[], false);
  }

  final int hardLimit = maxBytes == 0 ? 0 : maxBytes + 1;
  final builder = BytesBuilder(copy: false);

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
  if (stoppedEarly && bytes.length >= hardLimit && hardLimit == maxBytes + 1) {
    // We read one extra byte, which confirms truncation.
    return _ReadResult(Uint8List.sublistView(bytes, 0, maxBytes), true);
  }

  // Not truncated: stream ended or we never reached the hard limit.
  return _ReadResult(bytes, false);
}

/// Cancels a stream subscription as quickly as possible.
Future<void> _cancelStream(Stream<List<int>> stream) async {
  final sub = stream.listen((_) {});
  await sub.cancel();
}
