import 'dart:io';

import 'package:metalink/metalink.dart';
import 'package:test/test.dart';

void main() {
  // The static helpers build their own HttpFetcher, so these tests replace
  // dart:io HTTP for their zone: a cache miss then fails loudly instead of
  // reaching the internet.
  late List<Uri> networkAttempts;

  Future<T> withoutNetwork<T>(Future<T> Function() body) {
    networkAttempts = <Uri>[];
    return HttpOverrides.runZoned(
      body,
      createHttpClient: (_) => _RejectingHttpClient(networkAttempts),
    );
  }

  // Far longer than any test run, so a stub entry can never expire into a
  // network request.
  final ttlMs = const Duration(hours: 1).inMilliseconds;

  CacheEntry cachedEntry(Uri url, String title) {
    return CacheEntry(
      kind: CachePayloadKind.linkMetadata,
      createdAtMs: DateTime.now().millisecondsSinceEpoch,
      ttlMs: ttlMs,
      payload: LinkMetadata(
        originalUrl: url,
        resolvedUrl: url,
        title: title,
      ).toJson(),
    );
  }

  test('MetaLink.extract returns cached metadata without network', () async {
    final url = Uri.parse('https://example.com/a');
    final cache = _StubCacheStore(entry: cachedEntry(url, 'Cached'));

    final result = await withoutNetwork(
      () => MetaLink.extract(url.toString(), cacheStore: cache),
    );

    expect(networkAttempts, isEmpty);
    expect(result.metadata.title, 'Cached');
    expect(result.diagnostics.cacheHit, isTrue);
  });

  test('MetaLink.extractBatch returns cached results', () async {
    final url1 = Uri.parse('https://example.com/a');
    final url2 = Uri.parse('https://example.com/b');
    final cache = _StubCacheStore(
      queue: [cachedEntry(url1, 'A'), cachedEntry(url2, 'B')],
    );

    final results = await withoutNetwork(
      () => MetaLink.extractBatch(
        [url1.toString(), url2.toString()],
        cacheStore: cache,
        concurrency: 1,
      ),
    );

    expect(networkAttempts, isEmpty);
    expect(results.length, 2);
    expect(results.first.metadata.title, 'A');
    expect(results.last.metadata.title, 'B');
    expect(results.map((result) => result.diagnostics.cacheHit), [
      isTrue,
      isTrue,
    ]);
  });

  test('MetaLink.extractBatch rejects invalid concurrency', () async {
    expect(
      () => MetaLink.extractBatch(['https://example.com'], concurrency: 0),
      throwsArgumentError,
    );
  });
}

/// A dart:io client that records every request and fails it.
class _RejectingHttpClient implements HttpClient {
  _RejectingHttpClient(this.attempts);

  final List<Uri> attempts;

  @override
  void close({bool force = false}) {}

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) {
    attempts.add(url);
    throw StateError('Hermetic test attempted a network request: $method $url');
  }

  @override
  Never noSuchMethod(Invocation invocation) {
    throw StateError('Unexpected HttpClient use: ${invocation.memberName}');
  }
}

/// Serves one fixed entry, or queued entries in read order.
class _StubCacheStore implements CacheStore {
  _StubCacheStore({this.entry, List<CacheEntry>? queue})
    : _queue = queue ?? <CacheEntry>[];

  final CacheEntry? entry;
  final List<CacheEntry> _queue;

  @override
  Future<CacheReadResult> read(String key) async {
    if (entry != null) {
      return CacheReadResult(entry: entry);
    }
    if (_queue.isEmpty) {
      return const CacheReadResult(entry: null);
    }
    return CacheReadResult(entry: _queue.removeAt(0));
  }

  @override
  Future<CacheWriteResult> write(String key, CacheEntry entry) async {
    _queue.add(entry);
    return const CacheWriteResult(ok: true);
  }

  // Deleting must not consume an entry queued for a later read.
  @override
  Future<CacheOpResult> delete(String key) async {
    return const CacheOpResult(ok: true);
  }

  @override
  Future<CacheOpResult> clear() async {
    _queue.clear();
    return const CacheOpResult(ok: true);
  }

  @override
  Future<CachePurgeResult> purgeExpired() async {
    return const CachePurgeResult(ok: true, purged: 0);
  }

  @override
  Future<void> close() async {}
}
