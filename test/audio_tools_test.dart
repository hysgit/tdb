import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tingdubao/services/audio_tools.dart';

Uint8List wave({
  int channels = 2,
  int samples = 4410,
  bool extraChunk = false,
}) {
  final extra = extraChunk ? 10 : 0;
  final result = Uint8List(44 + extra + samples * channels * 2);
  final data = ByteData.sublistView(result);
  void text(int offset, String value) =>
      result.setAll(offset, ascii.encode(value));
  text(0, 'RIFF');
  data.setUint32(4, result.length - 8, Endian.little);
  text(8, 'WAVE');
  text(12, 'fmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, channels, Endian.little);
  data.setUint32(24, 44100, Endian.little);
  data.setUint32(28, 44100 * channels * 2, Endian.little);
  data.setUint16(32, channels * 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  if (extraChunk) {
    text(36, 'JUNK');
    data.setUint32(40, 1, Endian.little);
  }
  text(36 + extra, 'data');
  data.setUint32(40 + extra, samples * channels * 2, Endian.little);
  for (var i = 0; i < samples; i++) {
    final sample = (math.sin(i * 2 * math.pi * 440 / 44100) * 12000).round();
    for (var ch = 0; ch < channels; ch++) {
      data.setInt16(
        44 + extra + (i * channels + ch) * 2,
        sample,
        Endian.little,
      );
    }
  }
  return result;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  setUp(
    () async =>
        directory = await Directory.systemTemp.createTemp('tdb-audio-test-'),
  );
  tearDown(() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  Future<String> source({int samples = 4410, bool extraChunk = false}) async {
    final file = File('${directory.path}/source.wav');
    await file.writeAsBytes(wave(samples: samples, extraChunk: extraChunk));
    return file.path;
  }

  test('WAV parser follows chunks and RIFF odd-byte padding', () async {
    final path = await source(extraChunk: true);
    final info = await readPcmWav(path);
    expect(info.sampleRate, 44100);
    expect(info.channels, 2);
    expect(info.dataOffset, 54);
    expect(info.dataLength, 4410 * 4);
  });

  test('WAV parser rejects truncated and floating-point input', () async {
    final file = File('${directory.path}/broken.wav');
    await file.writeAsBytes(wave().sublist(0, 50));
    await expectLater(readPcmWav(file.path), throwsFormatException);
    final floating = wave();
    ByteData.sublistView(floating).setUint16(20, 3, Endian.little);
    await file.writeAsBytes(floating);
    await expectLater(readPcmWav(file.path), throwsFormatException);
  });

  test(
    'encoder writes genuine MPEG Layer III frames without altering source',
    () async {
      final path = await source();
      final before = await File(path).readAsBytes();
      for (final bitrate in [96, 128, 192]) {
        final output = '${directory.path}/$bitrate.mp3';
        await encodeWavToMp3(path, output, bitrate: bitrate);
        final bytes = await File(output).readAsBytes();
        expect(bytes.length, greaterThan(100));
        expect(bytes[0], 0xff);
        expect(bytes[1] & 0xe0, 0xe0);
        expect((bytes[1] >> 1) & 3, 1, reason: 'Layer III, not a renamed WAV');
        expect(String.fromCharCodes(bytes.take(4)), isNot('RIFF'));
      }
      expect(await File(path).readAsBytes(), before);
    },
  );

  test(
    'ffprobe verifies MP3 codec, channels, sample rate, bitrate and duration',
    () async {
      try {
        await Process.run('ffprobe', ['-version']);
      } on ProcessException {
        markTestSkipped(
          'ffprobe is unavailable; native iOS validation is separate.',
        );
        return;
      }
      final path = await source(samples: 44100);
      final output = '${directory.path}/verified.mp3';
      await encodeWavToMp3(path, output);
      final probe = await Process.run('ffprobe', [
        '-v',
        'error',
        '-show_streams',
        '-show_format',
        '-of',
        'json',
        output,
      ]);
      expect(probe.exitCode, 0, reason: '${probe.stderr}');
      final data = jsonDecode(probe.stdout as String) as Map<String, dynamic>;
      final stream = (data['streams'] as List).single as Map<String, dynamic>;
      expect(stream['codec_name'], 'mp3');
      expect(stream['sample_rate'], '44100');
      expect(stream['channels'], 2);
      expect(int.parse(stream['bit_rate'] as String), 128000);
      expect(
        double.parse((data['format'] as Map)['duration'] as String),
        closeTo(1, .12),
      );
    },
  );

  test(
    'encoder refuses source overwrite and closes files on cancellation',
    () async {
      final path = await source();
      await expectLater(encodeWavToMp3(path, path), throwsArgumentError);
      var checks = 0;
      final output = '${directory.path}/cancelled.mp3';
      await expectLater(
        encodeWavToMp3(path, output, cancelled: () => ++checks > 1),
        throwsA(isA<Exception>()),
      );
      expect(checks, greaterThanOrEqualTo(2));
      await File(output).delete();
      expect(await File(path).length(), wave().length);
    },
  );

  test(
    'export names preserve real selected format and strip source directories',
    () {
      expect(
        audioExportName('video.mov', AudioOutputFormat.mp3, 1),
        'video.mp3',
      );
      expect(
        audioExportName(r'folder\lesson.mp3', AudioOutputFormat.m4a, .5),
        'lesson_0.5x.m4a',
      );
    },
  );

  test('mono PCM creates a mono MPEG header', () async {
    final path = File('${directory.path}/mono.wav');
    await path.writeAsBytes(wave(channels: 1));
    final output = '${directory.path}/mono.mp3';
    await encodeWavToMp3(path.path, output);
    final header = await File(output).readAsBytes();
    expect(
      (header[3] >> 6) & 3,
      3,
      reason: 'MPEG channel mode must match one-channel PCM',
    );
  });

  group('native service lifecycle', () {
    const channel = MethodChannel('test/audio-tools');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    late AudioToolsService service;
    setUp(() => service = AudioToolsService(channel: channel));
    tearDown(() => messenger.setMockMethodCallHandler(channel, null));

    test(
      'MP3 uses native PCM then isolate encoding before import and release',
      () async {
        final path = await source();
        var released = false;
        var imported = false;
        messenger.setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'prepare') {
            expect((call.arguments as Map)['format'], 'wav');
            return {'id': 'job', 'path': path, 'duration': .1};
          }
          if (call.method == 'verifyMp3') {
            expect(call.arguments, {'id': 'job', 'duration': .1});
            expect(imported, isFalse);
            return null;
          }
          if (call.method == 'release') {
            expect(imported, isTrue);
            released = true;
            return null;
          }
          fail('Unexpected call ${call.method}');
        });
        await service.export(
          '/original/video.mp4',
          name: 'video.mp4',
          format: AudioOutputFormat.mp3,
          onExported: (output, name) async {
            expect(name, 'video.mp3');
            expect(output, endsWith('.mp3'));
            expect((await File(output).readAsBytes()).first, 0xff);
            expect(released, isFalse);
            imported = true;
          },
        );
        expect(imported && released, isTrue);
        expect(service.running, isFalse);
      },
    );

    test(
      'failed native MP3 verification rejects import and releases output',
      () async {
        final path = await source();
        var released = false;
        messenger.setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'prepare')
            return {'id': 'job', 'path': path, 'duration': .1};
          if (call.method == 'verifyMp3') {
            throw PlatformException(
              code: 'invalid_output',
              message: 'invalid MP3',
            );
          }
          if (call.method == 'release') {
            released = true;
            return null;
          }
          fail('Unexpected call ${call.method}');
        });
        await expectLater(
          service.export(
            '/source',
            name: 'source',
            format: AudioOutputFormat.mp3,
            onExported: (_, _) async => fail('Unverified MP3 must not import'),
          ),
          throwsA(
            isA<PlatformException>().having(
              (error) => error.code,
              'code',
              'invalid_output',
            ),
          ),
        );
        expect(released, isTrue);
      },
    );

    test(
      'failed library import releases temporary output and never reports success',
      () async {
        final path = await source();
        var released = false;
        messenger.setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'prepare') return {'id': 'job', 'path': path};
          if (call.method == 'release') {
            released = true;
            return null;
          }
          fail('Unexpected call ${call.method}');
        });
        await expectLater(
          service.export(
            '/original/audio.mp3',
            name: 'audio.mp3',
            format: AudioOutputFormat.m4a,
            onExported: (_, _) async => throw StateError('copy failed'),
          ),
          throwsStateError,
        );
        expect(released, isTrue);
        expect(service.running, isFalse);
      },
    );

    test(
      'cancel during library copy waits without releasing the copy input',
      () async {
        final path = await source();
        final entered = Completer<void>();
        final copy = Completer<void>();
        var released = false;
        messenger.setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'prepare') return {'id': 'job', 'path': path};
          if (call.method == 'release') {
            released = true;
            return null;
          }
          fail('Copy is in progress: native cancellation must not run');
        });
        final pending = service.export(
          '/source',
          name: 'source',
          format: AudioOutputFormat.m4a,
          onExported: (_, _) async {
            entered.complete();
            await copy.future;
          },
        );
        await entered.future;
        var cancelFinished = false;
        final cancellation = service.cancel().then(
          (_) => cancelFinished = true,
        );
        await Future<void>.delayed(Duration.zero);
        expect(released, isFalse);
        expect(cancelFinished, isFalse);
        copy.complete();
        await pending;
        await cancellation;
        expect(released, isTrue);
        expect(service.running, isFalse);
      },
    );

    test(
      'cancel waits for native work and resets the single-task state',
      () async {
        final entered = Completer<void>();
        final preparation = Completer<Object?>();
        messenger.setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'prepare') {
            entered.complete();
            return preparation.future;
          }
          if (call.method == 'cancel') {
            preparation.completeError(
              PlatformException(code: 'cancelled', message: 'cancelled'),
            );
            return null;
          }
          fail('Unexpected call ${call.method}');
        });
        final pending = service.export(
          '/source',
          name: 'source',
          format: AudioOutputFormat.m4a,
          onExported: (_, _) async => fail('Cancelled work must not import'),
        );
        final expected = expectLater(
          pending,
          throwsA(isA<PlatformException>()),
        );
        await entered.future;
        await expectLater(
          service.export(
            '/other',
            name: 'other',
            format: AudioOutputFormat.mp3,
            onExported: (_, _) async {},
          ),
          throwsStateError,
        );
        await service.cancel();
        await expected;
        expect(service.running, isFalse);
      },
    );

    test(
      'invalid speed or bitrate is rejected without invoking native code',
      () async {
        messenger.setMockMethodCallHandler(
          channel,
          (_) async => fail('Native must not be called'),
        );
        for (final speed in [0.0, 5.1, double.nan]) {
          await expectLater(
            service.export(
              '/source',
              name: 'source',
              format: AudioOutputFormat.m4a,
              speed: speed,
              onExported: (_, _) async {},
            ),
            throwsArgumentError,
          );
        }
      },
    );
  });
}
