import 'dart:convert';
import 'dart:async';
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
  late GlobalKey<PlayerViewState> viewKey;
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
    viewKey = GlobalKey<PlayerViewState>();
  });
  tearDown(() {
    player.dispose();
  });
  Future<void> mount(
    WidgetTester tester, {
    Size size = const Size(390, 844),
    bool media = true,
    RecognizeSegments? recognize,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    player.item = media ? item : null;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFFF58425)),
        ),
        home: Scaffold(
          appBar: AppBar(
            title: Text(item.name),
            actions: [
              IconButton(
                tooltip: '更多',
                onPressed: () => viewKey.currentState?.showMore(),
                icon: const Icon(Icons.more_horiz),
              ),
            ],
          ),
          body: PlayerView(
            key: viewKey,
            player: player,
            onSave: () async {
              saves++;
            },
            onMessage: messages.add,
            onRecognize: recognize,
          ),
        ),
      ),
    );
    player.moveTo(const Duration(seconds: 1));
    await tester.pump(const Duration(milliseconds: 100));
  }

  Future<void> unmount(WidgetTester tester, {bool allowMessage = false}) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 100));
    if (!allowMessage) expect(messages, isEmpty);
    expect(tester.takeException(), isNull);
  }

  testWidgets('empty player requests media selection', (tester) async {
    await mount(tester, media: false);
    expect(find.text('选择一个音频或视频开始听读'), findsOneWidget);
    await unmount(tester);
  });
  for (final size in [const Size(320, 568), const Size(390, 844)]) {
    testWidgets(
      'current recording toolbar and source rows fit ${size.width} width',
      (tester) async {
        await mount(tester, size: size);
        expect(item.cues, hasLength(23));
        for (final text in [
          '设置 A',
          '设置 B',
          '添加行',
          '删除行',
          '分句/识别',
          '导入/导出',
          '精听',
          '单句重复',
        ]) {
          expect(find.text(text), findsOneWidget);
        }
        expect(find.byType(SegmentedButton<int>), findsNothing);
        expect(find.text('We had a theory about China.'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await unmount(tester);
      },
    );
  }
  testWidgets(
    'manual AB row creation and deletion persist without deleting recordings',
    (tester) async {
      item.cues = [];
      await mount(tester);
      expect(find.text('自动分句、语音识别'), findsOneWidget);
      await tester.tap(find.text('手动分句'));
      await tester.pump();
      expect(item.cues, hasLength(1));
      expect(item.cues.single.start.inSeconds, 1);
      expect(saves, 1);
      final id = item.cues.single.id;
      item.attachRecording(id, 'retained.m4a');
      item.favorites = {id};
      await tester.tap(find.text('删除行'));
      await tester.pump();
      await tester.tap(find.widgetWithText(TextButton, '删除'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(item.cues, isEmpty);
      expect(item.favorites, isEmpty);
      expect(item.cueRecordings, isEmpty);
      expect(item.recordings, ['retained.m4a']);
      expect(saves, 2);
      await unmount(tester);
    },
  );
  testWidgets('marking A and B changes the selected persistent segment', (
    tester,
  ) async {
    await mount(tester);
    await tester.tap(find.text('设置 A'));
    await tester.pump();
    expect(item.cues.first.start.inMilliseconds, 1000);
    expect(saves, 1);
    player.moveTo(const Duration(milliseconds: 1500));
    await tester.pump();
    await tester.tap(find.text('设置 B'));
    await tester.pump();
    expect(item.cues.first.end.inMilliseconds, 1500);
    expect(saves, 2);
    await unmount(tester);
  });
  testWidgets(
    'row expansion exposes real per-cue controls and preserves favorite identity',
    (tester) async {
      await mount(tester);
      await tester.tap(find.text(item.cues.first.text));
      await tester.pump();
      for (final tooltip in ['回听录音', '跟读录音', '原音与录音对比', '播放片段原音', '识别这一行']) {
        expect(find.byTooltip(tooltip), findsOneWidget);
      }
      final vs = find.descendant(
        of: find.byTooltip('原音与录音对比'),
        matching: find.byType(TextButton),
      );
      expect(tester.widget<TextButton>(vs).onPressed, isNull);
      await tester.tap(find.byTooltip('收藏语句').first);
      await tester.pump();
      expect(item.favorites, contains(item.cues.first.id));
      expect(saves, 1);
      await unmount(tester);
    },
  );
  testWidgets('single sentence repeat and custom speed edits persist', (
    tester,
  ) async {
    await mount(tester);
    await tester.tap(find.text('单句重复'));
    await tester.pump();
    expect(item.singleSentence, isFalse);
    expect(saves, 1);
    await tester.tap(find.text('单句重复'));
    await tester.pump();
    expect(item.singleSentence, isTrue);
    expect(player.repeat.enabled, isTrue);
    expect(player.repeat.count, 0);
    unawaited(viewKey.currentState!.showCustomSpeeds());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.tap(find.byTooltip('速度 1 增加'));
    await tester.pump();
    expect(item.customSpeeds.first, .45);
    expect(saves, 3);
    await tester.tap(find.byTooltip('关闭速度设置'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await unmount(tester);
  });
  testWidgets(
    'custom speed stepper reaches five and clamps at the same limit',
    (tester) async {
      item.customSpeeds = [4.95];
      await mount(tester);
      unawaited(viewKey.currentState!.showCustomSpeeds());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      await tester.tap(find.byTooltip('速度 1 增加'));
      await tester.pump();
      expect(item.customSpeeds.single, 5);
      await tester.tap(find.byTooltip('速度 1 增加'));
      await tester.pump();
      expect(item.customSpeeds.single, 5);
      expect(
        MediaItem.fromJson(
          jsonDecode(jsonEncode(item.toJson())) as Map<String, dynamic>,
        ).customSpeeds.single,
        5,
      );
      await tester.tap(find.byTooltip('关闭速度设置'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      await unmount(tester);
    },
  );
  testWidgets('missing speech service reports a real unavailable state', (
    tester,
  ) async {
    await mount(tester);
    await tester.tap(find.text('分句/识别'));
    await tester.pump();
    expect(messages.single, contains('尚未配置语音识别服务'));
    expect(saves, 0);
    await unmount(tester, allowMessage: true);
  });
  testWidgets(
    'recognition never overwrites a concurrently edited subtitle list',
    (tester) async {
      final result = Completer<List<Cue>?>();
      await mount(tester, recognize: (_, _) => result.future);
      await tester.tap(find.text('分句/识别'));
      await tester.pump();
      await tester.tap(find.text('添加行'));
      await tester.pump();
      expect(item.cues, hasLength(24));
      result.complete([
        Cue(
          id: 'recognized',
          start: Duration.zero,
          end: const Duration(seconds: 2),
          text: 'Recognized',
        ),
      ]);
      await tester.pump();
      expect(item.cues, hasLength(24));
      expect(messages.single, contains('未覆盖'));
      await unmount(tester, allowMessage: true);
    },
  );
  testWidgets(
    'dictation is accessed through more and retains input across gaps',
    (tester) async {
      await mount(tester);
      await tester.tap(find.byTooltip('更多'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      await tester.tap(find.text('听写'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.text('第 1 / 23 句'), findsOneWidget);
      await tester.enterText(
        find.byType(TextField),
        'We had a theory about China.',
      );
      player.moveTo(const Duration(milliseconds: 2100));
      await tester.pump();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'We had a theory about China.',
      );
      await tester.tap(find.text('对照答案'));
      await tester.pump();
      expect(find.text('文字匹配 100 分'), findsOneWidget);
      await tester.tap(find.byTooltip('下一句'));
      await tester.pump();
      expect(find.text('第 2 / 23 句'), findsOneWidget);
      await tester.tap(find.text('完成'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      await unmount(tester);
    },
  );
  testWidgets(
    'subtitle editor rejects out of range time and keeps identity and favorites',
    (tester) async {
      await mount(tester);
      final cue = item.cues.first;
      item.favorites = {cue.id};
      await tester.tap(find.byTooltip('编辑字幕').first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      final fields = find.byType(TextFormField);
      await tester.enterText(fields.at(3), '100');
      await tester.tap(find.text('保存'));
      await tester.pump();
      expect(find.text('结束时间不能超过媒体长度'), findsOneWidget);
      expect(saves, 0);
      await tester.enterText(fields.at(0), 'Updated sentence.');
      await tester.enterText(fields.at(2), '.5');
      await tester.enterText(fields.at(3), '1.9');
      await tester.tap(find.text('保存'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(saves, 1);
      expect(item.cues.first.id, cue.id);
      expect(item.cues.first.text, 'Updated sentence.');
      expect(item.favorites, contains(cue.id));
      await unmount(tester);
    },
  );
}
