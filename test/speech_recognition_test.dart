import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tingdubao/services/speech_recognition.dart';

SpeechWord word(
  String text,
  double start,
  double duration, {
  double confidence = .8,
}) => SpeechWord.fromMap({
  'text': text,
  'timestamp': start,
  'duration': duration,
  'confidence': confidence,
});

void main() {
  group('speech word grouping', () {
    test(
      'punctuation groups real words without inventing translation or timing',
      () {
        final result = speechWordsToCues([
          word('Hello,', 3, .4),
          word('world!', 3.5, .5),
          word('Next', 4.1, .3),
          word('sentence.', 4.5, .8),
        ]);
        expect(result.map((cue) => cue.text), [
          'Hello, world!',
          'Next sentence.',
        ]);
        expect(result.first.start, const Duration(seconds: 3));
        expect(result.first.end, const Duration(seconds: 4));
        expect(result.last.end, const Duration(milliseconds: 5300));
        expect(
          result.every((cue) => cue.translation.isEmpty && !cue.inferredTiming),
          isTrue,
        );
      },
    );

    test('silence separates phrases and chronological sorting is stable', () {
      final result = speechWordsToCues([
        word('later', 12, .5),
        word('first', 10, .4),
        word('phrase', 10.5, .3),
      ]);
      expect(result.map((cue) => cue.text), ['first phrase', 'later']);
      expect(result.last.start, const Duration(seconds: 12));
    });

    test(
      'native absolute timestamps retain requested segment and slice offsets',
      () {
        final result = speechWordsToCues([
          word('A.', 90.125, .25),
          word('B.', 135.25, .5),
        ]);
        expect(result.first.start, const Duration(microseconds: 90125000));
        expect(result.first.end, const Duration(microseconds: 90375000));
        expect(result.last.start, const Duration(microseconds: 135250000));
        expect(result.last.end, const Duration(microseconds: 135750000));
      },
    );

    test(
      'Chinese and Japanese tokens join without inserted Western spaces',
      () {
        final result = speechWordsToCues([
          word('你好', 0, .3),
          word('世界。', .3, .4),
          word('こんにちは', .8, .5),
          word('世界。', 1.4, .5),
        ]);
        expect(result.map((cue) => cue.text), ['你好世界。', 'こんにちは世界。']);
      },
    );

    test('separate punctuation and closing quotes stay with the sentence', () {
      final result = speechWordsToCues([
        word('“Hello', 0, .4),
        word('world', .4, .4),
        word('!', .8, .1),
        word('”', .9, .1),
        word('Again.', 1, .5),
      ]);
      expect(result.map((cue) => cue.text), ['“Hello world!”', 'Again.']);
    });

    test('long uninterrupted speech splits into bounded phrase groups', () {
      final result = speechWordsToCues([
        for (var i = 0; i < 30; i++) word('word$i', i.toDouble(), .9),
      ]);
      expect(result.length, greaterThan(1));
      expect(
        result.every(
          (cue) => cue.end - cue.start <= const Duration(seconds: 12),
        ),
        isTrue,
      );
      expect(result.map((cue) => cue.text).join(' ').split(' '), hasLength(30));
    });

    test('overlapping word timing never shortens the containing phrase', () {
      final result = speechWordsToCues([
        word('long', 1, 1),
        word('word', 1.2, .1),
      ]);
      expect(result.single.start, const Duration(seconds: 1));
      expect(result.single.end, const Duration(seconds: 2));
    });

    test('empty inputs and blank tokens do not produce fake captions', () {
      expect(speechWordsToCues([]), isEmpty);
      expect(speechWordsToCues([word('  ', 0, .2)]), isEmpty);
    });

    test(
      'invalid platform numbers are rejected rather than repaired silently',
      () {
        for (final map in <Map<Object?, Object?>>[
          {
            'text': 'x',
            'timestamp': double.nan,
            'duration': 1,
            'confidence': .5,
          },
          {'text': 'x', 'timestamp': -1, 'duration': 1, 'confidence': .5},
          {'text': 'x', 'timestamp': 1, 'duration': 0, 'confidence': .5},
          {
            'text': 'x',
            'timestamp': 1,
            'duration': double.infinity,
            'confidence': .5,
          },
          {'text': 'x', 'timestamp': 1, 'duration': 1, 'confidence': 2},
        ]) {
          expect(() => SpeechWord.fromMap(map), throwsFormatException);
        }
      },
    );
  });

  group('file recognition channel contract', () {
    TestWidgetsFlutterBinding.ensureInitialized();
    const channel = MethodChannel('test/tdb-speech');
    late SpeechRecognitionService service;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    setUp(() => service = SpeechRecognitionService(channel: channel));
    tearDown(() => messenger.setMockMethodCallHandler(channel, null));

    test(
      'capability queries never invoke transcription or authorization',
      () async {
        final calls = <String>[];
        messenger.setMockMethodCallHandler(channel, (call) async {
          calls.add(call.method);
          if (call.method == 'locales') return ['en_US', 'zh_CN'];
          if (call.method == 'supportsOffline') {
            expect(call.arguments, {'locale': 'en_US'});
            return true;
          }
          fail('Unexpected method ${call.method}');
        });
        expect(await service.supportedLocales(), ['en_US', 'zh_CN']);
        expect(await service.supportsOffline('en_US'), isTrue);
        expect(calls, ['locales', 'supportsOffline']);
      },
    );

    test(
      'selected range and strict offline default are passed to native code',
      () async {
        messenger.setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'transcribe');
          expect(call.arguments, {
            'path': '/owned/audio.mp3',
            'locale': 'en_US',
            'offline': true,
            'startMilliseconds': 30000,
            'endMilliseconds': 35000,
          });
          return {
            'words': [
              {
                'text': 'Hello.',
                'timestamp': 30.5,
                'duration': .5,
                'confidence': .9,
              },
            ],
          };
        });
        final result = await service.transcribe(
          '/owned/audio.mp3',
          locale: 'en_US',
          start: const Duration(seconds: 30),
          end: const Duration(seconds: 35),
        );
        expect(result.single.start, const Duration(milliseconds: 30500));
        expect(result.single.translation, isEmpty);
        expect(service.running, isFalse);
      },
    );

    test('online mode requires an explicit false option', () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect((call.arguments as Map)['offline'], isFalse);
        return {'words': []};
      });
      expect(
        await service.transcribe(
          '/owned/audio.mp3',
          locale: 'en_US',
          offline: false,
        ),
        isEmpty,
      );
    });

    test(
      'busy work is rejected and cancellation keeps the failure visible',
      () async {
        final entered = Completer<void>();
        final reply = Completer<Object?>();
        messenger.setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'transcribe') {
            entered.complete();
            return reply.future;
          }
          if (call.method == 'cancel') {
            reply.completeError(
              PlatformException(code: 'cancelled', message: '已取消语音识别。'),
            );
            return null;
          }
          fail('Unexpected method ${call.method}');
        });
        final pending = service.transcribe('/owned/audio.mp3', locale: 'en_US');
        final cancelled = expectLater(
          pending,
          throwsA(
            isA<PlatformException>().having(
              (error) => error.code,
              'code',
              'cancelled',
            ),
          ),
        );
        await entered.future;
        expect(service.running, isTrue);
        await expectLater(
          service.transcribe('/owned/other.mp3', locale: 'en_US'),
          throwsStateError,
        );
        await service.cancel();
        await cancelled;
        expect(service.running, isFalse);
      },
    );

    test(
      'unsupported offline mode is propagated and never retried online',
      () async {
        var calls = 0;
        messenger.setMockMethodCallHandler(channel, (call) async {
          calls++;
          throw PlatformException(
            code: 'offline_unavailable',
            message: '此语言不支持离线识别。',
          );
        });
        await expectLater(
          service.transcribe('/owned/audio.mp3', locale: 'en_US'),
          throwsA(
            isA<PlatformException>().having(
              (error) => error.code,
              'code',
              'offline_unavailable',
            ),
          ),
        );
        expect(calls, 1);
        expect(service.running, isFalse);
      },
    );

    test('invalid ranges fail before touching native code', () async {
      messenger.setMockMethodCallHandler(
        channel,
        (_) async => fail('Must not call native code'),
      );
      await expectLater(
        service.transcribe(
          '/owned/audio.mp3',
          locale: 'en_US',
          start: const Duration(seconds: -1),
        ),
        throwsArgumentError,
      );
      await expectLater(
        service.transcribe(
          '/owned/audio.mp3',
          locale: 'en_US',
          start: const Duration(seconds: 5),
          end: const Duration(seconds: 4),
        ),
        throwsArgumentError,
      );
    });
  });
}
