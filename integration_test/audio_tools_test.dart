import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:material_ui/material_ui.dart';
import 'package:tingdubao/services/audio_tools.dart';
import 'package:tingdubao/services/waveform.dart';

Uint8List _oneSecondPcmWave() {
  const rate = 44100;
  const channels = 2;
  final bytes = Uint8List(44 + rate * channels * 2);
  final data = ByteData.sublistView(bytes);
  void text(int offset, String value) => bytes.setAll(offset, value.codeUnits);
  text(0, 'RIFF');
  data.setUint32(4, bytes.length - 8, Endian.little);
  text(8, 'WAVE');
  text(12, 'fmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, channels, Endian.little);
  data.setUint32(24, rate, Endian.little);
  data.setUint32(28, rate * channels * 2, Endian.little);
  data.setUint16(32, channels * 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  text(36, 'data');
  data.setUint32(40, rate * channels * 2, Endian.little);
  for (var frame = 0; frame < rate; frame++) {
    final sample = (math.sin(frame * 2 * math.pi * 440 / rate) * 10000).round();
    for (var channel = 0; channel < channels; channel++) {
      data.setInt16(
        44 + (frame * channels + channel) * 2,
        sample,
        Endian.little,
      );
    }
  }
  return bytes;
}

/// No mocked channels or permissions: the host launches the real iOS plugins.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('iOS AVFoundation exports retimed AAC and real MP3 with safe output release', (
    tester,
  ) async {
    expect(Platform.isIOS, isTrue, reason: 'A real iOS runtime is required.');
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(child: Text('Tdb native audio export probe')),
        ),
      ),
    );
    await tester.pump();
    debugPrint('TDB_AUDIO_E2E_START generated_pcm_seconds=1');
    await tester.runAsync(() async {
      final root = await Directory.systemTemp.createTemp(
        'tdb-ios-audio-probe-',
      );
      final imports = await Directory('${root.path}/imported').create();
      final original = _oneSecondPcmWave();
      final source = await File(
        '${root.path}/source.wav',
      ).writeAsBytes(original, flush: true);
      final sourceBefore = await source.stat();
      final service = AudioToolsService();
      final player = AudioPlayer();
      final copies = <File, Uint8List>{};
      var waveformInFlight = false;
      var released = 0;
      try {
        for (final (format, speed) in [
          (AudioOutputFormat.m4a, 1.5),
          (AudioOutputFormat.mp3, .8),
        ]) {
          String? workingPath;
          File? imported;
          await service
              .export(
                source.path,
                name: 'synthetic.wav',
                format: format,
                speed: speed,
                bitrate: 128,
                onExported: (path, name) async {
                  workingPath = path;
                  expect(path.toLowerCase(), endsWith('.${format.name}'));
                  expect(await File(path).exists(), isTrue);
                  final bytes = await File(path).readAsBytes();
                  expect(bytes, isNotEmpty);
                  imported = await File(path).copy('${imports.path}/$name');
                  copies[imported!] = bytes;
                  expect(
                    listEquals(await imported!.readAsBytes(), bytes),
                    isTrue,
                  );
                  expect(
                    await File(path).exists(),
                    isTrue,
                    reason:
                        'Native output stays alive until the library copy completes.',
                  );
                },
              )
              .timeout(const Duration(seconds: 90));
          expect(service.running, isFalse);
          expect(workingPath, isNotNull);
          expect(
            await File(workingPath!).exists(),
            isFalse,
            reason:
                'The production release method must remove its temporary output.',
          );
          expect(
            await File(workingPath!).parent.exists(),
            isFalse,
            reason:
                'The intermediate WAV and native job directory must also be released.',
          );
          released++;
          expect(imported, isNotNull);
          expect(await imported!.exists(), isTrue);
          expect(listEquals(await source.readAsBytes(), original), isTrue);
          expect((await source.stat()).modified, sourceBefore.modified);

          // just_audio reads duration through its actual Darwin AVPlayer plugin.
          final duration = await player
              .setFilePath(imported!.path)
              .timeout(const Duration(seconds: 30));
          expect(duration, isNotNull);
          expect(duration!.inMicroseconds, greaterThan(0));
          final expectedSeconds = 1 / speed;
          expect(
            duration.inMicroseconds / 1000000,
            closeTo(expectedSeconds, .15),
            reason: 'The output duration must reflect the requested speed.',
          );

          // Nonzero waveform data proves native decoding, rather than just metadata.
          waveformInFlight = true;
          final waveform = await WaveformService()
              .load(imported!.path)
              .timeout(const Duration(seconds: 60));
          waveformInFlight = false;
          expect(waveform.length, greaterThan(0));
          expect(waveform.sampleRate, greaterThan(0));
          expect(waveform.data.any((sample) => sample != 0), isTrue);
          final decodedSeconds =
              waveform.length * waveform.samplesPerPixel / waveform.sampleRate;
          expect(decodedSeconds, closeTo(expectedSeconds, .18));
          await player.stop().timeout(const Duration(seconds: 15));
          debugPrint(
            'TDB_AUDIO_E2E_FORMAT ${format.name} speed=$speed '
            'duration_us=${duration.inMicroseconds} decoded_samples=${waveform.length}',
          );
        }
        expect(released, 2);
        expect(copies, hasLength(2));
        for (final copy in copies.entries) {
          expect(await copy.key.exists(), isTrue);
          expect(
            listEquals(await copy.key.readAsBytes(), copy.value),
            isTrue,
            reason:
                'Releasing either native job must not delete or alter imported copies.',
          );
        }
        expect(listEquals(await source.readAsBytes(), original), isTrue);
        debugPrint(
          'TDB_AUDIO_E2E_OK formats=m4a,mp3 '
          'input_unchanged=true imported_copies_survive=true released_outputs=2',
        );
      } finally {
        var producerStopped = false;
        var playerDisposed = false;
        try {
          await service.cancel().timeout(const Duration(seconds: 30));
          producerStopped = !service.running;
        } finally {
          try {
            await player.dispose().timeout(const Duration(seconds: 15));
            playerDisposed = true;
          } finally {
            // A waveform timeout offers no native cancellation acknowledgement.
            // Retain only this isolated OS-temp root if any reader may remain active.
            if (producerStopped &&
                playerDisposed &&
                !waveformInFlight &&
                await root.exists()) {
              await root.delete(recursive: true);
            }
          }
        }
      }
    });
  }, timeout: const Timeout(Duration(minutes: 5)));
}
