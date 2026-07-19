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

  test('legacy nonpositive TTL uses the store default policy', () {
    const entry = CacheEntry(
      kind: CachePayloadKind.linkMetadata,
      createdAtMs: 1,
      ttlMs: 0,
      payload: {},
    );

    expect(entry.lifetime.kind, CacheLifetimeKind.storeDefault);
    expect(entry.isExpired(nowMs: 100000), isFalse);

    final resolved = entry.resolveStoreDefault(const Duration(seconds: 2));
    expect(resolved.lifetime.kind, CacheLifetimeKind.expiresAfter);
    expect(resolved.ttlMs, 2000);
  });

  test('explicit never-expiring lifetime survives serialization', () {
    final entry = CacheEntry.withLifetime(
      kind: CachePayloadKind.linkMetadata,
      createdAtMs: 1,
      lifetime: const CacheLifetime.neverExpires(),
      payload: const {'a': 1},
    );

    final decoded = CacheEntry.fromJson(entry.toJson());
    expect(decoded.lifetime.kind, CacheLifetimeKind.neverExpires);
    expect(decoded.isExpired(nowMs: 100000), isFalse);
  });

  test('explicit expiration lifetime survives serialization', () {
    final entry = CacheEntry.withLifetime(
      kind: CachePayloadKind.extractionResult,
      createdAtMs: 1000,
      lifetime: CacheLifetime.expiresAfter(const Duration(seconds: 1)),
      payload: const {},
    );

    final decoded = CacheEntry.fromJson(entry.toJson());
    expect(decoded.lifetime.kind, CacheLifetimeKind.expiresAfter);
    expect(decoded.ttlMs, 1000);
    expect(decoded.isExpired(nowMs: 2001), isTrue);
  });

  test('zero expiration is explicit and round trips', () {
    final entry = CacheEntry.withLifetime(
      kind: CachePayloadKind.linkMetadata,
      createdAtMs: 1000,
      lifetime: CacheLifetime.expiresAfter(Duration.zero),
      payload: const {},
    );

    final decoded = CacheEntry.fromJson(entry.toJson());
    expect(decoded.lifetime.kind, CacheLifetimeKind.expiresAfter);
    expect(decoded.ttlMs, 0);
    expect(decoded.isExpired(nowMs: 1001), isTrue);
  });

  test('CacheEntry.fromJson validates types', () {
    expect(
      () => CacheEntry.fromJson({
        'kind': 1,
        'createdAtMs': 0,
        'ttlMs': 0,
        'payload': {},
      }),
      throwsFormatException,
    );
    expect(
      () => CacheEntry.fromJson({
        'kind': 'x',
        'createdAtMs': 'bad',
        'ttlMs': 0,
        'payload': {},
      }),
      throwsFormatException,
    );
    expect(
      () => CacheEntry.fromJson({
        'kind': 'x',
        'createdAtMs': 0,
        'ttlMs': 'bad',
        'payload': {},
      }),
      throwsFormatException,
    );
    expect(
      () => CacheEntry.fromJson({
        'kind': 'x',
        'createdAtMs': 0,
        'ttlMs': 0,
        'payload': [],
      }),
      throwsFormatException,
    );
    expect(
      () => CacheEntry.fromJson({
        'kind': 'unknown',
        'createdAtMs': 0,
        'ttlMs': 0,
        'payload': {},
      }),
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
      ),
    );
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
