import 'dart:async';

import 'package:http/http.dart' as http;

import 'package:metalink/src/cache/cache_key.dart';
import 'package:metalink/src/cache/cache_store.dart';
import 'package:metalink/src/cache/memory_cache_store.dart';
import 'package:metalink/src/extract/extractors/json_ld_extractor.dart';
import 'package:metalink/src/extract/extractors/link_rel_extractor.dart';
import 'package:metalink/src/extract/extractors/open_graph_extractor.dart';
import 'package:metalink/src/extract/extractors/standard_meta_extractor.dart';
import 'package:metalink/src/extract/extractors/twitter_card_extractor.dart';
import 'package:metalink/src/extract/pipeline.dart';
import 'package:metalink/src/fetch/fetcher.dart';
import 'package:metalink/src/fetch/html_snippet_fetcher.dart';
import 'package:metalink/src/fetch/http_fetcher.dart';
import 'package:metalink/src/fetch/redirect_resolver.dart';
import 'package:metalink/src/model/diagnostics.dart';
import 'package:metalink/src/model/errors.dart';
import 'package:metalink/src/model/link_metadata.dart';
import 'package:metalink/src/model/raw_metadata.dart';
import 'package:metalink/src/model/url_optimization.dart';
import 'package:metalink/src/options.dart';
import 'package:metalink/src/result.dart';
import 'package:metalink/src/util/url_normalizer.dart';

/// A reusable client for extracting link metadata with connection pooling and caching.
///
/// [MetaLinkClient] maintains an HTTP client and optional [CacheStore] across multiple
/// extraction calls, enabling Keep-Alive connection reuse and consistent cache behavior.
///
/// ### When to Use
/// * Use [MetaLinkClient] for production applications where you extract metadata
///   from multiple URLs over time. The shared HTTP client improves performance.
/// * For simple one-off extractions, prefer the static [MetaLink.extract] helper instead.
///
/// ### Resource Management
/// * The client owns its internal HTTP client unless you inject one via [httpClient].
/// * Always call [close] when done to release network connections and cache resources.
/// * Using a `try/finally` block ensures cleanup even if extraction fails.
///
/// ### Example
/// ```dart
/// final client = MetaLinkClient(
///   options: MetaLinkClientOptions(
///     fetch: FetchOptions(timeout: Duration(seconds: 5)),
///     cache: CacheOptions(ttl: Duration(hours: 1)),
///   ),
/// );
///
/// try {
///   final result = await client.extract('https://flutter.dev');
///   print(result.metadata.title);
/// } finally {
///   client.close();
/// }
/// ```
///
/// See also:
/// * [MetaLink] for static convenience methods.
/// * [MetaLinkClientOptions] for configuration details.
/// * [ExtractionResult] for the structure of returned data.
class MetaLinkClient {
  /// Creates a new [MetaLinkClient] with the given configuration.
  ///
  /// ### Parameters
  /// * [httpClient] - An optional pre-configured HTTP client. If provided,
  ///   the client will **not** be closed when [close] is called.
  /// * [fetcher] - An optional custom [Fetcher] implementation. If provided,
  ///   it takes precedence over [httpClient].
  /// * [cacheStore] - An optional cache store. If `null` and caching is enabled,
  ///   a [MemoryCacheStore] is created automatically.
  /// * [options] - Configuration for fetch, extract, and cache behavior.
  /// * [logSink] - An optional callback for receiving log messages.
  MetaLinkClient({
    http.Client? httpClient,
    Fetcher? fetcher,
    CacheStore? cacheStore,
    this.options = const MetaLinkClientOptions(),
    MetaLinkLogSink? logSink,
  })  : _logSink = logSink,
        _fetcher = fetcher ??
            HttpFetcher(
              client: httpClient ?? http.Client(),
              logSink: logSink,
            ),
        _ownsFetcher = fetcher == null,
        _cacheStore = cacheStore ??
            (options.cache.enabled
                ? MemoryCacheStore(defaultTtl: options.cache.ttl)
                : null),
        _ownsCacheStore = cacheStore == null && options.cache.enabled {
    _htmlSnippetFetcher = HtmlSnippetFetcher(fetcher: _fetcher);
    _redirectResolver = RedirectResolver(fetcher: _fetcher);

    _pipeline = ExtractPipeline(
      stages: const [
        OpenGraphExtractor(),
        TwitterCardExtractor(),
        StandardMetaExtractor(),
        LinkRelExtractor(),
        JsonLdExtractor(),
      ],
      logSink: _logSink,
    );
  }

  /// The configuration used by this client for all operations.
  ///
  /// Individual method calls can override specific options via their parameters.
  final MetaLinkClientOptions options;

  final MetaLinkLogSink? _logSink;

  final Fetcher _fetcher;
  final bool _ownsFetcher;

  final CacheStore? _cacheStore;
  final bool _ownsCacheStore;

  late final HtmlSnippetFetcher _htmlSnippetFetcher;
  late final RedirectResolver _redirectResolver;
  late final ExtractPipeline _pipeline;

  bool _closed = false;

  /// Extracts metadata from a single URL.
  ///
  /// This method performs the full extraction pipeline:
  /// 1. **Normalize**: Parses and normalizes the input URL.
  /// 2. **Cache Check**: If caching is enabled, checks for a cached result.
  /// 3. **Resolve**: Follows HTTP redirects to find the final URL.
  /// 4. **Fetch**: Downloads the HTML content (up to [FetchOptions.maxBytes]).
  /// 5. **Extract**: Runs all configured extractors (OpenGraph, Twitter, JSON-LD, etc.).
  /// 6. **Cache Write**: Stores the result if caching is enabled and extraction succeeded.
  ///
  /// ### Parameters
  /// * [url] - The URL to extract metadata from. Must not be empty.
  /// * [fetchOptions] - Overrides [options.fetch] for this request.
  /// * [extractOptions] - Overrides [options.extract] for this request.
  /// * [cacheOptions] - Overrides [options.cache] for this request.
  /// * [skipCache] - If `true`, bypasses the cache for this request only.
  ///
  /// ### Returns
  /// An [ExtractionResult] containing:
  /// * [ExtractionResult.metadata] - The extracted [LinkMetadata].
  /// * [ExtractionResult.diagnostics] - Timing, provenance, and fetch details.
  /// * [ExtractionResult.warnings] - Non-fatal issues (e.g., cache failures).
  /// * [ExtractionResult.errors] - Fatal issues (e.g., network errors).
  ///
  /// ### Error Handling
  /// This method does **not** throw on network or parsing errors. Instead,
  /// errors are captured in [ExtractionResult.errors]. Use [ExtractionResult.isSuccess]
  /// to check if extraction completed without errors.
  ///
  /// ### Throws
  /// * [ArgumentError] if [url] is empty.
  Future<ExtractionResult<LinkMetadata>> extract(
    String url, {
    FetchOptions? fetchOptions,
    ExtractOptions? extractOptions,
    CacheOptions? cacheOptions,
    bool skipCache = false,
  }) async {
    final totalSw = Stopwatch()..start();

    final trimmed = url.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError.value(url, 'url', 'URL must not be empty');
    }

    if (_closed) {
      totalSw.stop();
      return _closedExtractionResult(totalSw.elapsed);
    }

    final fOpt = fetchOptions ?? options.fetch;
    final eOpt = extractOptions ?? options.extract;
    final cOpt = cacheOptions ?? options.cache;

    final warnings = <MetaLinkWarning>[];
    final errors = <MetaLinkError>[];

    final originalParsed = UrlNormalizer.parseLoose(trimmed);
    if (originalParsed == null) {
      totalSw.stop();
      errors.add(
        MetaLinkError(
          code: MetaLinkErrorCode.invalidUrl,
          message: 'Could not parse URL: "$url"',
          cause: const FormatException('Invalid URL'),
        ),
      );

      return ExtractionResult<LinkMetadata>(
        metadata: _minimalMetadata(
          originalUrl: Uri.parse('about:blank'),
          resolvedUrl: Uri.parse('about:blank'),
        ),
        diagnostics: ExtractionDiagnostics(
          cacheHit: false,
          totalTime: totalSw.elapsed,
          fetch: null,
          fieldProvenance: const <MetaField, FieldProvenance>{},
        ),
        raw: null,
        warnings: warnings,
        errors: errors,
      );
    }

    final originalUrl = originalParsed;
    final requestUrl = UrlNormalizer.normalizeForRequest(originalUrl);
    final cacheKeyUrl = UrlNormalizer.normalizeForCacheKey(originalUrl);
    final cacheKey = CacheKeyBuilder.buildForString(
      _cacheKeySignature(
        cacheKeyUrl: cacheKeyUrl,
        fetchOptions: fOpt,
        extractOptions: eOpt,
        cacheOptions: cOpt,
      ),
    );

    final cacheEnabled =
        !skipCache && cOpt.enabled && _cacheStore != null && !_closed;
    if (skipCache && cOpt.enabled && _cacheStore != null) {
      warnings.add(
        MetaLinkWarning(
          code: MetaLinkWarningCode.cacheBypassed,
          message: 'Cache was bypassed for this request.',
          uri: originalUrl,
        ),
      );
    }

    if (cacheEnabled) {
      final read = await _safeCacheRead(_cacheStore!, cacheKey);
      if (read.isError) {
        warnings.add(
          MetaLinkWarning(
            code: MetaLinkWarningCode.cacheReadFailed,
            message: 'Cache read failed; proceeding without cache.',
            uri: cacheKeyUrl,
            cause: read.error,
          ),
        );
      } else if (read.entry != null) {
        final entry = read.entry!;
        final nowMs = DateTime.now().millisecondsSinceEpoch;

        // Honor the stricter TTL to avoid extending cache lifetime beyond policy.
        final storedExpiry = entry.createdAtMs + entry.ttlMs;
        final configuredExpiry = entry.createdAtMs + cOpt.ttl.inMilliseconds;
        final effectiveExpiry =
            cOpt.ttl.inMilliseconds > 0 && configuredExpiry < storedExpiry
                ? configuredExpiry
                : storedExpiry;

        if (nowMs > effectiveExpiry) {
          // Best-effort cleanup so cache expiry does not block the success path.
          try {
            unawaited(_cacheStore!.delete(cacheKey));
          } catch (_) {
            // Swallow cleanup errors so reads remain non-blocking.
          }
        } else if (entry.kind == cOpt.payloadKind) {
          final fromCache = _tryBuildResultFromCacheEntry(
            entry: entry,
            requestedOriginalUrl: originalUrl,
            totalTime: totalSw.elapsed,
          );

          if (fromCache != null) {
            totalSw.stop();
            return ExtractionResult<LinkMetadata>(
              metadata: fromCache.metadata,
              diagnostics: fromCache.diagnostics,
              raw: fromCache.raw,
              warnings: [...warnings, ...fromCache.warnings],
              errors: fromCache.errors,
            );
          } else {
            // Cached payload corrupt or incompatible; attempt delete and continue.
            try {
              unawaited(_cacheStore!.delete(cacheKey));
            } catch (_) {
              // Swallow delete failures so cache issues do not abort extraction.
            }
          }
        }
      }
    }

    // Fetch HTML before running extraction so diagnostics capture network behavior.
    final fetched = await _htmlSnippetFetcher.fetch(
      requestUrl,
      options: fOpt,
    );

    final page = _copyHtmlFetchResultWithOriginal(
      fetched,
      originalUrl: originalUrl,
    );

    final fetchDiag = FetchDiagnostics(
      requestedUrl: requestUrl,
      finalUrl: page.finalUrl,
      statusCode: page.statusCode,
      redirects: page.redirects,
      bytesRead: page.bodyBytes.length,
      truncated: page.truncated,
      detectedCharset: page.detectedCharset,
      charsetSource: page.charsetSource,
      duration: page.duration,
    );

    if (page.truncated) {
      warnings.add(
        MetaLinkWarning(
          code: MetaLinkWarningCode.truncatedHtml,
          message:
              'HTML response was truncated to the configured maxBytes limit.',
          uri: page.finalUrl,
        ),
      );
    }

    if (page.charsetSource == CharsetSource.fallback ||
        page.charsetSource == CharsetSource.unknown) {
      warnings.add(
        MetaLinkWarning(
          code: MetaLinkWarningCode.charsetFallback,
          message: 'Character set detection used fallback or unknown.',
          uri: page.finalUrl,
        ),
      );
    }

    if (page.error != null) {
      totalSw.stop();

      errors.add(
        _mapFetchFailureToError(
          error: page.error!,
          stackTrace: page.stackTrace,
          uri: page.finalUrl,
          statusCode: page.statusCode,
        ),
      );

      return ExtractionResult<LinkMetadata>(
        metadata: _minimalMetadata(
          originalUrl: originalUrl,
          resolvedUrl: page.finalUrl,
        ),
        diagnostics: ExtractionDiagnostics(
          cacheHit: false,
          totalTime: totalSw.elapsed,
          fetch: fetchDiag,
          fieldProvenance: const <MetaField, FieldProvenance>{},
        ),
        raw: null,
        warnings: warnings,
        errors: errors,
      );
    }

    final contentType = _headerValue(page.headers, 'content-type');
    final contentTypeLower = contentType?.toLowerCase();
    final isHtml = contentTypeLower == null ||
        contentTypeLower.contains('text/html') ||
        contentTypeLower.contains('application/xhtml');

    if (!isHtml) {
      totalSw.stop();

      warnings.add(
        MetaLinkWarning(
          code: MetaLinkWarningCode.nonHtmlResponse,
          message:
              'Response content-type is not HTML: ${contentType ?? "(unknown)"}',
          uri: page.finalUrl,
        ),
      );

      errors.add(
        MetaLinkError(
          code: MetaLinkErrorCode.nonHtmlContent,
          message: 'Non-HTML content-type: ${contentType ?? "(unknown)"}',
          uri: page.finalUrl,
          statusCode: page.statusCode,
        ),
      );

      return ExtractionResult<LinkMetadata>(
        metadata: _minimalMetadata(
          originalUrl: originalUrl,
          resolvedUrl: page.finalUrl,
        ),
        diagnostics: ExtractionDiagnostics(
          cacheHit: false,
          totalTime: totalSw.elapsed,
          fetch: fetchDiag,
          fieldProvenance: const <MetaField, FieldProvenance>{},
        ),
        raw: null,
        warnings: warnings,
        errors: errors,
      );
    }

    if (page.statusCode != null &&
        (page.statusCode! < 200 || page.statusCode! >= 300)) {
      totalSw.stop();

      errors.add(
        MetaLinkError(
          code: MetaLinkErrorCode.httpStatus,
          message: 'HTTP status ${page.statusCode} for ${page.finalUrl}',
          uri: page.finalUrl,
          statusCode: page.statusCode,
        ),
      );

      return ExtractionResult<LinkMetadata>(
        metadata: _minimalMetadata(
          originalUrl: originalUrl,
          resolvedUrl: page.finalUrl,
        ),
        diagnostics: ExtractionDiagnostics(
          cacheHit: false,
          totalTime: totalSw.elapsed,
          fetch: fetchDiag,
          fieldProvenance: const <MetaField, FieldProvenance>{},
        ),
        raw: null,
        warnings: warnings,
        errors: errors,
      );
    }

    PipelineOutput pipelineOutput;
    try {
      pipelineOutput = await _pipeline.run(
        page: page,
        fetcher: _fetcher,
        fetchOptions: fOpt,
        extractOptions: eOpt,
      );
    } catch (e, st) {
      totalSw.stop();

      errors.add(
        MetaLinkError(
          code: MetaLinkErrorCode.parse,
          message: 'HTML metadata extraction pipeline failed.',
          uri: page.finalUrl,
          statusCode: page.statusCode,
          cause: e,
          stackTrace: st,
        ),
      );

      return ExtractionResult<LinkMetadata>(
        metadata: _minimalMetadata(
          originalUrl: originalUrl,
          resolvedUrl: page.finalUrl,
        ),
        diagnostics: ExtractionDiagnostics(
          cacheHit: false,
          totalTime: totalSw.elapsed,
          fetch: fetchDiag,
          fieldProvenance: const <MetaField, FieldProvenance>{},
        ),
        raw: null,
        warnings: warnings,
        errors: errors,
      );
    }

    warnings.addAll(pipelineOutput.warnings);
    errors.addAll(pipelineOutput.errors);

    var metadata = pipelineOutput.metadata;
    if (metadata.originalUrl != originalUrl) {
      metadata = _cloneMetadataWithOriginal(metadata, originalUrl);
    }

    // Cache write is best-effort so extraction success is not blocked by storage.
    if (cacheEnabled && errors.isEmpty) {
      final entry = CacheEntry(
        kind: cOpt.payloadKind,
        createdAtMs: DateTime.now().millisecondsSinceEpoch,
        ttlMs: cOpt.ttl.inMilliseconds,
        payload: _buildCachePayload(
          kind: cOpt.payloadKind,
          metadata: metadata,
          diagnostics: ExtractionDiagnostics(
            cacheHit: false,
            totalTime: Duration
                .zero, // replaced below; payload not required to include timing
            fetch: fetchDiag,
            fieldProvenance: pipelineOutput.fieldProvenance,
          ),
          raw: pipelineOutput.raw,
          warnings: warnings,
          errors: errors,
        ),
      );

      final write = await _safeCacheWrite(_cacheStore!, cacheKey, entry);
      if (!write.ok) {
        warnings.add(
          MetaLinkWarning(
            code: MetaLinkWarningCode.cacheWriteFailed,
            message: 'Cache write failed; continuing without cached value.',
            uri: cacheKeyUrl,
            cause: write.error,
          ),
        );
      }
    }

    totalSw.stop();

    final diagnostics = ExtractionDiagnostics(
      cacheHit: false,
      totalTime: totalSw.elapsed,
      fetch: fetchDiag,
      fieldProvenance: pipelineOutput.fieldProvenance,
    );

    return ExtractionResult<LinkMetadata>(
      metadata: metadata,
      diagnostics: diagnostics,
      raw: pipelineOutput.raw,
      warnings: warnings,
      errors: errors,
    );
  }

  /// Extracts metadata from multiple URLs concurrently.
  ///
  /// Useful for processing bulk lists efficiently. Each URL is processed using
  /// [extract], and results are returned in the same order as the input list.
  ///
  /// ### Parameters
  /// * [urls] - The list of URLs to extract metadata from.
  /// * [fetchOptions] - Overrides [options.fetch] for all requests.
  /// * [extractOptions] - Overrides [options.extract] for all requests.
  /// * [cacheOptions] - Overrides [options.cache] for all requests.
  /// * [skipCache] - If `true`, bypasses the cache for all requests.
  /// * [concurrency] - Maximum number of URLs processed simultaneously.
  ///   Defaults to `4`. Must be at least `1`.
  ///
  /// ### Error Handling
  /// This method does **not** throw if individual URLs fail. Instead, the
  /// returned list contains an [ExtractionResult] for each input URL at the
  /// corresponding index. Failed URLs will have [ExtractionResult.errors] populated.
  ///
  /// ### Throws
  /// * [ArgumentError] if [concurrency] is less than `1`.
  Future<List<ExtractionResult<LinkMetadata>>> extractBatch(
    List<String> urls, {
    FetchOptions? fetchOptions,
    ExtractOptions? extractOptions,
    CacheOptions? cacheOptions,
    bool skipCache = false,
    int concurrency = 4,
  }) async {
    if (concurrency < 1) {
      throw ArgumentError.value(
        concurrency,
        'concurrency',
        'concurrency must be >= 1',
      );
    }

    if (_closed) {
      if (urls.isEmpty) return const [];
      final result = _closedExtractionResult(Duration.zero);
      return List<ExtractionResult<LinkMetadata>>.filled(urls.length, result);
    }

    if (urls.isEmpty) return const [];

    return _runWithConcurrency<String, ExtractionResult<LinkMetadata>>(
      urls,
      concurrency: concurrency,
      task: (u) async {
        try {
          return await extract(
            u,
            fetchOptions: fetchOptions,
            extractOptions: extractOptions,
            cacheOptions: cacheOptions,
            skipCache: skipCache,
          );
        } on ArgumentError catch (e, st) {
          // Batch is resilient: convert invalid inputs into per-item errors.
          _log(
            MetaLinkLogLevel.warning,
            'Batch extract input rejected: $e',
            error: e,
            stackTrace: st,
            context: {'url': u},
          );

          final sw = Stopwatch()
            ..start()
            ..stop();
          return ExtractionResult<LinkMetadata>(
            metadata: _minimalMetadata(
              originalUrl: Uri.parse('about:blank'),
              resolvedUrl: Uri.parse('about:blank'),
            ),
            diagnostics: ExtractionDiagnostics(
              cacheHit: false,
              totalTime: sw.elapsed,
              fetch: null,
              fieldProvenance: const <MetaField, FieldProvenance>{},
            ),
            raw: null,
            warnings: const [],
            errors: [
              MetaLinkError(
                code: MetaLinkErrorCode.invalidUrl,
                message: e.message ?? 'Invalid URL input: "$u"',
                cause: e,
                stackTrace: st,
              ),
            ],
          );
        } catch (e, st) {
          _log(
            MetaLinkLogLevel.error,
            'Unexpected batch extract failure.',
            error: e,
            stackTrace: st,
            context: {'url': u},
          );

          final sw = Stopwatch()
            ..start()
            ..stop();
          return ExtractionResult<LinkMetadata>(
            metadata: _minimalMetadata(
              originalUrl: Uri.parse('about:blank'),
              resolvedUrl: Uri.parse('about:blank'),
            ),
            diagnostics: ExtractionDiagnostics(
              cacheHit: false,
              totalTime: sw.elapsed,
              fetch: null,
              fieldProvenance: const <MetaField, FieldProvenance>{},
            ),
            raw: null,
            warnings: const [],
            errors: [
              MetaLinkError(
                code: MetaLinkErrorCode.unknown,
                message: 'Unexpected failure during extractBatch().',
                cause: e,
                stackTrace: st,
              ),
            ],
          );
        }
      },
    );
  }

  /// Resolves redirects for a URL without extracting metadata.
  ///
  /// Use this method when you only need to find the final destination URL
  /// (e.g., for link shorteners like bit.ly) without the overhead of
  /// downloading and parsing HTML content.
  ///
  /// ### Parameters
  /// * [url] - The URL to resolve. Must not be empty.
  /// * [fetchOptions] - Overrides [options.fetch] for this request.
  ///
  /// ### Returns
  /// A [UrlOptimizationResult] containing:
  /// * [UrlOptimizationResult.originalUrl] - The normalized input URL.
  /// * [UrlOptimizationResult.finalUrl] - The URL after following all redirects.
  /// * [UrlOptimizationResult.redirects] - The list of redirect hops.
  /// * [UrlOptimizationResult.statusCode] - The final HTTP status code.
  ///
  /// ### Throws
  /// * [ArgumentError] if [url] is empty.
  Future<UrlOptimizationResult> optimizeUrl(
    String url, {
    FetchOptions? fetchOptions,
  }) async {
    final totalSw = Stopwatch()..start();

    final trimmed = url.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError.value(url, 'url', 'URL must not be empty');
    }

    if (_closed) {
      totalSw.stop();
      return UrlOptimizationResult(
        originalUrl: Uri.parse('about:blank'),
        finalUrl: Uri.parse('about:blank'),
        redirects: const [],
        statusCode: null,
        duration: totalSw.elapsed,
        error: StateError('MetaLinkClient is closed'),
        stackTrace: null,
      );
    }

    final fOpt = fetchOptions ?? options.fetch;

    final parsed = UrlNormalizer.parseLoose(trimmed);
    if (parsed == null) {
      totalSw.stop();
      return UrlOptimizationResult(
        originalUrl: Uri.parse('about:blank'),
        finalUrl: Uri.parse('about:blank'),
        redirects: const [],
        statusCode: null,
        duration: totalSw.elapsed,
        error: FormatException('Invalid URL: "$url"'),
        stackTrace: null,
      );
    }

    final originalUrl = parsed;
    final requestUrl = UrlNormalizer.normalizeForRequest(originalUrl);

    final resolved = await _redirectResolver.resolve(
      requestUrl,
      options: fOpt,
    );

    totalSw.stop();

    // Preserve the user-parsed original URL in the returned result for traceability.
    if (resolved.originalUrl == originalUrl) {
      return UrlOptimizationResult(
        originalUrl: resolved.originalUrl,
        finalUrl: resolved.finalUrl,
        redirects: resolved.redirects,
        statusCode: resolved.statusCode,
        duration: totalSw.elapsed,
        error: resolved.error,
        stackTrace: resolved.stackTrace,
      );
    }

    return UrlOptimizationResult(
      originalUrl: originalUrl,
      finalUrl: resolved.finalUrl,
      redirects: resolved.redirects,
      statusCode: resolved.statusCode,
      duration: totalSw.elapsed,
      error: resolved.error,
      stackTrace: resolved.stackTrace,
    );
  }

  /// Releases all resources held by this client.
  ///
  /// After calling [close], any subsequent calls to [extract], [extractBatch],
  /// or [optimizeUrl] will return error results without performing network requests.
  ///
  /// ### Behavior
  /// * Closes the internal HTTP client (unless one was injected via constructor).
  /// * Closes the cache store (unless one was injected via constructor).
  /// * This method is idempotent - calling it multiple times has no additional effect.
  ///
  /// ### Best Practice
  /// Always call [close] in a `finally` block to ensure resources are released:
  /// ```dart
  /// final client = MetaLinkClient();
  /// try {
  ///   await client.extract('https://example.com');
  /// } finally {
  ///   client.close();
  /// }
  /// ```
  void close() {
    if (_closed) return;
    _closed = true;

    // Close only resources we own so injected clients remain caller-controlled.
    if (_ownsFetcher) {
      try {
        _fetcher.close();
      } catch (e, st) {
        _log(
          MetaLinkLogLevel.warning,
          'Fetcher close failed (ignored).',
          error: e,
          stackTrace: st,
        );
      }
    }

    if (_ownsCacheStore && _cacheStore != null) {
      try {
        unawaited(
          _cacheStore!.close().catchError((_) {}),
        );
      } catch (_) {
        // Swallow close errors so shutdown does not crash callers.
      }
    }
  }

  // Private helpers keep error handling and caching logic centralized.

  void _log(
    MetaLinkLogLevel level,
    String message, {
    Object? error,
    StackTrace? stackTrace,
    Map<String, Object?>? context,
  }) {
    final sink = _logSink;
    if (sink == null) return;

    try {
      sink(
        MetaLinkLogRecord(
          level: level,
          message: message,
          timestamp: DateTime.now().toUtc(),
          error: error,
          stackTrace: stackTrace,
          context: context,
        ),
      );
    } catch (_) {
      // Logging must never throw so it cannot break extraction.
    }
  }

  LinkMetadata _minimalMetadata({
    required Uri originalUrl,
    required Uri resolvedUrl,
  }) {
    return LinkMetadata(
      originalUrl: originalUrl,
      resolvedUrl: resolvedUrl,
    );
  }

  ExtractionResult<LinkMetadata> _closedExtractionResult(Duration totalTime) {
    const errors = <MetaLinkError>[
      MetaLinkError(
        code: MetaLinkErrorCode.unknown,
        message: 'MetaLinkClient is closed.',
      ),
    ];

    return ExtractionResult<LinkMetadata>(
      metadata: _minimalMetadata(
        originalUrl: Uri.parse('about:blank'),
        resolvedUrl: Uri.parse('about:blank'),
      ),
      diagnostics: ExtractionDiagnostics(
        cacheHit: false,
        totalTime: totalTime,
        fetch: null,
        fieldProvenance: const <MetaField, FieldProvenance>{},
      ),
      raw: null,
      warnings: const [],
      errors: errors,
    );
  }

  HtmlFetchResult _copyHtmlFetchResultWithOriginal(
    HtmlFetchResult input, {
    required Uri originalUrl,
  }) {
    if (input.originalUrl == originalUrl) return input;

    return HtmlFetchResult(
      originalUrl: originalUrl,
      finalUrl: input.finalUrl,
      redirects: input.redirects,
      statusCode: input.statusCode,
      headers: input.headers,
      bodyBytes: input.bodyBytes,
      bodyText: input.bodyText,
      detectedCharset: input.detectedCharset,
      charsetSource: input.charsetSource,
      truncated: input.truncated,
      duration: input.duration,
      error: input.error,
      stackTrace: input.stackTrace,
    );
  }

  LinkMetadata _cloneMetadataWithOriginal(LinkMetadata input, Uri originalUrl) {
    return LinkMetadata(
      originalUrl: originalUrl,
      resolvedUrl: input.resolvedUrl,
      canonicalUrl: input.canonicalUrl,
      title: input.title,
      description: input.description,
      siteName: input.siteName,
      locale: input.locale,
      kind: input.kind,
      images: input.images,
      icons: input.icons,
      videos: input.videos,
      audios: input.audios,
      publishedAt: input.publishedAt,
      modifiedAt: input.modifiedAt,
      author: input.author,
      keywords: input.keywords,
      oembed: input.oembed,
      manifest: input.manifest,
      structuredData: input.structuredData,
    );
  }

  String? _headerValue(Map<String, String> headers, String name) {
    final needle = name.toLowerCase();
    for (final e in headers.entries) {
      if (e.key.toLowerCase() == needle) return e.value;
    }
    return null;
  }

  String _cacheKeySignature({
    required Uri cacheKeyUrl,
    required FetchOptions fetchOptions,
    required ExtractOptions extractOptions,
    required CacheOptions cacheOptions,
  }) {
    final parts = <String>[
      cacheKeyUrl.toString(),
      cacheOptions.payloadKind.name,
      _fetchOptionsSignature(fetchOptions),
      _extractOptionsSignature(extractOptions),
    ];
    return parts.join('|');
  }

  String _extractOptionsSignature(ExtractOptions options) {
    return <String>[
      options.extractOpenGraph ? 'og1' : 'og0',
      options.extractTwitterCard ? 'tw1' : 'tw0',
      options.extractStandardMeta ? 'sm1' : 'sm0',
      options.extractLinkRels ? 'lr1' : 'lr0',
      options.extractJsonLd ? 'jl1' : 'jl0',
      options.enableOEmbed ? 'oe1' : 'oe0',
      options.enableManifest ? 'wm1' : 'wm0',
      options.includeRawMetadata ? 'raw1' : 'raw0',
      'img${options.maxImages}',
      'ico${options.maxIcons}',
      'vid${options.maxVideos}',
      'aud${options.maxAudios}',
    ].join(',');
  }

  String _fetchOptionsSignature(FetchOptions options) {
    return <String>[
      't${options.timeout.inMilliseconds}',
      options.userAgent == null ? 'ua=' : 'ua=${options.userAgent}',
      options.followRedirects ? 'fr1' : 'fr0',
      'mr${options.maxRedirects}',
      'mb${options.maxBytes}',
      options.stopAfterHead ? 'sh1' : 'sh0',
      options.proxyUrl == null ? 'px=' : 'px=${options.proxyUrl}',
      'h=${_headersSignature(options.headers)}',
    ].join(',');
  }

  String _headersSignature(Map<String, String> headers) {
    if (headers.isEmpty) return '';
    final entries = headers.entries
        .map((e) => MapEntry(e.key.toLowerCase(), e.value))
        .toList(growable: false);
    entries.sort((a, b) => a.key.compareTo(b.key));
    return entries.map((e) => '${e.key}=${e.value}').join('&');
  }

  MetaLinkError _mapFetchFailureToError({
    required Object error,
    StackTrace? stackTrace,
    Uri? uri,
    int? statusCode,
  }) {
    if (error is TimeoutException) {
      return MetaLinkError(
        code: MetaLinkErrorCode.timeout,
        message: 'Request timed out.',
        uri: uri,
        statusCode: statusCode,
        cause: error,
        stackTrace: stackTrace,
      );
    }

    return MetaLinkError(
      code: MetaLinkErrorCode.network,
      message: 'Network request failed.',
      uri: uri,
      statusCode: statusCode,
      cause: error,
      stackTrace: stackTrace,
    );
  }

  Future<CacheReadResult> _safeCacheRead(CacheStore store, String key) async {
    try {
      return await store.read(key);
    } catch (e, st) {
      return CacheReadResult(entry: null, error: e, stackTrace: st);
    }
  }

  Future<CacheWriteResult> _safeCacheWrite(
    CacheStore store,
    String key,
    CacheEntry entry,
  ) async {
    try {
      return await store.write(key, entry);
    } catch (e, st) {
      return CacheWriteResult(ok: false, error: e, stackTrace: st);
    }
  }

  Map<String, dynamic> _buildCachePayload({
    required CachePayloadKind kind,
    required LinkMetadata metadata,
    required ExtractionDiagnostics diagnostics,
    required RawMetadata? raw,
    required List<MetaLinkWarning> warnings,
    required List<MetaLinkError> errors,
  }) {
    switch (kind) {
      case CachePayloadKind.linkMetadata:
        return metadata.toJson();

      case CachePayloadKind.extractionResult:
        return <String, dynamic>{
          'metadata': metadata.toJson(),
          'diagnostics': diagnostics.toJson(),
          'raw': raw?.toJson(),
          'warnings': warnings.map((w) => w.toJson()).toList(),
          'errors': errors.map((e) => e.toJson()).toList(),
        };
    }
  }

  ExtractionResult<LinkMetadata>? _tryBuildResultFromCacheEntry({
    required CacheEntry entry,
    required Uri requestedOriginalUrl,
    required Duration totalTime,
  }) {
    try {
      if (entry.kind == CachePayloadKind.linkMetadata) {
        final cached = LinkMetadata.fromJson(
          Map<String, dynamic>.from(entry.payload),
        );

        final patched =
            _cloneMetadataWithOriginal(cached, requestedOriginalUrl);

        return ExtractionResult<LinkMetadata>(
          metadata: patched,
          diagnostics: ExtractionDiagnostics(
            cacheHit: true,
            totalTime: totalTime,
            fetch: null,
            fieldProvenance: const <MetaField, FieldProvenance>{},
          ),
          raw: null,
          warnings: const [],
          errors: const [],
        );
      }

      if (entry.kind == CachePayloadKind.extractionResult) {
        final payload = Map<String, dynamic>.from(entry.payload);

        final metaJson = Map<String, dynamic>.from(payload['metadata'] as Map);
        final diagJson =
            Map<String, dynamic>.from(payload['diagnostics'] as Map);

        final cachedMeta = LinkMetadata.fromJson(metaJson);
        final cachedDiag = ExtractionDiagnostics.fromJson(diagJson);

        RawMetadata? raw;
        final rawAny = payload['raw'];
        if (rawAny is Map) {
          raw = RawMetadata.fromJson(Map<String, dynamic>.from(rawAny));
        }

        final warningsAny = payload['warnings'];
        final errorsAny = payload['errors'];

        final cachedWarnings = <MetaLinkWarning>[];
        if (warningsAny is List) {
          for (final w in warningsAny) {
            if (w is Map) {
              cachedWarnings.add(
                MetaLinkWarning.fromJson(Map<String, dynamic>.from(w)),
              );
            }
          }
        }

        final cachedErrors = <MetaLinkError>[];
        if (errorsAny is List) {
          for (final e in errorsAny) {
            if (e is Map) {
              cachedErrors.add(
                MetaLinkError.fromJson(Map<String, dynamic>.from(e)),
              );
            }
          }
        }

        final patchedMeta =
            _cloneMetadataWithOriginal(cachedMeta, requestedOriginalUrl);

        return ExtractionResult<LinkMetadata>(
          metadata: patchedMeta,
          diagnostics: ExtractionDiagnostics(
            cacheHit: true,
            totalTime: totalTime,
            fetch: cachedDiag.fetch,
            fieldProvenance: cachedDiag.fieldProvenance,
          ),
          raw: raw,
          warnings: cachedWarnings,
          errors: cachedErrors,
        );
      }

      return null;
    } catch (e, st) {
      _log(
        MetaLinkLogLevel.warning,
        'Failed to decode cached entry; treating as cache miss.',
        error: e,
        stackTrace: st,
      );
      return null;
    }
  }

  Future<List<R>> _runWithConcurrency<T, R>(
    List<T> items, {
    required int concurrency,
    required Future<R> Function(T item) task,
  }) async {
    final results = List<R?>.filled(items.length, null);
    var nextIndex = 0;

    Future<void> worker() async {
      while (true) {
        final i = nextIndex;
        nextIndex += 1;
        if (i >= items.length) return;

        results[i] = await task(items[i]);
      }
    }

    final workers = <Future<void>>[];
    for (var i = 0; i < concurrency; i++) {
      workers.add(worker());
    }

    await Future.wait(workers);
    return results.cast<R>();
  }
}
