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

/// The expiration policy attached to a [CacheEntry].
///
/// This replaces the ambiguous v2 convention where a nonpositive `ttlMs`
/// was documented as both "never expires" and "use the store default".
enum CacheLifetimeKind {
  /// Resolve the lifetime using the receiving store's configured default.
  storeDefault,

  /// Keep the entry until it is evicted or explicitly removed.
  neverExpires,

  /// Expire the entry after [CacheLifetime.duration].
  expiresAfter,
}

/// An explicit cache-entry lifetime.
class CacheLifetime {
  /// Uses the receiving [CacheStore]'s configured default lifetime.
  const CacheLifetime.storeDefault()
    : kind = CacheLifetimeKind.storeDefault,
      durationMs = null;

  /// Keeps the entry until it is evicted or explicitly removed.
  const CacheLifetime.neverExpires()
    : kind = CacheLifetimeKind.neverExpires,
      durationMs = null;

  /// Expires the entry after [duration].
  factory CacheLifetime.expiresAfter(Duration duration) {
    if (duration.isNegative) {
      throw ArgumentError.value(duration, 'duration', 'Must not be negative.');
    }
    return CacheLifetime.expiresAfterMilliseconds(duration.inMilliseconds);
  }

  /// Expires the entry after [durationMs] milliseconds.
  const CacheLifetime.expiresAfterMilliseconds(int durationMs)
    : assert(durationMs >= 0),
      durationMs = durationMs,
      kind = CacheLifetimeKind.expiresAfter;

  /// The kind of expiration policy.
  final CacheLifetimeKind kind;

  /// The expiration duration when [kind] is [CacheLifetimeKind.expiresAfter].
  final int? durationMs;

  /// The expiration duration when [kind] is [CacheLifetimeKind.expiresAfter].
  Duration? get duration =>
      durationMs == null ? null : Duration(milliseconds: durationMs!);

  Map<String, dynamic> toJson() => <String, dynamic>{
    'kind': kind.name,
    if (durationMs != null) 'durationMs': durationMs,
  };

  factory CacheLifetime.fromJson(Map<String, dynamic> json) {
    final kindRaw = json['kind'];
    if (kindRaw is! String) {
      throw const FormatException('CacheLifetime.kind must be a String');
    }

    final kind = CacheLifetimeKind.values.where((value) {
      return value.name == kindRaw;
    }).firstOrNull;
    if (kind == null) {
      throw FormatException('Unknown CacheLifetimeKind: $kindRaw');
    }

    return switch (kind) {
      CacheLifetimeKind.storeDefault => const CacheLifetime.storeDefault(),
      CacheLifetimeKind.neverExpires => const CacheLifetime.neverExpires(),
      CacheLifetimeKind.expiresAfter => _expiresAfterFromJson(json),
    };
  }

  static CacheLifetime _expiresAfterFromJson(Map<String, dynamic> json) {
    final durationMs = json['durationMs'];
    if (durationMs is! int || durationMs < 0) {
      throw const FormatException(
        'CacheLifetime.durationMs must be a nonnegative int',
      );
    }
    return CacheLifetime.expiresAfterMilliseconds(durationMs);
  }
}

/// Defines the structure of data stored in the cache.
class CacheEntry {
  /// Creates an entry using the legacy millisecond TTL contract.
  ///
  /// A positive [ttlMs] becomes [CacheLifetime.expiresAfter]. A nonpositive
  /// value means [CacheLifetime.storeDefault], matching the behavior of the v2
  /// stores. Prefer [CacheEntry.withLifetime] in new code.
  const CacheEntry({
    required this.kind,
    required this.createdAtMs,
    required this.ttlMs,
    required this.payload,
  }) : _explicitLifetime = null;

  /// Creates an entry with an explicit [lifetime].
  factory CacheEntry.withLifetime({
    required CachePayloadKind kind,
    required int createdAtMs,
    required CacheLifetime lifetime,
    required Map<String, dynamic> payload,
  }) {
    final ttlMs = switch (lifetime.kind) {
      CacheLifetimeKind.expiresAfter => lifetime.durationMs!,
      CacheLifetimeKind.storeDefault || CacheLifetimeKind.neverExpires => 0,
    };
    return CacheEntry._(
      kind: kind,
      createdAtMs: createdAtMs,
      ttlMs: ttlMs,
      explicitLifetime: lifetime,
      payload: payload,
    );
  }

  const CacheEntry._({
    required this.kind,
    required this.createdAtMs,
    required this.ttlMs,
    required CacheLifetime explicitLifetime,
    required this.payload,
  }) : _explicitLifetime = explicitLifetime;

  /// The type of data stored (e.g., just the metadata or the full result).
  final CachePayloadKind kind;

  /// The creation timestamp in milliseconds since epoch (UTC).
  final int createdAtMs;

  /// The time-to-live in milliseconds.
  ///
  /// A positive value is the expiration duration. A nonpositive value is the
  /// legacy representation of either a store-default or never-expiring entry;
  /// inspect [lifetime] for the unambiguous policy.
  final int ttlMs;

  final CacheLifetime? _explicitLifetime;

  /// The explicit expiration policy for this entry.
  ///
  /// Legacy entries derive this value from [ttlMs].
  CacheLifetime get lifetime =>
      _explicitLifetime ??
      (ttlMs > 0
          ? CacheLifetime.expiresAfterMilliseconds(ttlMs)
          : const CacheLifetime.storeDefault());

  /// The actual JSON-serializable data.
  final Map<String, dynamic> payload;

  /// Returns `true` if the entry has exceeded its TTL relative to [nowMs].
  ///
  /// [nowMs] defaults to the current time.
  bool isExpired({int? nowMs}) {
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    return switch (lifetime.kind) {
      CacheLifetimeKind.storeDefault => false,
      CacheLifetimeKind.neverExpires => false,
      CacheLifetimeKind.expiresAfter =>
        now > (createdAtMs + lifetime.durationMs!),
    };
  }

  /// Resolves [CacheLifetimeKind.storeDefault] to [defaultTtl].
  CacheEntry resolveStoreDefault(Duration defaultTtl) {
    if (lifetime.kind != CacheLifetimeKind.storeDefault) return this;
    return CacheEntry.withLifetime(
      kind: kind,
      createdAtMs: createdAtMs,
      lifetime: defaultTtl > Duration.zero
          ? CacheLifetime.expiresAfter(defaultTtl)
          : const CacheLifetime.neverExpires(),
      payload: payload,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'kind': kind.name,
      'createdAtMs': createdAtMs,
      'ttlMs': ttlMs,
      'lifetime': lifetime.toJson(),
      'payload': payload,
    };
  }

  factory CacheEntry.fromJson(Map<String, dynamic> json) {
    final kindRaw = json['kind'];
    final createdAtMsRaw = json['createdAtMs'];
    final ttlMsRaw = json['ttlMs'];
    final lifetimeRaw = json['lifetime'];
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

    if (lifetimeRaw == null) {
      return CacheEntry(
        kind: kind,
        createdAtMs: createdAtMsRaw,
        ttlMs: ttlMsRaw,
        payload: payload,
      );
    }
    if (lifetimeRaw is! Map) {
      throw const FormatException('CacheEntry.lifetime must be a Map');
    }

    return CacheEntry.withLifetime(
      kind: kind,
      createdAtMs: createdAtMsRaw,
      lifetime: CacheLifetime.fromJson(Map<String, dynamic>.from(lifetimeRaw)),
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
  const CacheReadResult({required this.entry, this.error, this.stackTrace});

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
  const CacheWriteResult({required this.ok, this.error, this.stackTrace});

  /// `true` if the write succeeded, `false` otherwise.
  final bool ok;

  /// The error that occurred during the write, if any.
  final Object? error;

  /// The stack trace associated with [error], if available.
  final StackTrace? stackTrace;
}

/// The result of a cache operation (delete, clear).
class CacheOpResult {
  const CacheOpResult({required this.ok, this.error, this.stackTrace});

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
