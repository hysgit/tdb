/// One action requested by the AB repeat plan.
///
/// A finished action stops at B. Otherwise seek to A, wait, then resume.
class RepeatDecision {
  const RepeatDecision({
    required this.seekTo,
    required this.wait,
    required this.finished,
  });

  final Duration seekTo;
  final Duration wait;
  final bool finished;
}

/// AB repeat decisions without playback or timer dependencies.
class RepeatPlan {
  Duration? get start => _start;
  Duration? get end => _end;
  int get count => _count;
  Duration get gap => _gap;
  int get completed => _completed;
  bool get enabled => _enabled;
  int get revision => _revision;

  Duration? _start;
  Duration? _end;
  int _count = 0;
  Duration _gap = Duration.zero;
  int _completed = 0;
  bool _enabled = false;
  bool _awaitingSeek = false;
  int _revision = 0;

  void setRange(
    Duration a,
    Duration b, {
    int count = 0,
    Duration gap = Duration.zero,
  }) {
    if (a.isNegative || b <= a) {
      throw ArgumentError('AB range requires 0 <= A < B.');
    }
    if (count < 0 || gap.isNegative) {
      throw ArgumentError('Repeat count and interval must be nonnegative.');
    }
    _start = a;
    _end = b;
    _count = count;
    _gap = gap;
    reset();
  }

  void clear() {
    _revision++;
    _start = null;
    _end = null;
    _count = 0;
    _gap = Duration.zero;
    _completed = 0;
    _enabled = false;
    _awaitingSeek = false;
  }

  /// Restart the configured range, including a previously finished plan.
  void reset() {
    _revision++;
    _completed = 0;
    _awaitingSeek = false;
    _enabled = _start != null && _end != null;
  }

  /// Call after the player has completed the requested seek back to A.
  void acknowledgeSeek() {
    _awaitingSeek = false;
  }

  RepeatDecision? onPosition(Duration position) {
    if (!_enabled || _awaitingSeek || position < _end!) {
      return null;
    }
    _completed++;
    if (_count > 0 && _completed >= _count) {
      _enabled = false;
      return RepeatDecision(seekTo: _end!, wait: Duration.zero, finished: true);
    }
    _awaitingSeek = true;
    return RepeatDecision(seekTo: _start!, wait: _gap, finished: false);
  }
}
