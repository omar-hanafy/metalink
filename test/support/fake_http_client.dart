import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

typedef RequestHandler = Future<http.StreamedResponse> Function(
  http.BaseRequest request,
);

class RecordingHttpClient extends http.BaseClient {
  RecordingHttpClient({
    required this.handler,
  });

  final RequestHandler handler;
  final List<http.BaseRequest> requests = <http.BaseRequest>[];
  bool closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (closed) {
      throw StateError('RecordingHttpClient is closed');
    }
    requests.add(request);
    return handler(request);
  }

  @override
  void close() {
    closed = true;
  }
}

http.StreamedResponse stringResponse(
  String body,
  int statusCode, {
  Map<String, String>? headers,
}) {
  final bytes = utf8.encode(body);
  return http.StreamedResponse(
    Stream<List<int>>.fromIterable(<List<int>>[bytes]),
    statusCode,
    headers: headers ?? const <String, String>{},
  );
}

http.StreamedResponse bytesResponse(
  List<int> body,
  int statusCode, {
  Map<String, String>? headers,
}) {
  return http.StreamedResponse(
    Stream<List<int>>.fromIterable(<List<int>>[body]),
    statusCode,
    headers: headers ?? const <String, String>{},
  );
}
