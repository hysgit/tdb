import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:tingdubao/library.dart';
import 'package:tingdubao/models.dart';
import 'package:tingdubao/player_view.dart';
import 'package:tingdubao/services/player.dart';

import 'player_test.dart' show FakeAudio;

class ViewPlayer extends StudyPlayer {
  ViewPlayer() : super(audio: FakeAudio());
  Duration at = const Duration(seconds: 1);
  bool active = false;
  @override
  Duration get position => at;
  @override
  Duration get duration => const Duration(seconds: 90);
  @override
  bool get playing => active;
  @override
  Future<void> seek(Duration target) async {
    at = target;
    notifyListeners();
  }

  @override
  Future<void> play() async {
    active = true;
    notifyListeners();
  }

  @override
  Future<void> pause() async {
    active = false;
    notifyListeners();
  }

  void moveTo(Duration target) {
    at = target;
    notifyListeners();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late ViewPlayer player;
  late MediaItem item;
  late int saves;
  late List<String> messages;

  setUp(() {
    messenger.setMockMethodCallHandler(
      const MethodChannel('com.llfbandit.record/messages'),
      (_) async => null,
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('com.ryanheise.audio_session'),
      (_) async => null,
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('com.ryanheise.just_audio.methods'),
      (_) async => <String, dynamic>{},
    );
    player = ViewPlayer();
    item = MediaItem(
      id: 'demo',
      name: 'Introduction.mp3',
      path: 'demo.mp3',
      cues: parseSubtitles(
        utf8.decode(File('assets/demo/Introduction.json').readAsBytesSync()),
      ),
    );
    saves = 0;
    messages = [];
  });

  tearDown(() {
    player.dispose();
  });

  Future<void> mount(
    WidgetTester tester, {
    Size size = const Size(390, 844),
    bool media = true,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    player.item = media ? item : null;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFFDC601D)),
        ),
        home: Scaffold(
          appBar: AppBar(title: const Text('听读宝')),
          body: PlayerView(
            player: player,
            onSave: () async {
              saves++;
            },
            onMessage: messages.add,
          ),
          bottomNavigationBar: NavigationBar(
            selectedIndex: 1,
            destinations: const [
              NavigationDestination(icon: Icon(Icons.folder), label: '文件'),
              NavigationDestination(icon: Icon(Icons.headphones), label: '听读'),
              NavigationDestination(icon: Icon(Icons.star), label: '收藏'),
              NavigationDestination(icon: Icon(Icons.settings), label: '设置'),
            ],
          ),
        ),
      ),
    );
    player.moveTo(const Duration(seconds: 1));
    await tester.pump(const Duration(milliseconds: 100));
  }

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 100));
    expect(messages, isEmpty);
    expect(tester.takeException(), isNull);
  }

  testWidgets('empty player gives a media selection instruction', (
    tester,
  ) async {
    await mount(tester, media: false);
    expect(find.text('选择一个音频或视频开始听读'), findsOneWidget);
    expect(find.text('开始录音'), findsNothing);
    await unmount(tester);
  });

  for (final size in [const Size(320, 568), const Size(390, 844)]) {
    testWidgets(
      'player with 23 source cues fits ${size.width}x${size.height}',
      (tester) async {
        await mount(tester, size: size);
        expect(item.cues, hasLength(23));
        expect(find.text('We had a theory about China.'), findsOneWidget);
        expect(find.text('听写'), findsOneWidget);
        expect(find.text('跟读'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await unmount(tester);
      },
    );
  }

  testWidgets('favorite toggles persist the original cue identity', (
    tester,
  ) async {
    await mount(tester);
    await tester.tap(find.byTooltip('收藏语句').first);
    await tester.pump();
    expect(item.favorites, contains(item.cues.first.id));
    expect(saves, 1);
    await tester.tap(find.byTooltip('取消收藏').first);
    await tester.pump();
    expect(item.favorites, isEmpty);
    expect(saves, 2);
    await unmount(tester);
  });

  testWidgets(
    'dictation retains input across gaps and moves only on explicit next',
    (tester) async {
      await mount(tester);
      await tester.tap(find.text('听写'));
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('第 1 / 23 句'), findsOneWidget);
      expect(find.text('We had a theory about China.'), findsNothing);
      await tester.enterText(
        find.byType(TextField),
        'We had a theory about China.',
      );
      player.moveTo(const Duration(milliseconds: 2100));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('We had a theory about China.'), findsOneWidget);
      expect(find.text('第 1 / 23 句'), findsOneWidget);
      expect(player.repeat.count, 1);
      expect(player.repeat.end, item.cues.first.end);
      await tester.tap(find.text('对照答案'));
      await tester.pump();
      expect(find.text('文字匹配 100 分'), findsOneWidget);
      await tester.tap(find.byTooltip('下一句'));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('第 2 / 23 句'), findsOneWidget);
      expect(find.text('文字匹配 100 分'), findsNothing);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        isEmpty,
      );
      await unmount(tester);
    },
  );

  testWidgets('subtitle editing validates bounds and preserves favorites', (
    tester,
  ) async {
    await mount(tester);
    final cue = item.cues.first;
    item.favorites = {cue.id};
    await tester.longPress(find.text(cue.text));
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.text('编辑字幕'), findsOneWidget);
    final fields = find.byType(TextFormField);
    await tester.enterText(fields.at(3), '100');
    await tester.tap(find.text('保存'));
    await tester.pump();
    expect(find.text('结束时间不能超过媒体长度'), findsOneWidget);
    expect(saves, 0);
    await tester.enterText(fields.at(0), 'Updated sentence.');
    await tester.enterText(fields.at(2), '0.5');
    await tester.enterText(fields.at(3), '1.9');
    await tester.tap(find.text('保存'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(saves, 1);
    expect(item.cues.first.id, cue.id);
    expect(item.cues.first.text, 'Updated sentence.');
    expect(item.cues.first.start.inMilliseconds, 500);
    expect(item.favorites, contains(cue.id));
    expect(item.cues.first.inferredTiming, isFalse);
    await unmount(tester);
  });
}
