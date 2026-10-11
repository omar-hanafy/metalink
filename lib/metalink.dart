/// Metadata extraction, pure parsing, request policy, caching, and diagnostics.
library;

import 'dart:async';

import 'package:metalink/src/cache/cache_store.dart';
import 'package:metalink/src/client.dart';
import 'package:metalink/src/model/link_metadata.dart';
import 'package:metalink/src/network/request_context.dart';
import 'package:metalink/src/options.dart';
import 'package:metalink/src/result.dart';

export 'package:metalink/src/cache/cache_key.dart';
export 'package:metalink/src/cache/cache_store.dart';
export 'package:metalink/src/cache/hive_cache_store.dart';
export 'package:metalink/src/cache/memory_cache_store.dart';
export 'package:metalink/src/client.dart';
export 'package:metalink/src/extract/candidate.dart';
export 'package:metalink/src/extract/ranking.dart';
export 'package:metalink/src/fetch/fetcher.dart';
export 'package:metalink/src/fetch/http_fetcher.dart';
export 'package:metalink/src/model/diagnostics.dart';
export 'package:metalink/src/model/errors.dart';
export 'package:metalink/src/model/icon.dart';
export 'package:metalink/src/model/link_metadata.dart';
export 'package:metalink/src/model/manifest.dart';
export 'package:metalink/src/model/media.dart';
export 'package:metalink/src/model/oembed.dart';
export 'package:metalink/src/model/raw_metadata.dart';
export 'package:metalink/src/model/structured_data.dart';
export 'package:metalink/src/model/url_optimization.dart';
export 'package:metalink/src/network/request_context.dart';
export 'package:metalink/src/network/request_engine.dart';
export 'package:metalink/src/network/request_policy.dart';
export 'package:metalink/src/options.dart';
export 'package:metalink/src/parse/metalink_parser.dart';
export 'package:metalink/src/parse/web_decoder.dart';
export 'package:metalink/src/result.dart';

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
    RequestContext? requestContext,
    bool skipCache = false,
  }) async {
    // If no cacheStore is provided, disable caching to avoid creating a short-lived MemoryCacheStore.
    final effectiveOptions = cacheStore == null
        ? options.copyWith(cache: options.cache.copyWith(enabled: false))
        : options;

    final client = MetaLinkClient(
      options: effectiveOptions,
      cacheStore: cacheStore,
    );

    try {
      return await client.extract(
        url,
        requestContext: requestContext,
        skipCache: skipCache,
      );
    } finally {
      await client.dispose();
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
    RequestContext? requestContext,
    bool skipCache = false,
    int concurrency = 4,
  }) async {
    if (concurrency < 1) {
      throw ArgumentError.value(concurrency, 'concurrency', 'Must be >= 1.');
    }

    final effectiveOptions = cacheStore == null
        ? options.copyWith(cache: options.cache.copyWith(enabled: false))
        : options;

    final client = MetaLinkClient(
      options: effectiveOptions,
      cacheStore: cacheStore,
    );

    try {
      return await client.extractBatch(
        urls,
        requestContext: requestContext,
        skipCache: skipCache,
        concurrency: concurrency,
      );
    } finally {
      await client.dispose();
    }
  }
}
