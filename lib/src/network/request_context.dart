import 'dart:async';

/// Shared lifetime controls for one logical network operation.
///
/// [totalTimeout] and [deadline] are operation-wide. When both are supplied,
/// the earlier limit wins. A request engine can still apply a smaller
/// per-attempt timeout while consuming this shared budget.
class RequestContext {
  /// Creates request lifetime controls.
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
  /// The configured [totalTimeout] is always applied. If [parent] already has
  /// an earlier deadline, that deadline wins. The parent's cancellation signal
  /// is preserved so redirects and enrichment requests observe one lifetime.
  factory RequestContext.forOperation({
    required Duration totalTimeout,
    RequestContext? parent,
  }) {
    final now = DateTime.now().toUtc();
    final normalizedTimeout = totalTimeout.isNegative
        ? Duration.zero
        : totalTimeout;
    final configuredDeadline = now.add(normalizedTimeout);
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
  /// Completion with either a value or an error is treated as cancellation.
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

  static DateTime? _effectiveDeadline({
    required DateTime startedAt,
    required Duration? totalTimeout,
    required DateTime? deadline,
  }) {
    final timeoutDeadline = totalTimeout == null
        ? null
        : startedAt.add(totalTimeout.isNegative ? Duration.zero : totalTimeout);
    final normalizedDeadline = deadline?.toUtc();

    if (timeoutDeadline == null) return normalizedDeadline;
    if (normalizedDeadline == null) return timeoutDeadline;
    return timeoutDeadline.isBefore(normalizedDeadline)
        ? timeoutDeadline
        : normalizedDeadline;
  }
}
