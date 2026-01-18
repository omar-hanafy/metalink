import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Utility for generating consistent, collision-resistant cache keys.
///
/// [CacheKeyBuilder] produces SHA-256 hashed keys to ensure uniform key lengths
/// and avoid issues with special characters in URLs or other input strings.
///
/// ### When to Use
/// * Use [buildForUrl] when caching based on a [Uri].
/// * Use [buildForString] when caching based on a composite key (e.g., URL + options).
///
/// ### Key Format
/// Generated keys follow the pattern: `{prefix}{sha256_hash}`.
/// The default prefix is `metalink:`.
class CacheKeyBuilder {
  /// Generates a cache key from a [Uri].
  ///
  /// The key is computed as `{prefix}{sha256(url.toString())}`.
  ///
  /// ### Parameters
  /// * [url] - The URI to hash.
  /// * [prefix] - A prefix to prepend to the hash. Defaults to `metalink:`.
  static String buildForUrl(
    Uri url, {
    String prefix = 'metalink:',
  }) {
    final canonical = url.toString();
    final digest = sha256.convert(utf8.encode(canonical)).toString();
    return '$prefix$digest';
  }

  /// Generates a cache key from an arbitrary string.
  ///
  /// The key is computed as `{prefix}{sha256(value)}`.
  ///
  /// Useful for composite keys that include URL, options, or other factors.
  ///
  /// ### Parameters
  /// * [value] - The string to hash.
  /// * [prefix] - A prefix to prepend to the hash. Defaults to `metalink:`.
  static String buildForString(
    String value, {
    String prefix = 'metalink:',
  }) {
    final digest = sha256.convert(utf8.encode(value)).toString();
    return '$prefix$digest';
  }
}
