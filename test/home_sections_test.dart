import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tingdubao/home_sections.dart';

void main() {
  testWidgets(
    'bottom bar presents the five recorded tabs and reports each selection',
    (tester) async {
      final changes = <int>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            bottomNavigationBar: TdbBottomBar(index: 2, onChanged: changes.add),
          ),
        ),
      );
      for (final name in ['文件', '录音', '更多', '听力', '我的']) {
        expect(find.text(name), findsOneWidget);
      }
      for (var i = 0; i < 5; i++) {
        await tester.tap(find.byKey(ValueKey('home-tab-$i')));
      }
      expect(changes, [0, 1, 2, 3, 4]);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('more page renders caller study values and weekly totals', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TdbMorePage(
            totalStudy: const Duration(hours: 2, minutes: 30),
            todayStudy: const Duration(minutes: 17),
            reviewCount: 9,
            weekMinutes: const [4, 9, 13, 16, 20, 24, 17],
            onAction: (_) {},
          ),
        ),
      ),
    );
    expect(find.text('2.5'), findsOneWidget);
    expect(find.text('17'), findsOneWidget);
    expect(find.text('9'), findsOneWidget);
    expect(find.text('今日 17 分钟'), findsOneWidget);
    expect(find.text('日均 15 分钟'), findsOneWidget);
    expect(find.text('1.7'), findsOneWidget);
    expect(find.text('0.7'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'more page forwards every tool action without simulating completion',
    (tester) async {
      final actions = <HomeAction>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TdbMorePage(
              totalStudy: Duration.zero,
              todayStudy: Duration.zero,
              reviewCount: 0,
              weekMinutes: const [],
              onAction: actions.add,
            ),
          ),
        ),
      );
      const expected = [
        HomeAction.importFiles,
        HomeAction.sync,
        HomeAction.playlist,
        HomeAction.recent,
        HomeAction.favorites,
        HomeAction.words,
        HomeAction.notes,
        HomeAction.reminder,
        HomeAction.timedPlay,
        HomeAction.sleep,
        HomeAction.studyTime,
        HomeAction.speed,
        HomeAction.videoAudio,
        HomeAction.podcasts,
      ];
      for (final action in expected) {
        final target = find.byKey(ValueKey('home-action-${action.name}'));
        await tester.ensureVisible(target);
        await tester.pump();
        await tester.tap(target);
      }
      expect(actions, expected);
      expect(find.byType(AlertDialog), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'my page uses supplied version/cache and exposes only action callbacks',
    (tester) async {
      final actions = <HomeAction>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TdbMyPage(
              version: '1.9.2 (19)',
              cacheLabel: '12.4 MB',
              onAction: actions.add,
            ),
          ),
        ),
      );
      expect(find.text('Tdb'), findsOneWidget);
      expect(find.text('测试版'), findsOneWidget);
      expect(find.text('12.4 MB'), findsOneWidget);
      expect(find.text('版本：1.9.2 (19)'), findsOneWidget);
      expect(find.text('已购买'), findsNothing);
      expect(find.text('恢复购买'), findsNothing);
      const expected = [
        HomeAction.feedback,
        HomeAction.share,
        HomeAction.settings,
        HomeAction.clearCache,
        HomeAction.interfaces,
        HomeAction.instructions,
        HomeAction.help,
      ];
      for (final action in expected) {
        final target = find.byKey(ValueKey('home-action-${action.name}'));
        await tester.ensureVisible(target);
        await tester.pump();
        await tester.tap(target);
      }
      expect(actions, expected);
      expect(find.byType(AlertDialog), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('more cards fit a narrow phone width with zero study data', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 320,
              child: TdbMorePage(
                totalStudy: Duration.zero,
                todayStudy: Duration.zero,
                reviewCount: 0,
                weekMinutes: const [],
                onAction: (_) {},
              ),
            ),
          ),
        ),
      ),
    );
    expect(find.text('0.0'), findsNWidgets(2));
    expect(find.text('今日 0 分钟'), findsOneWidget);
    expect(find.text('日均 0 分钟'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
