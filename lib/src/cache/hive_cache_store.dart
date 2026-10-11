import 'dart:async';
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
///   `MemoryCacheStore` instead.
///
/// ### Opening a Store
/// Use [HiveCacheStore.open] to open a box that MetaLink owns:
/// ```dart
/// final store = await HiveCacheStore.open(
///   boxName: 'metadata_cache',
///   path: cacheDirectoryPath,
/// );
/// ```
///
/// Or inject an already-open [Box] through the [HiveCacheStore.new]
/// constructor when the application manages the box lifecycle itself.
///
/// See also:
/// * `MemoryCacheStore` for in-memory caching.
/// * [CacheStore] for the interface contract.
class HiveCacheStore implements CacheStore {
  /// Creates a [HiveCacheStore] from an already-opened Hive [Box].
  ///
  /// ### Parameters
  /// * `box` - A pre-opened Hive box storing JSON-encoded entries.
  /// * `keyPrefix` - Prefix for all keys. Defaults to `metalink:`.
  /// * [defaultTtl] - Lifetime given to entries that request the store
  ///   default, either through [CacheLifetime.storeDefault] or a nonpositive
  ///   legacy [CacheEntry.ttlMs]. Defaults to 4 hours. A nonpositive value
  ///   keeps those entries until they are removed.
  /// * `closeBoxOnClose` - If `true`, closes the box when [close] is called.
  ///   Defaults to `false`, which leaves the box open for its owner.
  HiveCacheStore({
    required this._box,
    this._keyPrefix = 'metalink:',
    Duration defaultTtl = const Duration(hours: 4),
    this._closeBoxOnClose = false,
  }) : _defaultTtlMs = defaultTtl.inMilliseconds,
       _sharesOpenedBox = false;

  HiveCacheStore._opened({
    required this._box,
    required this._keyPrefix,
    required Duration defaultTtl,
    required this._sharesOpenedBox,
  }) : _defaultTtlMs = defaultTtl.inMilliseconds,
       _closeBoxOnClose = false;

  /// Counts the open stores that share each box opened by [open].
  ///
  /// Hive returns the already-open [Box] when a box name is opened twice, so
  /// stores opened on the same name share one box. The box is closed only
  /// when the last of those stores closes. Boxes are compared by identity
  /// because Hive creates a new instance whenever a closed box is reopened.
  static final Map<Box<String>, int> _openedBoxReferences =
      Map<Box<String>, int>.identity();

  /// The last pending open or close of each box, by lowercase box name.
  ///
  /// Hive identifies an open box by name alone, whatever its path, so the
  /// lock uses the same key. Without it, an [open] that overlaps the closing
  /// of the last tracked store can receive the box that is being closed.
  static final Map<String, Future<void>> _boxLocks = <String, Future<void>>{};

  final Box<String> _box;
  final String _keyPrefix;
  final int _defaultTtlMs;
  final bool _closeBoxOnClose;

  /// Whether this store holds one of the [_openedBoxReferences] for [_box].
  final bool _sharesOpenedBox;

  bool _closed = false;

  /// Opens a Hive box and returns a store backed by it.
  ///
  /// The box is opened with Hive's `openBox` and the given [path], so opening
  /// a store never calls `Hive.init` and never changes the home directory or
  /// storage backend that the application configured for its own boxes.
  ///
  /// ### Parameters
  /// * [boxName] - The name of the Hive box. Defaults to `metalink_cache`.
  /// * [keyPrefix] - Prefix for all keys. Defaults to `metalink:`.
  /// * [defaultTtl] - Lifetime given to entries that request the store
  ///   default, as described for the [HiveCacheStore.new] constructor.
  ///   Defaults to 4 hours.
  /// * [encryptionCipher] - Optional cipher for encrypted storage. It applies
  ///   only when this call opens the box; see Ownership.
  /// * [path] - The directory that holds the box files. When `null`, Hive
  ///   uses the home directory the application set with `Hive.init` (for
  ///   example through `Hive.initFlutter`). On native platforms, [path] is
  ///   required unless the application initialized Hive; otherwise this
  ///   method throws Hive's [HiveError]. Web storage ignores [path]. It
  ///   applies only when this call opens the box; see Ownership.
  /// * [crashRecovery] - If `true`, enables Hive crash recovery. It applies
  ///   only when this call opens the box; see Ownership.
  ///
  /// ### Ownership
  /// Stores opened with the same [boxName] share Hive's single open box. The
  /// box closes when the last of those stores is closed, so closing one store
  /// does not break the others. If the box was already open before this call,
  /// the application owns it and closing the store leaves it open.
  ///
  /// Hive identifies an open box by its name alone. When a box named
  /// [boxName] is already open, whether MetaLink or the application opened
  /// it, this method returns a store backed by that box, and Hive ignores the
  /// [encryptionCipher], [path], and [crashRecovery] passed to this call. The
  /// box keeps the settings it was first opened with, so a call that asks
  /// for encryption can receive an unencrypted box stored in another
  /// directory. These settings take effect again only after every holder has
  /// closed the box. Stores that need different settings must use different
  /// box names.
  ///
  /// MetaLink runs its own opens and closes of a box one at a time, so an
  /// [open] that overlaps a pending [close] waits for it and then opens a live
  /// box. MetaLink cannot see the application's own `openBox` or `close`
  /// calls that are still in flight. If Hive returns a box that is being
  /// closed, this method waits for Hive to release it and opens it once more,
  /// then throws a [StateError] if that box is closed as well. A box the
  /// application opens while this call runs is treated as opened by MetaLink.
  ///
  /// ### Example
  /// ```dart
  /// final store = await HiveCacheStore.open(
  ///   boxName: 'metadata_cache',
  ///   path: cacheDirectoryPath,
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
  }) {
    return _withBoxLock(boxName, () async {
      Future<Box<String>> openBox() {
        return Hive.openBox<String>(
          boxName,
          encryptionCipher: encryptionCipher,
          path: path,
          crashRecovery: crashRecovery,
        );
      }

      // A box that was already open and is not tracked below belongs to the
      // application, which keeps responsibility for closing it.
      var alreadyOpen = Hive.isBoxOpen(boxName);
      var box = await openBox();
      if (!box.isOpen) {
        // Something outside MetaLink is closing this box. Hive unregisters a
        // closing box early in its close, after which it opens a fresh one.
        for (var turn = 0; turn < 100 && Hive.isBoxOpen(boxName); turn++) {
          await Future<void>.delayed(Duration.zero);
        }
        alreadyOpen = Hive.isBoxOpen(boxName);
        box = await openBox();
        if (!box.isOpen) {
          throw StateError(
            'Hive box "$boxName" was closed while HiveCacheStore opened it.',
          );
        }
      }

      final references = _openedBoxReferences[box];
      final sharesOpenedBox = references != null || !alreadyOpen;
      if (sharesOpenedBox) {
        _openedBoxReferences[box] = (references ?? 0) + 1;
      }

      return HiveCacheStore._opened(
        box: box,
        keyPrefix: keyPrefix,
        defaultTtl: defaultTtl,
        sharesOpenedBox: sharesOpenedBox,
      );
    });
  }

  /// Runs [action] after every earlier MetaLink open or close of [boxName].
  ///
  /// A failed [action] fails only its own caller; later actions still run.
  static Future<T> _withBoxLock<T>(
    String boxName,
    Future<T> Function() action,
  ) {
    final key = boxName.toLowerCase();
    final previous = _boxLocks[key] ?? Future<void>.value();
    final result = previous.then((_) => action());
    final released = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    _boxLocks[key] = released;
    unawaited(
      released.whenComplete(() {
        if (identical(_boxLocks[key], released)) _boxLocks.remove(key);
      }),
    );
    return result;
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

      final normalizedEntry = entry.resolveStoreDefault(
        Duration(milliseconds: _defaultTtlMs),
      );

      if (normalizedEntry.isExpired()) {
        await _safeDelete(k);
        return const CacheReadResult(entry: null);
      }

      return CacheReadResult(entry: normalizedEntry);
    } catch (e, st) {
      // Best-effort cleanup so unreadable entries do not cause repeated failures.
      await _safeDelete(k);
      return CacheReadResult(entry: null, error: e, stackTrace: st);
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

    final normalizedEntry = entry.resolveStoreDefault(
      Duration(milliseconds: _defaultTtlMs),
    );

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
      return CacheWriteResult(ok: false, error: e, stackTrace: st);
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
          .where((k) => _keyPrefix.isEmpty || k.startsWith(_keyPrefix))
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
          final normalizedEntry = entry.resolveStoreDefault(
            Duration(milliseconds: _defaultTtlMs),
          );

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
        ok: false,
        purged: purged,
        error: e,
        stackTrace: st,
      );
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;

    if (_sharesOpenedBox) {
      // Serialized with open() so a concurrent open waits for this close to
      // finish instead of receiving the box while it is being closed.
      await _withBoxLock(_box.name, () async {
        if (_releaseOpenedBox()) await _closeBoxBestEffort();
      });
    } else if (_closeBoxOnClose) {
      await _closeBoxBestEffort();
    }
  }

  Future<void> _closeBoxBestEffort() async {
    try {
      await _box.close();
    } catch (_) {
      // Best-effort close so shutdown does not crash callers.
    }
  }

  /// Releases this store's reference and reports whether it was the last.
  bool _releaseOpenedBox() {
    final remaining = (_openedBoxReferences[_box] ?? 1) - 1;
    if (remaining > 0) {
      _openedBoxReferences[_box] = remaining;
      return false;
    }
    _openedBoxReferences.remove(_box);
    return true;
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
