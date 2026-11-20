// First run python scripts/build_preview_waveform.py, then flutter test this file.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_waveform/just_waveform.dart';
import 'package:material_ui/material_ui.dart';
import 'package:tingdubao/library.dart';
import 'package:tingdubao/models.dart';
import 'package:tingdubao/player_view.dart';
import 'package:tingdubao/services/waveform.dart';

import '../test/player_view_test.dart' show ViewPlayer;

class AudioPreviewEnvelope extends WaveformService {
  @override
  Future<Waveform> load(String path) async {
    final data =
        jsonDecode(
              File(
                'dist/current-reference/demo-envelope.json',
              ).readAsStringSync(),
            )
            as Map<String, dynamic>;
    return Waveform(
      version: data['version'] as int,
      flags: data['flags'] as int,
      sampleRate: data['sampleRate'] as int,
      samplesPerPixel: data['samplesPerPixel'] as int,
      length: data['length'] as int,
      data: List<int>.from(data['data'] as List),
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('render current recording structure with genuine sample envelope', (
    tester,
  ) async {
    final previousShadows = debugDisableShadows;
    debugDisableShadows = false;
    addTearDown(() => debugDisableShadows = previousShadows);
    final font = File(r'C:\Windows\Fonts\msyh.ttc');
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
        (_) async => null,
      );
    }
    final cues = parseSubtitles(
      File('assets/demo/Introduction.json').readAsStringSync(),
    );
    Directory('dist/current-reference/flutter').createSync(recursive: true);
    for (final size in [const Size(320, 568), const Size(390, 844)]) {
      final player = ViewPlayer();
      final item = MediaItem(
        id: 'sample',
        name: 'Introduction.mp3',
        path: 'assets/demo/Introduction.mp3',
        cues: cues,
      );
      player.item = item;
      final boundaryKey = GlobalKey();
      final viewKey = GlobalKey<PlayerViewState>();
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundaryKey,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: ThemeData(
              fontFamily: 'Preview',
              colorScheme: ColorScheme.fromSeed(
                seedColor: const Color(0xFFF58425),
              ),
              scaffoldBackgroundColor: Colors.white,
              appBarTheme: const AppBarTheme(
                backgroundColor: Colors.white,
                surfaceTintColor: Colors.transparent,
              ),
            ),
            home: Scaffold(
              appBar: AppBar(
                leading: const Icon(Icons.chevron_left),
                title: Text(
                  item.name,
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                actions: [
                  const IconButton(onPressed: null, icon: Icon(Icons.repeat)),
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
                onSave: () async {},
                onMessage: (_) {},
                waveformService: AudioPreviewEnvelope(),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      player.moveTo(const Duration(seconds: 1));
      await tester.tap(find.text(cues.first.text));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      Future<void> capture(String mode) async {
        expect(tester.takeException(), isNull);
        await tester.runAsync(() async {
          final boundary =
              boundaryKey.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary;
          final image = await boundary.toImage(pixelRatio: 1);
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          await File(
            'dist/current-reference/flutter/player-${size.width.toInt()}-$mode.png',
          ).writeAsBytes(data!.buffer.asUint8List());
          image.dispose();
        });
      }

      await capture('ab');
      unawaited(viewKey.currentState!.showCustomSpeeds());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      await capture('speeds');
      await tester.tap(find.byTooltip('关闭速度设置'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      item.cues = [];
      player.moveTo(const Duration(seconds: 1));
      await tester.pump();
      await capture('empty');
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      player.dispose();
    }
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
}
