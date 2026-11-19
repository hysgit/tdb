import 'package:flutter_test/flutter_test.dart';
import 'package:tingdubao/repeat_plan.dart';

void main() {
  const a = Duration(seconds: 2);
  const b = Duration(seconds: 5);

  test('configuration revisions invalidate delayed playback only on edits', () {
    final plan = RepeatPlan();
    final initial = plan.revision;
    plan.setRange(a, b);
    expect(plan.revision, initial + 1);
    plan.onPosition(b);
    plan.acknowledgeSeek();
    expect(plan.revision, initial + 1);
    plan.reset();
    expect(plan.revision, initial + 2);
    plan.clear();
    expect(plan.revision, initial + 3);
  });

  test('unconfigured plans do not request playback changes', () {
    final plan = RepeatPlan();
    expect(plan.start, isNull);
    expect(plan.end, isNull);
    expect(plan.count, 0);
    expect(plan.gap, Duration.zero);
    expect(plan.completed, 0);
    expect(plan.enabled, isFalse);
    expect(plan.onPosition(b), isNull);
    plan.reset();
    expect(plan.enabled, isFalse);
  });

  test('zero count repeats indefinitely and preserves the configured gap', () {
    final plan = RepeatPlan()
      ..setRange(a, b, gap: const Duration(milliseconds: 700));
    expect(plan.onPosition(a), isNull);
    expect(plan.onPosition(b - const Duration(microseconds: 1)), isNull);
    for (var round = 0; round < 8; round++) {
      final decision = plan.onPosition(b)!;
      expect(decision.seekTo, a);
      expect(decision.wait, const Duration(milliseconds: 700));
      expect(decision.finished, isFalse);
      expect(plan.completed, round + 1);
      expect(plan.enabled, isTrue);
      plan.acknowledgeSeek();
    }
  });

  test('count one stops at B without seeking back to A', () {
    final plan = RepeatPlan()..setRange(a, b, count: 1);
    final decision = plan.onPosition(b)!;
    expect(decision.finished, isTrue);
    expect(decision.seekTo, b);
    expect(decision.wait, Duration.zero);
    expect(plan.completed, 1);
    expect(plan.enabled, isFalse);
    expect(plan.onPosition(b), isNull);
    plan.acknowledgeSeek();
    expect(plan.onPosition(b), isNull);
  });

  test('count two loops once and stops on the second traversal', () {
    final plan = RepeatPlan()..setRange(a, b, count: 2);
    expect(plan.onPosition(b)!.finished, isFalse);
    plan.acknowledgeSeek();
    expect(plan.onPosition(a), isNull);
    final decision = plan.onPosition(b)!;
    expect(decision.finished, isTrue);
    expect(plan.completed, 2);
    expect(plan.enabled, isFalse);
  });

  test('overshoot triggers one boundary and pending callbacks are ignored', () {
    final plan = RepeatPlan()..setRange(a, b, count: 2);
    final decision = plan.onPosition(const Duration(seconds: 12))!;
    expect(decision.seekTo, a);
    expect(decision.finished, isFalse);
    expect(plan.onPosition(b), isNull);
    expect(plan.onPosition(const Duration(seconds: 99)), isNull);
    expect(plan.completed, 1);
    plan.acknowledgeSeek();
    expect(plan.onPosition(a), isNull);
    expect(plan.onPosition(b)!.finished, isTrue);
  });

  test('reset and replacement clear in-flight state and completed rounds', () {
    final plan = RepeatPlan()..setRange(a, b, count: 2);
    plan.onPosition(b);
    plan.reset();
    expect(plan.completed, 0);
    expect(plan.enabled, isTrue);
    expect(plan.onPosition(b)!.finished, isFalse);
    plan.setRange(Duration.zero, const Duration(seconds: 1), count: 1);
    expect(plan.completed, 0);
    expect(plan.onPosition(const Duration(seconds: 1))!.finished, isTrue);
    plan.reset();
    expect(plan.enabled, isTrue);
    expect(plan.completed, 0);
  });

  test('clear removes the configuration and pending operation', () {
    final plan = RepeatPlan()..setRange(a, b, count: 4);
    plan.onPosition(b);
    plan.clear();
    expect(plan.start, isNull);
    expect(plan.end, isNull);
    expect(plan.completed, 0);
    expect(plan.count, 0);
    expect(plan.gap, Duration.zero);
    expect(plan.enabled, isFalse);
    expect(plan.onPosition(b), isNull);
  });

  test('invalid ranges fail without changing the previous configuration', () {
    final plan = RepeatPlan()..setRange(a, b, count: 2);
    expect(() => plan.setRange(b, a), throwsArgumentError);
    expect(() => plan.setRange(a, a), throwsArgumentError);
    expect(
      () => plan.setRange(const Duration(seconds: -1), b),
      throwsArgumentError,
    );
    expect(() => plan.setRange(a, b, count: -1), throwsArgumentError);
    expect(
      () => plan.setRange(a, b, gap: const Duration(microseconds: -1)),
      throwsArgumentError,
    );
    expect(plan.start, a);
    expect(plan.end, b);
    expect(plan.count, 2);
    expect(plan.enabled, isTrue);
  });
}
