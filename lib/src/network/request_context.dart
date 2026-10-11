import 'dart:async';

/// Shared lifetime controls for one logical network operation.
///
/// A context combines an optional absolute [deadline] with an optional
/// [cancellationSignal]. The deadline is fixed when the context is created and
/// is shared by every redirect hop, fallback request, and enrichment request
/// of the operation. Each attempt is still limited by `FetchOptions.timeout`,
/// and each operation also applies its own `FetchOptions.totalTimeout`; the
/// earliest limit wins.
///
/// ### Signal lifetime
/// Scope a context and its [cancellationSignal] to one operation or one batch,
/// such as a single `MetaLinkClient.extractBatch` call, and complete the signal
/// when that work no longer matters. A [Future] cannot drop its listeners
/// before it completes, so every listener MetaLink attaches to the signal
/// stays attached until the signal completes. MetaLink attaches one for each
/// context it derives from this one, each policy check, each request attempt,
/// and each wait it bounds by the operation's lifetime, so a single
/// `MetaLinkClient.extract` attaches several, about ten for a plain page
/// fetch, and redirects and enrichment requests add more. The listeners are
/// small and do not keep responses or results alive, but a long-lived signal
/// shared across many operations, such as one that lives as long as the
/// process, accumulates all of them until it completes.
class RequestContext {
  /// Creates lifetime controls whose deadline is measured from now.
  ///
  /// When both [totalTimeout] and [deadline] are supplied, the earlier limit
  /// wins. A negative [totalTimeout] is treated as zero, so the context is
  /// already expired. A [totalTimeout] that reaches past the latest instant a
  /// [DateTime] can represent, such as the largest [Duration] used as a
  /// "no limit" sentinel, sets [deadline] to that latest instant, which is
  /// effectively unbounded. When neither is supplied, [deadline] is `null` and
  /// an operation is bounded only by its own `FetchOptions` limits and by
  /// [cancellationSignal].
  RequestContext({
    Duration? totalTimeout,
    DateTime? deadline,
    this.cancellationSignal,
  }) : _startedAt = DateTime.now().toUtc(),
       _stopwatch = Stopwatch()..start() {
    _deadline = _effectiveDeadline(
      startedAt: _startedAt,
      totalTimeout: totalTimeout,
      deadline: deadline,
    );

    cancellationSignal
        ?.then<void>(
          (_) => _cancelled = true,
          onError: (Object _, StackTrace _) {
            _cancelled = true;
          },
        )
        .ignore();
  }

  /// Creates the shared lifetime for one complete operation.
  ///
  /// The configured [totalTimeout] is always applied, and one beyond the
  /// [DateTime] range is treated as the latest representable instant, as in
  /// [RequestContext.new]. If [parent] already has an earlier deadline, that
  /// deadline wins. The parent's cancellation signal is preserved so redirects
  /// and enrichment requests observe one lifetime.
  factory RequestContext.forOperation({
    required Duration totalTimeout,
    RequestContext? parent,
  }) {
    final now = DateTime.now().toUtc();
    final normalizedTimeout = totalTimeout.isNegative
        ? Duration.zero
        : totalTimeout;
    final configuredDeadline = _addSaturating(now, normalizedTimeout);
    final parentDeadline = parent?.deadline;
    final effectiveDeadline =
        parentDeadline != null && parentDeadline.isBefore(configuredDeadline)
        ? parentDeadline
        : configuredDeadline;

    return RequestContext(
      deadline: effectiveDeadline,
      cancellationSignal: parent?.cancellationSignal,
    );
  }

  final DateTime _startedAt;
  final Stopwatch _stopwatch;

  late final DateTime? _deadline;
  bool _cancelled = false;

  /// Completes when the caller no longer needs the operation.
  ///
  /// Completion with either a value or an error is treated as cancellation:
  /// [isCancelled] becomes `true`, no further request starts, and in-flight
  /// requests are abandoned, or aborted when the transport supports it.
  ///
  /// Each operation that uses this signal attaches several small listeners to
  /// it, one for each derived context, policy check, request attempt, and
  /// lifetime-bounded wait, and they stay attached until the signal completes.
  /// Prefer a signal scoped to one operation or batch over one that is never
  /// completed; see [RequestContext].
  final Future<void>? cancellationSignal;

  /// The effective absolute deadline, if the operation has one.
  DateTime? get deadline => _deadline;

  /// Time elapsed since this context was created.
  Duration get elapsed => _stopwatch.elapsed;

  /// Whether cancellation has already been requested.
  bool get isCancelled => _cancelled;

  /// Remaining operation budget, or `null` when no deadline was configured.
  Duration? get remaining {
    final effectiveDeadline = _deadline;
    if (effectiveDeadline == null) return null;

    final budget = effectiveDeadline.difference(_startedAt);
    final value = budget - _stopwatch.elapsed;
    return value.isNegative ? Duration.zero : value;
  }

  /// Whether the operation-wide deadline has elapsed.
  bool get isExpired {
    final value = remaining;
    return value != null && value <= Duration.zero;
  }

  /// The latest instant a [DateTime] can represent, 8.64e15 ms after the
  /// epoch.
  static final DateTime _latestInstant = DateTime.fromMillisecondsSinceEpoch(
    8640000000000000,
    isUtc: true,
  );

  /// Returns [start] plus [timeout], or [_latestInstant] when that sum lies
  /// beyond the [DateTime] range.
  ///
  /// A timeout that long, such as the largest [Duration] used as a "no limit"
  /// sentinel, is effectively unbounded. [DateTime.add] would throw or
  /// overflow instead. [timeout] must not be negative.
  static DateTime _addSaturating(DateTime start, Duration timeout) {
    final headroom = _latestInstant.difference(start);
    return timeout >= headroom ? _latestInstant : start.add(timeout);
  }

  static DateTime? _effectiveDeadline({
    required DateTime startedAt,
    required Duration? totalTimeout,
    required DateTime? deadline,
  }) {
    final timeoutDeadline = totalTimeout == null
        ? null
        : _addSaturating(
            startedAt,
            totalTimeout.isNegative ? Duration.zero : totalTimeout,
          );
    final normalizedDeadline = deadline?.toUtc();

    if (timeoutDeadline == null) return normalizedDeadline;
    if (normalizedDeadline == null) return timeoutDeadline;
    return timeoutDeadline.isBefore(normalizedDeadline)
        ? timeoutDeadline
        : normalizedDeadline;
  }
}
