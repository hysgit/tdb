import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:tingdubao/home_sections.dart';
import 'package:tingdubao/import_page.dart';
import 'package:tingdubao/library.dart';
import 'package:tingdubao/library_state.dart';
import 'package:tingdubao/main.dart';
import 'package:tingdubao/models.dart';
import 'package:tingdubao/player_view.dart';
import 'package:tingdubao/recordings_page.dart';
import 'package:tingdubao/services/player.dart';

import 'player_test.dart' show FakeAudio;

/// Main-shell tests isolate storage; LibraryState's disk/rollback behavior has
/// separate repository tests. These paths never refer to a user's media library.
class HomeFlowRepository extends LibraryRepository {
  HomeFlowRepository()
    : super(Directory.systemTemp.createTempSync('tdb-home-flow-'));
  Map<String, dynamic>? saved;
  int writes = 0;
  @override
  Future<void> write(Map<String, dynamic> value) async {
    saved = jsonDecode(jsonEncode(value)) as Map<String, dynamic>;
    writes++;
  }
}

class HomeFlowPlayer extends StudyPlayer {
  HomeFlowPlayer() : super(audio: FakeAudio());
  Duration at = Duration.zero;
  bool active = false;
  final opened = <String>[];
  @override
  Duration get position => at;
  @override
  Duration get duration => const Duration(seconds: 90);
  @override
  bool get playing => active;
  @override
  Future<void> open(MediaItem selected) async {
    item = selected;
    at = Duration(milliseconds: selected.positionMs);
    active = false;
    repeat.clear();
    opened.add(selected.id);
    notifyListeners();
  }

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

LibraryState homeFlowFixture(HomeFlowRepository repository) {
  final state = LibraryState(repository);
  state.folders = {'课程', '课程/第一课', '归档'};
  state.items = [
    MediaItem(
      id: 'root-a',
      name: '音频练习.mp3',
      path: 'home-flow-root-a.mp3',
      cues: [
        Cue(
          id: 'sample-line',
          start: Duration.zero,
          end: const Duration(seconds: 5),
          text: 'Public sample listening practice.',
        ),
      ],
    ),
    MediaItem(id: 'root-b', name: '跟读示例.mp3', path: 'home-flow-root-b.mp3'),
    MediaItem(
      id: 'course',
      name: '课程介绍.mp3',
      path: 'home-flow-course.mp3',
      folder: '课程',
    ),
    MediaItem(
      id: 'nested',
      name: '第一课示例.mp3',
      path: 'home-flow-nested.mp3',
      folder: '课程/第一课',
    ),
  ];
  return state;
}

void installHomePluginMocks() {
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
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
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late HomeFlowRepository repository;
  late LibraryState library;
  late HomeFlowPlayer player;
  setUp(() {
    installHomePluginMocks();
  });

  Future<void> pumpFlow(WidgetTester tester) async {
    await tester.pump();
    for (var step = 0; step < 3; step++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
  }

  Future<void> mount(WidgetTester tester) async {
    repository = HomeFlowRepository();
    library = homeFlowFixture(repository);
    player = HomeFlowPlayer();
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        scaffoldMessengerKey: appMessenger,
        locale: const Locale('zh', 'CN'),
        supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: orange),
          scaffoldBackgroundColor: paper,
          useMaterial3: true,
        ),
        home: StudyHome(initialLibrary: library, studyPlayer: player),
      ),
    );
    await pumpFlow(tester);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await pumpFlow(tester);
      library.dispose();
      await tester.runAsync(() async {
        if (await repository.root.exists()) {
          await repository.root.delete(recursive: true);
        }
      });
    });
    expect(find.byType(CircularProgressIndicator), findsNothing);
  }

  Future<void> editRoot(WidgetTester tester) async {
    await tester.tap(find.byTooltip('添加'));
    await pumpFlow(tester);
    await tester.tap(find.text('编辑列表'));
    await pumpFlow(tester);
  }

  testWidgets('StudyHome switches through all five recorded tabs', (
    tester,
  ) async {
    await mount(tester);
    expect(find.byType(TdbBottomBar), findsOneWidget);
    for (final text in ['文件', '录音', '更多', '听力', '我的']) {
      expect(find.text(text), findsWidgets);
    }
    await tester.tap(find.byKey(const ValueKey('home-tab-1')));
    await pumpFlow(tester);
    expect(find.byType(RecordingsPage), findsOneWidget);
    expect(find.text('开始录音'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('home-tab-2')));
    await pumpFlow(tester);
    expect(find.byType(TdbMorePage), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('home-tab-3')));
    await pumpFlow(tester);
    expect(find.text('导入听力资料'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('home-tab-4')));
    await pumpFlow(tester);
    expect(find.byType(TdbMyPage), findsOneWidget);
    expect(find.text('Tdb'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('home-tab-0')));
    await pumpFlow(tester);
    expect(find.text('音频练习.mp3'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'folders show only direct children and parent navigation preserves hierarchy',
    (tester) async {
      await mount(tester);
      expect(find.text('课程'), findsOneWidget);
      expect(find.text('第一课'), findsNothing);
      expect(find.text('课程介绍.mp3'), findsNothing);
      await tester.tap(find.text('课程'));
      await pumpFlow(tester);
      expect(find.text('第一课'), findsOneWidget);
      expect(find.text('课程介绍.mp3'), findsOneWidget);
      expect(find.text('第一课示例.mp3'), findsNothing);
      expect(find.text('音频练习.mp3'), findsNothing);
      await tester.tap(find.text('第一课'));
      await pumpFlow(tester);
      expect(find.text('第一课示例.mp3'), findsOneWidget);
      await tester.tap(find.byTooltip('上一级'));
      await pumpFlow(tester);
      expect(find.text('课程介绍.mp3'), findsOneWidget);
      await tester.tap(find.byTooltip('上一级'));
      await pumpFlow(tester);
      expect(find.text('音频练习.mp3'), findsOneWidget);
      expect(find.text('课程介绍.mp3'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'player is a separate route without home tabs and returns to the retained mini player',
    (tester) async {
      await mount(tester);
      await tester.tap(find.text('音频练习.mp3'));
      await pumpFlow(tester);
      expect(
        find.byType(PlayerView),
        findsOneWidget,
        reason:
            'Opened=${player.opened}; writes=${repository.writes}; texts=${tester.widgetList<Text>(find.byType(Text)).map((text) => text.data).join(' | ')}',
      );
      expect(find.byType(TdbBottomBar), findsNothing);
      expect(player.opened, ['root-a']);
      player.moveTo(const Duration(seconds: 4));
      await tester.tap(find.byType(BackButton));
      await pumpFlow(tester);
      expect(find.byType(PlayerView), findsNothing);
      expect(find.byType(TdbBottomBar), findsOneWidget);
      expect(find.byTooltip('播放列表'), findsOneWidget);
      expect(find.text('00:04 / 01:30'), findsOneWidget);
      expect(player.item!.id, 'root-a');
      expect(library.recent.first, 'root-a');
      expect(repository.writes, greaterThanOrEqualTo(2));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'batch editing moves selected media and requires confirmation before deletion',
    (tester) async {
      await mount(tester);
      await editRoot(tester);
      expect(find.byType(Checkbox), findsNWidgets(2));
      await tester.tap(find.text('全选'));
      await tester.pump();
      expect(find.text('删除 (2)'), findsOneWidget);
      await tester.tap(find.text('移动'));
      await pumpFlow(tester);
      expect(find.text('移动到'), findsOneWidget);
      await tester.tap(find.text('归档'));
      await pumpFlow(tester);
      expect(library.items.where((item) => item.folder == '归档'), hasLength(2));
      await tester.tap(find.text('完成'));
      await pumpFlow(tester);
      await tester.tap(find.text('归档'));
      await pumpFlow(tester);
      await tester.tap(find.text('编辑列表'));
      await pumpFlow(tester);
      await tester.tap(find.text('全选'));
      await tester.pump();
      await tester.tap(find.text('删除 (2)'));
      await pumpFlow(tester);
      expect(find.text('删除 2 个文件？'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await pumpFlow(tester);
      expect(library.items, hasLength(4));
      await tester.tap(find.text('删除 (2)'));
      await pumpFlow(tester);
      await tester.tap(find.text('确定'));
      await pumpFlow(tester);
      expect(library.items.map((item) => item.id), ['course', 'nested']);
      expect((repository.saved!['items'] as List), hasLength(2));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'more opens the real import route and its safe source explanation',
    (tester) async {
      await mount(tester);
      await tester.tap(find.byKey(const ValueKey('home-tab-2')));
      await pumpFlow(tester);
      await tester.tap(find.byKey(const ValueKey('home-action-importFiles')));
      await pumpFlow(tester);
      expect(find.byType(ImportPage), findsOneWidget);
      expect(find.text('WiFi批量导入'), findsOneWidget);
      expect(find.text('iCloud 导入'), findsOneWidget);
      expect(find.byType(TdbBottomBar), findsNothing);
      await tester.tap(find.text('从 Apple Music 应用导入'));
      await pumpFlow(tester);
      expect(find.text('Apple Music'), findsOneWidget);
      expect(find.textContaining('曲库导入尚未接入'), findsOneWidget);
      await tester.tap(find.text('知道了'));
      await pumpFlow(tester);
      await tester.tap(find.byType(BackButton));
      await pumpFlow(tester);
      expect(find.byType(TdbMorePage), findsOneWidget);
      expect(find.byType(TdbBottomBar), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
