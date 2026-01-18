/// The type of data stored in a cache entry.
///
/// Determines how the cached payload is serialized and deserialized.
enum CachePayloadKind {
  /// Stores only the final [LinkMetadata] object.
  ///
  /// Smaller payload size, but loses diagnostics and provenance information.
  linkMetadata,

  /// Stores the complete [ExtractionResult], including diagnostics and warnings.
  ///
  /// Larger payload, but preserves full extraction context for debugging.
  extractionResult,
}

/// Defines the structure of data stored in the cache.
class CacheEntry {
  const CacheEntry({
    required this.kind,
    required this.createdAtMs,
    required this.ttlMs,
    required this.payload,
  });

  /// The type of data stored (e.g., just the metadata or the full result).
  final CachePayloadKind kind;

  /// The creation timestamp in milliseconds since epoch (UTC).
  final int createdAtMs;

  /// The time-to-live in milliseconds.
  ///
  /// A value `<= 0` indicates no expiration (though the store policy might still evict it).
  final int ttlMs;

  /// The actual JSON-serializable data.
  final Map<String, dynamic> payload;

  /// Returns `true` if the entry has exceeded its TTL relative to [nowMs].
  ///
  /// [nowMs] defaults to the current time.
  bool isExpired({int? nowMs}) {
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    if (ttlMs <= 0) return true;
    return now > (createdAtMs + ttlMs);
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'kind': kind.name,
      'createdAtMs': createdAtMs,
      'ttlMs': ttlMs,
      'payload': payload,
    };
  }

  factory CacheEntry.fromJson(Map<String, dynamic> json) {
    final kindRaw = json['kind'];
    final createdAtMsRaw = json['createdAtMs'];
    final ttlMsRaw = json['ttlMs'];
    final payloadRaw = json['payload'];

    if (kindRaw is! String) {
      throw const FormatException('CacheEntry.kind must be a String');
    }
    if (createdAtMsRaw is! int) {
      throw const FormatException('CacheEntry.createdAtMs must be an int');
    }
    if (ttlMsRaw is! int) {
      throw const FormatException('CacheEntry.ttlMs must be an int');
    }
    if (payloadRaw is! Map) {
      throw const FormatException('CacheEntry.payload must be a Map');
    }

    final kind = _cachePayloadKindFromName(kindRaw);
    final payload = Map<String, dynamic>.from(payloadRaw);

    return CacheEntry(
      kind: kind,
      createdAtMs: createdAtMsRaw,
      ttlMs: ttlMsRaw,
      payload: payload,
    );
  }
}

/// The result of a cache read operation.
///
/// Use the convenience getters to determine the outcome:
/// * [isHit] - Entry found and valid.
/// * [isMiss] - No entry found (not an error).
/// * [isError] - Read failed due to an exception.
class CacheReadResult {
  const CacheReadResult({
    required this.entry,
    this.error,
    this.stackTrace,
  });

  /// The cached entry, or `null` if not found or an error occurred.
  final CacheEntry? entry;

  /// The error that occurred during the read, if any.
  final Object? error;

  /// The stack trace associated with [error], if available.
  final StackTrace? stackTrace;

  /// Returns `true` if a valid entry was found.
  bool get isHit => entry != null && error == null;

  /// Returns `true` if no entry was found (but no error occurred).
  bool get isMiss => entry == null && error == null;

  /// Returns `true` if the read failed due to an error.
  bool get isError => error != null;
}

/// The result of a cache write operation.
class CacheWriteResult {
  const CacheWriteResult({
    required this.ok,
    this.error,
    this.stackTrace,
  });

  /// `true` if the write succeeded, `false` otherwise.
  final bool ok;

  /// The error that occurred during the write, if any.
  final Object? error;

  /// The stack trace associated with [error], if available.
  final StackTrace? stackTrace;
}

/// The result of a cache operation (delete, clear).
class CacheOpResult {
  const CacheOpResult({
    required this.ok,
    this.error,
    this.stackTrace,
  });

  /// `true` if the operation succeeded, `false` otherwise.
  final bool ok;

  /// The error that occurred during the operation, if any.
  final Object? error;

  /// The stack trace associated with [error], if available.
  final StackTrace? stackTrace;
}

/// The result of a cache purge operation.
class CachePurgeResult {
  const CachePurgeResult({
    required this.ok,
    required this.purged,
    this.error,
    this.stackTrace,
  });

  /// `true` if the purge completed (even partially), `false` on total failure.
  final bool ok;

  /// The number of entries successfully purged.
  final int purged;

  /// The error that occurred during the purge, if any.
  final Object? error;

  /// The stack trace associated with [error], if available.
  final StackTrace? stackTrace;
}

/// Interface for a persistent storage layer.
///
/// Implementations must handle serialization and storage of [CacheEntry] objects.
///
/// ### Thread Safety
/// Implementations must be safe to use across asynchronous gaps.
abstract interface class CacheStore {
  /// Retrieves an entry by its [key].
  ///
  /// Returns a [CacheReadResult] which may indicate a hit, miss, or error.
  /// Must not throw; exceptions should be captured in the result.
  Future<CacheReadResult> read(String key);

  /// Stores an [entry] under [key].
  ///
  /// Returns a [CacheWriteResult] indicating success or failure.
  /// Must not throw.
  Future<CacheWriteResult> write(String key, CacheEntry entry);

  /// Removes the entry for [key].
  Future<CacheOpResult> delete(String key);

  /// Removes all entries from the store.
  Future<CacheOpResult> clear();

  /// Scans the store and removes all entries that are expired.
  ///
  /// Returns a result containing the count of purged items.
  Future<CachePurgeResult> purgeExpired();

  /// Closes the store and releases resources.
  Future<void> close();
}

CachePayloadKind _cachePayloadKindFromName(String name) {
  for (final v in CachePayloadKind.values) {
    if (v.name == name) return v;
  }
  throw FormatException('Unknown CachePayloadKind: $name');
}
