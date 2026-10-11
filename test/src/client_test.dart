import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:metalink/src/cache/cache_key.dart';
import 'package:metalink/src/cache/cache_store.dart';
import 'package:metalink/src/cache/memory_cache_store.dart';
import 'package:metalink/src/client.dart';
import 'package:metalink/src/fetch/fetcher.dart';
import 'package:metalink/src/model/diagnostics.dart';
import 'package:metalink/src/model/errors.dart';
import 'package:metalink/src/model/link_metadata.dart';
import 'package:metalink/src/model/manifest.dart';
import 'package:metalink/src/model/url_optimization.dart';
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
          'images': <Object?>[],
          'icons': <Object?>[],
          'videos': <Object?>[],
          'audios': <Object?>[],
          'keywords': <Object?>[],
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

  test('a signal that fails mid-read cancels the pending cache read', () async {
    final fetcher = FakeFetcher();
    final cache = _ControllableCacheStore(hangRead: true);
    final cancellation = Completer<void>();
    final client = MetaLinkClient(fetcher: fetcher, cacheStore: cache);
    addTearDown(client.dispose);

    final extraction = client.extract(
      'https://example.com/fails-mid-read',
      requestContext: RequestContext(cancellationSignal: cancellation.future),
    );
    await Future<void>.delayed(Duration.zero);
    expect(cache.reads, 1);
    cancellation.completeError(StateError('caller went away'));
    final result = await extraction.timeout(const Duration(seconds: 1));

    expect(result.primaryError?.code, MetaLinkErrorCode.network);
    expect(result.primaryError?.reason, MetaLinkErrorReason.cancelled);
    expect(result.primaryError?.cause, isA<FetchCancellationException>());
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

  group('coalesced extraction', () {
    void registerGatedPage(
      FakeFetcher fetcher,
      Uri url,
      Future<void> gate, {
      String title = 'Shared',
    }) {
      fetcher.registerGet(url, (request) async {
        await gate;
        return FakeFetcher.buildResponse(
          url: request.url,
          statusCode: 200,
          headers: const {'content-type': 'text/html; charset=utf-8'},
          bodyText: '<title>$title</title>',
        );
      });
    }

    // A page with ordered images and keywords, so in-place edits are visible.
    void registerGatedListPage(
      FakeFetcher fetcher,
      Uri url,
      Future<void> gate,
    ) {
      fetcher.registerGet(url, (request) async {
        await gate;
        return FakeFetcher.buildResponse(
          url: request.url,
          headers: const {'content-type': 'text/html; charset=utf-8'},
          bodyText:
              '<title>Shared</title>'
              '<meta property="og:image" content="https://example.com/a.png">'
              '<meta property="og:image" content="https://example.com/b.png">'
              '<meta name="keywords" content="alpha, beta">',
        );
      });
    }

    void expectPristine(ExtractionResult<LinkMetadata> result) {
      expect(result.metadata.images.map((image) => image.url.toString()), [
        'https://example.com/a.png',
        'https://example.com/b.png',
      ]);
      expect(result.metadata.keywords, ['alpha', 'beta']);
      expect(result.diagnostics.fieldProvenance, isNotEmpty);
      expect(result.diagnostics.candidateDecisions, isNotEmpty);
      expect(result.warnings, isEmpty);
      expect(result.raw?.meta, isNotEmpty);
    }

    MetaLinkClient makeListClient(FakeFetcher fetcher) {
      return MetaLinkClient(
        fetcher: fetcher,
        options: const MetaLinkClientOptions(
          fetch: FetchOptions(stopAfterHead: false),
          extract: ExtractOptions(includeRawMetadata: true),
          cache: CacheOptions(enabled: false),
        ),
      );
    }

    test('R2-A: edits in the first caller then-callback stay local', () async {
      final fetcher = FakeFetcher();
      final url = Uri.parse('https://example.com/leader-then-edit');
      final release = Completer<void>();
      registerGatedListPage(fetcher, url, release.future);
      final client = makeListClient(fetcher);
      addTearDown(client.dispose);

      final leader = client.extract(url.toString()).then((result) {
        result.metadata.images.sort(
          (a, b) => b.url.toString().compareTo(a.url.toString()),
        );
        result.metadata.keywords.add('leader');
        return result;
      });
      final joiner = client.extract(url.toString());
      await Future<void>.delayed(Duration.zero);
      release.complete();
      final joined = await joiner;
      final led = await leader;

      expect(fetcher.requests, hasLength(1));
      expect(led.metadata.keywords, contains('leader'));
      expectPristine(joined);
    });

    test('R2-A2: edits after awaiting the first caller stay local', () async {
      final fetcher = FakeFetcher();
      final url = Uri.parse('https://example.com/leader-await-edit');
      final release = Completer<void>();
      registerGatedListPage(fetcher, url, release.future);
      final client = makeListClient(fetcher);
      addTearDown(client.dispose);

      Future<ExtractionResult<LinkMetadata>> editingCaller() async {
        final result = await client.extract(url.toString());
        result.metadata.images.clear();
        result.metadata.keywords.clear();
        result.warnings.add(
          const MetaLinkWarning(
            code: MetaLinkWarningCode.partialParse,
            message: 'added by the first caller',
          ),
        );
        return result;
      }

      final leader = editingCaller();
      final joiner = client.extract(url.toString());
      await Future<void>.delayed(Duration.zero);
      release.complete();
      final results = await Future.wait([leader, joiner]);

      expect(fetcher.requests, hasLength(1));
      expect(results.first.metadata.images, isEmpty);
      expectPristine(results.last);
    });

    test(
      'R2-A3: diagnostics and raw edits by the first caller stay local',
      () async {
        final fetcher = FakeFetcher();
        final url = Uri.parse('https://example.com/leader-diagnostics-edit');
        final release = Completer<void>();
        registerGatedListPage(fetcher, url, release.future);
        final client = makeListClient(fetcher);
        addTearDown(client.dispose);

        final leader = client.extract(url.toString()).then((result) {
          result.diagnostics.fieldProvenance.clear();
          result.diagnostics.candidateDecisions.clear();
          result.raw!.meta.clear();
          return result;
        });
        final joiners = [
          client.extract(url.toString()),
          client.extract(url.toString()),
        ];
        await Future<void>.delayed(Duration.zero);
        release.complete();
        await leader;
        final joined = await Future.wait(joiners);

        expect(fetcher.requests, hasLength(1));
        joined.forEach(expectPristine);
      },
    );

    test(
      'a joiner retries when only the first caller policy rejected',
      () async {
        final fetcher = FakeFetcher();
        final url = Uri.parse('https://example.com/leader-policy-rejects');
        registerGatedPage(fetcher, url, Future<void>.value(), title: 'Joiner');
        final leaderDecision = Completer<void>();
        final client = makeClient(fetcher: fetcher);
        addTearDown(client.dispose);

        final leader = client.extract(
          url.toString(),
          fetchOptions: FetchOptions(
            stopAfterHead: false,
            requestPolicy: RequestPolicy.secure(
              additionalValidator: (_) async {
                await leaderDecision.future;
                return const RequestPolicyDecision.reject('leader rejects');
              },
            ),
          ),
        );
        await Future<void>.delayed(Duration.zero);
        // Shares the default 'secure' partition, so it joins the leader.
        final joiner = client.extract(
          url.toString(),
          fetchOptions: FetchOptions(
            stopAfterHead: false,
            requestPolicy: RequestPolicy.secure(),
          ),
        );
        await Future<void>.delayed(Duration.zero);
        leaderDecision.complete();
        final leaderResult = await leader;
        final joinerResult = await joiner;

        expect(
          leaderResult.primaryError?.reason,
          MetaLinkErrorReason.policyRejected,
        );
        expect(joinerResult.errors, isEmpty);
        expect(joinerResult.metadata.title, 'Joiner');
        expect(fetcher.requests, hasLength(1));
      },
    );

    test('a joiner with the same policy shares its rejection', () async {
      final fetcher = FakeFetcher();
      final url = Uri.parse('https://example.com/redirects-away');
      fetcher.registerGetResponse(
        url,
        FakeFetcher.buildResponse(
          url: url,
          statusCode: 302,
          headers: const {'location': 'https://example.com/rejected-hop'},
        ),
      );
      // Admits every initial target and rejects every redirect hop, so the
      // joiner passes its own check while the shared request is rejected.
      final policy = RequestPolicy(
        cachePartition: 'no-redirects',
        targetValidator: (target) => target.stage == RequestTargetStage.redirect
            ? const RequestPolicyDecision.reject('redirects are not allowed')
            : const RequestPolicyDecision.allow(),
      );
      final client = makeClient(fetcher: fetcher);
      addTearDown(client.dispose);
      final fetchOptions = FetchOptions(
        stopAfterHead: false,
        requestPolicy: policy,
      );

      final leader = client.extract(url.toString(), fetchOptions: fetchOptions);
      final joiner = client.extract(url.toString(), fetchOptions: fetchOptions);
      final results = await Future.wait([leader, joiner]);

      expect(
        results.map((result) => result.primaryError?.reason),
        everyElement(MetaLinkErrorReason.policyRejected),
      );
      expect(fetcher.requests, hasLength(1));
    });

    test(
      'callers each passing RequestPolicy.secure() share a redirect rejection',
      () async {
        final fetcher = FakeFetcher();
        final url = Uri.parse('https://example.com/to-loopback');
        fetcher.registerGetResponse(
          url,
          FakeFetcher.buildResponse(
            url: url,
            statusCode: 302,
            headers: const {'location': 'http://127.0.0.1/'},
          ),
        );
        final client = makeClient(fetcher: fetcher);
        addTearDown(client.dispose);

        final results = await Future.wait([
          for (var i = 0; i < 4; i++)
            client.extract(
              url.toString(),
              fetchOptions: FetchOptions(
                stopAfterHead: false,
                requestPolicy: RequestPolicy.secure(),
              ),
            ),
        ]);

        expect(fetcher.requests, hasLength(1));
        expect(
          results.map((result) => result.primaryError?.reason),
          everyElement(MetaLinkErrorReason.policyRejected),
        );
      },
    );

    test(
      'a joiner with a different secure policy object retries a rejection',
      () async {
        final fetcher = FakeFetcher();
        final url = Uri.parse('https://example.com/to-loopback-custom');
        fetcher.registerGetResponse(
          url,
          FakeFetcher.buildResponse(
            url: url,
            statusCode: 302,
            headers: const {'location': 'http://127.0.0.1/'},
          ),
        );
        final client = makeClient(fetcher: fetcher);
        addTearDown(client.dispose);

        final leader = client.extract(
          url.toString(),
          fetchOptions: FetchOptions(
            stopAfterHead: false,
            requestPolicy: RequestPolicy.secure(),
          ),
        );
        // Keeps the default 'secure' partition, so it joins the leader, but
        // its validator differs and so may admit what the leader rejected.
        final joiner = client.extract(
          url.toString(),
          fetchOptions: FetchOptions(
            stopAfterHead: false,
            requestPolicy: RequestPolicy.secure(
              additionalValidator: (_) => const RequestPolicyDecision.allow(),
            ),
          ),
        );
        final results = await Future.wait([leader, joiner]);

        expect(fetcher.requests, hasLength(2));
        expect(
          results.map((result) => result.primaryError?.reason),
          everyElement(MetaLinkErrorReason.policyRejected),
        );
      },
    );

    test('a joiner does not retry after a per-attempt timeout', () async {
      // The server never answers. HttpFetcher enforces FetchOptions.timeout,
      // so the shared attempt ends long before the total deadline.
      final httpClient = RecordingHttpClient(
        handler: (_) => Completer<http.StreamedResponse>().future,
      );
      final client = MetaLinkClient(
        httpClient: httpClient,
        options: const MetaLinkClientOptions(
          fetch: FetchOptions(
            stopAfterHead: false,
            timeout: Duration(milliseconds: 100),
            totalTimeout: Duration(seconds: 30),
          ),
          cache: CacheOptions(enabled: false),
        ),
      );
      addTearDown(client.dispose);
      const url = 'https://example.com/attempt-timeout';

      final leader = client.extract(url);
      final joiner = client.extract(url);
      final results = await Future.wait([leader, joiner])
          .timeout(const Duration(seconds: 10));

      expect(
        results.map((result) => result.primaryError?.code),
        everyElement(MetaLinkErrorCode.timeout),
      );
      expect(httpClient.requests, hasLength(1));
    });

    test('a joining caller is checked by its own request policy', () async {
      final fetcher = FakeFetcher();
      final url = Uri.parse('https://example.com/coalesced-policy');
      final release = Completer<void>();
      registerGatedPage(fetcher, url, release.future);
      final client = makeClient(fetcher: fetcher);
      addTearDown(client.dispose);
      var joinerValidations = 0;

      final leader = client.extract(
        url.toString(),
        fetchOptions: FetchOptions(
          stopAfterHead: false,
          requestPolicy: RequestPolicy.secure(),
        ),
      );
      await Future<void>.delayed(Duration.zero);
      final joiner = client.extract(
        url.toString(),
        fetchOptions: FetchOptions(
          stopAfterHead: false,
          // Keeps the default 'secure' partition, so both callers share one
          // in-flight signature even though their admission rules differ.
          requestPolicy: RequestPolicy.secure(
            additionalValidator: (_) {
              joinerValidations++;
              return const RequestPolicyDecision.reject('joiner rejects');
            },
          ),
        ),
      );
      release.complete();
      final leaderResult = await leader;
      final joinerResult = await joiner;

      expect(leaderResult.metadata.title, 'Shared');
      expect(joinerValidations, 1);
      expect(joinerResult.primaryError?.code, MetaLinkErrorCode.network);
      expect(
        joinerResult.primaryError?.reason,
        MetaLinkErrorReason.policyRejected,
      );
      expect(joinerResult.primaryError?.message, 'joiner rejects');
      expect(joinerResult.metadata.title, isNull);
      expect(fetcher.requests, hasLength(1));
    });

    test('a joining caller whose policy allows shares the request', () async {
      final fetcher = FakeFetcher();
      final url = Uri.parse('https://example.com/coalesced-policy-allowed');
      final release = Completer<void>();
      registerGatedPage(fetcher, url, release.future);
      final client = makeClient(fetcher: fetcher);
      addTearDown(client.dispose);
      var joinerValidations = 0;

      final leader = client.extract(
        url.toString(),
        fetchOptions: FetchOptions(
          stopAfterHead: false,
          requestPolicy: RequestPolicy.secure(),
        ),
      );
      await Future<void>.delayed(Duration.zero);
      final joiner = client.extract(
        url.toString(),
        fetchOptions: FetchOptions(
          stopAfterHead: false,
          requestPolicy: RequestPolicy.secure(
            additionalValidator: (_) {
              joinerValidations++;
              return const RequestPolicyDecision.allow();
            },
          ),
        ),
      );
      await Future<void>.delayed(Duration.zero);
      release.complete();
      final results = await Future.wait([leader, joiner]);

      expect(
        results.map((result) => result.metadata.title),
        everyElement('Shared'),
      );
      expect(joinerValidations, 1);
      expect(fetcher.requests, hasLength(1));
    });

    test('a late joiner retries after the total deadline expires', () async {
      final fetcher = FakeFetcher();
      final url = Uri.parse('https://example.com/coalesced-deadline');
      // Every request made before this point is answered at t=650 ms.
      final serverReady = Future<void>.delayed(
        const Duration(milliseconds: 650),
      );
      registerGatedPage(fetcher, url, serverReady, title: 'Late');
      final client = MetaLinkClient(
        fetcher: fetcher,
        options: const MetaLinkClientOptions(
          fetch: FetchOptions(
            stopAfterHead: false,
            totalTimeout: Duration(milliseconds: 600),
          ),
          cache: CacheOptions(enabled: false),
        ),
      );
      addTearDown(client.dispose);

      // The leader's total deadline expires at t=600 ms, before the server
      // answers. The joiner's own deadline is at least t=750 ms.
      final leader = client.extract(url.toString());
      await Future<void>.delayed(const Duration(milliseconds: 150));
      final joiner = client.extract(url.toString());
      final leaderResult = await leader;
      final joinerResult = await joiner;

      expect(leaderResult.primaryError?.code, MetaLinkErrorCode.timeout);
      expect(joinerResult.errors, isEmpty);
      expect(joinerResult.metadata.title, 'Late');
      expect(fetcher.requests, hasLength(2));
    });

    test('a joined failure that is not a timeout is not retried', () async {
      final fetcher = FakeFetcher();
      final url = Uri.parse('https://example.com/coalesced-http-error');
      final release = Completer<void>();
      fetcher.registerGet(url, (request) async {
        await release.future;
        return FakeFetcher.buildResponse(
          url: request.url,
          statusCode: 503,
          headers: const {'content-type': 'text/html; charset=utf-8'},
          bodyText: '<title>Unavailable</title>',
        );
      });
      final client = makeClient(fetcher: fetcher);
      addTearDown(client.dispose);

      final leader = client.extract(url.toString());
      final joiner = client.extract(url.toString());
      await Future<void>.delayed(Duration.zero);
      release.complete();
      final results = await Future.wait([leader, joiner]);

      expect(
        results.map((result) => result.primaryError?.code),
        everyElement(MetaLinkErrorCode.httpStatus),
      );
      expect(fetcher.requests, hasLength(1));
    });

    test(
      'coalesced callers receive independent metadata collections',
      () async {
        final fetcher = FakeFetcher();
        final url = Uri.parse('https://example.com/coalesced-rich');
        final release = Completer<void>();
        const html = '''
<html lang="en"><head>
<title>Rich page</title>
<link rel="canonical" href="https://example.com/rich-canonical">
<meta property="og:title" content="Rich title">
<meta property="og:description" content="Rich description">
<meta property="og:site_name" content="Example Site">
<meta property="og:locale" content="en_US">
<meta property="og:type" content="article">
<meta property="og:image" content="https://example.com/a.png">
<meta property="og:image" content="https://example.com/b.png">
<meta property="og:video" content="https://example.com/v.mp4">
<meta property="og:audio" content="https://example.com/a.mp3">
<meta property="article:published_time" content="2024-01-02T03:04:05Z">
<meta property="article:modified_time" content="2024-02-03T04:05:06Z">
<meta name="author" content="Ada">
<meta name="keywords" content="alpha, beta">
<link rel="icon" href="https://example.com/favicon.ico">
<link rel="manifest" href="https://example.com/site.webmanifest">
<link rel="alternate" type="application/json+oembed"
  href="https://example.com/oembed.json">
<script type="application/ld+json">
{"@context":"https://schema.org","@type":"Article","headline":"LD"}
</script>
</head><body></body></html>''';
        fetcher.registerGet(url, (request) async {
          await release.future;
          return FakeFetcher.buildResponse(
            url: request.url,
            headers: const {'content-type': 'text/html; charset=utf-8'},
            bodyText: html,
          );
        });
        final oembedUrl = Uri.parse('https://example.com/oembed.json');
        fetcher.registerGetResponse(
          oembedUrl,
          FakeFetcher.buildResponse(
            url: oembedUrl,
            headers: const {'content-type': 'application/json'},
            bodyText:
                '{"version":"1.0","type":"rich","title":"OE","html":"<b>"}',
          ),
        );
        final manifestUrl = Uri.parse('https://example.com/site.webmanifest');
        fetcher.registerGetResponse(
          manifestUrl,
          FakeFetcher.buildResponse(
            url: manifestUrl,
            headers: const {'content-type': 'application/manifest+json'},
            bodyText: '{"name":"App","icons":[{"src":"/i.png","sizes":"1x1"}]}',
          ),
        );
        final client = MetaLinkClient(
          fetcher: fetcher,
          options: const MetaLinkClientOptions(
            fetch: FetchOptions(stopAfterHead: false),
            extract: ExtractOptions(
              enableOEmbed: true,
              enableManifest: true,
              includeRawMetadata: true,
            ),
            cache: CacheOptions(enabled: false),
          ),
        );
        addTearDown(client.dispose);

        final callers = [
          for (var i = 0; i < 3; i++) client.extract(url.toString()),
        ];
        await Future<void>.delayed(Duration.zero);
        release.complete();
        final [leader, joiner, otherJoiner] = await Future.wait(callers);

        expect(
          fetcher.requests.where((request) => request.url == url),
          hasLength(1),
        );
        // Every LinkMetadata field is populated, so a field the copy drops
        // would show up as a difference below.
        final metadata = leader.metadata;
        expect(metadata.canonicalUrl, isNotNull);
        expect(metadata.title, isNotNull);
        expect(metadata.description, isNotNull);
        expect(metadata.siteName, isNotNull);
        expect(metadata.locale, isNotNull);
        expect(metadata.kind, LinkKind.article);
        expect(metadata.images, hasLength(2));
        expect(metadata.icons, isNotEmpty);
        expect(metadata.videos, isNotEmpty);
        expect(metadata.audios, isNotEmpty);
        expect(metadata.publishedAt, isNotNull);
        expect(metadata.modifiedAt, isNotNull);
        expect(metadata.author, isNotNull);
        expect(metadata.keywords, isNotEmpty);
        expect(metadata.oembed, isNotNull);
        expect(metadata.manifest, isNotNull);
        expect(metadata.structuredData, isNotNull);
        expect(leader.diagnostics.fieldProvenance, isNotEmpty);
        expect(leader.diagnostics.itemProvenance, isNotEmpty);
        expect(leader.diagnostics.candidateDecisions, isNotEmpty);
        expect(leader.raw?.meta, isNotEmpty);
        expect(leader.raw?.links, isNotEmpty);

        String snapshot(ExtractionResult<LinkMetadata> result) => jsonEncode({
          'metadata': result.metadata.toJson(),
          'diagnostics': result.diagnostics.toJson(),
          'raw': result.raw?.toJson(),
        });
        final leaderSnapshot = snapshot(leader);
        expect(snapshot(joiner), leaderSnapshot);
        expect(snapshot(otherJoiner), leaderSnapshot);

        // UI code commonly reorders or edits these collections in place.
        leader.metadata.images.sort(
          (a, b) => b.url.toString().compareTo(a.url.toString()),
        );
        leader.metadata.keywords.add('leader');
        leader.metadata.icons.clear();
        leader.diagnostics.fieldProvenance.clear();
        leader.diagnostics.itemProvenance.clear();
        leader.diagnostics.candidateDecisions.clear();
        leader.raw!.meta.clear();
        joiner.metadata.images.clear();
        joiner.metadata.keywords.add('joiner');
        joiner.metadata.videos.clear();
        joiner.metadata.audios.clear();
        joiner.raw!.links.clear();

        expect(snapshot(otherJoiner), leaderSnapshot);
        expect(leader.metadata.images, hasLength(2));
        expect(leader.metadata.keywords, isNot(contains('joiner')));
        expect(leader.metadata.videos, isNotEmpty);
        expect(leader.raw!.links, isNotEmpty);
        expect(joiner.metadata.keywords, isNot(contains('leader')));
        expect(joiner.metadata.icons, isNotEmpty);
        expect(joiner.diagnostics.fieldProvenance, isNotEmpty);
        expect(joiner.diagnostics.candidateDecisions, isNotEmpty);
        for (final field in otherJoiner.diagnostics.candidateDecisions.keys) {
          expect(
            identical(
              joiner.diagnostics.candidateDecisions[field],
              otherJoiner.diagnostics.candidateDecisions[field],
            ),
            isFalse,
          );
        }
      },
    );

    test('coalesced callers receive independent result objects', () async {
      final fetcher = FakeFetcher();
      final url = Uri.parse('https://example.com/coalesced-results');
      final release = Completer<void>();
      registerGatedPage(fetcher, url, release.future);
      final client = makeClient(fetcher: fetcher);
      addTearDown(client.dispose);

      final first = client.extract(url.toString(), skipCache: true);
      final second = client.extract(url.toString(), skipCache: true);
      await Future<void>.delayed(Duration.zero);
      release.complete();
      final a = await first;
      final b = await second;

      expect(fetcher.requests, hasLength(1));
      expect(identical(a, b), isFalse);
      expect(a.warnings.map((warning) => warning.code), [
        MetaLinkWarningCode.cacheBypassed,
      ]);
      expect(b.warnings.map((warning) => warning.code), [
        MetaLinkWarningCode.cacheBypassed,
      ]);

      a.warnings.add(
        const MetaLinkWarning(
          code: MetaLinkWarningCode.partialParse,
          message: 'added by the first caller',
        ),
      );
      a.errors.add(
        const MetaLinkError(
          code: MetaLinkErrorCode.unknown,
          message: 'added by the first caller',
        ),
      );
      b.warnings.clear();

      expect(a.warnings, hasLength(2));
      expect(a.errors, hasLength(1));
      expect(b.warnings, isEmpty);
      expect(b.errors, isEmpty);
    });

    group('nested collections stay with the caller that edits them', () {
      final start = Uri.parse('https://example.com/nested-start');
      final page = Uri.parse('https://example.com/nested');
      final manifestUrl = Uri.parse('https://example.com/manifest.json');

      // A redirecting page with JSON-LD, a manifest, and an image, so the
      // result holds every nested collection a caller can edit. With
      // [cached], the shared work is a hit on a full cache entry, whose
      // decoded collections are all growable.
      MetaLinkClient nestedClient(FakeFetcher fetcher, {required bool cached}) {
        fetcher
          ..registerGetResponse(
            start,
            FakeFetcher.buildResponse(
              url: start,
              statusCode: 301,
              headers: {'location': page.toString()},
            ),
          )
          ..registerGetResponse(
            page,
            FakeFetcher.buildResponse(
              url: page,
              headers: const {'content-type': 'text/html; charset=utf-8'},
              bodyText:
                  '<title>Nested</title>'
                  '<link rel="manifest" href="/manifest.json">'
                  '<meta property="og:image" '
                  'content="https://example.com/a.png">'
                  '<script type="application/ld+json">'
                  '{"@context":"https://schema.org","@type":"Article",'
                  '"headline":"Headline",'
                  '"author":{"@type":"Person","name":"Ann"},'
                  '"about":[{"name":"First"},{"name":"Second"}]}'
                  '</script>',
            ),
          )
          ..registerGetResponse(
            manifestUrl,
            FakeFetcher.buildResponse(
              url: manifestUrl,
              headers: const {'content-type': 'application/manifest+json'},
              bodyText:
                  '{"name":"App","icons":'
                  '[{"src":"/icon.png","sizes":"192x192"}]}',
            ),
          );
        return MetaLinkClient(
          fetcher: fetcher,
          cacheStore: cached ? MemoryCacheStore() : null,
          options: MetaLinkClientOptions(
            fetch: const FetchOptions(stopAfterHead: false),
            extract: const ExtractOptions(enableManifest: true),
            cache: cached
                ? const CacheOptions(
                    payloadKind: CachePayloadKind.extractionResult,
                  )
                : const CacheOptions(enabled: false),
          ),
        );
      }

      Map<String, dynamic> firstNode(ExtractionResult<LinkMetadata> result) {
        return result.metadata.structuredData!.nodes.first;
      }

      // Each path edits one nested collection in place and reads it back.
      final paths =
          <
            String,
            ({
              void Function(ExtractionResult<LinkMetadata> result) edit,
              Object? Function(ExtractionResult<LinkMetadata> result) read,
            })
          >{
            'a structuredData node map': (
              edit: (result) => firstNode(result)['headline'] = 'Edited',
              read: (result) => firstNode(result)['headline'],
            ),
            'a map nested in a structuredData node': (
              edit: (result) =>
                  (firstNode(result)['author'] as Map)['name'] = 'Edited',
              read: (result) => (firstNode(result)['author'] as Map)['name'],
            ),
            'a map in a list nested in a structuredData node': (
              edit: (result) {
                final about = firstNode(result)['about'] as List;
                (about.first as Map)['name'] = 'Edited';
                about.add('appended');
              },
              read: (result) => (firstNode(result)['about'] as List)
                  .map((item) => item is Map ? item['name'] : item)
                  .toList(),
            ),
            'the manifest icons': (
              edit: (result) => result.metadata.manifest!.icons[0] =
                  ManifestIcon(src: Uri.parse('https://example.com/edited')),
              read: (result) =>
                  result.metadata.manifest!.icons.single.src.toString(),
            ),
            'the fetch redirects': (
              edit: (result) => result.diagnostics.fetch!.redirects[0] =
                  RedirectHop(from: page, to: page, statusCode: 399),
              read: (result) =>
                  result.diagnostics.fetch!.redirects.single.statusCode,
            ),
            'the item provenance contributors': (
              edit: (result) =>
                  result
                      .diagnostics
                      .itemProvenance[MetaField.images]!
                      .single
                      .contributors[0] = const FieldProvenance(
                    source: CandidateSource.heuristic,
                    score: 0,
                  ),
              read: (result) => result
                  .diagnostics
                  .itemProvenance[MetaField.images]!
                  .single
                  .contributors
                  .single
                  .source,
            ),
          };

      for (final (source, cached) in [
        ('a fetch', false),
        ('a full cache hit', true),
      ]) {
        for (final MapEntry(key: name, value: path) in paths.entries) {
          for (final (direction, editor) in [
            ('from the leader to its joiners', 0),
            ('from a joiner to the leader and other joiners', 1),
          ]) {
            test(
              'editing $name $direction stays local after $source',
              () async {
                final fetcher = FakeFetcher();
                final client = nestedClient(fetcher, cached: cached);
                addTearDown(client.dispose);
                if (cached) await client.extract(start.toString());

                final results = await Future.wait([
                  for (var i = 0; i < 3; i++) client.extract(start.toString()),
                ]);

                expect(
                  fetcher.requests.where((request) => request.url == start),
                  hasLength(1),
                );
                expect(
                  results.map((result) => result.diagnostics.cacheHit),
                  everyElement(cached),
                );
                final pristine = path.read(results[editor]);
                path.edit(results[editor]);
                expect(path.read(results[editor]), isNot(pristine));
                for (var i = 0; i < results.length; i++) {
                  if (i == editor) continue;
                  expect(path.read(results[i]), pristine, reason: 'caller $i');
                }
              },
            );
          }
        }
      }

      test('every caller of shared work receives every field', () async {
        const extractOptions = ExtractOptions(
          enableManifest: true,
          includeRawMetadata: true,
        );
        final fetcher = FakeFetcher();
        final client = nestedClient(fetcher, cached: false);
        addTearDown(client.dispose);

        final shared = await Future.wait([
          client.extract(start.toString(), extractOptions: extractOptions),
          client.extract(start.toString(), extractOptions: extractOptions),
        ]);
        final solo = await client.extract(
          start.toString(),
          extractOptions: extractOptions,
        );

        // Timings differ between runs, so they are left out.
        String encode(ExtractionResult<LinkMetadata> result) => jsonEncode({
          'metadata': result.metadata.toJson(),
          'diagnostics': {
            ...result.diagnostics.toJson(),
            'totalTimeMs': null,
            'fetch': {...?result.diagnostics.fetch?.toJson(), 'durationMs': 0},
          },
          'raw': result.raw?.toJson(),
          'warnings': [for (final w in result.warnings) w.toJson()],
          'errors': [for (final e in result.errors) e.toJson()],
          'status': result.status.name,
          'completeness': result.completeness,
        });

        expect(shared.first.metadata.manifest, isNotNull);
        expect(shared.first.raw, isNotNull);
        for (final result in shared) {
          expect(encode(result), encode(solo));
        }
      });

      test(
        'deeply nested structuredData is copied without recursion',
        () async {
          const depth = 200000;
          Object? deep = <dynamic>['bottom'];
          for (var i = 0; i < depth; i++) {
            deep = <dynamic>[deep];
          }
          final url = Uri.parse('https://example.com/deep');
          final cache = _SeededCacheStore(
            entry: CacheEntry(
              kind: CachePayloadKind.linkMetadata,
              createdAtMs: DateTime.now().millisecondsSinceEpoch,
              ttlMs: 60000,
              payload: <String, dynamic>{
                'originalUrl': url.toString(),
                'resolvedUrl': url.toString(),
                'structuredData': <String, dynamic>{
                  'nodes': <dynamic>[
                    <String, dynamic>{'@type': 'Thing', 'deep': deep},
                  ],
                },
              },
            ),
          );
          final client = MetaLinkClient(
            fetcher: FakeFetcher(),
            cacheStore: cache,
            options: const MetaLinkClientOptions(
              fetch: FetchOptions(stopAfterHead: false),
            ),
          );
          addTearDown(client.dispose);

          List<dynamic> bottom(ExtractionResult<LinkMetadata> result) {
            var current = firstNode(result)['deep'] as List;
            while (current.first is List) {
              current = current.first as List;
            }
            return current;
          }

          final results = await Future.wait([
            client.extract(url.toString()),
            client.extract(url.toString()),
          ]);
          bottom(results[1])[0] = 'edited';

          expect(results.first.diagnostics.cacheHit, isTrue);
          expect(bottom(results[0]), ['bottom']);
          expect(bottom(results[1]), ['edited']);
        },
      );
    });
  });

  group('cache payloads and stores', () {
    Map<String, dynamic> cachedMetadataJson(Uri url, String title) {
      return <String, dynamic>{
        'originalUrl': url.toString(),
        'resolvedUrl': url.toString(),
        'title': title,
        'images': <dynamic>[],
        'icons': <dynamic>[],
        'videos': <dynamic>[],
        'audios': <dynamic>[],
        'keywords': <dynamic>[],
      };
    }

    void registerPage(FakeFetcher fetcher, Uri url, String title) {
      fetcher.registerGetResponse(
        url,
        FakeFetcher.buildResponse(
          url: url,
          statusCode: 200,
          headers: const {'content-type': 'text/html; charset=utf-8'},
          bodyText: '<title>$title</title>',
        ),
      );
    }

    test(
      'cache operation warnings are not persisted in full payloads',
      () async {
        final fetcher = FakeFetcher();
        final url = Uri.parse('https://example.com/persisted-warnings');
        registerPage(fetcher, url, 'Persisted');
        final cache = _FailFirstReadCacheStore();
        final client = MetaLinkClient(
          fetcher: fetcher,
          cacheStore: cache,
          options: const MetaLinkClientOptions(
            fetch: FetchOptions(stopAfterHead: false),
            cache: CacheOptions(payloadKind: CachePayloadKind.extractionResult),
          ),
        );
        addTearDown(client.dispose);

        final first = await client.extract(url.toString());
        final second = await client.extract(url.toString());

        expect(
          first.warnings.map((warning) => warning.code),
          contains(MetaLinkWarningCode.cacheReadFailed),
        );
        final persisted = cache.written.single.payload['warnings']! as List;
        expect(persisted, isEmpty);
        expect(second.diagnostics.cacheHit, isTrue);
        expect(second.metadata.title, 'Persisted');
        expect(second.warnings, isEmpty);
      },
    );

    test('cache hits drop stale cache operation warnings', () async {
      final fetcher = FakeFetcher();
      final url = Uri.parse('https://example.com/legacy-warnings');
      final cache = _SeededCacheStore(
        entry: CacheEntry(
          kind: CachePayloadKind.extractionResult,
          createdAtMs: DateTime.now().millisecondsSinceEpoch,
          ttlMs: 60000,
          payload: <String, dynamic>{
            'metadata': cachedMetadataJson(url, 'Legacy'),
            'diagnostics': const <String, dynamic>{
              'cacheHit': false,
              'totalTimeMs': 1,
              'fetch': null,
            },
            'raw': null,
            'warnings': <dynamic>[
              const MetaLinkWarning(
                code: MetaLinkWarningCode.cacheReadFailed,
                message: 'Cache read failed; proceeding without cache.',
              ).toJson(),
              const MetaLinkWarning(
                code: MetaLinkWarningCode.truncatedHtml,
                message: 'HTML response was truncated.',
              ).toJson(),
            ],
            'errors': <dynamic>[],
            'status': 'partial',
            'completeness': null,
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
      addTearDown(client.dispose);

      final result = await client.extract(url.toString());

      expect(result.diagnostics.cacheHit, isTrue);
      expect(result.warnings.map((warning) => warning.code), [
        MetaLinkWarningCode.truncatedHtml,
      ]);
      expect(fetcher.requests, isEmpty);
    });

    for (final (label, status, cachedErrors, completeness)
        in <(String, String, List<dynamic>, double?)>[
          ('a failure status with no errors', 'failure', <dynamic>[], null),
          (
            'a failure status with no decodable errors',
            'failure',
            <dynamic>[42, 'not an error object'],
            null,
          ),
          ('an out-of-range completeness', 'success', <dynamic>[], 1.5),
        ]) {
      test('a cached result with $label is a cache miss', () async {
        final fetcher = FakeFetcher();
        final url = Uri.parse('https://example.com/inconsistent-failure');
        registerPage(fetcher, url, 'Fresh');
        final logs = <MetaLinkLogRecord>[];
        final cache = _SeededCacheStore(
          entry: CacheEntry(
            kind: CachePayloadKind.extractionResult,
            createdAtMs: DateTime.now().millisecondsSinceEpoch,
            ttlMs: 60000,
            payload: <String, dynamic>{
              'metadata': cachedMetadataJson(url, 'Inconsistent'),
              'diagnostics': const <String, dynamic>{
                'cacheHit': false,
                'totalTimeMs': 1,
                'fetch': null,
              },
              'raw': null,
              'warnings': <dynamic>[],
              'errors': cachedErrors,
              'status': status,
              'completeness': completeness,
            },
          ),
        );
        final client = MetaLinkClient(
          fetcher: fetcher,
          cacheStore: cache,
          logSink: logs.add,
          options: const MetaLinkClientOptions(
            fetch: FetchOptions(stopAfterHead: false),
            cache: CacheOptions(payloadKind: CachePayloadKind.extractionResult),
          ),
        );
        addTearDown(client.dispose);

        final result = await client.extract(url.toString());

        expect(result.diagnostics.cacheHit, isFalse);
        expect(result.metadata.title, 'Fresh');
        expect(result.status, ExtractionStatus.success);
        expect(fetcher.requests, hasLength(1));
        // The entry must be rejected by an explicit check that also runs in
        // release builds, not by the constructor assertion that only debug
        // builds evaluate.
        expect(logs.where((record) => record.error is AssertionError), isEmpty);
      });
    }

    test('injected store gives a nonpositive ttl the store default', () async {
      final fetcher = FakeFetcher();
      final url = Uri.parse('https://example.com/injected-store-default');
      registerPage(fetcher, url, 'Injected');
      const storeDefault = Duration(hours: 1);
      final cache = _AgingCacheStore(
        MemoryCacheStore(defaultTtl: storeDefault),
      );
      final client = MetaLinkClient(
        fetcher: fetcher,
        cacheStore: cache,
        options: const MetaLinkClientOptions(
          fetch: FetchOptions(stopAfterHead: false),
          cache: CacheOptions(ttl: Duration.zero),
        ),
      );
      addTearDown(client.dispose);

      final first = await client.extract(url.toString());
      final stored = (await cache.delegate.read(cache.writtenKeys.single))
          .entry;
      final second = await client.extract(url.toString());
      // Ages served entries past the store default instead of sleeping, so
      // neither the hit nor the expiry depends on scheduling.
      cache.age = storeDefault + const Duration(minutes: 1);
      final third = await client.extract(url.toString());

      expect(stored?.lifetime.kind, CacheLifetimeKind.expiresAfter);
      expect(stored?.lifetime.duration, storeDefault);
      expect(first.diagnostics.cacheHit, isFalse);
      expect(second.diagnostics.cacheHit, isTrue);
      expect(third.diagnostics.cacheHit, isFalse);
      expect(fetcher.requests, hasLength(2));
    });

    test('cache signatures carry the 2.2 engine tag', () async {
      final fetcher = FakeFetcher();
      final url = Uri.parse('https://example.com/engine-tag');
      registerPage(fetcher, url, 'Fresh');
      // The persisted cache signature for this URL and the default options,
      // differing only in the engine tag.
      String signature(String engine) {
        final policy = const RequestPolicy().cacheIdentity;
        return <String>[
          'engine=$engine',
          url.toString(),
          'linkMetadata',
          <String>[
            'ua0:',
            'fr1',
            'mr5',
            'mb${512 * 1024}',
            'sh0',
            'px0:',
            'policy${policy.length}:$policy',
            'h0:',
          ].join(','),
          'og1,tw1,sm1,lr1,jl1,oe0,wm0,raw0,img10,ico10,vid5,aud5',
        ].join('|');
      }

      final legacyKey = CacheKeyBuilder.buildForString(signature('2.1'));
      final cache = _KeyedCacheStore(<String, CacheEntry>{
        legacyKey: CacheEntry(
          kind: CachePayloadKind.linkMetadata,
          createdAtMs: DateTime.now().millisecondsSinceEpoch,
          ttlMs: const Duration(hours: 1).inMilliseconds,
          payload: cachedMetadataJson(url, 'Written by 2.1.0'),
        ),
      });
      final tagged = MetaLinkClient(
        fetcher: fetcher,
        cacheStore: cache,
        options: const MetaLinkClientOptions(
          fetch: FetchOptions(stopAfterHead: false),
        ),
      );
      addTearDown(tagged.dispose);

      final result = await tagged.extract(url.toString());

      // An entry persisted under the 2.1.0 key must not be served.
      expect(result.diagnostics.cacheHit, isFalse);
      expect(result.metadata.title, 'Fresh');
      expect(cache.readKeys, [
        CacheKeyBuilder.buildForString(signature('2.2')),
      ]);
    });

    test('per-request cache enablement creates an owned store', () async {
      final fetcher = FakeFetcher();
      final url = Uri.parse('https://example.com/on-demand-store');
      registerPage(fetcher, url, 'On demand');
      final client = MetaLinkClient(
        fetcher: fetcher,
        options: const MetaLinkClientOptions(
          fetch: FetchOptions(stopAfterHead: false),
          cache: CacheOptions(enabled: false, ttl: Duration.zero),
        ),
      );
      const perRequest = CacheOptions();

      final first = await client.extract(
        url.toString(),
        cacheOptions: perRequest,
      );
      final second = await client.extract(
        url.toString(),
        cacheOptions: perRequest,
      );
      final clientDefault = await client.extract(url.toString());

      expect(first.diagnostics.cacheHit, isFalse);
      expect(second.diagnostics.cacheHit, isTrue);
      expect(second.metadata.title, 'On demand');
      expect(clientDefault.diagnostics.cacheHit, isFalse);
      expect(fetcher.requests, hasLength(2));

      await client.dispose();
    });

    test('concurrent requests share one on-demand store', () async {
      final fetcher = FakeFetcher();
      final release = Completer<void>();
      final urls = [
        Uri.parse('https://example.com/on-demand-a'),
        Uri.parse('https://example.com/on-demand-b'),
      ];
      for (final url in urls) {
        fetcher.registerGet(url, (request) async {
          await release.future;
          return FakeFetcher.buildResponse(
            url: request.url,
            statusCode: 200,
            headers: const {'content-type': 'text/html; charset=utf-8'},
            bodyText: '<title>${request.url.path}</title>',
          );
        });
      }
      final client = MetaLinkClient(
        fetcher: fetcher,
        options: const MetaLinkClientOptions(
          fetch: FetchOptions(stopAfterHead: false),
          cache: CacheOptions(enabled: false),
        ),
      );
      addTearDown(client.dispose);
      const perRequest = CacheOptions();

      final firstPass = Future.wait([
        for (final url in urls)
          client.extract(url.toString(), cacheOptions: perRequest),
      ]);
      await Future<void>.delayed(Duration.zero);
      release.complete();
      await firstPass;
      final secondPass = await Future.wait([
        for (final url in urls)
          client.extract(url.toString(), cacheOptions: perRequest),
      ]);

      expect(
        secondPass.map((result) => result.diagnostics.cacheHit),
        everyElement(isTrue),
      );
      expect(fetcher.requests, hasLength(2));
    });
  });

  test('extractBatch starts no more workers than URLs', () async {
    final url = Uri.parse('https://example.com/single-batch-item');

    Future<int> microtasksFor(int concurrency) async {
      final fetcher = FakeFetcher();
      fetcher.registerGetResponse(
        url,
        FakeFetcher.buildResponse(
          url: url,
          statusCode: 200,
          headers: const {'content-type': 'text/html; charset=utf-8'},
          bodyText: '<title>One</title>',
        ),
      );
      final client = MetaLinkClient(
        fetcher: fetcher,
        options: const MetaLinkClientOptions(
          fetch: FetchOptions(stopAfterHead: false),
          cache: CacheOptions(enabled: false),
        ),
      );
      var scheduled = 0;
      final results = await runZoned(
        () => client.extractBatch([url.toString()], concurrency: concurrency),
        zoneSpecification: ZoneSpecification(
          scheduleMicrotask: (self, parent, zone, task) {
            scheduled++;
            parent.scheduleMicrotask(zone, task);
          },
        ),
      );
      await client.dispose();
      expect(results.single.metadata.title, 'One');
      return scheduled;
    }

    final oneWorker = await microtasksFor(1);
    final manyWorkers = await microtasksFor(1 << 16);

    // Idle workers each schedule completion work, so any surplus worker
    // shows up as additional microtasks.
    expect(manyWorkers, oneWorker);
  });

  test('a proxy misconfiguration is a non-retryable rejection', () async {
    final fetcher = FakeFetcher();
    final client = makeClient(fetcher: fetcher);
    addTearDown(client.dispose);

    final result = await client.extract(
      'https://example.com/proxied',
      fetchOptions: const FetchOptions(
        stopAfterHead: false,
        proxyUrl: 'not a proxy',
      ),
    );

    expect(result.primaryError?.code, MetaLinkErrorCode.network);
    expect(result.primaryError?.reason, MetaLinkErrorReason.policyRejected);
    expect(result.primaryError?.isRetryable, isFalse);
    expect(result.retryable, isFalse);
    expect(fetcher.requests, isEmpty);
  });
}

class _FailFirstReadCacheStore implements CacheStore {
  final MemoryCacheStore _delegate = MemoryCacheStore();
  final List<CacheEntry> written = <CacheEntry>[];
  var _reads = 0;

  @override
  Future<CacheReadResult> read(String key) async {
    _reads++;
    if (_reads == 1) {
      return CacheReadResult(entry: null, error: StateError('transient'));
    }
    return _delegate.read(key);
  }

  @override
  Future<CacheWriteResult> write(String key, CacheEntry entry) {
    written.add(entry);
    return _delegate.write(key, entry);
  }

  @override
  Future<CacheOpResult> delete(String key) => _delegate.delete(key);

  @override
  Future<CacheOpResult> clear() => _delegate.clear();

  @override
  Future<CachePurgeResult> purgeExpired() => _delegate.purgeExpired();

  @override
  Future<void> close() => _delegate.close();
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

/// Serves its delegate's entries as if they were [age] older.
class _AgingCacheStore implements CacheStore {
  _AgingCacheStore(this.delegate);

  final CacheStore delegate;
  final List<String> writtenKeys = <String>[];
  Duration age = Duration.zero;

  @override
  Future<CacheReadResult> read(String key) async {
    final read = await delegate.read(key);
    final entry = read.entry;
    if (entry == null || age == Duration.zero) return read;
    return CacheReadResult(
      entry: CacheEntry.withLifetime(
        kind: entry.kind,
        createdAtMs: entry.createdAtMs - age.inMilliseconds,
        lifetime: entry.lifetime,
        payload: entry.payload,
      ),
    );
  }

  @override
  Future<CacheWriteResult> write(String key, CacheEntry entry) {
    writtenKeys.add(key);
    return delegate.write(key, entry);
  }

  @override
  Future<CacheOpResult> delete(String key) => delegate.delete(key);

  @override
  Future<CacheOpResult> clear() => delegate.clear();

  @override
  Future<CachePurgeResult> purgeExpired() => delegate.purgeExpired();

  @override
  Future<void> close() => delegate.close();
}

/// Serves only the entries seeded under their exact keys.
class _KeyedCacheStore implements CacheStore {
  _KeyedCacheStore(this.entries);

  final Map<String, CacheEntry> entries;
  final List<String> readKeys = <String>[];

  @override
  Future<CacheReadResult> read(String key) async {
    readKeys.add(key);
    return CacheReadResult(entry: entries[key]);
  }

  @override
  Future<CacheWriteResult> write(String key, CacheEntry entry) async {
    entries[key] = entry;
    return const CacheWriteResult(ok: true);
  }

  @override
  Future<CacheOpResult> delete(String key) async {
    entries.remove(key);
    return const CacheOpResult(ok: true);
  }

  @override
  Future<CacheOpResult> clear() async {
    entries.clear();
    return const CacheOpResult(ok: true);
  }

  @override
  Future<CachePurgeResult> purgeExpired() async {
    return const CachePurgeResult(ok: true, purged: 0);
  }

  @override
  Future<void> close() async {}
}
