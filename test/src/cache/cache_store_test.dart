import 'package:metalink/src/cache/cache_store.dart';
import 'package:test/test.dart';

void main() {
  test('CacheEntry toJson and fromJson round trip', () {
    const entry = CacheEntry(
      kind: CachePayloadKind.linkMetadata,
      createdAtMs: 1,
      ttlMs: 1000,
      payload: {'a': 1},
    );
    final decoded = CacheEntry.fromJson(entry.toJson());
    expect(decoded.kind, CachePayloadKind.linkMetadata);
    expect(decoded.createdAtMs, 1);
    expect(decoded.ttlMs, 1000);
    expect(decoded.payload['a'], 1);
  });

  test('CacheEntry isExpired respects ttlMs', () {
    final now = DateTime.now().millisecondsSinceEpoch;
    final expired = CacheEntry(
      kind: CachePayloadKind.linkMetadata,
      createdAtMs: now - 1000,
      ttlMs: 1,
      payload: const {},
    );
    expect(expired.isExpired(nowMs: now), isTrue);

    final valid = CacheEntry(
      kind: CachePayloadKind.linkMetadata,
      createdAtMs: now,
      ttlMs: 1000,
      payload: const {},
    );
    expect(valid.isExpired(nowMs: now), isFalse);
  });

  test('CacheEntry.fromJson validates types', () {
    expect(
      () => CacheEntry.fromJson(
          {'kind': 1, 'createdAtMs': 0, 'ttlMs': 0, 'payload': {}}),
      throwsFormatException,
    );
    expect(
      () => CacheEntry.fromJson(
          {'kind': 'x', 'createdAtMs': 'bad', 'ttlMs': 0, 'payload': {}}),
      throwsFormatException,
    );
    expect(
      () => CacheEntry.fromJson(
          {'kind': 'x', 'createdAtMs': 0, 'ttlMs': 'bad', 'payload': {}}),
      throwsFormatException,
    );
    expect(
      () => CacheEntry.fromJson(
          {'kind': 'x', 'createdAtMs': 0, 'ttlMs': 0, 'payload': []}),
      throwsFormatException,
    );
    expect(
      () => CacheEntry.fromJson(
          {'kind': 'unknown', 'createdAtMs': 0, 'ttlMs': 0, 'payload': {}}),
      throwsFormatException,
    );
  });

  test('CacheReadResult flags', () {
    const hit = CacheReadResult(
        entry: CacheEntry(
      kind: CachePayloadKind.linkMetadata,
      createdAtMs: 0,
      ttlMs: 1,
      payload: {},
    ));
    const miss = CacheReadResult(entry: null);
    final err = CacheReadResult(entry: null, error: StateError('x'));
    expect(hit.isHit, isTrue);
    expect(hit.isMiss, isFalse);
    expect(hit.isError, isFalse);
    expect(miss.isHit, isFalse);
    expect(miss.isMiss, isTrue);
    expect(miss.isError, isFalse);
    expect(err.isError, isTrue);
  });
}
