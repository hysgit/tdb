import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_waveform/just_waveform.dart';
import 'package:tingdubao/services/waveform.dart';

Waveform waveformFixture() => Waveform(
  version: 1,
  flags: 0,
  sampleRate: 100,
  samplesPerPixel: 1,
  length: 1000,
  data: List<int>.generate(2000, (i) => i.isEven ? -12000 : 16000),
);

Future<void> until(bool Function() ready) async {
  for (var i = 0; i < 200 && !ready(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(ready(), isTrue, reason: 'Timed out waiting for waveform extraction');
}

void main() {
  late Directory temporary;
  late File source;
  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('tingdubao_wave_test_');
    source = File('${temporary.path}/source.mp3');
    await source.writeAsBytes([1, 2, 3]);
  });
  tearDown(() async {
    await temporary.delete(recursive: true);
  });

  test(
    'concurrent readers share one extraction and cleanup waits for completion',
    () async {
      final gate = Completer<Waveform>();
      final outputs = <File>[];
      final service = WaveformService(
        temporaryDirectory: () async => temporary,
        extractor: (input, output) async {
          outputs.add(output);
          await output.writeAsBytes([0]);
          return gate.future;
        },
      );
      final first = service.load(source.path);
      final second = service.load(source.path);
      await until(() => outputs.length == 1);
      expect(await outputs.single.parent.exists(), isTrue);
      expect(await outputs.single.exists(), isTrue);
      gate.complete(waveformFixture());
      final results = await Future.wait([first, second]);
      expect(identical(results[0], results[1]), isTrue);
      expect(outputs, hasLength(1));
      expect(await outputs.single.parent.exists(), isFalse);
    },
  );

  test('different input files have independent output paths', () async {
    final other = File('${temporary.path}/other.mp3');
    await other.writeAsBytes([4, 5, 6]);
    final gates = <String, Completer<Waveform>>{};
    final outputs = <File>[];
    final service = WaveformService(
      temporaryDirectory: () async => temporary,
      extractor: (input, output) {
        outputs.add(output);
        return (gates[input.path] = Completer<Waveform>()).future;
      },
    );
    final first = service.load(source.path);
    final second = service.load(other.path);
    await until(() => outputs.length == 2);
    expect(outputs[0].path, isNot(outputs[1].path));
    gates[other.absolute.path]!.complete(waveformFixture());
    await second;
    expect(await outputs[0].parent.exists(), isTrue);
    expect(await outputs[1].parent.exists(), isFalse);
    gates[source.absolute.path]!.complete(waveformFixture());
    await first;
    expect(await outputs[0].parent.exists(), isFalse);
  });

  test(
    'failed native extraction does not unlink a potentially active output',
    () async {
      File? output;
      final service = WaveformService(
        temporaryDirectory: () async => temporary,
        extractor: (input, target) async {
          output = target;
          await target.writeAsBytes([0]);
          throw const FormatException('decoder failed');
        },
      );
      await expectLater(service.load(source.path), throwsFormatException);
      expect(await output!.exists(), isTrue);
    },
  );

  test(
    'changed input is rejected and completed output is cleaned up',
    () async {
      final gate = Completer<Waveform>();
      File? output;
      final service = WaveformService(
        temporaryDirectory: () async => temporary,
        extractor: (input, target) {
          output = target;
          return gate.future;
        },
      );
      final result = service.load(source.path);
      await until(() => output != null);
      await source.writeAsBytes([1, 2, 3, 4]);
      final expectation = expectLater(
        result,
        throwsA(isA<FileSystemException>()),
      );
      gate.complete(waveformFixture());
      await expectation;
      expect(await output!.parent.exists(), isFalse);
    },
  );

  test('missing source is rejected before starting a decoder', () async {
    var extracted = false;
    final service = WaveformService(
      temporaryDirectory: () async => temporary,
      extractor: (input, output) async {
        extracted = true;
        return waveformFixture();
      },
    );
    await expectLater(
      service.load('${temporary.path}/missing.mp3'),
      throwsA(isA<FileSystemException>()),
    );
    expect(extracted, isFalse);
  });
}
