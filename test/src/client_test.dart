import 'dart:async';

import 'package:metalink/src/cache/cache_store.dart';
import 'package:metalink/src/cache/memory_cache_store.dart';
import 'package:metalink/src/client.dart';
import 'package:metalink/src/model/errors.dart';
import 'package:metalink/src/options.dart';
import 'package:test/test.dart';

import '../support/fake_fetcher.dart';

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

  test('extract returns error when client closed', () async {
    final fetcher = FakeFetcher();
    final client = makeClient(fetcher: fetcher);
    client.close();
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
      FakeFetcher.buildResponse(
        url: url,
        error: TimeoutException('timeout'),
      ),
    );

    final client = makeClient(fetcher: fetcher);
    final result = await client.extract(url.toString());
    expect(result.errors.first.code, MetaLinkErrorCode.timeout);
  });

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
    expect(result.metadata.title, 'Cached');
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
        isTrue);
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
        result.warnings
            .any((w) => w.code == MetaLinkWarningCode.cacheReadFailed),
        isTrue);
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
    client.close();
    final result = await client.optimizeUrl('https://example.com');
    expect(result.error, isNotNull);
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
