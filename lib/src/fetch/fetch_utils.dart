import 'package:metalink/src/fetch/fetcher.dart';
import 'package:metalink/src/options.dart';
import 'package:metalink/src/util/url_normalizer.dart';
import 'package:metalink/src/extract/url_resolver.dart';

/// Utility functions for HTTP fetching with redirect handling.
///
/// [FetchUtils] provides helper methods for common fetch patterns used
/// throughout the library.
class FetchUtils {
  static const UrlResolver _urlResolver = UrlResolver();

  static Future<FetchResponse> getWithRedirects(
    Fetcher fetcher,
    Uri startUrl, {
    required FetchOptions options,
    Map<String, String>? headers,
    int? maxBytes,
  }) async {
    // If redirects are disabled, issue a single GET and return immediately.
    if (!options.followRedirects || options.maxRedirects <= 0) {
      final requestUrl = _applyProxyIfNeeded(startUrl, options.proxyUrl);
      return fetcher.get(
        requestUrl,
        options: options,
        headers: headers,
        maxBytes: maxBytes,
      );
    }

    var current = startUrl;
    // Keep the last response so we can return a best-effort result on exit.
    FetchResponse? lastResponse;

    for (var i = 0; i <= options.maxRedirects; i++) {
      final requestUrl = _applyProxyIfNeeded(current, options.proxyUrl);

      final resp = await fetcher.get(
        requestUrl,
        options: options,
        headers: headers,
        maxBytes: maxBytes,
      );

      lastResponse = resp;

      if (resp.error != null) {
        return resp;
      }

      final statusCode = resp.statusCode;
      final location = _headerValue(resp.headers, 'location');
      final isRedirect = location != null &&
          location.trim().isNotEmpty &&
          statusCode != null &&
          (statusCode == 300 ||
              statusCode == 301 ||
              statusCode == 302 ||
              statusCode == 303 ||
              statusCode == 307 ||
              statusCode == 308);

      if (!isRedirect) {
        return resp;
      }

      if (i == options.maxRedirects) {
        return FetchResponse(
          url: current,
          statusCode: resp.statusCode,
          headers: resp.headers,
          bodyBytes: resp.bodyBytes,
          truncated: resp.truncated,
          duration: resp.duration,
          error:
              StateError('Too many redirects (max: ${options.maxRedirects}).'),
        );
      }

      final next = _urlResolver.resolve(current, location);
      if (next == null) {
        return FetchResponse(
          url: current,
          statusCode: resp.statusCode,
          headers: resp.headers,
          bodyBytes: resp.bodyBytes,
          truncated: resp.truncated,
          duration: resp.duration,
          error: FormatException('Invalid redirect location: $location'),
        );
      }

      if (next == current) {
        return FetchResponse(
          url: current,
          statusCode: resp.statusCode,
          headers: resp.headers,
          bodyBytes: resp.bodyBytes,
          truncated: resp.truncated,
          duration: resp.duration,
          error:
              StateError('Redirect loop detected (Location points to self).'),
        );
      }

      current = next;
    }

    // Defensive fallback in case the loop exits without returning.
    return lastResponse ??
        FetchResponse(
          url: startUrl,
          statusCode: null,
          headers: const {},
          bodyBytes: const [],
          truncated: false,
          duration: Duration.zero,
          error: StateError('Unexpected redirect loop exit'),
        );
  }

  static Uri _applyProxyIfNeeded(Uri targetUrl, String? proxyUrl) {
    if (proxyUrl == null || proxyUrl.trim().isEmpty) return targetUrl;
    return UrlNormalizer.applyProxy(targetUrl, proxyUrl);
  }

  static String? _headerValue(Map<String, String> headers, String name) {
    final needle = name.toLowerCase();
    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() == needle) return entry.value;
    }
    return null;
  }
}
