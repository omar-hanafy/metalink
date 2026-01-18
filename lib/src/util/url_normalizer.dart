/// Utility functions for URL normalization and parsing.
///
/// [UrlNormalizer] provides methods for:
/// * Parsing loose URL strings into valid [Uri] objects
/// * Normalizing URLs for consistent cache keys
/// * Removing fragments and default ports
/// * Applying CORS proxy URLs
///
/// ### Supported Input Formats
/// * Absolute URLs: `https://example.com/path`
/// * Protocol-relative: `//example.com/path` (defaults to HTTPS)
/// * Host only: `example.com` (defaults to HTTPS)
///
/// ### Filtered Schemes
/// Non-HTTP schemes (`mailto:`, `javascript:`, `data:`, etc.) return `null`.
class UrlNormalizer {
  static final RegExp _absoluteSchemeRegex =
      RegExp(r'^[a-zA-Z][a-zA-Z0-9+\-.]*://');

  static final List<String> _forbiddenSchemes = <String>[
    'mailto:',
    'tel:',
    'sms:',
    'javascript:',
    'data:',
    'file:',
    'ftp:',
    'about:',
    'chrome:',
    'blob:',
  ];

  /// Parses a loose URL string into a normalized [Uri].
  ///
  /// Handles protocol-relative URLs, host-only input, and filters
  /// non-HTTP schemes. Returns `null` for invalid or unsupported input.
  static Uri? parseLoose(String input) {
    final raw = input.trim();
    if (raw.isEmpty) return null;

    final rawLower = raw.toLowerCase();
    for (final scheme in _forbiddenSchemes) {
      if (rawLower.startsWith(scheme)) return null;
    }

    // Protocol-relative URLs inherit https to form a valid absolute URL.
    String candidate = raw;
    if (candidate.startsWith('//')) {
      candidate = 'https:$candidate';
    }

    // If it already has a scheme, only accept http or https for safety.
    if (_absoluteSchemeRegex.hasMatch(candidate)) {
      final uri = Uri.tryParse(candidate);
      if (uri == null) return null;

      final scheme = uri.scheme.toLowerCase();
      if (scheme != 'http' && scheme != 'https') return null;
      if (uri.host.isEmpty) return null;

      return normalizeForRequest(uri);
    }

    // Reject clearly relative paths because there is no base to resolve against.
    if (candidate.startsWith('/')) return null;

    // Otherwise treat as host or host:port and assume https by default.
    final uri = Uri.tryParse('https://$candidate');
    if (uri == null) return null;
    if (uri.host.isEmpty) return null;

    return normalizeForRequest(uri);
  }

  /// Upgrades an HTTP URL to HTTPS.
  ///
  /// Returns [input] unchanged if already HTTPS or uses an unknown scheme.
  static Uri ensureHttpsScheme(Uri input) {
    final schemeLower = input.scheme.toLowerCase();
    if (schemeLower == 'https') return input;

    if (schemeLower == 'http' || schemeLower.isEmpty) {
      return input.replace(scheme: 'https');
    }

    // Leave unknown or non-web schemes untouched so callers can decide how to handle them.
    return input;
  }

  /// Removes the fragment (hash) from a URL.
  ///
  /// Fragments are not sent to servers and should be stripped for
  /// cache keys and asset deduplication.
  static Uri removeFragment(Uri input) {
    if (!input.hasFragment) return input;
    return Uri(
      scheme: input.scheme,
      userInfo: input.userInfo,
      host: input.host,
      port: input.port,
      path: input.path,
      query: input.hasQuery ? input.query : null,
    );
  }

  /// Normalizes a URL for HTTP requests.
  ///
  /// * Removes fragments
  /// * Lowercases scheme and host
  /// * Removes default ports (80 for HTTP, 443 for HTTPS)
  /// * Ensures path is at least `/`
  static Uri normalizeForRequest(Uri input) {
    final noFrag = removeFragment(input);

    final scheme =
        (noFrag.scheme.isEmpty ? 'https' : noFrag.scheme).toLowerCase();
    final host = noFrag.host.toLowerCase();
    final path = noFrag.path.isEmpty ? '/' : noFrag.path;

    // Normalize default ports away so equivalent URLs compare equal.
    int? port = noFrag.hasPort ? noFrag.port : null;
    if ((scheme == 'http' && port == 80) ||
        (scheme == 'https' && port == 443)) {
      port = null;
    }

    return noFrag.replace(
      scheme: scheme,
      host: host,
      path: path,
      port: port,
    );
  }

  /// Normalizes a URL for use as a cache key.
  ///
  /// Uses the same normalization as [normalizeForRequest] to ensure
  /// equivalent URLs produce identical cache keys.
  static Uri normalizeForCacheKey(Uri input) {
    // Cache keys must be stable. Normalize scheme and host, drop fragments, and ensure path is at least "/".
    // Do not rewrite query parameter ordering to avoid changing cache semantics.
    return normalizeForRequest(input);
  }

  /// Applies a CORS proxy URL to the target URL.
  ///
  /// ### Supported Placeholders
  /// * `{url}` - Replaced with the raw URL
  /// * `{urlEncoded}` - Replaced with the URL-encoded URL
  ///
  /// If no placeholder is found, the target URL is appended to the proxy base.
  ///
  /// ### Example
  /// ```dart
  /// final proxied = UrlNormalizer.applyProxy(
  ///   Uri.parse('https://example.com'),
  ///   'https://corsproxy.io/?{urlEncoded}',
  /// );
  /// ```
  static Uri applyProxy(Uri targetUrl, String proxyUrl) {
    final p = proxyUrl.trim();
    if (p.isEmpty) return targetUrl;

    // Supported placeholders:
    // - {url} uses the raw URL string
    // - {urlEncoded} uses the URL-encoded string
    final raw = targetUrl.toString();
    final encoded = Uri.encodeComponent(raw);

    String built;
    if (p.contains('{urlEncoded}')) {
      built = p.replaceAll('{urlEncoded}', encoded);
    } else if (p.contains('{url}')) {
      built = p.replaceAll('{url}', raw);
    } else {
      // Prefix mode appends the raw URL to the proxy base.
      built = '$p$raw';
    }

    return Uri.tryParse(built) ?? targetUrl;
  }
}
