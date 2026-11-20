import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_waveform/just_waveform.dart';
import 'package:tingdubao/library.dart';
import 'package:tingdubao/services/player.dart';
import 'package:tingdubao/services/waveform.dart';
import 'package:tingdubao/waveform_view.dart';

import 'player_test.dart' show FakeAudio;
import 'waveform_service_test.dart' show waveformFixture;

class WavePlayer extends StudyPlayer {
  WavePlayer() : super(audio: FakeAudio());
  Duration current = Duration.zero;
  @override
  Duration get position => current;
  @override
  Duration get duration => const Duration(seconds: 10);
  void select(String path) {
    item = MediaItem(id: path, name: path, path: path);
    notifyListeners();
  }

  void move(Duration value) {
    current = value;
    notifyListeners();
  }
}

class FixtureService extends WaveformService {
  @override
  Future<Waveform> load(String path) async => waveformFixture();
}

class PendingService extends WaveformService {
  final jobs = <String, Completer<Waveform>>{};
  @override
  Future<Waveform> load(String path) =>
      (jobs[path] = Completer<Waveform>()).future;
}

void main() {
  late WavePlayer player;
  setUp(() {
    player = WavePlayer()..select('first.mp3');
  });
  tearDown(() {
    player.dispose();
  });

  Future<void> mount(
    WidgetTester tester, {
    WaveformService? service,
    ValueChanged<Duration>? onSeek,
    void Function(Duration, Duration)? onRangeChanged,
    Duration a = const Duration(seconds: 1),
    Duration b = const Duration(seconds: 3),
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 400,
              child: StudyWaveform(
                player: player,
                waveformService: service ?? FixtureService(),
                a: a,
                b: b,
                onSeek: onSeek ?? (_) {},
                onRangeChanged: onRangeChanged ?? (_, _) {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  testWidgets('a waveform tap seeks to its actual time coordinate', (
    tester,
  ) async {
    Duration? seek;
    await mount(tester, onSeek: (value) => seek = value);
    final origin = tester.getTopLeft(find.byType(StudyWaveform));
    await tester.tapAt(origin + const Offset(296, 38));
    expect(seek, const Duration(seconds: 2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('dragging A beyond B cannot make the AB range empty', (
    tester,
  ) async {
    Duration? selectedA;
    Duration? selectedB;
    await mount(
      tester,
      onRangeChanged: (a, b) {
        selectedA = a;
        selectedB = b;
      },
    );
    await tester.drag(
      find.byKey(const ValueKey('waveform-a-handle')),
      const Offset(300, 0),
    );
    expect(selectedA, isNotNull);
    expect(selectedA! < selectedB!, isTrue);
    expect(selectedB, const Duration(seconds: 3));
    expect(selectedA, const Duration(milliseconds: 2999));
    expect(tester.takeException(), isNull);
  });

  testWidgets('dragging B before A keeps a positive range', (tester) async {
    Duration? selectedA;
    Duration? selectedB;
    await mount(
      tester,
      onRangeChanged: (a, b) {
        selectedA = a;
        selectedB = b;
      },
    );
    await tester.drag(
      find.byKey(const ValueKey('waveform-b-handle')),
      const Offset(-300, 0),
    );
    expect(selectedA, const Duration(seconds: 1));
    expect(selectedA! < selectedB!, isTrue);
    expect(selectedB, const Duration(milliseconds: 1001));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'a submillisecond range at the media end remains valid when dragging B',
    (tester) async {
      player.current = const Duration(seconds: 9);
      Duration? selectedA;
      Duration? selectedB;
      await mount(
        tester,
        a: const Duration(microseconds: 9999500),
        b: const Duration(seconds: 10),
        onRangeChanged: (a, b) {
          selectedA = a;
          selectedB = b;
        },
      );
      await tester.drag(
        find.byKey(const ValueKey('waveform-b-handle')),
        const Offset(-300, 0),
      );
      expect(selectedA, const Duration(microseconds: 9999500));
      expect(selectedB, const Duration(seconds: 10));
      expect(selectedA! < selectedB!, isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('automatic scrolling follows the playback position', (
    tester,
  ) async {
    await mount(tester);
    player.move(const Duration(seconds: 4));
    await tester.pump();
    final scroll = tester.widget<SingleChildScrollView>(
      find.byKey(const ValueKey('waveform-scroll')),
    );
    expect(scroll.controller!.offset, closeTo(192, 0.5));
    expect(tester.takeException(), isNull);
  });

  testWidgets('old file extraction errors cannot overwrite a newer waveform', (
    tester,
  ) async {
    final service = PendingService();
    await mount(tester, service: service);
    expect(find.text('正在生成波形…'), findsOneWidget);
    player.select('second.mp3');
    await tester.pump();
    service.jobs['second.mp3']!.complete(waveformFixture());
    await tester.pump();
    await tester.pump();
    expect(find.text('正在生成波形…'), findsNothing);
    service.jobs['first.mp3']!.completeError(
      const FormatException('old file failed'),
    );
    await tester.pump();
    expect(find.text('无法生成波形，点此重试'), findsNothing);
    expect(find.byKey(const ValueKey('waveform-scroll')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('extraction may finish after the waveform widget was disposed', (
    tester,
  ) async {
    final service = PendingService();
    await mount(tester, service: service);
    await tester.pumpWidget(const SizedBox.shrink());
    service.jobs['first.mp3']!.complete(waveformFixture());
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
