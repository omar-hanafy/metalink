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
import 'package:metalink/src/network/request_engine.dart';
import 'package:metalink/src/network/request_context.dart';
import 'package:metalink/src/network/request_policy.dart';
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
/// * Always await [dispose] when done to release network connections and cache resources.
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
///   await client.dispose();
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
  ///   the client will **not** be closed when [dispose] is called.
  /// * [httpClientCapabilities] - A truthful capability description for an
  ///   injected [httpClient]. Unknown capabilities fail closed when the
  ///   selected request policy requires inspectable redirect hops.
  /// * [fetcher] - An optional custom [Fetcher] implementation. If provided,
  ///   it takes precedence over [httpClient].
  /// * [cacheStore] - An optional cache store. If `null` and caching is enabled,
  ///   a [MemoryCacheStore] is created automatically.
  /// * [options] - Configuration for fetch, extract, and cache behavior.
  /// * [logSink] - An optional callback for receiving log messages.
  MetaLinkClient({
    http.Client? httpClient,
    FetcherCapabilities? httpClientCapabilities,
    Fetcher? fetcher,
    CacheStore? cacheStore,
    this.options = const MetaLinkClientOptions(),
    MetaLinkLogSink? logSink,
  }) : assert(
         httpClient != null || httpClientCapabilities == null,
         'httpClientCapabilities requires an injected httpClient',
       ),
       _logSink = logSink,
       _fetcher =
           fetcher ??
           HttpFetcher(
             client: httpClient,
             capabilities: httpClient == null ? null : httpClientCapabilities,
             logSink: logSink,
           ),
       _ownsFetcher = fetcher == null,
       _cacheStore =
           cacheStore ??
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
  Future<void>? _disposeFuture;
  final Map<String, Future<ExtractionResult<LinkMetadata>>> _inFlight = {};
  final Set<Future<void>> _activeOperations = <Future<void>>{};

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
  /// * [fetchOptions] - Overrides [MetaLinkClientOptions.fetch] for this request.
  /// * [extractOptions] - Overrides [MetaLinkClientOptions.extract] for this request.
  /// * [cacheOptions] - Overrides [MetaLinkClientOptions.cache] for this request.
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
    RequestContext? requestContext,
    bool skipCache = false,
  }) async {
    final trimmed = url.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError.value(url, 'url', 'URL must not be empty');
    }

    if (_closed) {
      return _closedExtractionResult(Duration.zero);
    }

    final fOpt = fetchOptions ?? options.fetch;
    final eOpt = extractOptions ?? options.extract;
    final cOpt = cacheOptions ?? options.cache;
    final parsed = UrlNormalizer.parseLoose(trimmed);

    // Invalid inputs still flow through the normal result builder. They are not
    // coalesced because no stable HTTP request identity exists for them.
    if (parsed == null) {
      return _extractOnce(
        url,
        fetchOptions: fOpt,
        extractOptions: eOpt,
        cacheOptions: cOpt,
        requestContext: requestContext,
        skipCache: skipCache,
      );
    }

    // A caller-owned context carries its own cancellation and deadline. Do not
    // coalesce it with another caller whose lifetime may differ.
    if (requestContext != null) {
      return _trackOperation(
        _extractOnce(
          url,
          fetchOptions: fOpt,
          extractOptions: eOpt,
          cacheOptions: cOpt,
          requestContext: requestContext,
          skipCache: skipCache,
        ),
      );
    }

    final inFlightKey = _inFlightSignature(
      originalUrl: parsed,
      cacheKeyUrl: UrlNormalizer.normalizeForCacheKey(parsed),
      fetchOptions: fOpt,
      extractOptions: eOpt,
      cacheOptions: cOpt,
      skipCache: skipCache,
    );
    final existing = _inFlight[inFlightKey];
    if (existing != null) return existing;

    final future = _extractOnce(
      url,
      fetchOptions: fOpt,
      extractOptions: eOpt,
      cacheOptions: cOpt,
      requestContext: null,
      skipCache: skipCache,
    );
    _inFlight[inFlightKey] = future;

    try {
      return await future;
    } finally {
      if (identical(_inFlight[inFlightKey], future)) {
        _inFlight.remove(inFlightKey);
      }
    }
  }

  Future<ExtractionResult<LinkMetadata>> _extractOnce(
    String url, {
    required FetchOptions fetchOptions,
    required ExtractOptions extractOptions,
    required CacheOptions cacheOptions,
    required RequestContext? requestContext,
    required bool skipCache,
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

    final fOpt = fetchOptions;
    final eOpt = extractOptions;
    final cOpt = cacheOptions;

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
    final networkContext = RequestContext.forOperation(
      totalTimeout: fOpt.totalTimeout,
      parent: requestContext,
    );

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
      final lifetimeFailure = _currentRequestLifetimeFailure(
        context: networkContext,
        requestUrl: requestUrl,
      );
      if (lifetimeFailure != null) {
        totalSw.stop();
        return _requestFailureExtractionResult(
          originalUrl: originalUrl,
          requestUrl: requestUrl,
          totalTime: totalSw.elapsed,
          failure: lifetimeFailure,
          warnings: warnings,
        );
      }

      CacheReadResult read;
      try {
        read = await _raceWithRequestLifetime(
          _safeCacheRead(_cacheStore, cacheKey),
          context: networkContext,
          requestUrl: requestUrl,
        );
      } catch (error, stackTrace) {
        if (error is! TimeoutException &&
            error is! FetchCancellationException) {
          rethrow;
        }
        totalSw.stop();
        return _requestFailureExtractionResult(
          originalUrl: originalUrl,
          requestUrl: requestUrl,
          totalTime: totalSw.elapsed,
          failure: _requestLifetimeFailureFromException(
            error: error,
            stackTrace: stackTrace,
            requestUrl: requestUrl,
          ),
          warnings: warnings,
        );
      }
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
        final configuredExpiry = entry.createdAtMs + cOpt.ttl.inMilliseconds;
        final expiredByStoredPolicy = entry.isExpired(nowMs: nowMs);
        final expiredByRequestPolicy =
            cOpt.ttl > Duration.zero && nowMs > configuredExpiry;

        if (expiredByStoredPolicy || expiredByRequestPolicy) {
          // Best-effort cleanup so cache expiry does not block the success path.
          unawaited(_deleteCacheEntryBestEffort(_cacheStore, cacheKey));
        } else if (entry.kind == cOpt.payloadKind) {
          final fromCache = _tryBuildResultFromCacheEntry(
            entry: entry,
            requestedOriginalUrl: originalUrl,
            totalTime: totalSw.elapsed,
          );

          if (fromCache != null) {
            final policyFailure = await _validateInitialRequestPolicy(
              policy: fOpt.requestPolicy,
              requestUrl: requestUrl,
              context: networkContext,
            );
            if (policyFailure != null) {
              totalSw.stop();
              return _requestFailureExtractionResult(
                originalUrl: originalUrl,
                requestUrl: requestUrl,
                totalTime: totalSw.elapsed,
                failure: policyFailure,
                warnings: warnings,
              );
            }
            totalSw.stop();
            final cachedDiagnostics = ExtractionDiagnostics(
              cacheHit: fromCache.diagnostics.cacheHit,
              totalTime: totalSw.elapsed,
              fetch: fromCache.diagnostics.fetch,
              fieldProvenance: fromCache.diagnostics.fieldProvenance,
              provenanceAvailable: fromCache.diagnostics.provenanceAvailable,
              itemProvenance: fromCache.diagnostics.itemProvenance,
              candidateDecisions: fromCache.diagnostics.candidateDecisions,
            );
            return ExtractionResult<LinkMetadata>(
              metadata: fromCache.metadata,
              diagnostics: cachedDiagnostics,
              raw: fromCache.raw,
              warnings: [...warnings, ...fromCache.warnings],
              errors: fromCache.errors,
              status: fromCache.status,
              completeness: fromCache.completeness,
            );
          } else {
            // Cached payload corrupt or incompatible; attempt delete and continue.
            unawaited(_deleteCacheEntryBestEffort(_cacheStore, cacheKey));
          }
        }
      }
    }

    // Fetch HTML before running extraction so diagnostics capture network behavior.
    final fetched = await _htmlSnippetFetcher.fetch(
      requestUrl,
      options: fOpt,
      context: networkContext,
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
    final isHtml =
        contentTypeLower == null ||
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
        requestContext: networkContext,
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
    // A failed remote enrichment may be transient or deadline-dependent. Do
    // not let that degraded result poison a later request that can complete.
    final remoteEnrichmentFailed = warnings.any(
      (warning) =>
          warning.code == MetaLinkWarningCode.oembedFailed ||
          warning.code == MetaLinkWarningCode.manifestFailed,
    );
    if (cacheEnabled && errors.isEmpty && !remoteEnrichmentFailed) {
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
            itemProvenance: pipelineOutput.itemProvenance,
            candidateDecisions: pipelineOutput.candidateDecisions,
          ),
          raw: pipelineOutput.raw,
          warnings: warnings,
          errors: errors,
          status: ExtractionResult.inferStatus(
            errors: errors,
            warnings: warnings,
          ),
          completeness: null,
        ),
      );

      final write = await _safeCacheWriteWithinLifetime(
        _cacheStore,
        cacheKey,
        entry,
        context: networkContext,
        requestUrl: requestUrl,
      );
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
      itemProvenance: pipelineOutput.itemProvenance,
      candidateDecisions: pipelineOutput.candidateDecisions,
    );

    return ExtractionResult<LinkMetadata>(
      metadata: metadata,
      diagnostics: diagnostics,
      raw: pipelineOutput.raw,
      warnings: warnings,
      errors: errors,
      status: ExtractionResult.inferStatus(errors: errors, warnings: warnings),
    );
  }

  /// Extracts metadata from multiple URLs concurrently.
  ///
  /// Useful for processing bulk lists efficiently. Each URL is processed using
  /// [extract], and results are returned in the same order as the input list.
  ///
  /// ### Parameters
  /// * [urls] - The list of URLs to extract metadata from.
  /// * [fetchOptions] - Overrides [MetaLinkClientOptions.fetch] for all requests.
  /// * [extractOptions] - Overrides [MetaLinkClientOptions.extract] for all requests.
  /// * [cacheOptions] - Overrides [MetaLinkClientOptions.cache] for all requests.
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
    RequestContext? requestContext,
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
            requestContext: requestContext,
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
  /// * [fetchOptions] - Overrides [MetaLinkClientOptions.fetch] for this request.
  /// * [requestContext] - Optional caller-owned deadline or cancellation signal.
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
    RequestContext? requestContext,
  }) {
    return _trackOperation(
      _optimizeUrlOnce(
        url,
        fetchOptions: fetchOptions,
        requestContext: requestContext,
      ),
    );
  }

  Future<UrlOptimizationResult> _optimizeUrlOnce(
    String url, {
    FetchOptions? fetchOptions,
    RequestContext? requestContext,
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
      context: requestContext,
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

  /// Releases all resources held by this client and waits for owned resources.
  ///
  /// Active extractions are allowed to finish before owned transports and cache
  /// stores are closed. New work is rejected as soon as disposal begins.
  Future<void> dispose() {
    final existing = _disposeFuture;
    if (existing != null) return existing;

    _closed = true;
    final future = _disposeOwnedResources();
    _disposeFuture = future;
    return future;
  }

  Future<void> _disposeOwnedResources() async {
    final active = <Future<void>>[
      for (final operation in _inFlight.values)
        operation.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
      ..._activeOperations,
    ];
    if (active.isNotEmpty) {
      try {
        await Future.wait(active);
      } catch (e, st) {
        _log(
          MetaLinkLogLevel.warning,
          'An active extraction failed while the client was disposing.',
          error: e,
          stackTrace: st,
        );
      }
    }

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
        await _cacheStore.close();
      } catch (e, st) {
        _log(
          MetaLinkLogLevel.warning,
          'Cache store close failed (ignored).',
          error: e,
          stackTrace: st,
        );
      }
    }
  }

  /// Starts releasing resources without waiting for asynchronous cleanup.
  ///
  /// Prefer [dispose], which gives callers deterministic completion. This
  /// compatibility method will be removed in a future major release.
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
  /// Always await [dispose] in a `finally` block to ensure resources are released:
  /// ```dart
  /// final client = MetaLinkClient();
  /// try {
  ///   await client.extract('https://example.com');
  /// } finally {
  ///   await client.dispose();
  /// }
  /// ```
  @Deprecated('Use and await dispose() instead. Will be removed in 3.0.0.')
  void close() => unawaited(dispose());

  // Private helpers keep error handling and caching logic centralized.

  Future<T> _trackOperation<T>(Future<T> operation) {
    final completion = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    _activeOperations.add(completion);
    unawaited(
      completion.whenComplete(() {
        _activeOperations.remove(completion);
      }),
    );
    return operation;
  }

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

  Future<RequestFailure?> _validateInitialRequestPolicy({
    required RequestPolicy policy,
    required Uri requestUrl,
    required RequestContext context,
  }) async {
    final lifetimeFailure = _currentRequestLifetimeFailure(
      context: context,
      requestUrl: requestUrl,
    );
    if (lifetimeFailure != null) return lifetimeFailure;

    try {
      final decision = await _raceWithRequestLifetime(
        policy.validateTarget(
          RequestTarget(
            uri: requestUrl,
            purpose: RequestPurpose.document,
            stage: RequestTargetStage.initial,
            redirectCount: 0,
          ),
        ),
        context: context,
        requestUrl: requestUrl,
      );
      if (decision.allowed) return null;
      return RequestFailure(
        code: RequestFailureCode.policyRejected,
        message: decision.reason ?? 'Request target rejected by policy.',
        uri: requestUrl,
      );
    } catch (e, st) {
      if (e is TimeoutException) {
        return RequestFailure(
          code: RequestFailureCode.timeout,
          message: 'The complete request deadline elapsed.',
          uri: requestUrl,
          cause: e,
          stackTrace: st,
        );
      }
      if (e is FetchCancellationException) {
        return RequestFailure(
          code: RequestFailureCode.cancelled,
          message: 'The request was cancelled.',
          uri: requestUrl,
          cause: e,
          stackTrace: st,
        );
      }
      _log(
        MetaLinkLogLevel.warning,
        'Initial request policy evaluation failed closed.',
        error: e,
        stackTrace: st,
        context: <String, Object?>{'url': requestUrl.toString()},
      );
      return RequestFailure(
        code: RequestFailureCode.policyRejected,
        message: 'Request policy evaluation failed.',
        uri: requestUrl,
        cause: e,
        stackTrace: st,
      );
    }
  }

  Future<T> _raceWithRequestLifetime<T>(
    Future<T> operation, {
    required RequestContext context,
    required Uri requestUrl,
  }) async {
    final races = <Future<T>>[operation];
    Timer? deadlineTimer;
    final remaining = context.remaining;
    if (remaining != null) {
      final deadline = Completer<T>();
      deadlineTimer = Timer(
        remaining,
        () => deadline.completeError(
          TimeoutException('Complete request deadline elapsed'),
        ),
      );
      races.add(deadline.future);
    }

    final cancellation = context.cancellationSignal;
    if (cancellation != null) {
      final cancelled = Completer<T>();
      cancellation
          .then<void>(
            (_) =>
                cancelled.completeError(FetchCancellationException(requestUrl)),
            onError: (Object _, StackTrace _) {
              cancelled.completeError(FetchCancellationException(requestUrl));
            },
          )
          .ignore();
      races.add(cancelled.future);
    }

    try {
      return await Future.any<T>(races);
    } finally {
      deadlineTimer?.cancel();
    }
  }

  RequestFailure? _currentRequestLifetimeFailure({
    required RequestContext context,
    required Uri requestUrl,
  }) {
    if (context.isCancelled) {
      return RequestFailure(
        code: RequestFailureCode.cancelled,
        message: 'The request was cancelled.',
        uri: requestUrl,
      );
    }
    if (context.isExpired) {
      return RequestFailure(
        code: RequestFailureCode.timeout,
        message: 'The complete request deadline elapsed.',
        uri: requestUrl,
      );
    }
    return null;
  }

  RequestFailure _requestLifetimeFailureFromException({
    required Object error,
    required StackTrace stackTrace,
    required Uri requestUrl,
  }) {
    if (error is FetchCancellationException) {
      return RequestFailure(
        code: RequestFailureCode.cancelled,
        message: 'The request was cancelled.',
        uri: requestUrl,
        cause: error,
        stackTrace: stackTrace,
      );
    }
    return RequestFailure(
      code: RequestFailureCode.timeout,
      message: 'The complete request deadline elapsed.',
      uri: requestUrl,
      cause: error,
      stackTrace: stackTrace,
    );
  }

  ExtractionResult<LinkMetadata> _requestFailureExtractionResult({
    required Uri originalUrl,
    required Uri requestUrl,
    required Duration totalTime,
    required RequestFailure failure,
    required List<MetaLinkWarning> warnings,
  }) {
    return ExtractionResult<LinkMetadata>(
      metadata: _minimalMetadata(
        originalUrl: originalUrl,
        resolvedUrl: requestUrl,
      ),
      diagnostics: ExtractionDiagnostics(
        cacheHit: false,
        totalTime: totalTime,
        fetch: null,
        fieldProvenance: const <MetaField, FieldProvenance>{},
      ),
      warnings: warnings,
      errors: <MetaLinkError>[
        _mapFetchFailureToError(
          error: failure,
          stackTrace: failure.stackTrace,
          uri: requestUrl,
        ),
      ],
    );
  }

  LinkMetadata _minimalMetadata({
    required Uri originalUrl,
    required Uri resolvedUrl,
  }) {
    return LinkMetadata(originalUrl: originalUrl, resolvedUrl: resolvedUrl);
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
      'engine=2.1',
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
      _lengthPrefixed('ua', options.userAgent ?? ''),
      options.followRedirects ? 'fr1' : 'fr0',
      'mr${options.maxRedirects}',
      'mb${options.maxBytes}',
      options.stopAfterHead ? 'sh1' : 'sh0',
      _lengthPrefixed('px', options.proxyUrl ?? ''),
      _lengthPrefixed('policy', options.requestPolicy.cacheIdentity),
      _lengthPrefixed('h', _headersSignature(options.headers)),
    ].join(',');
  }

  String _inFlightSignature({
    required Uri originalUrl,
    required Uri cacheKeyUrl,
    required FetchOptions fetchOptions,
    required ExtractOptions extractOptions,
    required CacheOptions cacheOptions,
    required bool skipCache,
  }) {
    return <String>[
      _lengthPrefixed('original', originalUrl.toString()),
      _cacheKeySignature(
        cacheKeyUrl: cacheKeyUrl,
        fetchOptions: fetchOptions,
        extractOptions: extractOptions,
        cacheOptions: cacheOptions,
      ),
      'attemptTimeout=${fetchOptions.timeout.inMicroseconds}',
      'totalTimeout=${fetchOptions.totalTimeout.inMicroseconds}',
      'cacheEnabled=${cacheOptions.enabled}',
      'cacheTtl=${cacheOptions.ttl.inMicroseconds}',
      'skipCache=$skipCache',
    ].join('|');
  }

  String _headersSignature(Map<String, String> headers) {
    if (headers.isEmpty) return '';
    final entries = headers.entries
        .map((e) => MapEntry(e.key.toLowerCase(), e.value))
        .toList(growable: false);
    entries.sort((a, b) => a.key.compareTo(b.key));
    return entries
        .map(
          (entry) => <String>[
            _lengthPrefixed('k', entry.key),
            _lengthPrefixed('v', entry.value),
          ].join(),
        )
        .join();
  }

  String _lengthPrefixed(String label, String value) {
    return '$label${value.length}:$value';
  }

  MetaLinkError _mapFetchFailureToError({
    required Object error,
    StackTrace? stackTrace,
    Uri? uri,
    int? statusCode,
  }) {
    if (error is RequestFailure) {
      final code = switch (error.code) {
        RequestFailureCode.invalidTarget => MetaLinkErrorCode.invalidUrl,
        RequestFailureCode.policyRejected ||
        RequestFailureCode.unsupportedCapability => MetaLinkErrorCode.network,
        RequestFailureCode.redirectLimit ||
        RequestFailureCode.redirectLoop ||
        RequestFailureCode.invalidRedirect => MetaLinkErrorCode.network,
        RequestFailureCode.timeout => MetaLinkErrorCode.timeout,
        RequestFailureCode.cancelled => MetaLinkErrorCode.network,
        RequestFailureCode.proxyConfiguration ||
        RequestFailureCode.transport => MetaLinkErrorCode.network,
      };
      final reason = switch (error.code) {
        RequestFailureCode.policyRejected ||
        RequestFailureCode.unsupportedCapability =>
          MetaLinkErrorReason.policyRejected,
        RequestFailureCode.redirectLimit ||
        RequestFailureCode.redirectLoop ||
        RequestFailureCode.invalidRedirect =>
          MetaLinkErrorReason.redirectsExceeded,
        RequestFailureCode.cancelled => MetaLinkErrorReason.cancelled,
        RequestFailureCode.invalidTarget ||
        RequestFailureCode.timeout ||
        RequestFailureCode.proxyConfiguration ||
        RequestFailureCode.transport => null,
      };
      return MetaLinkError(
        code: code,
        reason: reason,
        message: error.message,
        uri: error.uri,
        statusCode: statusCode,
        cause: error.cause ?? error,
        stackTrace: error.stackTrace ?? stackTrace,
      );
    }

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

  Future<CacheWriteResult> _safeCacheWriteWithinLifetime(
    CacheStore store,
    String key,
    CacheEntry entry, {
    required RequestContext context,
    required Uri requestUrl,
  }) async {
    try {
      return await _raceWithRequestLifetime(
        _safeCacheWrite(store, key, entry),
        context: context,
        requestUrl: requestUrl,
      );
    } catch (error, stackTrace) {
      return CacheWriteResult(ok: false, error: error, stackTrace: stackTrace);
    }
  }

  Future<void> _deleteCacheEntryBestEffort(CacheStore store, String key) async {
    try {
      final result = await store.delete(key);
      if (!result.ok) {
        _log(
          MetaLinkLogLevel.warning,
          'Cache entry cleanup failed (ignored).',
          error: result.error,
          stackTrace: result.stackTrace,
          context: <String, Object?>{'cacheKey': key},
        );
      }
    } catch (error, stackTrace) {
      _log(
        MetaLinkLogLevel.warning,
        'Cache entry cleanup threw (ignored).',
        error: error,
        stackTrace: stackTrace,
        context: <String, Object?>{'cacheKey': key},
      );
    }
  }

  Map<String, dynamic> _buildCachePayload({
    required CachePayloadKind kind,
    required LinkMetadata metadata,
    required ExtractionDiagnostics diagnostics,
    required RawMetadata? raw,
    required List<MetaLinkWarning> warnings,
    required List<MetaLinkError> errors,
    required ExtractionStatus status,
    required double? completeness,
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
          'status': status.name,
          'completeness': completeness,
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

        final patched = _cloneMetadataWithOriginal(
          cached,
          requestedOriginalUrl,
        );

        return ExtractionResult<LinkMetadata>(
          metadata: patched,
          diagnostics: ExtractionDiagnostics(
            cacheHit: true,
            totalTime: totalTime,
            fetch: null,
            provenanceAvailable: false,
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
        final diagJson = Map<String, dynamic>.from(
          payload['diagnostics'] as Map,
        );

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

        final patchedMeta = _cloneMetadataWithOriginal(
          cachedMeta,
          requestedOriginalUrl,
        );
        final statusName = payload['status'];
        final cachedStatus = statusName is String
            ? ExtractionStatus.values
                  .where((status) => status.name == statusName)
                  .firstOrNull
            : null;
        final completenessValue = payload['completeness'];
        final cachedCompleteness = completenessValue is num
            ? completenessValue.toDouble()
            : null;

        return ExtractionResult<LinkMetadata>(
          metadata: patchedMeta,
          diagnostics: ExtractionDiagnostics(
            cacheHit: true,
            totalTime: totalTime,
            fetch: cachedDiag.fetch,
            provenanceAvailable: cachedDiag.provenanceAvailable,
            fieldProvenance: cachedDiag.fieldProvenance,
            itemProvenance: cachedDiag.itemProvenance,
            candidateDecisions: cachedDiag.candidateDecisions,
          ),
          raw: raw,
          warnings: cachedWarnings,
          errors: cachedErrors,
          status: cachedStatus,
          completeness: cachedCompleteness,
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
