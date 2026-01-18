// ignore_for_file: always_use_package_imports, unnecessary_library_name
// Keep these ignores local to this library file while still exporting public APIs.
library metalink;

import 'dart:async';

import 'src/client.dart';
import 'src/options.dart';
import 'src/result.dart';
import 'src/cache/cache_store.dart';
import 'src/model/link_metadata.dart';

export 'src/client.dart';
export 'src/options.dart';
export 'src/result.dart';

export 'src/cache/cache_store.dart';
export 'src/cache/cache_key.dart';
export 'src/cache/memory_cache_store.dart';
export 'src/cache/hive_cache_store.dart';

export 'src/model/errors.dart';
export 'src/model/diagnostics.dart';
export 'src/model/raw_metadata.dart';
export 'src/model/url_optimization.dart';
export 'src/model/structured_data.dart';
export 'src/model/media.dart';
export 'src/model/icon.dart';
export 'src/model/oembed.dart';
export 'src/model/manifest.dart';
export 'src/model/link_metadata.dart';

/// Convenience one-off API for link metadata extraction.
///
/// [MetaLink] provides static methods for quick, stateless interactions where
/// managing a persistent [MetaLinkClient] is not necessary.
///
/// ### Behavior & Performance
/// * Each method call creates a **new** internal [MetaLinkClient] and closes it immediately after completion.
/// * This ensures no resources (like HTTP clients) leak, but it prevents connection reuse (Keep-Alive)
///   across multiple calls.
/// * For high-throughput applications (e.g., processing a queue of URLs), prefer creating a
///   long-lived [MetaLinkClient] instead.
///
/// ### Usage
/// ```dart
/// // Simple extraction
/// final result = await MetaLink.extract('https://flutter.dev');
///
/// // Batch with concurrency
/// final results = await MetaLink.extractBatch(urls, concurrency: 10);
/// ```
class MetaLink {
  /// Extracts metadata from a single [url].
  ///
  /// This method performs the full extraction pipeline:
  /// 1. **Resolve**: Follows redirects to find the final URL.
  /// 2. **Fetch**: Downloads the HTML content (up to configured limits).
  /// 3. **Extract**: Parses standard meta, OpenGraph, Twitter Cards, and JSON-LD.
  ///
  /// ### Caching
  /// * If [cacheStore] is provided, results are read from/written to it.
  /// * If [cacheStore] is `null` (default), the internal client is configured with caching **disabled**
  ///   to avoid the overhead of creating a temporary `MemoryCacheStore` that would be immediately discarded.
  ///
  /// Returns an [ExtractionResult] containing the metadata and any warnings/errors encountered.
  static Future<ExtractionResult<LinkMetadata>> extract(
    String url, {
    MetaLinkClientOptions options = const MetaLinkClientOptions(),
    CacheStore? cacheStore,
    bool skipCache = false,
  }) async {
    // If no cacheStore is provided, disable caching to avoid creating a short-lived MemoryCacheStore.
    final effectiveOptions = cacheStore == null
        ? options.copyWith(
            cache: options.cache.copyWith(enabled: false),
          )
        : options;

    final client = MetaLinkClient(
      options: effectiveOptions,
      cacheStore: cacheStore,
    );

    try {
      return await client.extract(
        url,
        skipCache: skipCache,
      );
    } finally {
      client.close();
    }
  }

  /// Extracts metadata from a list of [urls] in parallel.
  ///
  /// Useful for processing bulk lists efficiently. The [concurrency] parameter controls
  /// how many URLs are processed simultaneously.
  ///
  /// ### Error Handling
  /// * This method does **not** throw if individual URLs fail. Instead, the returned list
  ///   contains an [ExtractionResult] for each input URL in the corresponding index.
  /// * Failed URLs will have [ExtractionResult.errors] populated.
  ///
  /// Throws [ArgumentError] if [concurrency] is less than 1.
  static Future<List<ExtractionResult<LinkMetadata>>> extractBatch(
    List<String> urls, {
    MetaLinkClientOptions options = const MetaLinkClientOptions(),
    CacheStore? cacheStore,
    bool skipCache = false,
    int concurrency = 4,
  }) async {
    if (concurrency < 1) {
      throw ArgumentError.value(concurrency, 'concurrency', 'Must be >= 1.');
    }

    final client = MetaLinkClient(
      options: options,
      cacheStore: cacheStore,
    );

    try {
      return await client.extractBatch(
        urls,
        skipCache: skipCache,
        concurrency: concurrency,
      );
    } finally {
      client.close();
    }
  }
}
