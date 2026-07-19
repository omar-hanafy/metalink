import 'dart:async';

import 'package:metalink/src/cache/cache_store.dart';
import 'package:metalink/src/cache/memory_cache_store.dart';
import 'package:metalink/src/client.dart';
import 'package:metalink/src/fetch/fetcher.dart';
import 'package:metalink/src/model/diagnostics.dart';
import 'package:metalink/src/model/errors.dart';
import 'package:metalink/src/network/request_context.dart';
import 'package:metalink/src/network/request_engine.dart';
import 'package:metalink/src/network/request_policy.dart';
import 'package:metalink/src/options.dart';
import 'package:metalink/src/result.dart';
import 'package:test/test.dart';

import '../support/fake_fetcher.dart';
import '../support/fake_http_client.dart';

void main() {
  MetaLinkClient makeClient({
    required FakeFetcher fetcher,
    CacheOptions? cacheOptions,
  }) {
    return MetaLinkClient(
      fetcher: fetcher,
      options: MetaLinkClientOptions(
        fetch: const FetchOptions(stopAfterHead: false),
        cache: cacheOptions ?? const CacheOptions(),
      ),
    );
  }

  test('extract throws on empty url', () async {
    final fetcher = FakeFetcher();
    final client = makeClient(fetcher: fetcher);
    expect(() => client.extract('   '), throwsArgumentError);
  });

  test('extract returns invalidUrl error for bad url', () async {
    final fetcher = FakeFetcher();
    final client = makeClient(fetcher: fetcher);
    final result = await client.extract('mailto:test@example.com');
    expect(result.errors.first.code, MetaLinkErrorCode.invalidUrl);
  });

  test(
    'secure request policy rejects a target before cache or fetch',
    () async {
      final fetcher = FakeFetcher();
      final client = makeClient(fetcher: fetcher);

      final result = await client.extract(
        'http://127.0.0.1/private',
        fetchOptions: FetchOptions(
          stopAfterHead: false,
          requestPolicy: RequestPolicy.secure(),
        ),
      );

      expect(result.primaryError?.code, MetaLinkErrorCode.network);
      expect(result.primaryError?.reason, MetaLinkErrorReason.policyRejected);
      expect(fetcher.requests, isEmpty);
    },
  );

  test('request policy exceptions fail closed', () async {
    final fetcher = FakeFetcher();
    final client = makeClient(fetcher: fetcher);

    final result = await client.extract(
      'https://example.com/private',
      fetchOptions: FetchOptions(
        stopAfterHead: false,
        requestPolicy: RequestPolicy(
          cachePartition: 'throws',
          targetValidator: (_) => throw StateError('validator failed'),
        ),
      ),
    );

    expect(result.primaryError?.code, MetaLinkErrorCode.network);
    expect(result.primaryError?.reason, MetaLinkErrorReason.policyRejected);
    expect(fetcher.requests, isEmpty);
  });

  test('uncached targets invoke a custom policy once per hop', () async {
    final fetcher = FakeFetcher();
    final url = Uri.parse('https://example.com/policy-once');
    fetcher.registerGetResponse(
      url,
      FakeFetcher.buildResponse(
        url: url,
        statusCode: 200,
        headers: const {'content-type': 'text/html; charset=utf-8'},
        bodyText: '<title>Allowed</title>',
      ),
    );
    var validations = 0;
    final client = makeClient(fetcher: fetcher);

    final result = await client.extract(
      url.toString(),
      fetchOptions: FetchOptions(
        stopAfterHead: false,
        requestPolicy: RequestPolicy(
          cachePartition: 'counted',
          targetValidator: (_) {
            validations++;
            return const RequestPolicyDecision.allow();
          },
        ),
      ),
    );

    expect(result.isSuccess, isTrue);
    expect(validations, 1);
  });

  test('injected HTTP clients can declare inspectable redirects', () async {
    final httpClient = RecordingHttpClient(
      handler: (_) async => stringResponse(
        '<title>Trusted transport</title>',
        200,
        headers: const {'content-type': 'text/html; charset=utf-8'},
      ),
    );
    final client = MetaLinkClient(
      httpClient: httpClient,
      httpClientCapabilities: const FetcherCapabilities(
        supportsAbort: false,
        redirectHandling: RedirectHandlingCapability.inspectable,
      ),
      options: MetaLinkClientOptions(
        fetch: FetchOptions(
          stopAfterHead: false,
          requestPolicy: RequestPolicy.secure(),
        ),
        cache: const CacheOptions(enabled: false),
      ),
    );

    final result = await client.extract('https://example.com/transport');
    await client.dispose();

    expect(result.isSuccess, isTrue);
    expect(result.metadata.title, 'Trusted transport');
    expect(httpClient.closed, isFalse);
  });

  test('extract returns error when client closed', () async {
    final fetcher = FakeFetcher();
    final client = makeClient(fetcher: fetcher);
    await client.dispose();
    final result = await client.extract('https://example.com');
    expect(result.errors.first.code, MetaLinkErrorCode.unknown);
  });

  test('extract returns nonHtmlContent error', () async {
    final fetcher = FakeFetcher();
    final url = Uri.parse('https://example.com/a');
    fetcher.registerGetResponse(
      url,
      FakeFetcher.buildResponse(
        url: url,
        statusCode: 200,
        headers: const {'content-type': 'application/json'},
        bodyText: '{"ok":true}',
      ),
    );

    final client = makeClient(fetcher: fetcher);
    final result = await client.extract(url.toString());
    expect(result.errors.first.code, MetaLinkErrorCode.nonHtmlContent);
    expect(
      result.warnings.any((w) => w.code == MetaLinkWarningCode.nonHtmlResponse),
      isTrue,
    );
  });

  test('extract returns httpStatus error for non-2xx', () async {
    final fetcher = FakeFetcher();
    final url = Uri.parse('https://example.com/a');
    fetcher.registerGetResponse(
      url,
      FakeFetcher.buildResponse(
        url: url,
        statusCode: 500,
        headers: const {'content-type': 'text/html'},
        bodyText: '<html></html>',
      ),
    );

    final client = makeClient(fetcher: fetcher);
    final result = await client.extract(url.toString());
    expect(result.errors.first.code, MetaLinkErrorCode.httpStatus);
  });

  test('extract maps timeout errors', () async {
    final fetcher = FakeFetcher();
    final url = Uri.parse('https://example.com/a');
    fetcher.registerGetResponse(
      url,
      FakeFetcher.buildResponse(url: url, error: TimeoutException('timeout')),
    );

    final client = makeClient(fetcher: fetcher);
    final result = await client.extract(url.toString());
    expect(result.errors.first.code, MetaLinkErrorCode.timeout);
    expect(result.retryable, isTrue);
  });

  test(
    'extract exposes cancellation without expanding the v2 code enum',
    () async {
      final fetcher = FakeFetcher();
      final cancellation = Completer<void>()..complete();
      final client = makeClient(fetcher: fetcher);

      final result = await client.extract(
        'https://example.com/cancelled',
        requestContext: RequestContext(cancellationSignal: cancellation.future),
        skipCache: true,
      );

      expect(result.primaryError?.code, MetaLinkErrorCode.network);
      expect(result.primaryError?.reason, MetaLinkErrorReason.cancelled);
      expect(result.retryable, isFalse);
      expect(fetcher.requests, isEmpty);
    },
  );

  test(
    'concurrent identical extractions share one in-flight request',
    () async {
      final fetcher = FakeFetcher();
      final url = Uri.parse('https://example.com/coalesced');
      final release = Completer<void>();
      fetcher.registerGet(url, (request) async {
        await release.future;
        return FakeFetcher.buildResponse(
          url: request.url,
          statusCode: 200,
          headers: const {'content-type': 'text/html; charset=utf-8'},
          bodyText: '<title>Shared</title>',
        );
      });

      final client = makeClient(fetcher: fetcher);
      final first = client.extract(url.toString(), skipCache: true);
      final second = client.extract(url.toString(), skipCache: true);
      await Future<void>.delayed(Duration.zero);

      expect(fetcher.requests, hasLength(1));
      release.complete();
      final results = await Future.wait([first, second]);
      expect(
        results.map((result) => result.metadata.title),
        everyElement('Shared'),
      );
      expect(fetcher.requests, hasLength(1));
    },
  );

  test('cache hit returns cached result', () async {
    final fetcher = FakeFetcher();
    final url = Uri.parse('https://example.com/a');
    final cache = _SeededCacheStore(
      entry: CacheEntry(
        kind: CachePayloadKind.linkMetadata,
        createdAtMs: DateTime.now().millisecondsSinceEpoch,
        ttlMs: 1000,
        payload: const <String, dynamic>{
          'originalUrl': 'https://example.com/a',
          'resolvedUrl': 'https://example.com/a',
          'title': 'Cached',
          'images': [],
          'icons': [],
          'videos': [],
          'audios': [],
          'keywords': [],
        },
      ),
    );
    final client = MetaLinkClient(
      fetcher: fetcher,
      cacheStore: cache,
      options: const MetaLinkClientOptions(
        fetch: FetchOptions(stopAfterHead: false),
      ),
    );

    final result = await client.extract(url.toString());
    expect(result.diagnostics.cacheHit, isTrue);
    expect(result.diagnostics.provenanceAvailable, isFalse);
    expect(result.metadata.title, 'Cached');
  });

  test('cache-hit policy validation obeys the total timeout', () async {
    final fetcher = FakeFetcher();
    final url = Uri.parse('https://example.com/cached-timeout');
    final cache = _SeededCacheStore(
      entry: CacheEntry(
        kind: CachePayloadKind.linkMetadata,
        createdAtMs: DateTime.now().millisecondsSinceEpoch,
        ttlMs: 1000,
        payload: <String, dynamic>{
          'originalUrl': url.toString(),
          'resolvedUrl': url.toString(),
          'title': 'Cached',
          'images': <dynamic>[],
          'icons': <dynamic>[],
          'videos': <dynamic>[],
          'audios': <dynamic>[],
          'keywords': <dynamic>[],
        },
      ),
    );
    final never = Completer<RequestPolicyDecision>();
    final client = MetaLinkClient(
      fetcher: fetcher,
      cacheStore: cache,
      options: MetaLinkClientOptions(
        fetch: FetchOptions(
          stopAfterHead: false,
          totalTimeout: const Duration(milliseconds: 10),
          requestPolicy: RequestPolicy(
            cachePartition: 'hanging-cache-policy',
            targetValidator: (_) => never.future,
          ),
        ),
      ),
    );

    final result = await client.extract(url.toString());

    expect(result.primaryError?.code, MetaLinkErrorCode.timeout);
    expect(fetcher.requests, isEmpty);
  });

  test('cache-hit policy validation obeys caller cancellation', () async {
    final fetcher = FakeFetcher();
    final url = Uri.parse('https://example.com/cached-cancelled');
    final cache = _SeededCacheStore(
      entry: CacheEntry(
        kind: CachePayloadKind.linkMetadata,
        createdAtMs: DateTime.now().millisecondsSinceEpoch,
        ttlMs: 1000,
        payload: <String, dynamic>{
          'originalUrl': url.toString(),
          'resolvedUrl': url.toString(),
          'title': 'Cached',
          'images': <dynamic>[],
          'icons': <dynamic>[],
          'videos': <dynamic>[],
          'audios': <dynamic>[],
          'keywords': <dynamic>[],
        },
      ),
    );
    final cancellation = Completer<void>()..complete();
    final client = MetaLinkClient(fetcher: fetcher, cacheStore: cache);

    final result = await client.extract(
      url.toString(),
      requestContext: RequestContext(cancellationSignal: cancellation.future),
    );

    expect(result.primaryError?.code, MetaLinkErrorCode.network);
    expect(result.primaryError?.reason, MetaLinkErrorReason.cancelled);
    expect(fetcher.requests, isEmpty);
  });

  test('cancelled extraction is not blocked by a pending cache read', () async {
    final fetcher = FakeFetcher();
    final cache = _ControllableCacheStore(hangRead: true);
    final cancellation = Completer<void>()..complete();
    final client = MetaLinkClient(fetcher: fetcher, cacheStore: cache);

    final result = await client.extract(
      'https://example.com/cancelled-before-cache',
      requestContext: RequestContext(cancellationSignal: cancellation.future),
    );

    expect(result.primaryError?.reason, MetaLinkErrorReason.cancelled);
    expect(cache.reads, 1);
    expect(fetcher.requests, isEmpty);
  });

  test('pending cache read obeys the complete request deadline', () async {
    final fetcher = FakeFetcher();
    final cache = _ControllableCacheStore(hangRead: true);
    final client = MetaLinkClient(
      fetcher: fetcher,
      cacheStore: cache,
      options: const MetaLinkClientOptions(
        fetch: FetchOptions(totalTimeout: Duration(milliseconds: 15)),
      ),
    );

    final result = await client
        .extract('https://example.com/hanging-cache-read')
        .timeout(const Duration(seconds: 1));

    expect(result.primaryError?.code, MetaLinkErrorCode.timeout);
    expect(cache.reads, 1);
    expect(fetcher.requests, isEmpty);
  });

  test('cache-hit timing includes asynchronous policy validation', () async {
    final fetcher = FakeFetcher();
    final url = Uri.parse('https://example.com/cached-policy-timing');
    final cache = _SeededCacheStore(
      entry: CacheEntry(
        kind: CachePayloadKind.linkMetadata,
        createdAtMs: DateTime.now().millisecondsSinceEpoch,
        ttlMs: 1000,
        payload: <String, dynamic>{
          'originalUrl': url.toString(),
          'resolvedUrl': url.toString(),
          'title': 'Cached',
          'images': <dynamic>[],
          'icons': <dynamic>[],
          'videos': <dynamic>[],
          'audios': <dynamic>[],
          'keywords': <dynamic>[],
        },
      ),
    );
    final release = Completer<RequestPolicyDecision>();
    final client = MetaLinkClient(
      fetcher: fetcher,
      cacheStore: cache,
      options: MetaLinkClientOptions(
        fetch: FetchOptions(
          stopAfterHead: false,
          requestPolicy: RequestPolicy(
            cachePartition: 'delayed-cache-policy',
            targetValidator: (_) => release.future,
          ),
        ),
      ),
    );

    final extraction = client.extract(url.toString());
    await Future<void>.delayed(const Duration(milliseconds: 20));
    release.complete(const RequestPolicyDecision.allow());
    final result = await extraction;

    expect(result.diagnostics.cacheHit, isTrue);
    expect(
      result.diagnostics.totalTime,
      greaterThanOrEqualTo(const Duration(milliseconds: 15)),
    );
    expect(fetcher.requests, isEmpty);
  });

  test(
    'full cache payload restores status, completeness, and provenance',
    () async {
      final fetcher = FakeFetcher();
      final url = Uri.parse('https://example.com/full-cache');
      final cache = _SeededCacheStore(
        entry: CacheEntry(
          kind: CachePayloadKind.extractionResult,
          createdAtMs: DateTime.now().millisecondsSinceEpoch,
          ttlMs: 1000,
          payload: <String, dynamic>{
            'metadata': <String, dynamic>{
              'originalUrl': url.toString(),
              'resolvedUrl': url.toString(),
              'title': 'Cached full result',
              'images': <dynamic>[],
              'icons': <dynamic>[],
              'videos': <dynamic>[],
              'audios': <dynamic>[],
              'keywords': <dynamic>[],
            },
            'diagnostics': const <String, dynamic>{
              'cacheHit': false,
              'totalTimeMs': 4,
              'fetch': null,
              'provenanceAvailable': true,
              'fieldProvenance': <String, dynamic>{
                'title': <String, dynamic>{'source': 'openGraph', 'score': 0.9},
              },
            },
            'raw': null,
            'warnings': <dynamic>[],
            'errors': <dynamic>[],
            'status': 'partial',
            'completeness': 0.75,
          },
        ),
      );
      final client = MetaLinkClient(
        fetcher: fetcher,
        cacheStore: cache,
        options: const MetaLinkClientOptions(
          fetch: FetchOptions(stopAfterHead: false),
          cache: CacheOptions(payloadKind: CachePayloadKind.extractionResult),
        ),
      );

      final result = await client.extract(url.toString());

      expect(result.status, ExtractionStatus.partial);
      expect(result.completeness, 0.75);
      expect(result.diagnostics.provenanceAvailable, isTrue);
      expect(result.diagnostics.fieldProvenance, contains(MetaField.title));
      expect(fetcher.requests, isEmpty);
    },
  );

  test('attempt timeout changes do not invalidate cached content', () async {
    final fetcher = FakeFetcher();
    final url = Uri.parse('https://example.com/cache-timeout');
    fetcher.registerGetResponse(
      url,
      FakeFetcher.buildResponse(
        url: url,
        statusCode: 200,
        headers: const {'content-type': 'text/html; charset=utf-8'},
        bodyText: '<title>Stable</title>',
      ),
    );
    final client = makeClient(
      fetcher: fetcher,
      cacheOptions: const CacheOptions(
        payloadKind: CachePayloadKind.extractionResult,
      ),
    );

    final first = await client.extract(
      url.toString(),
      fetchOptions: const FetchOptions(
        stopAfterHead: false,
        timeout: Duration(seconds: 1),
      ),
    );
    final second = await client.extract(
      url.toString(),
      fetchOptions: const FetchOptions(
        stopAfterHead: false,
        timeout: Duration(seconds: 5),
      ),
    );

    expect(first.metadata.title, 'Stable');
    expect(second.metadata.title, 'Stable');
    expect(second.diagnostics.cacheHit, isTrue);
    expect(second.diagnostics.fieldProvenance, contains(MetaField.title));
    expect(second.diagnostics.candidateDecisions[MetaField.title], isNotEmpty);
    expect(fetcher.requests, hasLength(1));
  });

  test('failed remote enrichment does not poison the shared cache', () async {
    final fetcher = FakeFetcher();
    final pageUrl = Uri.parse('https://example.com/enrichment-cache');
    final oembedUrl = Uri.parse('https://example.com/oembed.json');
    fetcher.registerGetResponse(
      pageUrl,
      FakeFetcher.buildResponse(
        url: pageUrl,
        statusCode: 200,
        headers: const {'content-type': 'text/html; charset=utf-8'},
        bodyText:
            '<title>Local</title>'
            '<link rel="alternate" type="application/json+oembed" '
            'href="https://example.com/oembed.json">',
      ),
    );
    fetcher.registerGetResponse(
      oembedUrl,
      FakeFetcher.buildResponse(
        url: oembedUrl,
        statusCode: 503,
        headers: const {'content-type': 'application/json'},
        bodyText: '{}',
      ),
    );
    final client = makeClient(fetcher: fetcher);

    final degraded = await client.extract(
      pageUrl.toString(),
      fetchOptions: const FetchOptions(
        stopAfterHead: false,
        timeout: Duration(seconds: 1),
      ),
      extractOptions: const ExtractOptions(enableOEmbed: true),
    );
    fetcher.registerGetResponse(
      oembedUrl,
      FakeFetcher.buildResponse(
        url: oembedUrl,
        statusCode: 200,
        headers: const {'content-type': 'application/json'},
        bodyText: '{"version":"1.0","type":"photo","title":"Enriched"}',
      ),
    );
    final recovered = await client.extract(
      pageUrl.toString(),
      fetchOptions: const FetchOptions(
        stopAfterHead: false,
        timeout: Duration(seconds: 5),
      ),
      extractOptions: const ExtractOptions(enableOEmbed: true),
    );

    expect(
      degraded.warnings.any(
        (warning) => warning.code == MetaLinkWarningCode.oembedFailed,
      ),
      isTrue,
    );
    expect(recovered.diagnostics.cacheHit, isFalse);
    expect(recovered.metadata.oembed?.title, 'Enriched');
    expect(
      fetcher.requests.where((request) => request.url == pageUrl),
      hasLength(2),
    );
  });

  test('pending best-effort cache write cannot hang extraction', () async {
    final fetcher = FakeFetcher();
    final pageUrl = Uri.parse('https://example.com/hanging-cache-write');
    fetcher.registerGetResponse(
      pageUrl,
      FakeFetcher.buildResponse(
        url: pageUrl,
        statusCode: 200,
        headers: const {'content-type': 'text/html; charset=utf-8'},
        bodyText: '<title>Fetched</title>',
      ),
    );
    final cache = _ControllableCacheStore(hangWrite: true);
    final client = MetaLinkClient(
      fetcher: fetcher,
      cacheStore: cache,
      options: const MetaLinkClientOptions(
        fetch: FetchOptions(
          stopAfterHead: false,
          totalTimeout: Duration(milliseconds: 100),
        ),
      ),
    );

    final result = await client
        .extract(pageUrl.toString())
        .timeout(const Duration(seconds: 1));
    await client.dispose().timeout(const Duration(seconds: 1));

    expect(result.metadata.title, 'Fetched');
    expect(
      result.warnings.any(
        (warning) => warning.code == MetaLinkWarningCode.cacheWriteFailed,
      ),
      isTrue,
    );
    expect(cache.writes, 1);
  });

  test('cache header signatures cannot collide through delimiters', () async {
    final fetcher = FakeFetcher();
    final url = Uri.parse('https://example.com/cache-headers');
    fetcher.registerGetResponse(
      url,
      FakeFetcher.buildResponse(
        url: url,
        statusCode: 200,
        headers: const {'content-type': 'text/html; charset=utf-8'},
        bodyText: '<title>Headers</title>',
      ),
    );
    final client = makeClient(fetcher: fetcher);

    final oneHeader = await client.extract(
      url.toString(),
      fetchOptions: const FetchOptions(
        stopAfterHead: false,
        headers: {'a': 'b&c=d'},
      ),
    );
    final twoHeaders = await client.extract(
      url.toString(),
      fetchOptions: const FetchOptions(
        stopAfterHead: false,
        headers: {'a': 'b', 'c': 'd'},
      ),
    );

    expect(oneHeader.metadata.title, 'Headers');
    expect(twoHeaders.metadata.title, 'Headers');
    expect(fetcher.requests, hasLength(2));
  });

  test('request policy partitions cannot share cache entries', () async {
    final fetcher = FakeFetcher();
    final url = Uri.parse('https://example.com/cache-policy');
    fetcher.registerGetResponse(
      url,
      FakeFetcher.buildResponse(
        url: url,
        statusCode: 200,
        headers: const {'content-type': 'text/html; charset=utf-8'},
        bodyText: '<title>Policy</title>',
      ),
    );
    final client = makeClient(fetcher: fetcher);

    await client.extract(url.toString());
    await client.extract(
      url.toString(),
      fetchOptions: FetchOptions(
        stopAfterHead: false,
        requestPolicy: RequestPolicy.secure(),
      ),
    );

    expect(fetcher.requests, hasLength(2));
  });

  test('skipCache adds warning', () async {
    final fetcher = FakeFetcher();
    final url = Uri.parse('https://example.com/a');
    fetcher.registerGetResponse(
      url,
      FakeFetcher.buildResponse(
        url: url,
        statusCode: 200,
        headers: const {'content-type': 'text/html'},
        bodyText: '<title>Hello</title>',
      ),
    );

    final cache = MemoryCacheStore();
    final client = MetaLinkClient(
      fetcher: fetcher,
      cacheStore: cache,
      options: const MetaLinkClientOptions(
        fetch: FetchOptions(stopAfterHead: false),
      ),
    );

    final result = await client.extract(url.toString(), skipCache: true);
    expect(
      result.warnings.any((w) => w.code == MetaLinkWarningCode.cacheBypassed),
      isTrue,
    );
  });

  test('cache read failure adds warning', () async {
    final fetcher = FakeFetcher();
    final url = Uri.parse('https://example.com/a');
    fetcher.registerGetResponse(
      url,
      FakeFetcher.buildResponse(
        url: url,
        statusCode: 200,
        headers: const {'content-type': 'text/html'},
        bodyText: '<title>Hello</title>',
      ),
    );

    final client = MetaLinkClient(
      fetcher: fetcher,
      cacheStore: _ThrowingCacheStore(),
      options: const MetaLinkClientOptions(
        fetch: FetchOptions(stopAfterHead: false),
      ),
    );

    final result = await client.extract(url.toString());
    expect(
      result.warnings.any((w) => w.code == MetaLinkWarningCode.cacheReadFailed),
      isTrue,
    );
  });

  test('asynchronous expired-entry cleanup failures stay contained', () async {
    final fetcher = FakeFetcher();
    final url = Uri.parse('https://example.com/expired-cleanup');
    fetcher.registerGetResponse(
      url,
      FakeFetcher.buildResponse(
        url: url,
        statusCode: 200,
        headers: const {'content-type': 'text/html; charset=utf-8'},
        bodyText: '<title>Fresh</title>',
      ),
    );
    final cache = _AsyncDeleteFailingCacheStore(
      entry: CacheEntry(
        kind: CachePayloadKind.linkMetadata,
        createdAtMs: DateTime.now()
            .subtract(const Duration(seconds: 1))
            .millisecondsSinceEpoch,
        ttlMs: 1,
        payload: <String, dynamic>{
          'originalUrl': url.toString(),
          'resolvedUrl': url.toString(),
          'title': 'Expired',
          'images': <dynamic>[],
          'icons': <dynamic>[],
          'videos': <dynamic>[],
          'audios': <dynamic>[],
          'keywords': <dynamic>[],
        },
      ),
    );
    final client = MetaLinkClient(
      fetcher: fetcher,
      cacheStore: cache,
      options: const MetaLinkClientOptions(
        fetch: FetchOptions(stopAfterHead: false),
      ),
    );

    final result = await client.extract(url.toString());
    await Future<void>.delayed(Duration.zero);

    expect(result.metadata.title, 'Fresh');
    expect(cache.deletes, 1);
  });

  test('extractBatch handles invalid inputs', () async {
    final fetcher = FakeFetcher();
    final url = Uri.parse('https://example.com/a');
    fetcher.registerGetResponse(
      url,
      FakeFetcher.buildResponse(
        url: url,
        statusCode: 200,
        headers: const {'content-type': 'text/html'},
        bodyText: '<title>Hello</title>',
      ),
    );

    final client = makeClient(fetcher: fetcher);
    final results = await client.extractBatch([
      url.toString(),
      'mailto:test@example.com',
    ]);
    expect(results.length, 2);
    expect(results.first.errors, isEmpty);
    expect(results.last.errors.first.code, MetaLinkErrorCode.invalidUrl);
  });

  test('extractBatch rejects invalid concurrency', () async {
    final fetcher = FakeFetcher();
    final client = makeClient(fetcher: fetcher);
    expect(
      () => client.extractBatch(['https://example.com'], concurrency: 0),
      throwsArgumentError,
    );
  });

  test('optimizeUrl returns error for invalid url', () async {
    final fetcher = FakeFetcher();
    final client = makeClient(fetcher: fetcher);
    final result = await client.optimizeUrl('mailto:test@example.com');
    expect(result.error, isNotNull);
    expect(result.originalUrl.toString(), 'about:blank');
  });

  test('optimizeUrl returns error when closed', () async {
    final fetcher = FakeFetcher();
    final client = makeClient(fetcher: fetcher);
    await client.dispose();
    final result = await client.optimizeUrl('https://example.com');
    expect(result.error, isNotNull);
  });

  test('optimizeUrl accepts caller cancellation', () async {
    final fetcher = FakeFetcher();
    final cancellation = Completer<void>()..complete();
    final client = makeClient(fetcher: fetcher);

    final result = await client.optimizeUrl(
      'https://example.com/cancelled',
      requestContext: RequestContext(cancellationSignal: cancellation.future),
    );

    expect(result.error, isA<RequestFailure>());
    expect(
      (result.error! as RequestFailure).code,
      RequestFailureCode.cancelled,
    );
    expect(fetcher.requests, isEmpty);
  });

  test('dispose is idempotent and rejects new work', () async {
    final fetcher = FakeFetcher();
    final client = makeClient(fetcher: fetcher);

    final firstDispose = client.dispose();
    final secondDispose = client.dispose();
    expect(identical(firstDispose, secondDispose), isTrue);
    await firstDispose;

    final result = await client.extract('https://example.com');
    expect(result.isFailure, isTrue);
    expect(fetcher.requests, isEmpty);
  });

  test('dispose waits for an active URL optimization', () async {
    final fetcher = FakeFetcher();
    final url = Uri.parse('https://example.com/slow-redirect');
    final release = Completer<void>();
    fetcher.registerHead(url, (request) async {
      await release.future;
      return FakeFetcher.buildResponse(url: request.url, statusCode: 200);
    });
    final client = makeClient(fetcher: fetcher);

    final optimization = client.optimizeUrl(url.toString());
    await Future<void>.delayed(Duration.zero);
    var disposed = false;
    final disposal = client.dispose().then((_) => disposed = true);
    await Future<void>.delayed(Duration.zero);

    expect(disposed, isFalse);
    release.complete();
    await optimization;
    await disposal;
    expect(disposed, isTrue);
  });

  test('dispose waits for a context-bearing extraction', () async {
    final fetcher = FakeFetcher();
    final url = Uri.parse('https://example.com/slow-context');
    final release = Completer<void>();
    fetcher.registerGet(url, (request) async {
      await release.future;
      return FakeFetcher.buildResponse(
        url: request.url,
        statusCode: 200,
        headers: const {'content-type': 'text/html; charset=utf-8'},
        bodyText: '<title>Done</title>',
      );
    });
    final client = makeClient(fetcher: fetcher);

    final extraction = client.extract(
      url.toString(),
      requestContext: RequestContext(totalTimeout: const Duration(seconds: 5)),
      skipCache: true,
    );
    await Future<void>.delayed(Duration.zero);
    var disposed = false;
    final disposal = client.dispose().then((_) => disposed = true);
    await Future<void>.delayed(Duration.zero);

    expect(disposed, isFalse);
    release.complete();
    await extraction;
    await disposal;
    expect(disposed, isTrue);
  });

  test('dispose waits for a normal coalesced extraction', () async {
    final fetcher = FakeFetcher();
    final url = Uri.parse('https://example.com/slow-coalesced');
    final release = Completer<void>();
    fetcher.registerGet(url, (request) async {
      await release.future;
      return FakeFetcher.buildResponse(
        url: request.url,
        statusCode: 200,
        headers: const {'content-type': 'text/html; charset=utf-8'},
        bodyText: '<title>Done</title>',
      );
    });
    final client = makeClient(fetcher: fetcher);

    final extraction = client.extract(url.toString(), skipCache: true);
    await Future<void>.delayed(Duration.zero);
    var disposed = false;
    final disposal = client.dispose().then((_) => disposed = true);
    await Future<void>.delayed(Duration.zero);

    expect(disposed, isFalse);
    release.complete();
    await extraction;
    await disposal;
    expect(disposed, isTrue);
  });
}

class _ThrowingCacheStore implements CacheStore {
  @override
  Future<CacheReadResult> read(String key) async {
    throw StateError('read failed');
  }

  @override
  Future<CacheWriteResult> write(String key, CacheEntry entry) async {
    return const CacheWriteResult(ok: true);
  }

  @override
  Future<CacheOpResult> delete(String key) async {
    return const CacheOpResult(ok: true);
  }

  @override
  Future<CacheOpResult> clear() async {
    return const CacheOpResult(ok: true);
  }

  @override
  Future<CachePurgeResult> purgeExpired() async {
    return const CachePurgeResult(ok: true, purged: 0);
  }

  @override
  Future<void> close() async {}
}

class _SeededCacheStore implements CacheStore {
  _SeededCacheStore({required this.entry});

  final CacheEntry entry;

  @override
  Future<CacheReadResult> read(String key) async {
    return CacheReadResult(entry: entry);
  }

  @override
  Future<CacheWriteResult> write(String key, CacheEntry entry) async {
    return const CacheWriteResult(ok: true);
  }

  @override
  Future<CacheOpResult> delete(String key) async {
    return const CacheOpResult(ok: true);
  }

  @override
  Future<CacheOpResult> clear() async {
    return const CacheOpResult(ok: true);
  }

  @override
  Future<CachePurgeResult> purgeExpired() async {
    return const CachePurgeResult(ok: true, purged: 0);
  }

  @override
  Future<void> close() async {}
}

class _AsyncDeleteFailingCacheStore extends _SeededCacheStore {
  _AsyncDeleteFailingCacheStore({required super.entry});

  int deletes = 0;

  @override
  Future<CacheOpResult> delete(String key) async {
    deletes++;
    await Future<void>.delayed(Duration.zero);
    throw StateError('delete failed asynchronously');
  }
}

class _ControllableCacheStore implements CacheStore {
  _ControllableCacheStore({this.hangRead = false, this.hangWrite = false});

  final bool hangRead;
  final bool hangWrite;
  int reads = 0;
  int writes = 0;

  @override
  Future<CacheReadResult> read(String key) async {
    reads++;
    if (hangRead) return Completer<CacheReadResult>().future;
    return const CacheReadResult(entry: null);
  }

  @override
  Future<CacheWriteResult> write(String key, CacheEntry entry) async {
    writes++;
    if (hangWrite) return Completer<CacheWriteResult>().future;
    return const CacheWriteResult(ok: true);
  }

  @override
  Future<CacheOpResult> delete(String key) async {
    return const CacheOpResult(ok: true);
  }

  @override
  Future<CacheOpResult> clear() async {
    return const CacheOpResult(ok: true);
  }

  @override
  Future<CachePurgeResult> purgeExpired() async {
    return const CachePurgeResult(ok: true, purged: 0);
  }

  @override
  Future<void> close() async {}
}
