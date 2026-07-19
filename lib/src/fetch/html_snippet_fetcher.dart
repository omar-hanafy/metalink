import 'package:metalink/src/fetch/fetcher.dart';
import 'package:metalink/src/model/diagnostics.dart';
import 'package:metalink/src/model/url_optimization.dart';
import 'package:metalink/src/network/request_context.dart';
import 'package:metalink/src/network/request_engine.dart';
import 'package:metalink/src/network/request_policy.dart';
import 'package:metalink/src/options.dart';
import 'package:metalink/src/parse/web_decoder.dart';

/// The result of fetching an HTML page.
///
/// [HtmlFetchResult] contains the fetched HTML content along with metadata
/// about the fetch operation including redirects, charset detection, and timing.
///
/// ### Fields
/// * [originalUrl] - The URL that was originally requested.
/// * [finalUrl] - The final URL after following redirects.
/// * [redirects] - List of redirect hops taken.
/// * [bodyText] - Decoded HTML text, or `null` if decoding failed.
/// * [detectedCharset] - The charset used for decoding.
/// * [charsetSource] - How the charset was determined.
class HtmlFetchResult {
  /// Creates an [HtmlFetchResult].
  const HtmlFetchResult({
    required this.originalUrl,
    required this.finalUrl,
    required this.redirects,
    required this.statusCode,
    required this.headers,
    required this.bodyBytes,
    required this.bodyText,
    required this.detectedCharset,
    required this.charsetSource,
    required this.truncated,
    required this.duration,
    this.error,
    this.stackTrace,
  });

  /// The URL that was originally requested.
  final Uri originalUrl;

  /// The final URL after following redirects.
  final Uri finalUrl;

  /// The sequence of redirect hops taken.
  final List<RedirectHop> redirects;

  /// HTTP status code, or `null` if the request failed.
  final int? statusCode;

  /// Response headers with lowercase keys.
  final Map<String, String> headers;

  /// Raw response body bytes.
  final List<int> bodyBytes;

  /// Decoded HTML text, or `null` if decoding failed or content is not text.
  final String? bodyText;

  /// The charset used for decoding (e.g., `utf-8`, `latin1`).
  final String? detectedCharset;

  /// How the charset was determined. See [CharsetSource].
  final CharsetSource charsetSource;

  /// Whether the response was truncated due to size limits.
  final bool truncated;

  /// Total time for the fetch operation.
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

/// Fetches HTML pages with redirect resolution and charset detection.
///
/// [HtmlSnippetFetcher] is the primary fetcher used for metadata extraction.
/// It handles:
/// * Following redirects (optionally using HEAD to avoid large downloads)
/// * Detecting charset from headers, BOM, or meta tags
/// * Decoding HTML to text with proper encoding
/// * Truncating responses that exceed size limits
///
/// ### Redirect Strategy
/// When [FetchOptions.stopAfterHead] is `true`, redirects are resolved using
/// HEAD requests first. This avoids downloading large non-HTML responses.
/// If HEAD indicates non-HTML content, the fetch stops early.
class HtmlSnippetFetcher {
  /// Creates an [HtmlSnippetFetcher] with the given [Fetcher].
  HtmlSnippetFetcher({required Fetcher fetcher}) : _fetcher = fetcher;

  final Fetcher _fetcher;

  Future<HtmlFetchResult> fetch(
    Uri url, {
    required FetchOptions options,
    RequestContext? context,
  }) async {
    try {
      final outcome = await RequestEngine(fetcher: _fetcher).execute(
        url,
        options: options,
        context: context ?? RequestContext(totalTimeout: options.totalTimeout),
        purpose: RequestPurpose.document,
        strategy: options.followRedirects && options.stopAfterHead
            ? RequestMethodStrategy.headThenGet
            : RequestMethodStrategy.get,
        headers: _buildRequestHeaders(options),
        maxBytes: options.maxBytes,
        shouldFetchBodyAfterHead: (response) => _looksLikeHtmlContentType(
          _headerValue(response.headers, 'content-type'),
        ),
      );
      final response = outcome.response;
      final responseHeaders = response?.headers ?? const <String, String>{};
      final responseBytes = response?.bodyBytes ?? const <int>[];
      final contentType = _headerValue(responseHeaders, 'content-type');
      final shouldDecode =
          responseBytes.isNotEmpty && _isProbablyTextContentType(contentType);
      final decoded = shouldDecode
          ? const WebDecoder().decode(responseBytes, headers: responseHeaders)
          : null;

      return HtmlFetchResult(
        originalUrl: outcome.originalUrl,
        finalUrl: outcome.finalUrl,
        redirects: outcome.redirects,
        statusCode: response?.statusCode,
        headers: responseHeaders,
        bodyBytes: responseBytes,
        bodyText: decoded?.text,
        detectedCharset: decoded?.charset,
        charsetSource: decoded?.source ?? CharsetSource.unknown,
        truncated: response?.truncated ?? false,
        duration: outcome.duration,
        error: outcome.failure ?? response?.error,
        stackTrace: outcome.failure?.stackTrace ?? response?.stackTrace,
      );
    } catch (e, st) {
      return HtmlFetchResult(
        originalUrl: url,
        finalUrl: url,
        redirects: const <RedirectHop>[],
        statusCode: null,
        headers: const <String, String>{},
        bodyBytes: const <int>[],
        bodyText: null,
        detectedCharset: null,
        charsetSource: CharsetSource.unknown,
        truncated: false,
        duration: Duration.zero,
        error: e,
        stackTrace: st,
      );
    }
  }

  // Header and redirect helpers centralize parsing behavior.

  static Map<String, String> _buildRequestHeaders(FetchOptions options) {
    final headers = <String, String>{};

    bool hasConfiguredHeader(String name) => options.headers.keys.any(
      (key) => key.toLowerCase() == name.toLowerCase(),
    );

    // Add a default Accept header so servers return HTML by preference.
    if (!hasConfiguredHeader('accept')) {
      headers['Accept'] =
          'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8';
    }

    return headers;
  }

  static String? _headerValue(Map<String, String> headers, String name) {
    final target = name.toLowerCase();
    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() == target) return entry.value;
    }
    return null;
  }

  static bool _looksLikeHtmlContentType(String? contentType) {
    if (contentType == null || contentType.trim().isEmpty) {
      // Unknown content-type: assume HTML to avoid skipping valid pages.
      return true;
    }
    final ct = contentType.toLowerCase();
    // Conservative HTML checks to avoid misclassifying binary responses.
    return ct.contains('text/html') ||
        ct.contains('application/xhtml') ||
        ct.contains('html');
  }

  static bool _isProbablyTextContentType(String? contentType) {
    if (contentType == null || contentType.trim().isEmpty) {
      return true;
    }

    final ct = contentType.toLowerCase();
    if (ct.startsWith('text/')) {
      return true;
    }

    // Some servers use these content-types for HTML-like responses.
    if (ct.contains('html') || ct.contains('xml') || ct.contains('json')) {
      return true;
    }

    // Default to non-text when no signals are present.
    return false;
  }
}
