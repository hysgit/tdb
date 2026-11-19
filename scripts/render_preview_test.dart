// Run with: flutter test scripts/render_preview_test.dart
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:tingdubao/library.dart';
import 'package:tingdubao/models.dart';
import 'package:tingdubao/player_view.dart';

import '../test/player_view_test.dart' show ViewPlayer;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('render the player with bundled sample subtitles', (
    tester,
  ) async {
    final font = File(
      const String.fromEnvironment(
        'PREVIEW_FONT',
        defaultValue: r'C:\Windows\Fonts\msyh.ttc',
      ),
    );
    if (font.existsSync()) {
      final loader = FontLoader('Preview');
      loader.addFont(
        Future.value(ByteData.sublistView(font.readAsBytesSync())),
      );
      await loader.load();
    }
    final icons = FontLoader('MaterialIcons');
    icons.addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icons.load();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final channel in [
      'com.llfbandit.record/messages',
      'com.ryanheise.audio_session',
      'com.ryanheise.just_audio.methods',
    ]) {
      messenger.setMockMethodCallHandler(
        MethodChannel(channel),
        (_) async => <String, dynamic>{},
      );
    }
    final player = ViewPlayer()
      ..item = MediaItem(
        id: 'preview',
        name: 'China · 听力练习',
        path: 'demo.mp3',
        cues: parseSubtitles(
          utf8.decode(File('assets/demo/Introduction.json').readAsBytesSync()),
        ),
      );
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    final key = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          fontFamily: 'Preview',
          colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFFDC601D)),
          scaffoldBackgroundColor: const Color(0xFFF7F7F9),
        ),
        home: RepaintBoundary(
          key: key,
          child: Scaffold(
            appBar: AppBar(title: const Text('Tdb')),
            body: PlayerView(
              player: player,
              onSave: () async {},
              onMessage: (_) {},
            ),
            bottomNavigationBar: NavigationBar(
              selectedIndex: 1,
              destinations: const [
                NavigationDestination(icon: Icon(Icons.folder), label: '文件'),
                NavigationDestination(
                  icon: Icon(Icons.headphones),
                  label: '播放',
                ),
                NavigationDestination(
                  icon: Icon(Icons.star_border),
                  label: '收藏',
                ),
                NavigationDestination(icon: Icon(Icons.tune), label: '设置'),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.runAsync(() async {
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 2);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      await Directory('dist').create(recursive: true);
      await File(
        'dist/Tdb-player-preview.png',
      ).writeAsBytes(data!.buffer.asUint8List());
      image.dispose();
    });
    await tester.pumpWidget(const SizedBox.shrink());
    player.dispose();
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
}
