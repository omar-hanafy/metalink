import 'dart:convert';

import 'package:hive_ce/hive_ce.dart';

import 'package:metalink/src/cache/cache_store.dart';

/// A persistent [CacheStore] implementation backed by Hive.
///
/// [HiveCacheStore] stores cache entries on disk, allowing metadata to persist
/// across app restarts. This is ideal for production applications where
/// re-fetching metadata on every launch would be wasteful.
///
/// ### When to Use
/// * Use [HiveCacheStore] for Flutter apps or long-running Dart applications
///   where cache persistence is desired.
/// * For ephemeral caching (e.g., testing, short-lived scripts), use
///   [MemoryCacheStore] instead.
///
/// ### Initialization
/// Use the static [open] factory to create and initialize a store:
/// ```dart
/// final store = await HiveCacheStore.open(boxName: 'my_cache');
/// ```
///
/// Or inject a pre-opened [Box] if you manage Hive initialization yourself.
///
/// See also:
/// * [MemoryCacheStore] for in-memory caching.
/// * [CacheStore] for the interface contract.
class HiveCacheStore implements CacheStore {
  /// Creates a [HiveCacheStore] from an already-opened Hive [Box].
  ///
  /// ### Parameters
  /// * [box] - A pre-opened Hive box storing JSON-encoded entries.
  /// * [keyPrefix] - Prefix for all keys. Defaults to `metalink:`.
  /// * [defaultTtl] - TTL applied to entries with no explicit TTL.
  /// * [closeBoxOnClose] - If `true`, closes the box when [close] is called.
  HiveCacheStore({
    required Box<String> box,
    String keyPrefix = 'metalink:',
    Duration defaultTtl = const Duration(hours: 4),
    bool closeBoxOnClose = false,
  })  : _box = box,
        _keyPrefix = keyPrefix,
        _defaultTtlMs = defaultTtl.inMilliseconds,
        _closeBoxOnClose = closeBoxOnClose;

  final Box<String> _box;
  final String _keyPrefix;
  final int _defaultTtlMs;
  final bool _closeBoxOnClose;

  bool _closed = false;

  /// Opens a new [HiveCacheStore] with the given configuration.
  ///
  /// This factory handles Hive initialization and box opening.
  ///
  /// ### Parameters
  /// * [boxName] - The name of the Hive box. Defaults to `metalink_cache`.
  /// * [keyPrefix] - Prefix for all keys. Defaults to `metalink:`.
  /// * [defaultTtl] - TTL for entries without explicit TTL. Defaults to 4 hours.
  /// * [encryptionCipher] - Optional cipher for encrypted storage.
  /// * [path] - Optional directory path. If provided, initializes Hive at this path.
  /// * [crashRecovery] - If `true`, enables Hive crash recovery.
  ///
  /// ### Example
  /// ```dart
  /// final store = await HiveCacheStore.open(
  ///   boxName: 'metadata_cache',
  ///   defaultTtl: Duration(hours: 1),
  /// );
  /// ```
  static Future<HiveCacheStore> open({
    String boxName = 'metalink_cache',
    String keyPrefix = 'metalink:',
    Duration defaultTtl = const Duration(hours: 4),
    HiveCipher? encryptionCipher,
    String? path,
    bool crashRecovery = true,
  }) async {
    if (path != null) {
      // Best-effort init for Dart-only usage; ignore if another layer already initialized Hive.
      try {
        Hive.init(path);
      } catch (_) {
        // Ignore init errors to avoid breaking callers that already configured Hive.
      }
    }

    final box = await Hive.openBox<String>(
      boxName,
      encryptionCipher: encryptionCipher,
      path: path,
      crashRecovery: crashRecovery,
    );

    return HiveCacheStore(
      box: box,
      keyPrefix: keyPrefix,
      defaultTtl: defaultTtl,
      closeBoxOnClose: true,
    );
  }

  @override
  Future<CacheReadResult> read(String key) async {
    if (_closed) {
      return CacheReadResult(
        entry: null,
        error: StateError('HiveCacheStore is closed'),
      );
    }

    final k = _normalizeKey(key);

    try {
      final raw = _box.get(k);
      if (raw == null) {
        return const CacheReadResult(entry: null);
      }

      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        // Corrupt entry: delete it and surface the format error to callers.
        await _safeDelete(k);
        return const CacheReadResult(
          entry: null,
          error: FormatException('Cached value is not a JSON object'),
        );
      }

      final entry = CacheEntry.fromJson(Map<String, dynamic>.from(decoded));

      // Apply default TTL to legacy entries that lack a valid TTL.
      final normalizedEntry = entry.ttlMs <= 0
          ? CacheEntry(
              kind: entry.kind,
              createdAtMs: entry.createdAtMs,
              ttlMs: _defaultTtlMs,
              payload: entry.payload,
            )
          : entry;

      if (normalizedEntry.isExpired()) {
        await _safeDelete(k);
        return const CacheReadResult(entry: null);
      }

      return CacheReadResult(entry: normalizedEntry);
    } catch (e, st) {
      // Best-effort cleanup so unreadable entries do not cause repeated failures.
      await _safeDelete(k);
      return CacheReadResult(
        entry: null,
        error: e,
        stackTrace: st,
      );
    }
  }

  @override
  Future<CacheWriteResult> write(String key, CacheEntry entry) async {
    if (_closed) {
      return CacheWriteResult(
        ok: false,
        error: StateError('HiveCacheStore is closed'),
      );
    }

    final k = _normalizeKey(key);

    final normalizedEntry = entry.ttlMs <= 0
        ? CacheEntry(
            kind: entry.kind,
            createdAtMs: entry.createdAtMs,
            ttlMs: _defaultTtlMs,
            payload: entry.payload,
          )
        : entry;

    // If entry is already expired, remove any existing value and treat as a no-op write.
    if (normalizedEntry.isExpired()) {
      await _safeDelete(k);
      return const CacheWriteResult(ok: true);
    }

    try {
      final raw = jsonEncode(normalizedEntry.toJson());
      await _box.put(k, raw);
      return const CacheWriteResult(ok: true);
    } catch (e, st) {
      return CacheWriteResult(
        ok: false,
        error: e,
        stackTrace: st,
      );
    }
  }

  @override
  Future<CacheOpResult> delete(String key) async {
    if (_closed) {
      return CacheOpResult(
        ok: false,
        error: StateError('HiveCacheStore is closed'),
      );
    }

    final k = _normalizeKey(key);

    try {
      await _box.delete(k);
      return const CacheOpResult(ok: true);
    } catch (e, st) {
      return CacheOpResult(ok: false, error: e, stackTrace: st);
    }
  }

  @override
  Future<CacheOpResult> clear() async {
    if (_closed) {
      return CacheOpResult(
        ok: false,
        error: StateError('HiveCacheStore is closed'),
      );
    }

    try {
      final keysToDelete = _box.keys
          .whereType<String>()
          .where((k) => _keyPrefix.isEmpty ? true : k.startsWith(_keyPrefix))
          .toList(growable: false);

      if (keysToDelete.isEmpty) {
        return const CacheOpResult(ok: true);
      }

      await _box.deleteAll(keysToDelete);
      return const CacheOpResult(ok: true);
    } catch (e, st) {
      return CacheOpResult(ok: false, error: e, stackTrace: st);
    }
  }

  @override
  Future<CachePurgeResult> purgeExpired() async {
    if (_closed) {
      return CachePurgeResult(
        ok: false,
        purged: 0,
        error: StateError('HiveCacheStore is closed'),
      );
    }

    final now = DateTime.now().millisecondsSinceEpoch;
    final keysToDelete = <String>[];
    var purged = 0;

    try {
      for (final key in _box.keys.whereType<String>()) {
        if (_keyPrefix.isNotEmpty && !key.startsWith(_keyPrefix)) {
          continue;
        }

        final raw = _box.get(key);
        if (raw == null) continue;

        try {
          final decoded = jsonDecode(raw);
          if (decoded is! Map) {
            // Corrupt entries are purged so cache health is preserved.
            keysToDelete.add(key);
            continue;
          }

          final entry = CacheEntry.fromJson(Map<String, dynamic>.from(decoded));
          final ttlMs = entry.ttlMs <= 0 ? _defaultTtlMs : entry.ttlMs;
          final normalizedEntry = entry.ttlMs <= 0
              ? CacheEntry(
                  kind: entry.kind,
                  createdAtMs: entry.createdAtMs,
                  ttlMs: ttlMs,
                  payload: entry.payload,
                )
              : entry;

          if (normalizedEntry.isExpired(nowMs: now)) {
            keysToDelete.add(key);
          }
        } catch (_) {
          // Purge on decode or parse errors to keep the cache healthy.
          keysToDelete.add(key);
        }
      }

      if (keysToDelete.isNotEmpty) {
        await _box.deleteAll(keysToDelete);
        purged = keysToDelete.length;
      }

      return CachePurgeResult(ok: true, purged: purged);
    } catch (e, st) {
      return CachePurgeResult(
          ok: false, purged: purged, error: e, stackTrace: st);
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;

    if (_closeBoxOnClose) {
      try {
        await _box.close();
      } catch (_) {
        // Best-effort close so shutdown does not crash callers.
      }
    }
  }

  String _normalizeKey(String key) {
    if (_keyPrefix.isEmpty) return key;
    if (key.startsWith(_keyPrefix)) return key;
    return '$_keyPrefix$key';
  }

  Future<void> _safeDelete(String key) async {
    try {
      await _box.delete(key);
    } catch (_) {
      // Ignore delete errors so cleanup remains best-effort.
    }
  }
}
