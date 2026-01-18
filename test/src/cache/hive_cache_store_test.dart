import 'dart:convert';

import 'package:metalink/src/cache/cache_store.dart';
import 'package:metalink/src/cache/hive_cache_store.dart';
import 'package:test/test.dart';

import '../../support/hive_test_utils.dart';

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

  test('read/write round trip', () async {
    final testBox = await openTestBox(name: 'hive_roundtrip');
    final store = HiveCacheStore(box: testBox.box);
    addTearDown(() async {
      await store.close();
      await closeTestBox(testBox);
    });

    final now = DateTime.now().millisecondsSinceEpoch;
    await store.write('k1', entry(createdAtMs: now, ttlMs: 1000));
    final read = await store.read('k1');
    expect(read.entry, isNotNull);
  });

  test('ttlMs <= 0 uses default ttl', () async {
    final testBox = await openTestBox(name: 'hive_ttl');
    final store = HiveCacheStore(
      box: testBox.box,
      defaultTtl: const Duration(seconds: 2),
    );
    addTearDown(() async {
      await store.close();
      await closeTestBox(testBox);
    });

    final now = DateTime.now().millisecondsSinceEpoch;
    await store.write('k1', entry(createdAtMs: now, ttlMs: 0));
    final read = await store.read('k1');
    expect(read.entry!.ttlMs, 2000);
  });

  test('corrupt entry is deleted and returns error', () async {
    final testBox = await openTestBox(name: 'hive_corrupt');
    final box = testBox.box;
    final store = HiveCacheStore(box: box);
    addTearDown(() async {
      await store.close();
      await closeTestBox(testBox);
    });

    await box.put('metalink:k1', 'not-json');
    final read = await store.read('k1');
    expect(read.entry, isNull);
    expect(read.error, isNotNull);
  });

  test('purgeExpired removes expired entries', () async {
    final testBox = await openTestBox(name: 'hive_purge');
    final box = testBox.box;
    final store = HiveCacheStore(box: box);
    addTearDown(() async {
      await store.close();
      await closeTestBox(testBox);
    });

    final now = DateTime.now().millisecondsSinceEpoch;
    final expired = entry(createdAtMs: now - 1000, ttlMs: 1);
    final valid = entry(createdAtMs: now, ttlMs: 1000);
    await box.put('metalink:k1', jsonEncode(expired.toJson()));
    await box.put('metalink:k2', jsonEncode(valid.toJson()));

    final purge = await store.purgeExpired();
    expect(purge.ok, isTrue);
    expect(purge.purged, 1);
    expect((await store.read('k1')).entry, isNull);
    expect((await store.read('k2')).entry, isNotNull);
  });

  test('clear removes only prefixed keys', () async {
    final testBox = await openTestBox(name: 'hive_clear');
    final box = testBox.box;
    final store = HiveCacheStore(box: box, keyPrefix: 'p:');
    addTearDown(() async {
      await store.close();
      await closeTestBox(testBox);
    });

    final now = DateTime.now().millisecondsSinceEpoch;
    final entryJson = jsonEncode(entry(createdAtMs: now, ttlMs: 1000).toJson());
    await box.put('p:k1', entryJson);
    await box.put('other:k2', entryJson);

    final clear = await store.clear();
    expect(clear.ok, isTrue);
    expect(box.get('p:k1'), isNull);
    expect(box.get('other:k2'), isNotNull);
  });

  test('closed store returns errors', () async {
    final testBox = await openTestBox(name: 'hive_closed');
    final store = HiveCacheStore(box: testBox.box);
    await store.close();
    addTearDown(() async {
      await closeTestBox(testBox);
    });

    final read = await store.read('k1');
    expect(read.error, isNotNull);
    final write = await store.write('k1', entry(createdAtMs: 0, ttlMs: 1));
    expect(write.ok, isFalse);
  });
}
