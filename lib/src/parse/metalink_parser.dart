import 'dart:convert';

import 'package:metalink/src/extract/extractors/json_ld_extractor.dart';
import 'package:metalink/src/extract/extractors/link_rel_extractor.dart';
import 'package:metalink/src/extract/extractors/open_graph_extractor.dart';
import 'package:metalink/src/extract/extractors/standard_meta_extractor.dart';
import 'package:metalink/src/extract/extractors/twitter_card_extractor.dart';
import 'package:metalink/src/extract/pipeline.dart';
import 'package:metalink/src/extract/ranking.dart';
import 'package:metalink/src/fetch/html_snippet_fetcher.dart';
import 'package:metalink/src/model/diagnostics.dart';
import 'package:metalink/src/model/errors.dart';
import 'package:metalink/src/model/link_metadata.dart';
import 'package:metalink/src/options.dart';
import 'package:metalink/src/parse/web_decoder.dart';
import 'package:metalink/src/result.dart';

/// Pure HTML metadata parser with no implicit network activity.
///
/// Use [parseHtml] when HTML has already been decoded, or [parseResponse] when
/// raw response bytes and headers are available. Remote oEmbed and manifest
/// enrichment is intentionally not performed by this class.
class MetaLinkParser {
  MetaLinkParser({
    WebDecoder decoder = const WebDecoder(),
    RankingPolicy rankingPolicy = const DefaultRankingPolicy(),
  }) : _decoder = decoder,
       _pipeline = ExtractPipeline(
         stages: const [
           OpenGraphExtractor(),
           TwitterCardExtractor(),
           StandardMetaExtractor(),
           LinkRelExtractor(),
           JsonLdExtractor(),
         ],
         rankingPolicy: rankingPolicy,
       );

  final WebDecoder _decoder;
  final ExtractPipeline _pipeline;

  /// Parses an already-decoded HTML document.
  Future<ExtractionResult<LinkMetadata>> parseHtml(
    String html, {
    required Uri documentUrl,
    Uri? requestedUrl,
    ExtractOptions options = const ExtractOptions(),
  }) async {
    final bytes = utf8.encode(html);
    final page = HtmlFetchResult(
      originalUrl: requestedUrl ?? documentUrl,
      finalUrl: documentUrl,
      redirects: const [],
      statusCode: 200,
      headers: const <String, String>{
        'content-type': 'text/html; charset=utf-8',
      },
      bodyBytes: bytes,
      bodyText: html,
      detectedCharset: 'utf-8',
      charsetSource: CharsetSource.header,
      truncated: false,
      duration: Duration.zero,
    );

    return _parsePage(page, options: options, includeDecodeDiagnostics: false);
  }

  /// Decodes and parses raw HTML response bytes.
  Future<ExtractionResult<LinkMetadata>> parseResponse(
    List<int> bodyBytes, {
    required Uri requestedUrl,
    required Uri finalUrl,
    required Map<String, String> headers,
    ExtractOptions options = const ExtractOptions(),
  }) async {
    final normalizedHeaders = _normalizeHeaders(headers);
    final decoded = _decoder.decode(bodyBytes, headers: normalizedHeaders);
    final page = HtmlFetchResult(
      originalUrl: requestedUrl,
      finalUrl: finalUrl,
      redirects: const [],
      statusCode: 200,
      headers: normalizedHeaders,
      bodyBytes: List<int>.unmodifiable(bodyBytes),
      bodyText: decoded.text,
      detectedCharset: decoded.charset,
      charsetSource: decoded.source,
      truncated: false,
      duration: Duration.zero,
    );

    return _parsePage(page, options: options, includeDecodeDiagnostics: true);
  }

  Future<ExtractionResult<LinkMetadata>> _parsePage(
    HtmlFetchResult page, {
    required ExtractOptions options,
    required bool includeDecodeDiagnostics,
  }) async {
    final stopwatch = Stopwatch()..start();
    final output = await _pipeline.runLocal(
      page: page,
      extractOptions: options,
    );
    stopwatch.stop();

    final warnings = <MetaLinkWarning>[...output.warnings];
    if (includeDecodeDiagnostics &&
        (page.charsetSource == CharsetSource.fallback ||
            page.charsetSource == CharsetSource.unknown)) {
      warnings.insert(
        0,
        MetaLinkWarning(
          code: MetaLinkWarningCode.charsetFallback,
          message: 'Character set detection used the UTF-8 fallback.',
          uri: page.finalUrl,
        ),
      );
    }
    if (options.enableOEmbed || options.enableManifest) {
      warnings.add(
        MetaLinkWarning(
          code: MetaLinkWarningCode.partialParse,
          message: 'Pure parsing skipped remote oEmbed or manifest enrichment.',
          uri: page.finalUrl,
        ),
      );
    }

    return ExtractionResult<LinkMetadata>(
      metadata: output.metadata,
      diagnostics: ExtractionDiagnostics(
        cacheHit: false,
        totalTime: stopwatch.elapsed,
        fetch: includeDecodeDiagnostics
            ? FetchDiagnostics(
                requestedUrl: page.originalUrl,
                finalUrl: page.finalUrl,
                statusCode: page.statusCode,
                redirects: page.redirects,
                bytesRead: page.bodyBytes.length,
                truncated: page.truncated,
                detectedCharset: page.detectedCharset,
                charsetSource: page.charsetSource,
                duration: Duration.zero,
              )
            : null,
        fieldProvenance: output.fieldProvenance,
        itemProvenance: output.itemProvenance,
        candidateDecisions: output.candidateDecisions,
      ),
      raw: output.raw,
      warnings: warnings,
      errors: output.errors,
      status: ExtractionResult.inferStatus(
        warnings: warnings,
        errors: output.errors,
      ),
    );
  }

  static Map<String, String> _normalizeHeaders(Map<String, String> headers) {
    return <String, String>{
      for (final entry in headers.entries) entry.key.toLowerCase(): entry.value,
    };
  }
}
