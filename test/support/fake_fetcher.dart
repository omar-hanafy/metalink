import 'dart:async';

import 'package:metalink/src/fetch/fetcher.dart';
import 'package:metalink/src/options.dart';
import 'package:metalink/src/util/url_normalizer.dart';

class FetchRequest {
  FetchRequest({
    required this.method,
    required this.url,
    required this.options,
    this.headers,
    this.maxBytes,
  });

  final String method;
  final Uri url;
  final FetchOptions options;
  final Map<String, String>? headers;
  final int? maxBytes;
}

typedef FetchHandler = FutureOr<FetchResponse> Function(FetchRequest request);

class FakeFetcher implements Fetcher {
  FakeFetcher({
    FetchHandler? onMissing,
  }) : _onMissing = onMissing ?? _defaultMissingHandler;

  final FetchHandler _onMissing;
  final List<FetchRequest> requests = <FetchRequest>[];

  final Map<String, FetchHandler> _getHandlers = <String, FetchHandler>{};
  final Map<String, FetchHandler> _headHandlers = <String, FetchHandler>{};

  bool _closed = false;

  void registerGet(Uri url, FetchHandler handler) {
    _getHandlers[_key(url)] = handler;
  }

  void registerHead(Uri url, FetchHandler handler) {
    _headHandlers[_key(url)] = handler;
  }

  void registerGetResponse(Uri url, FetchResponse response) {
    registerGet(url, (_) => response);
  }

  void registerHeadResponse(Uri url, FetchResponse response) {
    registerHead(url, (_) => response);
  }

  @override
  Future<FetchResponse> get(
    Uri url, {
    required FetchOptions options,
    Map<String, String>? headers,
    int? maxBytes,
  }) async {
    if (_closed) {
      return FetchResponse(
        url: url,
        statusCode: null,
        headers: const <String, String>{},
        bodyBytes: const <int>[],
        truncated: false,
        duration: Duration.zero,
        error: StateError('FakeFetcher is closed'),
      );
    }

    final request = FetchRequest(
      method: 'GET',
      url: url,
      options: options,
      headers: headers,
      maxBytes: maxBytes,
    );
    requests.add(request);

    final handler = _getHandlers[_key(url)] ?? _onMissing;
    final response = await handler(request);
    return _applyMaxBytes(response, maxBytes);
  }

  @override
  Future<FetchResponse> head(
    Uri url, {
    required FetchOptions options,
    Map<String, String>? headers,
  }) async {
    if (_closed) {
      return FetchResponse(
        url: url,
        statusCode: null,
        headers: const <String, String>{},
        bodyBytes: const <int>[],
        truncated: false,
        duration: Duration.zero,
        error: StateError('FakeFetcher is closed'),
      );
    }

    final request = FetchRequest(
      method: 'HEAD',
      url: url,
      options: options,
      headers: headers,
      maxBytes: null,
    );
    requests.add(request);

    final handler = _headHandlers[_key(url)] ?? _onMissing;
    return await handler(request);
  }

  @override
  void close() {
    _closed = true;
  }

  static FetchResponse buildResponse({
    required Uri url,
    int statusCode = 200,
    Map<String, String>? headers,
    List<int>? bodyBytes,
    String? bodyText,
    bool truncated = false,
    Duration duration = Duration.zero,
    Object? error,
    StackTrace? stackTrace,
  }) {
    final bytes =
        bodyBytes ?? (bodyText == null ? <int>[] : bodyText.codeUnits);
    return FetchResponse(
      url: url,
      statusCode: statusCode,
      headers: headers ?? const <String, String>{},
      bodyBytes: bytes,
      truncated: truncated,
      duration: duration,
      error: error,
      stackTrace: stackTrace,
    );
  }

  static FetchResponse _defaultMissingHandler(FetchRequest request) {
    return FetchResponse(
      url: request.url,
      statusCode: null,
      headers: const <String, String>{},
      bodyBytes: const <int>[],
      truncated: false,
      duration: Duration.zero,
      error: StateError(
          'No handler registered for ${request.method} ${request.url}'),
    );
  }

  static String _key(Uri url) {
    return UrlNormalizer.normalizeForRequest(url).toString();
  }

  static FetchResponse _applyMaxBytes(FetchResponse response, int? maxBytes) {
    if (maxBytes == null) return response;
    if (maxBytes <= 0) {
      return FetchResponse(
        url: response.url,
        statusCode: response.statusCode,
        headers: response.headers,
        bodyBytes: const <int>[],
        truncated: false,
        duration: response.duration,
        error: response.error,
        stackTrace: response.stackTrace,
      );
    }

    if (response.bodyBytes.length <= maxBytes) return response;

    final truncatedBytes = response.bodyBytes.sublist(0, maxBytes);
    return FetchResponse(
      url: response.url,
      statusCode: response.statusCode,
      headers: response.headers,
      bodyBytes: truncatedBytes,
      truncated: true,
      duration: response.duration,
      error: response.error,
      stackTrace: response.stackTrace,
    );
  }
}
