import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_waveform/just_waveform.dart';
import 'package:material_ui/material_ui.dart';
import 'package:tingdubao/library.dart';
import 'package:tingdubao/models.dart';
import 'package:tingdubao/recognition_workflow.dart';
import 'package:tingdubao/services/speech_recognition.dart';

class ControlledSpeech extends SpeechRecognitionService {
  final started = Completer<void>();
  final result = Completer<List<Cue>>();
  final cancellation = Completer<void>();
  int cancels = 0;
  @override
  Future<List<Cue>> transcribe(
    String path, {
    required String locale,
    Duration? start,
    Duration? end,
    bool offline = true,
  }) {
    started.complete();
    return result.future;
  }

  @override
  Future<void> cancel() async {
    cancels++;
    await cancellation.future;
  }
}

class RouteLog extends NavigatorObserver {
  final popped = <String?>[];
  final removed = <String?>[];
  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    popped.add(route.settings.name);
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    removed.add(route.settings.name);
  }
}

Waveform bins(List<int> amplitudes) => Waveform(
  version: 1,
  flags: 0,
  sampleRate: 1000,
  samplesPerPixel: 100,
  length: amplitudes.length,
  data: [
    for (final amplitude in amplitudes) ...[-amplitude, amplitude],
  ],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  group('silence based splitting', () {
    test('silent audio emits no invented intervals', () {
      expect(splitWaveform(bins(List.filled(30, 0))), isEmpty);
    });
    test(
      'a genuine pause creates separate intervals trimmed around speech',
      () {
        final wave = bins([
          ...List.filled(3, 0),
          ...List.filled(8, 1000),
          ...List.filled(6, 0),
          ...List.filled(5, 900),
          ...List.filled(8, 0),
        ]);
        final cues = splitWaveform(wave);
        expect(cues, hasLength(2));
        expect(cues.first.start, const Duration(milliseconds: 250));
        expect(cues.first.end, const Duration(milliseconds: 1200));
        expect(cues.last.start, const Duration(milliseconds: 1650));
        expect(cues.last.end, const Duration(milliseconds: 2300));
        expect(
          cues.every((cue) => cue.text.isEmpty && cue.translation.isEmpty),
          isTrue,
        );
      },
    );
    test(
      'a brief pause stays in one phrase and trailing speech is not dropped',
      () {
        final wave = bins([
          ...List.filled(5, 1000),
          ...List.filled(2, 0),
          ...List.filled(4, 900),
        ]);
        final cues = splitWaveform(wave);
        expect(cues, hasLength(1));
        expect(cues.single.start, Duration.zero);
        expect(cues.single.end, wave.duration);
      },
    );
    test(
      'final phrase is emitted even without a full trailing silence window',
      () {
        final wave = bins([
          ...List.filled(5, 1000),
          ...List.filled(5, 0),
          ...List.filled(3, 900),
        ]);
        final cues = splitWaveform(wave);
        expect(cues, hasLength(2));
        expect(cues.last.end, wave.duration);
        expect(cues.last.start, const Duration(milliseconds: 950));
      },
    );
    test('partial waveform bins never escape the requested range', () {
      final wave = bins(List.filled(30, 1000));
      final cues = splitWaveform(
        wave,
        start: const Duration(milliseconds: 650),
        end: const Duration(milliseconds: 1450),
      );
      expect(cues.single.start, const Duration(milliseconds: 650));
      expect(cues.single.end, const Duration(milliseconds: 1450));
      expect(
        splitWaveform(wave, end: const Duration(seconds: 20)).single.end,
        wave.duration,
      );
      expect(splitWaveform(wave, start: wave.duration), isEmpty);
      expect(splitWaveform(wave, start: const Duration(seconds: 20)), isEmpty);
    });
    test('negative or reversed ranges are rejected before indexing', () {
      final wave = bins(List.filled(10, 1000));
      expect(
        () => splitWaveform(wave, start: const Duration(milliseconds: -1)),
        throwsArgumentError,
      );
      expect(
        () => splitWaveform(
          wave,
          start: const Duration(seconds: 1),
          end: const Duration(milliseconds: 500),
        ),
        throwsArgumentError,
      );
    });
  });

  for (final nativeFinishesFirst in [false, true]) {
    testWidgets(
      'cancel closes only its dialog when native finishes first=$nativeFinishesFirst',
      (tester) async {
        final speech = ControlledSpeech();
        final observer = RouteLog();
        final navigator = GlobalKey<NavigatorState>();
        final item = MediaItem(
          id: 'sample',
          name: 'sample',
          path: 'sample.mp3',
        );
        await tester.pumpWidget(
          MaterialApp(
            navigatorKey: navigator,
            navigatorObservers: [observer],
            home: const Scaffold(body: Text('library root')),
          ),
        );
        unawaited(
          navigator.currentState!.push(
            MaterialPageRoute<void>(
              settings: const RouteSettings(name: 'file'),
              builder: (_) => const Scaffold(body: Text('selected file page')),
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));
        unawaited(
          navigator.currentState!.push(
            DialogRoute<List<Cue>>(
              context: navigator.currentContext!,
              settings: const RouteSettings(name: 'recognition'),
              builder: (_) => RecognitionProgressDialog(
                item: item,
                segment: null,
                service: speech,
                speech: true,
                offline: true,
                locale: 'en_US',
              ),
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));
        for (var i = 0; i < 20 && !speech.started.isCompleted; i++) {
          await tester.pump(const Duration(milliseconds: 10));
        }
        expect(speech.started.isCompleted, isTrue);
        await tester.tap(find.text('取消'));
        await tester.pump();
        expect(speech.cancels, 1);
        if (nativeFinishesFirst) {
          speech.result.completeError(
            PlatformException(
              code: 'cancelled',
              message: 'cancelled after export settled',
            ),
          );
        } else {
          speech.cancellation.complete();
        }
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));
        expect(observer.popped, isEmpty);
        expect(find.text('正在取消…'), findsOneWidget);
        await tester.binding.handlePopRoute();
        await tester.pump();
        expect(observer.popped, isEmpty);
        if (nativeFinishesFirst) {
          speech.cancellation.complete();
        } else {
          speech.result.completeError(
            PlatformException(
              code: 'cancelled',
              message: 'cancelled after export settled',
            ),
          );
        }
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));
        expect(observer.popped, ['recognition']);
        expect(find.text('selected file page'), findsOneWidget);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
  testWidgets('completion behind another route removes only its own dialog', (
    tester,
  ) async {
    final speech = ControlledSpeech();
    final observer = RouteLog();
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        navigatorObservers: [observer],
        home: const Scaffold(body: Text('library root')),
      ),
    );
    unawaited(
      navigator.currentState!.push(
        DialogRoute<List<Cue>>(
          context: navigator.currentContext!,
          settings: const RouteSettings(name: 'recognition'),
          builder: (_) => RecognitionProgressDialog(
            item: MediaItem(id: 'sample', name: 'sample', path: 'sample.mp3'),
            segment: null,
            service: speech,
            speech: true,
            offline: true,
            locale: 'en_US',
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    unawaited(
      navigator.currentState!.push(
        MaterialPageRoute<void>(
          settings: const RouteSettings(name: 'other'),
          builder: (_) => const Scaffold(body: Text('another page')),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    speech.result.complete([
      Cue(
        id: 'recognized',
        start: Duration.zero,
        end: const Duration(seconds: 1),
        text: 'Hello',
      ),
    ]);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(observer.popped, isEmpty);
    expect(observer.removed, ['recognition']);
    expect(find.text('another page'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
