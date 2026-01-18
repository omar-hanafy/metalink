import 'package:html/dom.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:metalink/src/extract/pipeline.dart';
import 'package:metalink/src/fetch/fetcher.dart';
import 'package:metalink/src/model/diagnostics.dart';
import 'package:metalink/src/model/link_metadata.dart';
import 'package:metalink/src/options.dart';

import 'html_fetch_result.dart';

final Uri testBaseUrl = Uri.parse('https://example.com/page');

Document parseHtml(String html) {
  return html_parser.parse(html);
}

Future<LinkMetadata> runPipeline({
  required String html,
  required List<HtmlMetadataExtractorStage> stages,
  Fetcher? fetcher,
  FetchOptions fetchOptions = const FetchOptions(),
  ExtractOptions extractOptions = const ExtractOptions(),
  Uri? originalUrl,
  Uri? finalUrl,
}) async {
  final origin = originalUrl ?? testBaseUrl;
  final result = await ExtractPipeline(stages: stages).run(
    page: buildHtmlFetchResult(
      originalUrl: origin,
      finalUrl: finalUrl ?? origin,
      statusCode: 200,
      headers: const {'content-type': 'text/html; charset=utf-8'},
      bodyText: html,
      detectedCharset: 'utf-8',
      charsetSource: CharsetSource.header,
    ),
    fetcher: fetcher ?? _NoopFetcher(),
    fetchOptions: fetchOptions,
    extractOptions: extractOptions,
  );
  return result.metadata;
}

class _NoopFetcher implements Fetcher {
  @override
  Future<FetchResponse> get(
    Uri url, {
    required FetchOptions options,
    Map<String, String>? headers,
    int? maxBytes,
  }) async {
    return FetchResponse(
      url: url,
      statusCode: 200,
      headers: const <String, String>{},
      bodyBytes: const <int>[],
      truncated: false,
      duration: Duration.zero,
    );
  }

  @override
  Future<FetchResponse> head(
    Uri url, {
    required FetchOptions options,
    Map<String, String>? headers,
  }) async {
    return FetchResponse(
      url: url,
      statusCode: 200,
      headers: const <String, String>{},
      bodyBytes: const <int>[],
      truncated: false,
      duration: Duration.zero,
    );
  }

  @override
  void close() {}
}
