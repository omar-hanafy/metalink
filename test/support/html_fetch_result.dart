import 'dart:convert';

import 'package:metalink/src/fetch/html_snippet_fetcher.dart';
import 'package:metalink/src/model/diagnostics.dart';

HtmlFetchResult buildHtmlFetchResult({
  required Uri originalUrl,
  Uri? finalUrl,
  int? statusCode,
  Map<String, String>? headers,
  List<int>? bodyBytes,
  String? bodyText,
  String? detectedCharset,
  CharsetSource charsetSource = CharsetSource.unknown,
  bool truncated = false,
  Duration duration = Duration.zero,
  Object? error,
  StackTrace? stackTrace,
}) {
  final resolvedUrl = finalUrl ?? originalUrl;
  final bytes =
      bodyBytes ?? (bodyText == null ? const <int>[] : utf8.encode(bodyText));
  return HtmlFetchResult(
    originalUrl: originalUrl,
    finalUrl: resolvedUrl,
    redirects: const [],
    statusCode: statusCode,
    headers: headers ?? const <String, String>{},
    bodyBytes: bytes,
    bodyText: bodyText,
    detectedCharset: detectedCharset,
    charsetSource: charsetSource,
    truncated: truncated,
    duration: duration,
    error: error,
    stackTrace: stackTrace,
  );
}
