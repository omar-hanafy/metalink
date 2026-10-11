import 'dart:async';

/// The longest delay one platform timer can wait on every platform.
///
/// Browsers store a `setTimeout` delay as a signed 32-bit millisecond count,
/// and dart2js, DDC, and dart2wasm pass a [Timer] duration through unchanged.
/// A longer delay overflows, and the browser fires the timer almost
/// immediately. 2^31-1 ms is about 24.8 days.
const Duration maxPlatformTimerDelay = Duration(milliseconds: 0x7FFFFFFF);

/// Starts a one-shot timer that calls [callback] once [delay] has elapsed.
///
/// Unlike [Timer.new], [delay] may exceed [maxPlatformTimerDelay]. A longer
/// delay is waited out in segments of at most [maxSegment], re-armed against
/// a [Stopwatch] until the full delay has passed, so a deadline set months or
/// centuries away never fires early on the web. A zero or negative [delay]
/// fires as soon as possible, like [Timer.new].
///
/// [maxSegment] exists for tests and defaults to [maxPlatformTimerDelay].
Timer startDeadlineTimer(
  Duration delay,
  void Function() callback, {
  Duration maxSegment = maxPlatformTimerDelay,
}) {
  if (delay <= maxSegment) return Timer(delay, callback);
  return _SegmentedTimer(delay, callback, maxSegment);
}

/// A one-shot [Timer] whose delay spans several platform timers.
final class _SegmentedTimer implements Timer {
  _SegmentedTimer(this._delay, this._callback, this._maxSegment) {
    _arm();
  }

  final Duration _delay;
  final void Function() _callback;
  final Duration _maxSegment;
  final Stopwatch _stopwatch = Stopwatch()..start();
  Timer? _segment;
  bool _fired = false;

  void _arm() {
    final left = _delay - _stopwatch.elapsed;
    if (left <= _maxSegment) {
      _segment = Timer(left, _fire);
    } else {
      _segment = Timer(_maxSegment, _arm);
    }
  }

  void _fire() {
    _segment = null;
    _fired = true;
    _callback();
  }

  @override
  bool get isActive => _segment?.isActive ?? false;

  @override
  int get tick => _fired ? 1 : 0;

  @override
  void cancel() {
    _segment?.cancel();
    _segment = null;
  }
}
