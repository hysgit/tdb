import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:tingdubao/library.dart';
import 'package:tingdubao/services/player.dart';

class FakeAudio extends Fake implements AudioPlayer {
  final errors = StreamController<PlayerException>.broadcast();
  final loaded = <String>[];
  Completer<void>? loadGate;
  Duration current = Duration.zero;
  Duration? length;
  bool active = false;
  ProcessingState processing = ProcessingState.idle;
  int plays = 0;
  double lastSpeed = 1;

  @override
  Stream<PlayerException> get errorStream => errors.stream;
  @override
  Duration get position => current;
  @override
  Duration? get duration => length;
  @override
  bool get playing => active;
  @override
  ProcessingState get processingState => processing;
  @override
  Future<Duration?> setFilePath(
    String path, {
    Duration? initialPosition,
    bool preload = true,
    dynamic tag,
  }) async {
    loaded.add(path);
    final gate = loadGate;
    loadGate = null;
    if (gate != null) await gate.future;
    length = const Duration(seconds: 10);
    current = initialPosition ?? Duration.zero;
    processing = ProcessingState.ready;
    return length;
  }

  @override
  Future<void> stop() async {
    active = false;
    current = Duration.zero;
    processing = ProcessingState.idle;
  }

  @override
  Future<void> pause() async {
    active = false;
  }

  @override
  Future<void> play() async {
    active = true;
    plays++;
  }

  @override
  Future<void> seek(Duration? position, {int? index}) async {
    current = position ?? Duration.zero;
    processing = ProcessingState.ready;
  }

  @override
  Future<void> setSpeed(double speed) async {
    lastSpeed = speed;
  }

  @override
  Future<void> setVolume(double volume) async {}
  @override
  Future<void> dispose() async {
    active = false;
    await errors.close();
  }
}

Future<void> waitUntil(bool Function() condition) async {
  for (var i = 0; i < 200 && !condition(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(condition(), isTrue, reason: 'Timed out waiting for player state');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temporary;
  late FakeAudio audio;
  late StudyPlayer player;
  late MediaItem first;
  late MediaItem second;
  var disposedByTest = false;

  setUp(() async {
    disposedByTest = false;
    temporary = await Directory.systemTemp.createTemp('tingdubao_player_');
    first = MediaItem(
      id: 'first',
      name: 'first',
      path: '${temporary.path}/first.mp3',
    );
    second = MediaItem(
      id: 'second',
      name: 'second',
      path: '${temporary.path}/second.mp3',
    );
    await File(first.path).writeAsBytes([0]);
    await File(second.path).writeAsBytes([0]);
    audio = FakeAudio();
    player = StudyPlayer(audio: audio);
  });

  tearDown(() async {
    if (!disposedByTest) player.dispose();
    await Future<void>.delayed(Duration.zero);
    await temporary.delete(recursive: true);
  });

  test(
    'speed supports the recorded 0.1 to 5.0 range and clamps outside it',
    () async {
      await player.open(first);
      await player.setSpeed(5.0);
      expect(player.speed, 5.0);
      expect(audio.lastSpeed, 5.0);
      await player.setSpeed(8.0);
      expect(player.speed, 5.0);
      expect(audio.lastSpeed, 5.0);
      await player.setSpeed(0.0);
      expect(player.speed, 0.1);
      expect(audio.lastSpeed, 0.1);
    },
  );

  test('dispose during a pending load prevents later notifications', () async {
    final gate = Completer<void>();
    audio.loadGate = gate;
    var notifications = 0;
    player.addListener(() => notifications++);
    final loading = player.open(first);
    await waitUntil(() => audio.loaded.isNotEmpty);
    player.dispose();
    disposedByTest = true;
    final countAtDispose = notifications;
    gate.complete();
    await loading;
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(notifications, countAtDispose);
  });

  test(
    'switching files during an AB interval cancels the old resume',
    () async {
      await player.open(first);
      player.repeat.setRange(
        const Duration(seconds: 2),
        const Duration(seconds: 5),
        gap: const Duration(milliseconds: 220),
      );
      await player.play();
      audio.current = const Duration(seconds: 5);
      await waitUntil(
        () => !audio.active && audio.current == const Duration(seconds: 2),
      );
      await player.open(second);
      await Future<void>.delayed(const Duration(milliseconds: 350));
      expect(player.item, same(second));
      expect(audio.plays, 1);
      expect(player.playing, isFalse);
    },
  );

  test(
    'pause during a pending load does not strand the loading state',
    () async {
      final gate = Completer<void>();
      audio.loadGate = gate;
      final loading = player.open(first);
      await waitUntil(() => audio.loaded.isNotEmpty);
      await player.pause();
      gate.complete();
      await loading;
      expect(player.loading, isFalse);
      expect(player.error, isNull);
      expect(player.duration, const Duration(seconds: 10));
      expect(player.playing, isFalse);
    },
  );

  test(
    'switching during a load serializes sources and selects the newest file',
    () async {
      final gate = Completer<void>();
      audio.loadGate = gate;
      final firstLoad = player.open(first);
      await waitUntil(() => audio.loaded.length == 1);
      final secondLoad = player.open(second);
      expect(player.item, same(second));
      expect(player.position, Duration.zero);
      expect(player.duration, Duration.zero);
      gate.complete();
      await Future.wait([firstLoad, secondLoad]);
      expect(audio.loaded, [first.path, second.path]);
      expect(player.item, same(second));
      expect(player.loading, isFalse);
      expect(player.error, isNull);
    },
  );

  test(
    'a missing file has a visible path and exposes no stale audio state',
    () async {
      await player.open(first);
      audio.current = const Duration(seconds: 7);
      final missing = MediaItem(
        id: 'missing',
        name: 'missing',
        path: '${temporary.path}/missing.mp3',
      );
      await player.open(missing);
      expect(player.loading, isFalse);
      expect(player.item, same(missing));
      expect(player.error, contains(missing.path));
      expect(player.duration, Duration.zero);
      expect(player.position, Duration.zero);
      expect(player.playing, isFalse);
    },
  );

  test(
    'finite AB completion pauses exactly at B even after overshoot',
    () async {
      await player.open(first);
      player.repeat.setRange(
        const Duration(seconds: 2),
        const Duration(seconds: 5),
        count: 1,
      );
      await player.play();
      audio.current = const Duration(seconds: 6);
      await waitUntil(() => !player.repeat.enabled);
      await waitUntil(() => audio.current == const Duration(seconds: 5));
      expect(player.playing, isFalse);
      expect(audio.plays, 1);
    },
  );

  test('an AB boundary at native completion still seeks back to A', () async {
    await player.open(first);
    player.repeat.setRange(
      const Duration(seconds: 2),
      const Duration(seconds: 10),
    );
    await player.play();
    audio.current = const Duration(seconds: 10);
    audio.processing = ProcessingState.completed;
    await waitUntil(() => audio.plays == 2);
    expect(audio.current, const Duration(seconds: 2));
    expect(player.playing, isTrue);
  });

  for (final action in ['pause', 'clear', 'replace', 'seek']) {
    test(
      '$action during the AB interval cannot revive delayed playback',
      () async {
        await player.open(first);
        player.repeat.setRange(
          const Duration(seconds: 2),
          const Duration(seconds: 5),
          gap: const Duration(milliseconds: 220),
        );
        await player.play();
        audio.current = const Duration(seconds: 5);
        await waitUntil(
          () => !audio.active && audio.current == const Duration(seconds: 2),
        );
        switch (action) {
          case 'pause':
            await player.pause();
          case 'clear':
            player.repeat.clear();
          case 'replace':
            player.repeat.setRange(Duration.zero, const Duration(seconds: 1));
          case 'seek':
            await player.seek(const Duration(seconds: 7));
        }
        await Future<void>.delayed(const Duration(milliseconds: 350));
        expect(audio.plays, 1);
        expect(player.playing, isFalse);
      },
    );
  }
}
