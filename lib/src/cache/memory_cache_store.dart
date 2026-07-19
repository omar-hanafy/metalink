import 'dart:collection';
import 'dart:convert';

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
  }) : _keyPrefix = keyPrefix,
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

    final entry = stored.resolveStoreDefault(
      Duration(milliseconds: _defaultTtlMs),
    );

    if (entry.isExpired()) {
      _entries.remove(k);
      return const CacheReadResult(entry: null);
    }

    // LRU bump: reinsert so recently read entries stay hottest.
    _entries.remove(k);
    _entries[k] = entry;

    try {
      return CacheReadResult(entry: _snapshot(entry));
    } catch (e, st) {
      _entries.remove(k);
      return CacheReadResult(entry: null, error: e, stackTrace: st);
    }
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

    late final CacheEntry normalizedEntry;
    try {
      normalizedEntry = _snapshot(
        entry.resolveStoreDefault(Duration(milliseconds: _defaultTtlMs)),
      );
    } catch (e, st) {
      return CacheWriteResult(ok: false, error: e, stackTrace: st);
    }

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

  CacheEntry _snapshot(CacheEntry entry) {
    final decoded = jsonDecode(jsonEncode(entry.toJson()));
    if (decoded is! Map) {
      throw const FormatException('Cache entry did not encode as an object.');
    }
    return CacheEntry.fromJson(Map<String, dynamic>.from(decoded));
  }
}
