import 'dart:collection';

import 'package:metalink/src/cache/cache_store.dart';

/// An in-memory [CacheStore] implementation with LRU eviction.
///
/// [MemoryCacheStore] keeps cache entries in memory using a [LinkedHashMap]
/// for efficient LRU (Least Recently Used) ordering. Entries are evicted
/// when [maxEntries] is exceeded.
///
/// ### When to Use
/// * Use [MemoryCacheStore] for short-lived applications, testing, or when
///   cache persistence across restarts is not needed.
/// * For persistent caching, use [HiveCacheStore] instead.
///
/// ### Eviction Policy
/// * When [maxEntries] is exceeded, the oldest (least recently used) entries
///   are removed until the limit is satisfied.
/// * Expired entries are lazily removed on read or during [purgeExpired].
///
/// See also:
/// * [HiveCacheStore] for disk-based persistent caching.
/// * [CacheStore] for the interface contract.
class MemoryCacheStore implements CacheStore {
  /// Creates a [MemoryCacheStore] with the given configuration.
  ///
  /// ### Parameters
  /// * [keyPrefix] - Prefix for all keys. Defaults to `metalink:`.
  /// * [defaultTtl] - TTL for entries without explicit TTL. Defaults to 4 hours.
  /// * [maxEntries] - Maximum number of entries before LRU eviction. Defaults to `500`.
  MemoryCacheStore({
    String keyPrefix = 'metalink:',
    Duration defaultTtl = const Duration(hours: 4),
    int maxEntries = 500,
  })  : _keyPrefix = keyPrefix,
        _defaultTtlMs = defaultTtl.inMilliseconds,
        _maxEntries = maxEntries < 0 ? 0 : maxEntries;

  final String _keyPrefix;
  final int _defaultTtlMs;
  final int _maxEntries;

  final LinkedHashMap<String, CacheEntry> _entries = LinkedHashMap();
  bool _closed = false;

  @override
  Future<CacheReadResult> read(String key) async {
    if (_closed) {
      return CacheReadResult(
        entry: null,
        error: StateError('MemoryCacheStore is closed'),
      );
    }

    final k = _normalizeKey(key);
    final stored = _entries[k];
    if (stored == null) {
      return const CacheReadResult(entry: null);
    }

    final entry = stored.ttlMs <= 0
        ? CacheEntry(
            kind: stored.kind,
            createdAtMs: stored.createdAtMs,
            ttlMs: _defaultTtlMs,
            payload: stored.payload,
          )
        : stored;

    if (entry.isExpired()) {
      _entries.remove(k);
      return const CacheReadResult(entry: null);
    }

    // LRU bump: reinsert so recently read entries stay hottest.
    _entries.remove(k);
    _entries[k] = entry;

    return CacheReadResult(entry: entry);
  }

  @override
  Future<CacheWriteResult> write(String key, CacheEntry entry) async {
    if (_closed) {
      return CacheWriteResult(
        ok: false,
        error: StateError('MemoryCacheStore is closed'),
      );
    }

    final k = _normalizeKey(key);

    // If caller supplied ttlMs=0, fall back to the default TTL to avoid immediate expiry.
    final normalizedEntry = entry.ttlMs <= 0
        ? CacheEntry(
            kind: entry.kind,
            createdAtMs: entry.createdAtMs,
            ttlMs: _defaultTtlMs,
            payload: entry.payload,
          )
        : entry;

    // Skip storing expired entries so the cache stays clean.
    if (normalizedEntry.isExpired()) {
      _entries.remove(k);
      return const CacheWriteResult(ok: true);
    }

    _entries.remove(k);
    _entries[k] = normalizedEntry;

    _evictIfNeeded();

    return const CacheWriteResult(ok: true);
  }

  @override
  Future<CacheOpResult> delete(String key) async {
    if (_closed) {
      return CacheOpResult(
        ok: false,
        error: StateError('MemoryCacheStore is closed'),
      );
    }

    final k = _normalizeKey(key);
    _entries.remove(k);
    return const CacheOpResult(ok: true);
  }

  @override
  Future<CacheOpResult> clear() async {
    if (_closed) {
      return CacheOpResult(
        ok: false,
        error: StateError('MemoryCacheStore is closed'),
      );
    }

    _entries.clear();
    return const CacheOpResult(ok: true);
  }

  @override
  Future<CachePurgeResult> purgeExpired() async {
    if (_closed) {
      return CachePurgeResult(
        ok: false,
        purged: 0,
        error: StateError('MemoryCacheStore is closed'),
      );
    }

    final now = DateTime.now().millisecondsSinceEpoch;
    var purged = 0;

    final keys = List<String>.from(_entries.keys);
    for (final k in keys) {
      final entry = _entries[k];
      if (entry == null) continue;
      if (entry.isExpired(nowMs: now)) {
        _entries.remove(k);
        purged++;
      }
    }

    return CachePurgeResult(ok: true, purged: purged);
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _entries.clear();
  }

  String _normalizeKey(String key) {
    if (_keyPrefix.isEmpty) return key;
    if (key.startsWith(_keyPrefix)) return key;
    return '$_keyPrefix$key';
  }

  void _evictIfNeeded() {
    if (_maxEntries <= 0) {
      _entries.clear();
      return;
    }
    while (_entries.length > _maxEntries) {
      final oldestKey = _entries.keys.first;
      _entries.remove(oldestKey);
    }
  }
}
