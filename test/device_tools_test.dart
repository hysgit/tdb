import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tingdubao/services/device_tools.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('tingdubao/utilities-contract');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late DeviceTools tools;
  late List<MethodCall> calls;

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    calls = [];
    tools = DeviceTools(channel: channel);
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return call.method == 'share' ? false : null;
    });
  });
  tearDown(() {
    tools.dispose();
    messenger.setMockMethodCallHandler(channel, null);
    debugDefaultTargetPlatformOverride = null;
  });

  test(
    'lookup and native share report the requested term and user cancellation',
    () async {
      await tools.lookup('  pronunciation  ');
      expect(calls.single.method, 'lookup');
      expect(calls.single.arguments, {'word': 'pronunciation'});
      expect(await tools.share('Tdb\n学习资料'), isFalse);
      expect(calls.last.method, 'share');
      expect(calls.last.arguments, {'text': 'Tdb\n学习资料'});
    },
  );

  test('only HTTP or HTTPS pages reach the system browser bridge', () async {
    await tools.openUrl(Uri.parse('https://example.com/help?q=Tdb'));
    expect(calls.single.arguments, {'url': 'https://example.com/help?q=Tdb'});
    await expectLater(
      tools.openUrl(Uri.parse('javascript:alert(1)')),
      throwsArgumentError,
    );
    await expectLater(
      tools.openUrl(Uri.parse('http://user:pw@example.com/')),
      throwsArgumentError,
    );
    expect(calls, hasLength(1));
  });

  test(
    'scheduling forwards an absolute deadline and cancellation identifies the same request',
    () async {
      final at = DateTime.now().add(const Duration(minutes: 5));
      expect(
        calls,
        isEmpty,
        reason: 'Constructing the service cannot request permission.',
      );
      await tools.schedule(
        id: ' reminder-1 ',
        title: '复习',
        body: '点击播放',
        at: at,
        mediaId: 'media-7',
      );
      expect(calls.single.method, 'schedule');
      expect(calls.single.arguments, {
        'id': 'reminder-1',
        'title': '复习',
        'body': '点击播放',
        'atMilliseconds': at.millisecondsSinceEpoch,
        'mediaId': 'media-7',
      });
      await tools.cancelNotification('reminder-1');
      expect(calls.last.method, 'cancelNotification');
      expect(calls.last.arguments, {'id': 'reminder-1'});
    },
  );

  test(
    'native permission denial remains an error instead of a false completion',
    () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(code: 'PERMISSION_DENIED', message: '通知权限未开启。');
      });
      await expectLater(
        tools.schedule(
          id: 'n1',
          title: '提醒',
          body: '',
          at: DateTime.now().add(const Duration(minutes: 2)),
        ),
        throwsA(
          isA<PlatformException>().having(
            (error) => error.code,
            'code',
            'PERMISSION_DENIED',
          ),
        ),
      );
    },
  );

  test(
    'a native action is acknowledged only after its typed handler finishes',
    () async {
      final release = Completer<void>();
      DeviceAction? received;
      tools.setActionHandler((action) async {
        received = action;
        await release.future;
      });
      var replied = false;
      final reply = messenger
          .handlePlatformMessage(
            channel.name,
            const StandardMethodCodec().encodeMethodCall(
              const MethodCall('action', {
                'id': 'action-1',
                'type': 'play',
                'mediaId': 'media-7',
              }),
            ),
            null,
          )
          .then((value) {
            replied = true;
            return value;
          });
      await Future<void>.delayed(Duration.zero);
      expect(received!.type, DeviceActionType.play);
      expect(received!.mediaId, 'media-7');
      expect(received!.id, 'action-1');
      expect(replied, isFalse);
      release.complete();
      expect(
        const StandardMethodCodec().decodeEnvelope((await reply)!),
        isNull,
      );
    },
  );

  test(
    'the pending cold-start action is returned without inventing one',
    () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'pendingAction') {
          return {'id': 'pending-1', 'type': 'upload'};
        }
        return null;
      });
      final action = await tools.pendingAction();
      expect(action!.type, DeviceActionType.upload);
      expect(action.id, 'pending-1');
      expect(action.mediaId, isNull);
      messenger.setMockMethodCallHandler(channel, (call) async => null);
      expect(await tools.pendingAction(), isNull);
    },
  );

  test(
    'invalid notification inputs cannot reach the permission-requesting method',
    () async {
      await expectLater(
        tools.schedule(
          id: 'n1',
          title: '提醒',
          body: '',
          at: DateTime.now().subtract(const Duration(seconds: 1)),
        ),
        throwsArgumentError,
      );
      await expectLater(tools.cancelNotification(''), throwsArgumentError);
      await expectLater(tools.lookup(''), throwsArgumentError);
      expect(calls, isEmpty);
    },
  );

  test(
    'unsupported Android tools never return a fabricated native result',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      expect(tools.supported, isFalse);
      await expectLater(tools.lookup('hello'), throwsUnsupportedError);
      await expectLater(tools.share('Tdb'), throwsUnsupportedError);
      expect(calls, isEmpty);
    },
  );
}
