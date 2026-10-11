import 'dart:io';

import 'package:hive_ce/hive_ce.dart';
import 'package:metalink/src/cache/cache_store.dart';
import 'package:metalink/src/cache/hive_cache_store.dart';
import 'package:test/test.dart';

// These tests need Hive's isolate-global home path to stay unset, so they live
// in their own suite: every test file runs in a fresh isolate, and no test in
// this file calls Hive.init.
void main() {
  test('open without a path surfaces the Hive error', () async {
    await expectLater(
      HiveCacheStore.open(boxName: 'uninitialized_cache'),
      throwsA(isA<HiveError>()),
    );
    expect(Hive.isBoxOpen('uninitialized_cache'), isFalse);
  });

  test('open with a path does not initialize Hive for other boxes', () async {
    final dir = await Directory.systemTemp.createTemp('metalink_hive_uninit_');
    addTearDown(() => dir.delete(recursive: true));

    final store = await HiveCacheStore.open(
      boxName: 'explicit_path_cache',
      path: dir.path,
    );
    addTearDown(store.close);
    final write = await store.write(
      'k1',
      CacheEntry(
        kind: CachePayloadKind.linkMetadata,
        createdAtMs: DateTime.now().millisecondsSinceEpoch,
        ttlMs: 60000,
        payload: const <String, dynamic>{},
      ),
    );
    expect(write.ok, isTrue);
    expect((await store.read('k1')).entry, isNotNull);

    // Hive still has no home path, so an unrelated box needs its own path.
    await expectLater(
      Hive.openBox<String>('unrelated_application_box'),
      throwsA(isA<HiveError>()),
    );
  });
}
