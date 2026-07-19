import 'package:metalink/src/cache/cache_store.dart';
import 'package:metalink/src/cache/memory_cache_store.dart';
import 'package:test/test.dart';

void main() {
  CacheEntry entry({
    required int createdAtMs,
    required int ttlMs,
    Map<String, dynamic>? payload,
  }) {
    return CacheEntry(
      kind: CachePayloadKind.linkMetadata,
      createdAtMs: createdAtMs,
      ttlMs: ttlMs,
      payload: payload ?? const {},
    );
  }

  test('read/write returns stored entry', () async {
    final store = MemoryCacheStore(keyPrefix: 't:');
    final now = DateTime.now().millisecondsSinceEpoch;
    await store.write('k1', entry(createdAtMs: now, ttlMs: 1000));
    final read = await store.read('k1');
    expect(read.entry, isNotNull);
    expect(read.entry!.ttlMs, 1000);
  });

  test('write and read snapshots nested mutable payloads', () async {
    final store = MemoryCacheStore();
    final now = DateTime.now().millisecondsSinceEpoch;
    final nested = <dynamic>[
      <String, dynamic>{
        'keywords': <dynamic>['original'],
      },
    ];
    final source = entry(
      createdAtMs: now,
      ttlMs: 1000,
      payload: <String, dynamic>{'nested': nested},
    );

    expect((await store.write('snapshot', source)).ok, isTrue);
    (nested.single as Map<String, dynamic>)['keywords'] = <dynamic>['changed'];

    final first = (await store.read('snapshot')).entry!;
    final firstNested = first.payload['nested']! as List<dynamic>;
    final firstMap = firstNested.single as Map<String, dynamic>;
    expect(firstMap['keywords'], <dynamic>['original']);
    (firstMap['keywords']! as List<dynamic>).add('mutated read');

    final second = (await store.read('snapshot')).entry!;
    final secondNested = second.payload['nested']! as List<dynamic>;
    final secondMap = secondNested.single as Map<String, dynamic>;
    expect(secondMap['keywords'], <dynamic>['original']);
  });

  test('keyPrefix is applied consistently', () async {
    final store = MemoryCacheStore(keyPrefix: 'p:');
    final now = DateTime.now().millisecondsSinceEpoch;
    await store.write('p:k1', entry(createdAtMs: now, ttlMs: 1000));
    final read = await store.read('k1');
    expect(read.entry, isNotNull);
  });

  test('ttlMs <= 0 uses default TTL', () async {
    final store = MemoryCacheStore(defaultTtl: const Duration(seconds: 2));
    final now = DateTime.now().millisecondsSinceEpoch;
    await store.write('k1', entry(createdAtMs: now, ttlMs: 0));
    final read = await store.read('k1');
    expect(read.entry, isNotNull);
    expect(read.entry!.ttlMs, 2000);
  });

  test('explicit never-expiring entry does not use default TTL', () async {
    final store = MemoryCacheStore(defaultTtl: const Duration(milliseconds: 1));
    final entry = CacheEntry.withLifetime(
      kind: CachePayloadKind.linkMetadata,
      createdAtMs: 1,
      lifetime: const CacheLifetime.neverExpires(),
      payload: const {},
    );
    await store.write('never', entry);

    final read = await store.read('never');
    expect(read.entry, isNotNull);
    expect(read.entry!.lifetime.kind, CacheLifetimeKind.neverExpires);
  });

  test('expired entries are removed', () async {
    final store = MemoryCacheStore();
    final now = DateTime.now().millisecondsSinceEpoch;
    await store.write('k1', entry(createdAtMs: now - 1000, ttlMs: 1));
    final read = await store.read('k1');
    expect(read.entry, isNull);
  });

  test('maxEntries evicts oldest', () async {
    final store = MemoryCacheStore(maxEntries: 2);
    final now = DateTime.now().millisecondsSinceEpoch;
    await store.write('k1', entry(createdAtMs: now, ttlMs: 1000));
    await store.write('k2', entry(createdAtMs: now, ttlMs: 1000));
    await store.write('k3', entry(createdAtMs: now, ttlMs: 1000));
    final read1 = await store.read('k1');
    final read2 = await store.read('k2');
    final read3 = await store.read('k3');
    expect(read1.entry, isNull);
    expect(read2.entry, isNotNull);
    expect(read3.entry, isNotNull);
  });

  test('maxEntries zero clears all', () async {
    final store = MemoryCacheStore(maxEntries: 0);
    final now = DateTime.now().millisecondsSinceEpoch;
    await store.write('k1', entry(createdAtMs: now, ttlMs: 1000));
    final read = await store.read('k1');
    expect(read.entry, isNull);
  });

  test('purgeExpired removes expired entries', () async {
    final store = MemoryCacheStore();
    final now = DateTime.now().millisecondsSinceEpoch;
    await store.write('k1', entry(createdAtMs: now - 1000, ttlMs: 1));
    await store.write('k2', entry(createdAtMs: now, ttlMs: 1000));
    final purge = await store.purgeExpired();
    expect(purge.ok, isTrue);
    expect(purge.purged, 0);
    expect((await store.read('k1')).entry, isNull);
    expect((await store.read('k2')).entry, isNotNull);
  });

  test('closed store returns errors', () async {
    final store = MemoryCacheStore();
    await store.close();
    final read = await store.read('k');
    expect(read.error, isNotNull);
    final write = await store.write('k', entry(createdAtMs: 0, ttlMs: 1));
    expect(write.ok, isFalse);
  });
}
