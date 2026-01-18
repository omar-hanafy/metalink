import 'package:metalink/src/options.dart';
import 'package:metalink/src/model/url_optimization.dart';
import 'package:metalink/src/fetch/fetcher.dart';
import 'package:metalink/src/util/url_normalizer.dart';

/// Resolves URL redirects to discover the final destination.
///
/// [RedirectResolver] follows HTTP redirects (301, 302, 303, 307, 308) using
/// HEAD requests to avoid downloading response bodies. Falls back to GET
/// when HEAD is not supported.
///
/// ### When to Use
/// Use via [MetaLinkClient.optimizeUrl] to resolve shortened URLs (bit.ly, t.co)
/// or discover canonical destinations without full metadata extraction.
///
/// ### Example
/// ```dart
/// final resolver = RedirectResolver(fetcher: HttpFetcher());
/// final result = await resolver.resolve(
///   Uri.parse('https://bit.ly/example'),
///   options: FetchOptions(),
/// );
/// print('Final URL: ${result.finalUrl}');
/// print('Redirects: ${result.redirects.length}');
/// ```
class RedirectResolver {
  /// Creates a [RedirectResolver] with the given [Fetcher].
  RedirectResolver({
    required Fetcher fetcher,
  }) : _fetcher = fetcher;

  final Fetcher _fetcher;

  Future<UrlOptimizationResult> resolve(
    Uri url, {
    required FetchOptions options,
  }) async {
    final sw = Stopwatch()..start();

    final redirects = <RedirectHop>[];
    Uri current = url;
    int? statusCode;

    Object? error;
    StackTrace? stackTrace;

    try {
      if (!options.followRedirects || options.maxRedirects <= 0) {
        final resp = await _headThenMaybeGet(current, options);
        statusCode = resp.statusCode;
        error = resp.error;
        stackTrace = resp.stackTrace;

        return UrlOptimizationResult(
          originalUrl: url,
          finalUrl: current,
          redirects: const [],
          statusCode: statusCode,
          duration: sw.elapsed,
          error: error,
          stackTrace: stackTrace,
        );
      }

      bool lastWasRedirect = false;
      bool lastHadLocation = false;

      for (var i = 0; i < options.maxRedirects; i++) {
        final resp = await _headThenMaybeGet(current, options);

        statusCode = resp.statusCode;
        if (resp.error != null) {
          error = resp.error;
          stackTrace = resp.stackTrace;
          lastWasRedirect = false;
          lastHadLocation = false;
          break;
        }

        final sc = statusCode;
        final location = _getHeader(resp.headers, 'location');

        lastWasRedirect = _isRedirectStatus(sc);
        lastHadLocation = location != null && location.trim().isNotEmpty;

        if (!lastWasRedirect || !lastHadLocation) {
          break;
        }

        final next = _resolveLocation(current, location);
        if (next == null) {
          // Invalid location, stop resolving so current stays the final URL.
          break;
        }

        redirects.add(
          RedirectHop(
            from: current,
            to: next,
            statusCode: sc!,
            location: location,
          ),
        );

        current = next;
      }

      // If we exhausted redirects and still see a redirect, surface a limit error.
      if (error == null &&
          redirects.length == options.maxRedirects &&
          lastWasRedirect &&
          lastHadLocation) {
        error = StateError('Too many redirects');
      }

      return UrlOptimizationResult(
        originalUrl: url,
        finalUrl: current,
        redirects: redirects,
        statusCode: statusCode,
        duration: sw.elapsed,
        error: error,
        stackTrace: stackTrace,
      );
    } catch (e, st) {
      // Keep a non-throw contract even for unexpected errors.
      return UrlOptimizationResult(
        originalUrl: url,
        finalUrl: current,
        redirects: redirects,
        statusCode: statusCode,
        duration: sw.elapsed,
        error: e,
        stackTrace: st,
      );
    }
  }

  Future<FetchResponse> _headThenMaybeGet(Uri url, FetchOptions options) async {
    // Prefer HEAD to avoid bodies, falling back to GET when HEAD is blocked or unreliable.
    final requestUrl = _applyProxyIfNeeded(url, options.proxyUrl);
    final head = await _fetcher.head(
      requestUrl,
      options: options,
      headers: null,
    );

    if (head.error != null) {
      // Fall back to GET so redirect resolution can continue.
      return _fetcher.get(
        requestUrl,
        options: options,
        headers: null,
        maxBytes: 0,
      );
    }

    final sc = head.statusCode;
    if (sc == 405 || sc == 501) {
      // Method not allowed or not implemented, so fall back to GET.
      return _fetcher.get(
        requestUrl,
        options: options,
        headers: null,
        maxBytes: 0,
      );
    }

    return head;
  }

  bool _isRedirectStatus(int? statusCode) {
    if (statusCode == null) return false;
    switch (statusCode) {
      case 300:
      case 301:
      case 302:
      case 303:
      case 307:
      case 308:
        return true;
      default:
        return false;
    }
  }

  String? _getHeader(Map<String, String> headers, String name) {
    final needle = name.toLowerCase();
    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() == needle) return entry.value;
    }
    return null;
  }

  Uri? _resolveLocation(Uri base, String location) {
    final raw = location.trim();
    if (raw.isEmpty) return null;

    final parsed = Uri.tryParse(raw);
    if (parsed == null) return null;

    // Absolute URLs are accepted after scheme checks.
    if (parsed.hasScheme) return _accept(parsed);

    // Resolve relative or protocol-relative URLs against the current URL.
    try {
      final resolved = base.resolveUri(parsed);
      return _accept(resolved);
    } catch (_) {
      return null;
    }
  }

  Uri? _accept(Uri uri) {
    final scheme = uri.scheme.toLowerCase();
    if (scheme != 'http' && scheme != 'https') return null;
    return uri;
  }

  Uri _applyProxyIfNeeded(Uri targetUrl, String? proxyUrl) {
    if (proxyUrl == null || proxyUrl.trim().isEmpty) return targetUrl;
    return UrlNormalizer.applyProxy(targetUrl, proxyUrl);
  }
}
