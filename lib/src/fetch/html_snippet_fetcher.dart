import 'dart:convert';

import 'package:metalink/src/extract/url_resolver.dart';
import 'package:metalink/src/model/diagnostics.dart';
import 'package:metalink/src/model/url_optimization.dart';
import 'package:metalink/src/options.dart';
import 'package:metalink/src/util/url_normalizer.dart';
import 'package:metalink/src/fetch/fetcher.dart';

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
  HtmlSnippetFetcher({
    required Fetcher fetcher,
  }) : _fetcher = fetcher;

  final Fetcher _fetcher;

  static const UrlResolver _urlResolver = UrlResolver();

  /// Number of bytes to probe for charset detection in meta tags.
  static const int _charsetProbeBytes = 4096;

  Future<HtmlFetchResult> fetch(
    Uri url, {
    required FetchOptions options,
  }) async {
    final sw = Stopwatch()..start();

    final Uri originalUrl = url;
    Uri currentUrl = url;

    final redirects = <RedirectHop>[];

    int? statusCode;
    Map<String, String> headers = const <String, String>{};

    List<int> bodyBytes = const <int>[];
    String? bodyText;
    String? detectedCharset;
    CharsetSource charsetSource = CharsetSource.unknown;
    bool truncated = false;

    Object? error;
    StackTrace? stackTrace;

    final requestHeaders = _buildRequestHeaders(options);

    try {
      // Resolve redirects with HEAD first to avoid downloading bodies when possible.
      if (options.followRedirects && options.stopAfterHead) {
        final headOutcome = await _resolveRedirectsWithHead(
          startUrl: currentUrl,
          options: options,
          requestHeaders: requestHeaders,
          redirects: redirects,
        );

        if (headOutcome._error != null) {
          // Treat terminal HEAD failures as final to avoid extra requests.
          error = headOutcome._error;
          stackTrace = null;
          statusCode = headOutcome._statusCode;
          headers = headOutcome._headers ?? headers;
          currentUrl = headOutcome._finalUrl ?? currentUrl;

          // HEAD path returns no body, so keep body empty.
          bodyBytes = const <int>[];
          bodyText = null;
          detectedCharset = null;
          charsetSource = CharsetSource.unknown;
          truncated = false;

          return HtmlFetchResult(
            originalUrl: originalUrl,
            finalUrl: currentUrl,
            redirects: redirects,
            statusCode: statusCode,
            headers: headers,
            bodyBytes: bodyBytes,
            bodyText: bodyText,
            detectedCharset: detectedCharset,
            charsetSource: charsetSource,
            truncated: truncated,
            duration: sw.elapsed,
            error: error,
            stackTrace: stackTrace,
          );
        }

        // If HEAD indicates non-HTML, stop early to avoid downloading large binaries.
        if (headOutcome._headResponse != null) {
          final headResp = headOutcome._headResponse!;
          statusCode = headResp.statusCode;
          headers = headResp.headers;

          final contentType = _headerValue(headers, 'content-type');
          if (!_looksLikeHtmlContentType(contentType)) {
            currentUrl = headOutcome._finalUrl ?? currentUrl;
            // Stop early with an empty body because content is not HTML.
            return HtmlFetchResult(
              originalUrl: originalUrl,
              finalUrl: currentUrl,
              redirects: redirects,
              statusCode: statusCode,
              headers: headers,
              bodyBytes: const <int>[],
              bodyText: null,
              detectedCharset: null,
              charsetSource: CharsetSource.unknown,
              truncated: false,
              duration: sw.elapsed,
              error: null,
              stackTrace: null,
            );
          }
        }

        currentUrl = headOutcome._finalUrl ?? currentUrl;
      }

      // Fetch final HTML with GET and follow remaining redirects if needed.
      final getOutcome = await _fetchWithGetAndRedirects(
        startUrl: currentUrl,
        originalUrl: originalUrl,
        options: options,
        requestHeaders: requestHeaders,
        redirects: redirects,
      );

      statusCode = getOutcome._statusCode;
      headers = getOutcome._headers ?? headers;
      truncated = getOutcome._truncated;
      currentUrl = getOutcome._finalUrl ?? currentUrl;

      if (getOutcome._error != null) {
        error = getOutcome._error;
        stackTrace = getOutcome._stackTrace;

        bodyBytes = getOutcome._bodyBytes ?? const <int>[];
        // Decode best-effort when content-type suggests text.
        final ct = _headerValue(headers, 'content-type');
        if (_isProbablyTextContentType(ct) && bodyBytes.isNotEmpty) {
          final decoded = _decodeBody(bodyBytes, headers);
          bodyText = decoded?.text;
          detectedCharset = decoded?.charset;
          charsetSource = decoded?.source ?? CharsetSource.unknown;
        } else {
          bodyText = null;
          detectedCharset = null;
          charsetSource = CharsetSource.unknown;
        }
      } else {
        bodyBytes = getOutcome._bodyBytes ?? const <int>[];
        final ct = _headerValue(headers, 'content-type');

        if (_isProbablyTextContentType(ct) && bodyBytes.isNotEmpty) {
          final decoded = _decodeBody(bodyBytes, headers);
          bodyText = decoded?.text;
          detectedCharset = decoded?.charset;
          charsetSource = decoded?.source ?? CharsetSource.unknown;
        } else {
          bodyText = null;
          detectedCharset = null;
          charsetSource = CharsetSource.unknown;
        }
      }
    } catch (e, st) {
      error = e;
      stackTrace = st;
    } finally {
      sw.stop();
    }

    return HtmlFetchResult(
      originalUrl: originalUrl,
      finalUrl: currentUrl,
      redirects: redirects,
      statusCode: statusCode,
      headers: headers,
      bodyBytes: bodyBytes,
      bodyText: bodyText,
      detectedCharset: detectedCharset,
      charsetSource: charsetSource,
      truncated: truncated,
      duration: sw.elapsed,
      error: error,
      stackTrace: stackTrace,
    );
  }

  // Resolve redirects using HEAD first to avoid fetching bodies.

  Future<_HeadRedirectOutcome> _resolveRedirectsWithHead({
    required Uri startUrl,
    required FetchOptions options,
    required Map<String, String> requestHeaders,
    required List<RedirectHop> redirects,
  }) async {
    Uri current = startUrl;
    FetchResponse? lastHead;

    for (var i = 0; i <= options.maxRedirects; i++) {
      final resp = await _safeHead(
        logicalUrl: current,
        options: options,
        headers: requestHeaders,
      );

      lastHead = resp;

      // If HEAD is unusable, fall back to GET-based resolution from the current URL.
      if (_shouldFallbackFromHead(resp)) {
        return _HeadRedirectOutcome(
          finalUrl: current,
          headResponse: null,
        );
      }

      final location = _headerValue(resp.headers, 'location');
      if (options.followRedirects &&
          _isRedirectWithLocation(resp.statusCode, location)) {
        if (redirects.length >= options.maxRedirects) {
          return _HeadRedirectOutcome(
            finalUrl: current,
            headResponse: resp,
            error: StateError(
              'Too many redirects (max: ${options.maxRedirects}).',
            ),
          );
        }

        final next = _resolveRedirectTarget(current, location!);
        if (next == null) {
          return _HeadRedirectOutcome(
            finalUrl: current,
            headResponse: resp,
            error: FormatException('Invalid redirect location: $location'),
          );
        }

        if (next == current) {
          return _HeadRedirectOutcome(
            finalUrl: current,
            headResponse: resp,
            error:
                StateError('Redirect loop detected (Location points to self).'),
          );
        }

        redirects.add(
          RedirectHop(
            from: current,
            to: next,
            statusCode: resp.statusCode ?? 0,
            location: location,
          ),
        );
        current = next;
        continue;
      }

      // Not a redirect or no Location header, so stop resolving.
      return _HeadRedirectOutcome(
        finalUrl: current,
        headResponse: lastHead,
      );
    }

    // If we exit the loop, treat it as too many redirects for safety.
    return _HeadRedirectOutcome(
      finalUrl: current,
      headResponse: lastHead,
      error: StateError('Too many redirects (max: ${options.maxRedirects}).'),
    );
  }

  // Final fetch with GET, handling redirects manually for consistent accounting.

  Future<_GetFetchOutcome> _fetchWithGetAndRedirects({
    required Uri startUrl,
    required Uri originalUrl,
    required FetchOptions options,
    required Map<String, String> requestHeaders,
    required List<RedirectHop> redirects,
  }) async {
    Uri current = startUrl;

    FetchResponse? lastGet;

    while (true) {
      lastGet = await _safeGet(
        logicalUrl: current,
        options: options,
        headers: requestHeaders,
        maxBytes: options.maxBytes,
      );

      // Network or timeout errors return early so callers can surface failures.
      if (lastGet.error != null) {
        return _GetFetchOutcome(
          finalUrl: current,
          statusCode: lastGet.statusCode,
          headers: lastGet.headers,
          bodyBytes: lastGet.bodyBytes,
          truncated: lastGet.truncated,
          error: lastGet.error,
          stackTrace: lastGet.stackTrace,
        );
      }

      final location = _headerValue(lastGet.headers, 'location');
      if (options.followRedirects &&
          _isRedirectWithLocation(lastGet.statusCode, location)) {
        if (redirects.length >= options.maxRedirects) {
          return _GetFetchOutcome(
            finalUrl: current,
            statusCode: lastGet.statusCode,
            headers: lastGet.headers,
            bodyBytes: lastGet.bodyBytes,
            truncated: lastGet.truncated,
            error: StateError(
              'Too many redirects (max: ${options.maxRedirects}).',
            ),
          );
        }

        final next = _resolveRedirectTarget(current, location!);
        if (next == null) {
          return _GetFetchOutcome(
            finalUrl: current,
            statusCode: lastGet.statusCode,
            headers: lastGet.headers,
            bodyBytes: lastGet.bodyBytes,
            truncated: lastGet.truncated,
            error: FormatException('Invalid redirect location: $location'),
          );
        }

        if (next == current) {
          return _GetFetchOutcome(
            finalUrl: current,
            statusCode: lastGet.statusCode,
            headers: lastGet.headers,
            bodyBytes: lastGet.bodyBytes,
            truncated: lastGet.truncated,
            error:
                StateError('Redirect loop detected (Location points to self).'),
          );
        }

        redirects.add(
          RedirectHop(
            from: current,
            to: next,
            statusCode: lastGet.statusCode ?? 0,
            location: location,
          ),
        );
        current = next;
        continue;
      }

      // Final non-redirect response.
      return _GetFetchOutcome(
        finalUrl: current,
        statusCode: lastGet.statusCode,
        headers: lastGet.headers,
        bodyBytes: lastGet.bodyBytes,
        truncated: lastGet.truncated,
      );
    }
  }

  // Network calls are proxy-safe and exception-safe to isolate fetcher issues.

  Future<FetchResponse> _safeHead({
    required Uri logicalUrl,
    required FetchOptions options,
    required Map<String, String> headers,
  }) async {
    try {
      final requestUrl = _applyProxyIfNeeded(logicalUrl, options.proxyUrl);
      return await _fetcher.head(
        requestUrl,
        options: options,
        headers: headers,
      );
    } catch (e, st) {
      // Fetcher should not throw, but contain any errors to keep flow safe.
      return FetchResponse(
        url: logicalUrl,
        statusCode: null,
        headers: const <String, String>{},
        bodyBytes: const <int>[],
        truncated: false,
        duration: Duration.zero,
        error: e,
        stackTrace: st,
      );
    }
  }

  Future<FetchResponse> _safeGet({
    required Uri logicalUrl,
    required FetchOptions options,
    required Map<String, String> headers,
    required int maxBytes,
  }) async {
    try {
      final requestUrl = _applyProxyIfNeeded(logicalUrl, options.proxyUrl);
      return await _fetcher.get(
        requestUrl,
        options: options,
        headers: headers,
        maxBytes: maxBytes,
      );
    } catch (e, st) {
      return FetchResponse(
        url: logicalUrl,
        statusCode: null,
        headers: const <String, String>{},
        bodyBytes: const <int>[],
        truncated: false,
        duration: Duration.zero,
        error: e,
        stackTrace: st,
      );
    }
  }

  static Uri _applyProxyIfNeeded(Uri targetUrl, String? proxyUrl) {
    if (proxyUrl == null || proxyUrl.trim().isEmpty) return targetUrl;
    return UrlNormalizer.applyProxy(targetUrl, proxyUrl);
  }

  // Header and redirect helpers centralize parsing behavior.

  static Map<String, String> _buildRequestHeaders(FetchOptions options) {
    final headers = <String, String>{...options.headers};

    bool hasHeader(String name) =>
        headers.keys.any((k) => k.toLowerCase() == name.toLowerCase());

    // Add a default Accept header so servers return HTML by preference.
    if (!hasHeader('accept')) {
      headers['Accept'] =
          'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8';
    }

    if (options.userAgent != null && options.userAgent!.trim().isNotEmpty) {
      headers['User-Agent'] = options.userAgent!;
    } else if (!hasHeader('user-agent')) {
      headers['User-Agent'] =
          'MetaLink/2.0.0 (+https://github.com/omar-hanafy/metalink)';
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

  static bool _isRedirectWithLocation(int? statusCode, String? location) {
    if (statusCode == null) return false;
    if (location == null || location.trim().isEmpty) return false;

    // 304 is not a redirect and should not trigger redirect handling.
    if (statusCode == 304) return false;

    // Most common redirect status codes that include Location.
    return statusCode == 300 ||
        statusCode == 301 ||
        statusCode == 302 ||
        statusCode == 303 ||
        statusCode == 307 ||
        statusCode == 308;
  }

  static Uri? _resolveRedirectTarget(Uri base, String location) {
    // Use shared URL resolver so relative and protocol-relative URLs resolve consistently.
    return _urlResolver.resolve(base, location);
  }

  static bool _shouldFallbackFromHead(FetchResponse resp) {
    final sc = resp.statusCode;

    if (resp.error != null) return true;
    if (sc == null) return true;

    // HEAD not allowed or not implemented, so fall back to GET.
    if (sc == 405 || sc == 501) return true;

    // Some servers behave differently on HEAD vs GET for errors.
    // Fall back to GET on any 4xx or 5xx to avoid false negatives.
    if (sc >= 400 && sc < 600) return true;

    return false;
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

  // Charset detection and decoding prefer explicit hints but fall back safely.

  _DecodeResult? _decodeBody(List<int> bytes, Map<String, String> headers) {
    if (bytes.isEmpty) return null;

    // Detect UTF-8 BOM and decode directly if present.
    var body = bytes;
    if (body.length >= 3 &&
        body[0] == 0xEF &&
        body[1] == 0xBB &&
        body[2] == 0xBF) {
      body = body.sublist(3);
      final text = utf8.decode(body, allowMalformed: true);
      return _DecodeResult(
          text: text, charset: 'utf-8', source: CharsetSource.bom);
    }

    // 1) Header-declared charset has highest precedence.
    final headerCharset =
        _detectCharsetFromHeader(_headerValue(headers, 'content-type'));
    if (headerCharset != null) {
      final decoded = _decodeWithCharset(body, headerCharset);
      if (decoded != null) {
        return _DecodeResult(
          text: decoded,
          charset: headerCharset,
          source: CharsetSource.header,
        );
      }
    }

    // 2) Meta-declared charset using a small byte probe.
    final metaCharset = _detectCharsetFromMeta(body);
    if (metaCharset != null) {
      final decoded = _decodeWithCharset(body, metaCharset);
      if (decoded != null) {
        return _DecodeResult(
          text: decoded,
          charset: metaCharset,
          source: CharsetSource.meta,
        );
      }
    }

    // 3) Fallback to UTF-8 with malformed handling.
    final fallbackText = utf8.decode(body, allowMalformed: true);
    return _DecodeResult(
      text: fallbackText,
      charset: 'utf-8',
      source: CharsetSource.fallback,
    );
  }

  static String? _detectCharsetFromHeader(String? contentType) {
    if (contentType == null || contentType.isEmpty) return null;

    final lower = contentType.toLowerCase();
    final idx = lower.indexOf('charset=');
    if (idx == -1) return null;

    var value = lower.substring(idx + 'charset='.length).trim();

    // Strip trailing parameters to isolate the charset token.
    final semi = value.indexOf(';');
    if (semi != -1) value = value.substring(0, semi).trim();

    // Strip quotes around the charset value.
    value = value.replaceAll('"', '').replaceAll("'", '').trim();

    return _normalizeSupportedCharset(value);
  }

  static String? _detectCharsetFromMeta(List<int> bytes) {
    final probeLen =
        bytes.length < _charsetProbeBytes ? bytes.length : _charsetProbeBytes;
    if (probeLen <= 0) return null;

    // Latin1 is a 1:1 byte to codepoint mapping, safe for ASCII probing.
    final probe = latin1.decode(bytes.sublist(0, probeLen)).toLowerCase();

    // Detect explicit meta charset declarations.
    final direct = RegExp(
      '<meta[^>]*charset\\s*=\\s*["\']?\\s*([a-z0-9_\\-]+)',
      caseSensitive: false,
    ).firstMatch(probe);
    if (direct != null && direct.groupCount >= 1) {
      final cs = direct.group(1);
      final norm = _normalizeSupportedCharset(cs);
      if (norm != null) return norm;
    }

    // Detect charset tokens embedded in meta http-equiv content values.
    final generic = RegExp(
      'charset\\s*=\\s*["\']?\\s*([a-z0-9_\\-]+)',
      caseSensitive: false,
    ).firstMatch(probe);
    if (generic != null && generic.groupCount >= 1) {
      final cs = generic.group(1);
      final norm = _normalizeSupportedCharset(cs);
      if (norm != null) return norm;
    }

    return null;
  }

  static String? _normalizeSupportedCharset(String? raw) {
    if (raw == null) return null;
    final v = raw.trim().toLowerCase();
    if (v.isEmpty) return null;

    if (v == 'utf-8' || v == 'utf8') return 'utf-8';

    // Treat common latin1 aliases as latin1 for decoding.
    if (v == 'latin1' ||
        v == 'iso-8859-1' ||
        v == 'iso8859-1' ||
        v == 'windows-1252') {
      return 'latin1';
    }

    // Unsupported charset returns null so decoding can fall back.
    return null;
  }

  static String? _decodeWithCharset(List<int> bytes, String charset) {
    switch (charset) {
      case 'utf-8':
        return utf8.decode(bytes, allowMalformed: true);
      case 'latin1':
        return latin1.decode(bytes);
      default:
        return null;
    }
  }
}

class _DecodeResult {
  const _DecodeResult({
    required this.text,
    required this.charset,
    required this.source,
  });

  final String text;
  final String? charset;
  final CharsetSource source;
}

class _HeadRedirectOutcome {
  const _HeadRedirectOutcome({
    required this.finalUrl,
    required this.headResponse,
    this.error,
  });

  final Uri finalUrl;
  final FetchResponse? headResponse;
  final Object? error;

  Uri? get _finalUrl => finalUrl;
  FetchResponse? get _headResponse => headResponse;
  Object? get _error => error;

  int? get _statusCode => headResponse?.statusCode;
  Map<String, String>? get _headers => headResponse?.headers;
}

class _GetFetchOutcome {
  const _GetFetchOutcome({
    required this.finalUrl,
    required this.statusCode,
    required this.headers,
    required this.bodyBytes,
    required this.truncated,
    this.error,
    this.stackTrace,
  });

  final Uri finalUrl;
  final int? statusCode;
  final Map<String, String>? headers;
  final List<int>? bodyBytes;
  final bool truncated;
  final Object? error;
  final StackTrace? stackTrace;

  Uri? get _finalUrl => finalUrl;
  int? get _statusCode => statusCode;
  Map<String, String>? get _headers => headers;
  List<int>? get _bodyBytes => bodyBytes;
  bool get _truncated => truncated;
  Object? get _error => error;
  StackTrace? get _stackTrace => stackTrace;
}
