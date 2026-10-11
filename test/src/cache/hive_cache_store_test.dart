import 'dart:convert';
import 'dart:io';

import 'package:hive_ce/hive_ce.dart';
import 'package:metalink/src/cache/cache_store.dart';
import 'package:metalink/src/cache/hive_cache_store.dart';
import 'package:path/path.dart' as p;
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

  test(
    'constructor closeBoxOnClose decides whether close closes the box',
    () async {
      final kept = await openTestBox(name: 'hive_injected_kept');
      final closed = await openTestBox(name: 'hive_injected_closed');
      addTearDown(() async {
        await closeTestBox(kept);
        await closeTestBox(closed);
      });

      await HiveCacheStore(box: kept.box).close();
      await HiveCacheStore(box: closed.box, closeBoxOnClose: true).close();

      expect(kept.box.isOpen, isTrue);
      expect(closed.box.isOpen, isFalse);
    },
  );

  group('open', () {
    Future<String> tempPath() async {
      final dir = await Directory.systemTemp.createTemp('metalink_hive_open_');
      addTearDown(() => dir.delete(recursive: true));
      return dir.path;
    }

    test('a cache path does not move the application Hive home', () async {
      final root = await tempPath();
      final appDir = p.join(root, 'app');
      final cacheDir = p.join(root, 'cache');
      Hive.init(appDir);

      final store = await HiveCacheStore.open(
        boxName: 'open_metadata_cache',
        path: cacheDir,
      );
      final prefs = await Hive.openBox<String>('open_user_prefs');
      addTearDown(() async {
        await store.close();
        await prefs.close();
      });

      expect(
        File(p.join(cacheDir, 'open_metadata_cache.hive')).existsSync(),
        isTrue,
      );
      expect(File(p.join(appDir, 'open_user_prefs.hive')).existsSync(), isTrue);
      expect(
        File(p.join(cacheDir, 'open_user_prefs.hive')).existsSync(),
        isFalse,
      );
    });

    test('stores opened on one box close independently', () async {
      final dir = await tempPath();
      final first = await HiveCacheStore.open(
        boxName: 'open_shared',
        path: dir,
      );
      final second = await HiveCacheStore.open(
        boxName: 'open_shared',
        path: dir,
      );
      addTearDown(second.close);

      await first.close();
      final now = DateTime.now().millisecondsSinceEpoch;
      final write = await second.write(
        'k1',
        entry(createdAtMs: now, ttlMs: 60000),
      );
      final read = await second.read('k1');

      expect(write.ok, isTrue);
      expect(read.error, isNull);
      expect(read.entry, isNotNull);
      expect(Hive.isBoxOpen('open_shared'), isTrue);

      await second.close();
      expect(Hive.isBoxOpen('open_shared'), isFalse);
    });

    test('a later open of an open box keeps its first settings', () async {
      // Documented on HiveCacheStore.open: Hive ignores the cipher and path
      // of a later open, so stores needing other settings need another name.
      final plainDir = await tempPath();
      final otherDir = await tempPath();
      final plain = await HiveCacheStore.open(
        boxName: 'open_first_settings',
        path: plainDir,
      );
      final encrypted = await HiveCacheStore.open(
        boxName: 'open_first_settings',
        path: otherDir,
        encryptionCipher: HiveAesCipher(List<int>.filled(32, 7)),
      );
      final now = DateTime.now().millisecondsSinceEpoch;
      final write = await encrypted.write(
        'k1',
        entry(
          createdAtMs: now,
          ttlMs: 60000,
          payload: const {'title': 'plain-text-marker'},
        ),
      );
      await plain.close();
      await encrypted.close();

      expect(write.ok, isTrue);
      expect(Directory(otherDir).listSync(), isEmpty);
      final bytes = File(p.join(plainDir, 'open_first_settings.hive'))
          .readAsBytesSync();
      expect(
        latin1.decode(bytes, allowInvalid: true),
        contains('plain-text-marker'),
      );
    });

    test('a box the application opened first is never closed', () async {
      final dir = await tempPath();
      final appBox = await Hive.openBox<String>('open_app_owned', path: dir);
      addTearDown(appBox.close);

      final first = await HiveCacheStore.open(
        boxName: 'open_app_owned',
        path: dir,
      );
      final second = await HiveCacheStore.open(
        boxName: 'open_app_owned',
        path: dir,
      );
      await first.close();
      await second.close();

      expect(appBox.isOpen, isTrue);
      await appBox.put('app-key', 'app-value');
      expect(appBox.get('app-key'), 'app-value');
    });

    test('a reopened box is owned again after the last store closes', () async {
      final dir = await tempPath();
      final first = await HiveCacheStore.open(
        boxName: 'open_reopened',
        path: dir,
      );
      await first.close();
      expect(Hive.isBoxOpen('open_reopened'), isFalse);

      final second = await HiveCacheStore.open(
        boxName: 'open_reopened',
        path: dir,
      );
      expect(Hive.isBoxOpen('open_reopened'), isTrue);
      await second.close();
      expect(Hive.isBoxOpen('open_reopened'), isFalse);
    });

    Future<void> expectWritable(HiveCacheStore store) async {
      final now = DateTime.now().millisecondsSinceEpoch;
      final write = await store.write(
        'k1',
        entry(createdAtMs: now, ttlMs: 60000),
      );
      expect(write.ok, isTrue, reason: '${write.error}');
      final read = await store.read('k1');
      expect(read.error, isNull);
      expect(read.entry, isNotNull);
    }

    test('R2-D1: open after an unawaited close gets a live box', () async {
      final dir = await tempPath();
      final first = await HiveCacheStore.open(boxName: 'race_d1', path: dir);

      final closing = first.close();
      final second = await HiveCacheStore.open(boxName: 'race_d1', path: dir);
      addTearDown(second.close);
      await closing;

      await expectWritable(second);
    });

    test(
      'R2-D2: a close awaited while open is pending keeps the box',
      () async {
        final dir = await tempPath();
        final first = await HiveCacheStore.open(boxName: 'race_d2', path: dir);

        final opening = HiveCacheStore.open(boxName: 'race_d2', path: dir);
        await first.close();
        final second = await opening;
        addTearDown(second.close);

        await expectWritable(second);
      },
    );

    test('R2-D3: concurrent close and open leave a live box', () async {
      final dir = await tempPath();
      final first = await HiveCacheStore.open(boxName: 'race_d3', path: dir);

      final results = await Future.wait<Object?>([
        first.close(),
        HiveCacheStore.open(boxName: 'race_d3', path: dir),
      ]);
      final second = results.last! as HiveCacheStore;
      addTearDown(second.close);

      await expectWritable(second);
      await second.close();
      expect(Hive.isBoxOpen('race_d3'), isFalse);
    });

    test('open while the application closes its box gets a live box', () async {
      final dir = await tempPath();
      final appBox = await Hive.openBox<String>('race_app', path: dir);

      // Hive still returns this box while it closes, so open must retry.
      final closing = appBox.close();
      final store = await HiveCacheStore.open(boxName: 'race_app', path: dir);
      await closing;

      await expectWritable(store);
      // The fresh box was opened by MetaLink, so closing the store closes it.
      await store.close();
      expect(Hive.isBoxOpen('race_app'), isFalse);
    });
  });
}
