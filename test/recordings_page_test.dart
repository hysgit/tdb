import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:tingdubao/recordings_page.dart';

class NativePlayback {
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  String? id;
  Completer<Map<String, dynamic>>? playing;
  int loads = 0, plays = 0, pauses = 0;

  void install() {
    messenger.setMockMethodCallHandler(
      const MethodChannel('com.ryanheise.audio_session'),
      (_) async => null,
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('com.ryanheise.just_audio.methods'),
      (call) async {
        if (call.method == 'init') {
          id = (call.arguments as Map)['id'] as String;
          messenger.setMockMethodCallHandler(
            MethodChannel('com.ryanheise.just_audio.events.$id'),
            (_) async => null,
          );
          messenger.setMockMethodCallHandler(
            MethodChannel('com.ryanheise.just_audio.data.$id'),
            (_) async => null,
          );
          messenger.setMockMethodCallHandler(
            MethodChannel('com.ryanheise.just_audio.methods.$id'),
            (request) async {
              switch (request.method) {
                case 'load':
                  loads++;
                  emit(3);
                  return {'duration': 3000000};
                case 'play':
                  plays++;
                  playing = Completer<Map<String, dynamic>>();
                  return playing!.future;
                case 'pause':
                  pauses++;
                  finish();
                  return <String, dynamic>{};
                default:
                  return <String, dynamic>{};
              }
            },
          );
        } else if (call.method == 'disposePlayer') {
          finish();
        }
        return <String, dynamic>{};
      },
    );
  }

  void emit(int state) {
    if (id == null) return;
    ServicesBinding.instance.channelBuffers.push(
      'com.ryanheise.just_audio.events.$id',
      const StandardMethodCodec().encodeSuccessEnvelope({
        'processingState': state,
        'updateTime': DateTime.now().millisecondsSinceEpoch,
        'updatePosition': state == 4 ? 3000000 : 0,
        'bufferedPosition': 3000000,
        'duration': 3000000,
        'currentIndex': 0,
      }),
      (_) {},
    );
  }

  void finish({bool completed = false}) {
    if (completed) emit(4);
    final gate = playing;
    playing = null;
    if (gate != null && !gate.isCompleted) gate.complete({});
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory directory;
  late NativePlayback playback;
  late String path;
  late List<String> order;
  late int stops, saved, deletes, disposes;
  late bool allowPermission, failSave;
  Completer<void>? stopGate;
  Completer<void>? beforeGate;
  late GlobalKey<RecordingsPageState> pageKey;

  setUp(() {
    directory = Directory.systemTemp.createTempSync(
      'tingdubao_recordings_test_',
    );
    path = '${directory.path}/recording.m4a';
    order = [];
    stops = 0;
    saved = 0;
    deletes = 0;
    disposes = 0;
    allowPermission = true;
    failSave = false;
    stopGate = null;
    beforeGate = null;
    pageKey = GlobalKey<RecordingsPageState>();
    playback = NativePlayback()..install();
    messenger.setMockMethodCallHandler(
      const MethodChannel('com.llfbandit.record/messages'),
      (call) async {
        final args = call.arguments as Map?;
        switch (call.method) {
          case 'create':
            final id = args!['recorderId'];
            messenger.setMockMethodCallHandler(
              MethodChannel('com.llfbandit.record/events/$id'),
              (_) async => null,
            );
            return null;
          case 'hasPermission':
            return allowPermission;
          case 'start':
            order.add('start');
            path = args!['path'] as String;
            File(path).writeAsBytesSync([1, 2, 3]);
            return null;
          case 'stop':
            stops++;
            if (stopGate != null) await stopGate!.future;
            return path;
          case 'dispose':
            disposes++;
            return null;
          default:
            return null;
        }
      },
    );
  });
  tearDown(() {
    playback.finish();
    directory.deleteSync(recursive: true);
  });

  Future<void> flush(WidgetTester tester) async {
    // File metadata checks run outside the widget test's fake clock. Pump each
    // completed IO continuation so the next real IO request can be delivered.
    for (var i = 0; i < 4; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
  }

  Future<void> mount(
    WidgetTester tester, {
    List<RecordingEntry> entries = const [],
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 568);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          appBar: AppBar(title: const Text('录音')),
          body: RecordingsPage(
            key: pageKey,
            entries: entries,
            createPath: () async {
              order.add('path');
              return path;
            },
            beforeRecording: () async {
              order.add('before');
              if (beforeGate != null) await beforeGate!.future;
            },
            onSaved: (value) async {
              saved++;
              if (failSave) throw StateError('storage unavailable');
            },
            onDelete: (value) async {
              deletes++;
            },
          ),
          bottomNavigationBar: NavigationBar(
            destinations: const [
              NavigationDestination(icon: Icon(Icons.folder), label: '文件'),
              NavigationDestination(icon: Icon(Icons.mic), label: '录音'),
            ],
          ),
        ),
      ),
    );
    await flush(tester);
  }

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await flush(tester);
    expect(tester.takeException(), isNull);
  }

  Future<void> start(WidgetTester tester) async {
    await tester.tap(find.text('开始录音'));
    await flush(tester);
    expect(find.text('正在录音'), findsOneWidget);
  }

  testWidgets(
    'recording starts only after original audio pause and permission',
    (tester) async {
      await mount(tester);
      await start(tester);
      expect(order, ['before', 'path', 'start']);
      await tester.tap(find.text('停止并保存'));
      await flush(tester);
      expect(saved, 1);
      expect(stops, 1);
      expect(find.text('准备录音'), findsOneWidget);
      await unmount(tester);
      expect(File(path).existsSync(), isTrue);
    },
  );
  testWidgets('duplicate stop clicks share the same stop and save operation', (
    tester,
  ) async {
    await mount(tester);
    await start(tester);
    stopGate = Completer<void>();
    await tester.tap(find.text('停止并保存'));
    await tester.tap(find.text('停止并保存'));
    await tester.pump();
    expect(stops, 1);
    expect(saved, 0);
    stopGate!.complete();
    await flush(tester);
    expect(stops, 1);
    expect(saved, 1);
    await unmount(tester);
    expect(saved, 1);
  });
  testWidgets(
    'root interruption waits for pending start and saves exactly once',
    (tester) async {
      await mount(tester);
      beforeGate = Completer<void>();
      await tester.tap(find.text('开始录音'));
      await flush(tester);
      expect(order, ['before']);
      final first = pageKey.currentState!.finishRecording();
      final second = pageKey.currentState!.finishRecording();
      beforeGate!.complete();
      await flush(tester);
      await Future.wait([first, second]);
      expect(stops, 1);
      expect(saved, 1);
      expect(order, ['before', 'path', 'start']);
      await unmount(tester);
    },
  );
  testWidgets('root interruption retries a retained pending save', (
    tester,
  ) async {
    await mount(tester);
    await start(tester);
    failSave = true;
    await tester.tap(find.text('停止并保存'));
    await flush(tester);
    expect(saved, 1);
    failSave = false;
    final finishing = pageKey.currentState!.finishRecording();
    await flush(tester);
    await finishing;
    expect(saved, 2);
    expect(stops, 1);
    expect(File(path).existsSync(), isTrue);
    await unmount(tester);
  });
  testWidgets(
    'root navigation is blocked by pending save and proceeds only after retry succeeds',
    (tester) async {
      await mount(tester);
      await start(tester);
      failSave = true;
      await tester.tap(find.text('停止并保存'));
      await flush(tester);
      expect(saved, 1);
      Future<void> openPlayer() async {
        await pageKey.currentState!.finishRecording();
        unawaited(
          Navigator.of(pageKey.currentContext!).pushReplacement(
            MaterialPageRoute<void>(
              builder: (_) => const Scaffold(body: Text('player route')),
            ),
          ),
        );
      }

      final blocked = expectLater(openPlayer(), throwsStateError);
      await flush(tester);
      await blocked;
      expect(saved, 2);
      expect(stops, 1);
      expect(find.byType(RecordingsPage), findsOneWidget);
      expect(find.text('player route'), findsNothing);
      expect(find.text('保存失败，录音文件已保留'), findsOneWidget);
      expect(File(path).existsSync(), isTrue);
      failSave = false;
      final opening = openPlayer();
      await flush(tester);
      await opening;
      await tester.pump(const Duration(milliseconds: 350));
      expect(saved, 3);
      expect(stops, 1);
      expect(find.text('player route'), findsOneWidget);
      expect(File(path).existsSync(), isTrue);
      await unmount(tester);
    },
  );
  testWidgets(
    'failed save retains the path and retries without stopping again',
    (tester) async {
      await mount(tester);
      await start(tester);
      failSave = true;
      await tester.tap(find.text('停止并保存'));
      await flush(tester);
      expect(find.text('保存失败，录音文件已保留'), findsOneWidget);
      expect(File(path).existsSync(), isTrue);
      expect(saved, 1);
      expect(stops, 1);
      failSave = false;
      await tester.ensureVisible(find.text('重试保存'));
      await tester.tap(find.text('重试保存'));
      await flush(tester);
      expect(saved, 2);
      expect(stops, 1);
      expect(find.text('保存失败，录音文件已保留'), findsNothing);
      expect(tester.takeException(), isNull);
      await unmount(tester);
    },
  );
  testWidgets(
    'dispose completes an active recording and keeps the saved file',
    (tester) async {
      await mount(tester);
      await start(tester);
      await unmount(tester);
      expect(stops, 1);
      expect(saved, 1);
      expect(disposes, 1);
      expect(File(path).existsSync(), isTrue);
    },
  );
  testWidgets('permission denial starts no native recording or output path', (
    tester,
  ) async {
    allowPermission = false;
    await mount(tester);
    await tester.tap(find.text('开始录音'));
    await flush(tester);
    expect(order, isEmpty);
    expect(saved, 0);
    expect(find.textContaining('允许麦克风权限'), findsOneWidget);
    await unmount(tester);
  });
  testWidgets(
    'history playback pauses, resumes and clears its state on completion',
    (tester) async {
      File(path).writeAsBytesSync([1, 2, 3]);
      await mount(tester, entries: [(path: path, title: '示例录音')]);
      await tester.tap(find.byTooltip('回放录音'));
      await flush(tester);
      expect(playback.loads, 1);
      expect(playback.plays, 1);
      expect(find.byTooltip('暂停录音回放'), findsOneWidget);
      await tester.tap(find.byTooltip('暂停录音回放'));
      await flush(tester);
      expect(playback.pauses, 1);
      expect(find.byTooltip('回放录音'), findsOneWidget);
      await tester.tap(find.byTooltip('回放录音'));
      await flush(tester);
      expect(playback.loads, 1);
      expect(playback.plays, 2);
      playback.finish(completed: true);
      await flush(tester);
      expect(find.byTooltip('暂停录音回放'), findsNothing);
      await unmount(tester);
    },
  );
  testWidgets(
    'history deletion calls the owner only after local confirmation',
    (tester) async {
      await mount(tester, entries: [(path: path, title: '示例录音')]);
      await tester.tap(find.byTooltip('删除录音'));
      await tester.pump();
      expect(deletes, 0);
      await tester.tap(find.text('取消'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(deletes, 0);
      await tester.tap(find.byTooltip('删除录音'));
      await tester.pump();
      await tester.tap(find.widgetWithText(TextButton, '删除'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(deletes, 1);
      await unmount(tester);
    },
  );
}
