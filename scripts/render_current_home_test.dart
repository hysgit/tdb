// Local visual QA of the actual StudyHome shell with public, isolated UI fixtures.
// Run: flutter test scripts/render_current_home_test.dart
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:tingdubao/main.dart';

import '../test/home_flow_test.dart'
    show
        HomeFlowPlayer,
        HomeFlowRepository,
        homeFlowFixture,
        installHomePluginMocks;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'render current home, more and my pages using public sample names',
    (tester) async {
      final previousShadows = debugDisableShadows;
      debugDisableShadows = false;
      addTearDown(() => debugDisableShadows = previousShadows);
      final font = File(r'C:\Windows\Fonts\msyh.ttc');
      if (font.existsSync()) {
        final loader = FontLoader('HomePreview');
        loader.addFont(
          Future.value(ByteData.sublistView(font.readAsBytesSync())),
        );
        await loader.load();
      }
      final icons = FontLoader('MaterialIcons');
      icons.addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
      await icons.load();
      installHomePluginMocks();
      final output = Directory('dist/current-reference/flutter')
        ..createSync(recursive: true);

      Future<void> transition() async {
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));
        await tester.pump();
      }

      for (final size in [const Size(320, 568), const Size(390, 844)]) {
        final repository = HomeFlowRepository();
        final library = homeFlowFixture(repository);
        final player = HomeFlowPlayer()
          ..item = library.items.first
          ..at = const Duration(seconds: 4);
        final boundaryKey = GlobalKey();
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = size;
        await tester.pumpWidget(
          Builder(
            builder: (context) {
              // Read the app's actual theme rather than maintaining a preview copy.
              final app = const TingdubaoApp().build(context) as MaterialApp;
              final theme = app.theme!;
              final previewTheme = theme.copyWith(
                textTheme: theme.textTheme.apply(fontFamily: 'HomePreview'),
                primaryTextTheme: theme.primaryTextTheme.apply(
                  fontFamily: 'HomePreview',
                ),
                appBarTheme: theme.appBarTheme.copyWith(
                  titleTextStyle: theme.appBarTheme.titleTextStyle?.copyWith(
                    fontFamily: 'HomePreview',
                  ),
                ),
              );
              return RepaintBoundary(
                key: boundaryKey,
                child: MaterialApp(
                  title: app.title,
                  scaffoldMessengerKey: appMessenger,
                  debugShowCheckedModeBanner: false,
                  locale: app.locale,
                  supportedLocales: app.supportedLocales,
                  localizationsDelegates: app.localizationsDelegates,
                  theme: previewTheme,
                  home: StudyHome(initialLibrary: library, studyPlayer: player),
                ),
              );
            },
          ),
        );
        await transition();
        Future<void> capture(String section) async {
          expect(tester.takeException(), isNull);
          await tester.runAsync(() async {
            final boundary =
                boundaryKey.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary;
            final image = await boundary.toImage(pixelRatio: 1);
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            await File(
              '${output.path}/home-${size.width.toInt()}-$section.png',
            ).writeAsBytes(bytes!.buffer.asUint8List());
            image.dispose();
          });
        }

        await capture('files');
        await tester.tap(find.byKey(const ValueKey('home-tab-2')));
        await transition();
        await capture('more');
        await tester.ensureVisible(find.text('工具'));
        await transition();
        await capture('more-tools');
        await tester.tap(find.byKey(const ValueKey('home-tab-4')));
        await transition();
        await capture('my');
        await tester.pumpWidget(const SizedBox.shrink());
        await transition();
        library.dispose();
        await tester.runAsync(() async {
          if (await repository.root.exists()) {
            await repository.root.delete(recursive: true);
          }
        });
      }
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    },
  );
}
