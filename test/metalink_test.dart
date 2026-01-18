import 'package:metalink/metalink.dart';
import 'package:test/test.dart';

void main() {
  test('MetaLink.extract returns cached metadata without network', () async {
    final url = Uri.parse('https://example.com/a');
    final cache = _StubCacheStore(
      entry: CacheEntry(
        kind: CachePayloadKind.linkMetadata,
        createdAtMs: DateTime.now().millisecondsSinceEpoch,
        ttlMs: 1000,
        payload: LinkMetadata(
          originalUrl: url,
          resolvedUrl: url,
          title: 'Cached',
        ).toJson(),
      ),
    );

    final result = await MetaLink.extract(
      url.toString(),
      cacheStore: cache,
    );
    expect(result.metadata.title, 'Cached');
    expect(result.diagnostics.cacheHit, isTrue);
  });

  test('MetaLink.extractBatch returns cached results', () async {
    final url1 = Uri.parse('https://example.com/a');
    final url2 = Uri.parse('https://example.com/b');
    final cache = _StubCacheStore(
      queue: [
        CacheEntry(
          kind: CachePayloadKind.linkMetadata,
          createdAtMs: DateTime.now().millisecondsSinceEpoch,
          ttlMs: 1000,
          payload: LinkMetadata(
            originalUrl: url1,
            resolvedUrl: url1,
            title: 'A',
          ).toJson(),
        ),
        CacheEntry(
          kind: CachePayloadKind.linkMetadata,
          createdAtMs: DateTime.now().millisecondsSinceEpoch,
          ttlMs: 1000,
          payload: LinkMetadata(
            originalUrl: url2,
            resolvedUrl: url2,
            title: 'B',
          ).toJson(),
        ),
      ],
    );

    final results = await MetaLink.extractBatch(
      [url1.toString(), url2.toString()],
      cacheStore: cache,
      concurrency: 1,
    );
    expect(results.length, 2);
    expect(results.first.metadata.title, 'A');
    expect(results.last.metadata.title, 'B');
  });

  test('MetaLink.extractBatch rejects invalid concurrency', () async {
    expect(
      () => MetaLink.extractBatch(['https://example.com'], concurrency: 0),
      throwsArgumentError,
    );
  });
}

class _StubCacheStore implements CacheStore {
  _StubCacheStore({
    this.entry,
    List<CacheEntry>? queue,
  }) : _queue = queue ?? <CacheEntry>[];

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

  @override
  Future<CacheOpResult> delete(String key) async {
    if (_queue.isNotEmpty) {
      _queue.removeAt(0);
    }
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
