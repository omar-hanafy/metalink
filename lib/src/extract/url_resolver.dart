/// Resolves relative and protocol-relative URLs against a base URL.
///
/// [UrlResolver] normalizes URL strings found in HTML attributes into
/// absolute [Uri] objects. It filters out non-HTTP schemes to ensure
/// only fetchable URLs enter the extraction pipeline.
///
/// ### Handled Cases
/// * Absolute URLs (`https://example.com/path`)
/// * Protocol-relative URLs (`//example.com/path`)
/// * Relative URLs (`/path`, `path`, `../path`)
///
/// ### Filtered Schemes
/// Returns `null` for `javascript:`, `mailto:`, `tel:`, `data:`, and fragment-only URLs.
class UrlResolver {
  /// Creates a [UrlResolver].
  const UrlResolver();

  /// Resolves [raw] against [base] to produce an absolute HTTP(S) URI.
  ///
  /// Returns `null` if [raw] is empty, invalid, or uses a non-HTTP scheme.
  Uri? resolve(Uri base, String? raw) {
    if (raw == null) return null;
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;

    // Ignore non-fetchable schemes so only safe HTTP(S) URLs enter the pipeline.
    final lower = trimmed.toLowerCase();
    if (lower.startsWith('#')) return null;
    if (lower.startsWith('javascript:')) return null;
    if (lower.startsWith('mailto:')) return null;
    if (lower.startsWith('tel:')) return null;
    if (lower.startsWith('data:')) return null;

    try {
      // Protocol-relative URLs inherit the base scheme to form a valid URI.
      if (trimmed.startsWith('//')) {
        final candidate = Uri.tryParse('${base.scheme}:$trimmed');
        return _accept(candidate);
      }

      final parsed = Uri.tryParse(trimmed);
      if (parsed == null) return null;

      // Absolute URLs can be accepted directly after scheme checks.
      if (parsed.hasScheme) {
        return _accept(parsed);
      }

      // Relative URLs resolve against the page base URL.
      final resolved = base.resolveUri(parsed);
      return _accept(resolved);
    } catch (_) {
      return null;
    }
  }

  /// Resolves multiple raw URL strings against [base].
  ///
  /// Invalid or non-HTTP URLs are filtered out.
  List<Uri> resolveAll(Uri base, Iterable<String?> rawValues) {
    final out = <Uri>[];
    for (final raw in rawValues) {
      final uri = resolve(base, raw);
      if (uri != null) out.add(uri);
    }
    return out;
  }

  Uri? _accept(Uri? uri) {
    if (uri == null) return null;
    final scheme = uri.scheme.toLowerCase();
    if (scheme != 'http' && scheme != 'https') return null;
    return uri;
  }
}
