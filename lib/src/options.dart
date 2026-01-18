import 'package:metalink/src/cache/cache_store.dart';

/// Configuration for the network layer of the extraction process.
///
/// Controls how `MetaLinkClient` connects to servers, handles redirects,
/// and enforces resource limits.
class FetchOptions {
  /// Creates a configuration for network operations.
  const FetchOptions({
    this.timeout = const Duration(seconds: 10),
    this.userAgent,
    this.followRedirects = true,
    this.maxRedirects = 5,
    this.maxBytes = 512 * 1024,
    this.stopAfterHead = true,
    this.proxyUrl,
    this.headers = const {},
  });

  /// The maximum duration to wait for a network connection or response.
  ///
  /// If this limit is exceeded during any phase (HEAD, GET, or redirect),
  /// a `TimeoutException` is thrown and the request is aborted.
  ///
  /// Defaults to 10 seconds.
  final Duration timeout;

  /// The value for the `User-Agent` HTTP header.
  ///
  /// If `null`, a default user agent indicating `MetaLink/2.0.0` will be used.
  /// Some servers may block requests with missing or generic user agents.
  final String? userAgent;

  /// Whether to automatically follow HTTP 3xx redirects.
  ///
  /// If `false`, the client will return the result of the first response, even
  /// if it is a redirect status (301, 302, etc.).
  ///
  /// Defaults to `true`.
  final bool followRedirects;

  /// The maximum number of redirects to follow before aborting.
  ///
  /// This prevents infinite redirect loops. If the limit is reached,
  /// the client stops and may return an error or the last response depending on context.
  ///
  /// Defaults to 5.
  final int maxRedirects;

  /// The maximum number of bytes to read from the response body.
  ///
  /// This protects the client from memory exhaustion attacks or unexpectedly large files.
  /// If the response exceeds this size, reading stops and the content is truncated.
  ///
  /// Defaults to 512 KB (512 * 1024).
  final int maxBytes;

  /// Optimization: whether to attempt a `HEAD` request before `GET`.
  ///
  /// If `true`, the client sends a `HEAD` request first to check the `Content-Type`.
  /// If the content is not HTML (e.g., a large binary file), the `GET` request
  /// is skipped to save bandwidth.
  ///
  /// Defaults to `true`.
  final bool stopAfterHead;

  /// An optional proxy URL string (e.g., for routing requests through a service).
  ///
  /// If provided, `UrlNormalizer.applyProxy` is used to rewrite the target URL.
  /// Supported patterns depend on the implementation (e.g., standard prefix or placeholder replacement).
  final String? proxyUrl;

  /// Additional HTTP headers to send with every request.
  ///
  /// These are merged with default headers (like `Accept` and `User-Agent`).
  /// Keys are case-insensitive.
  final Map<String, String> headers;

  /// Creates a copy of this options object with the given fields replaced.
  FetchOptions copyWith({
    Duration? timeout,
    String? userAgent,
    bool? followRedirects,
    int? maxRedirects,
    int? maxBytes,
    bool? stopAfterHead,
    String? proxyUrl,
    Map<String, String>? headers,
  }) {
    return FetchOptions(
      timeout: timeout ?? this.timeout,
      userAgent: userAgent ?? this.userAgent,
      followRedirects: followRedirects ?? this.followRedirects,
      maxRedirects: maxRedirects ?? this.maxRedirects,
      maxBytes: maxBytes ?? this.maxBytes,
      stopAfterHead: stopAfterHead ?? this.stopAfterHead,
      proxyUrl: proxyUrl ?? this.proxyUrl,
      headers: headers ?? this.headers,
    );
  }
}

/// Configuration for the metadata extraction pipeline.
///
/// Controls which extractors are active and the limits on collected metadata items
/// (images, videos, etc.). Disabling unused extractors can improve performance.
class ExtractOptions {
  /// Creates a configuration for the extraction pipeline.
  const ExtractOptions({
    this.extractOpenGraph = true,
    this.extractTwitterCard = true,
    this.extractStandardMeta = true,
    this.extractLinkRels = true,
    this.extractJsonLd = true,
    this.enableOEmbed = false,
    this.enableManifest = false,
    this.includeRawMetadata = false,
    this.maxImages = 10,
    this.maxIcons = 10,
    this.maxVideos = 5,
    this.maxAudios = 5,
  });

  /// Whether to parse Open Graph (`og:*`) meta tags.
  ///
  /// See: `OpenGraphExtractor`.
  final bool extractOpenGraph;

  /// Whether to parse Twitter Card (`twitter:*`) meta tags.
  ///
  /// See: `TwitterCardExtractor`.
  final bool extractTwitterCard;

  /// Whether to parse standard HTML meta tags (title, description, keywords).
  ///
  /// See: `StandardMetaExtractor`.
  final bool extractStandardMeta;

  /// Whether to parse `<link rel="...">` tags (canonical URL, icons, manifest).
  ///
  /// See: `LinkRelExtractor`.
  final bool extractLinkRels;

  /// Whether to parse and process JSON-LD structured data blocks.
  ///
  /// See: `JsonLdExtractor`.
  final bool extractJsonLd;

  /// Whether to fetch oEmbed data if an oEmbed discovery link is found.
  ///
  /// **Note:** This triggers an additional HTTP request to the oEmbed provider.
  /// Defaults to `false` to avoid implicit network calls.
  final bool enableOEmbed;

  /// Whether to fetch the Web App Manifest if a manifest link is found.
  ///
  /// **Note:** This triggers an additional HTTP request to the manifest URL.
  /// Defaults to `false` to avoid implicit network calls.
  final bool enableManifest;

  /// Whether to populate `LinkMetadata.raw` with raw key-value pairs from the DOM.
  ///
  /// Useful for debugging or accessing non-standard tags not normalized by `MetaLink`.
  /// Defaults to `false` to save memory.
  final bool includeRawMetadata;

  /// The maximum number of unique image candidates to retain.
  ///
  /// Images are scored and deduped; only the top-scoring `maxImages` are kept.
  final int maxImages;

  /// The maximum number of unique icon candidates to retain.
  ///
  /// Icons are scored and deduped; only the top `maxIcons` are kept.
  /// Defaults to 10.
  final int maxIcons;

  /// The maximum number of unique video candidates to retain.
  ///
  /// Videos are scored and deduped; only the top `maxVideos` are kept.
  /// Defaults to 5.
  final int maxVideos;

  /// The maximum number of unique audio candidates to retain.
  ///
  /// Audios are scored and deduped; only the top `maxAudios` are kept.
  /// Defaults to 5.
  final int maxAudios;

  /// Creates a copy of this options object with the given fields replaced.
  ExtractOptions copyWith({
    bool? extractOpenGraph,
    bool? extractTwitterCard,
    bool? extractStandardMeta,
    bool? extractLinkRels,
    bool? extractJsonLd,
    bool? enableOEmbed,
    bool? enableManifest,
    bool? includeRawMetadata,
    int? maxImages,
    int? maxIcons,
    int? maxVideos,
    int? maxAudios,
  }) {
    return ExtractOptions(
      extractOpenGraph: extractOpenGraph ?? this.extractOpenGraph,
      extractTwitterCard: extractTwitterCard ?? this.extractTwitterCard,
      extractStandardMeta: extractStandardMeta ?? this.extractStandardMeta,
      extractLinkRels: extractLinkRels ?? this.extractLinkRels,
      extractJsonLd: extractJsonLd ?? this.extractJsonLd,
      enableOEmbed: enableOEmbed ?? this.enableOEmbed,
      enableManifest: enableManifest ?? this.enableManifest,
      includeRawMetadata: includeRawMetadata ?? this.includeRawMetadata,
      maxImages: maxImages ?? this.maxImages,
      maxIcons: maxIcons ?? this.maxIcons,
      maxVideos: maxVideos ?? this.maxVideos,
      maxAudios: maxAudios ?? this.maxAudios,
    );
  }
}

/// Configuration for the caching layer.
///
/// Controls whether results are stored/retrieved from the [CacheStore] and
/// the policy for expiration.
class CacheOptions {
  /// Creates a configuration for caching.
  const CacheOptions({
    this.enabled = true,
    this.ttl = const Duration(hours: 4),
    this.payloadKind = CachePayloadKind.linkMetadata,
  });

  /// Whether caching is enabled for this request.
  ///
  /// If `false`, the [CacheStore] is ignored for both read and write operations.
  final bool enabled;

  /// The time-to-live for cached entries created by this request.
  ///
  /// If a cached entry is older than this duration, it is considered expired
  /// and ignored (treated as a cache miss).
  ///
  /// Defaults to 4 hours.
  final Duration ttl;

  /// The type of data to store in the cache.
  ///
  /// * [CachePayloadKind.linkMetadata]: Stores only the final resolved `LinkMetadata`. Smaller size.
  /// * [CachePayloadKind.extractionResult]: Stores the full `ExtractionResult`, including diagnostics,
  ///   warnings, and errors. Useful if debugging information needs to be preserved.
  final CachePayloadKind payloadKind;

  /// Creates a copy of this options object with the given fields replaced.
  CacheOptions copyWith({
    bool? enabled,
    Duration? ttl,
    CachePayloadKind? payloadKind,
  }) {
    return CacheOptions(
      enabled: enabled ?? this.enabled,
      ttl: ttl ?? this.ttl,
      payloadKind: payloadKind ?? this.payloadKind,
    );
  }
}

/// The root configuration object for `MetaLinkClient`.
///
/// Aggregates [FetchOptions], [ExtractOptions], and [CacheOptions].
class MetaLinkClientOptions {
  /// Creates a complete configuration set.
  const MetaLinkClientOptions({
    this.fetch = const FetchOptions(),
    this.extract = const ExtractOptions(),
    this.cache = const CacheOptions(),
  });

  /// Options controlling network behavior (timeout, redirects, etc.).
  final FetchOptions fetch;

  /// Options controlling metadata extraction (which extractors to run).
  final ExtractOptions extract;

  /// Options controlling result caching (TTL, enabled state).
  final CacheOptions cache;

  /// Creates a copy of this options object with the given fields replaced.
  MetaLinkClientOptions copyWith({
    FetchOptions? fetch,
    ExtractOptions? extract,
    CacheOptions? cache,
  }) {
    return MetaLinkClientOptions(
      fetch: fetch ?? this.fetch,
      extract: extract ?? this.extract,
      cache: cache ?? this.cache,
    );
  }
}
