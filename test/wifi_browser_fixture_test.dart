import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../scripts/wifi_browser_fixture.dart';

void main() {
  late Directory temporary;
  late WifiFixtureLibrary fixture;
  setUp(() async {
    temporary = await Directory.systemTemp.createTemp(
      'tingdubao_wifi_fixture_',
    );
    fixture = await WifiFixtureLibrary.open(
      Directory('${temporary.path}/library'),
    );
  });
  tearDown(() async {
    await temporary.delete(recursive: true);
  });

  test(
    'concurrent duplicate names preserve independent files and a complete ledger',
    () async {
      final source = File('${temporary.path}/source.mp3');
      await source.writeAsBytes([1, 3, 5, 7]);
      await Future.wait(
        List.generate(
          12,
          (_) => fixture.importFile(source.path, 'Introduction.mp3'),
        ),
      );
      final ledger =
          jsonDecode(
                await File('${fixture.root.path}/ledger.json').readAsString(),
              )
              as Map<String, dynamic>;
      final files = ledger['files'] as List;
      expect(ledger['backend'], 'pure-dart-copy-ledger');
      expect(files, hasLength(12));
      expect(files.map((file) => file['path']).toSet(), hasLength(12));
      for (final file in files) {
        expect(await File(file['path'] as String).readAsBytes(), [1, 3, 5, 7]);
        expect(file['bytes'], 4);
      }
    },
  );
  test(
    'standalone UTF-8 captions are persisted and survive fixture restart',
    () async {
      final source = File('${temporary.path}/independent.srt');
      await source.writeAsString('1\n00:00:00,500 --> 00:00:02,000\n独立字幕\n');
      await fixture.importFile(source.path, 'independent.srt');
      fixture = await WifiFixtureLibrary.open(fixture.root);
      await fixture.importFile(source.path, 'another.srt');
      final ledger =
          jsonDecode(
                await File('${fixture.root.path}/ledger.json').readAsString(),
              )
              as Map<String, dynamic>;
      final files = ledger['files'] as List;
      expect(files, hasLength(2));
      expect(files.first['kind'], 'subtitle');
      expect((files.first['cues'] as List).single['text'], '独立字幕');
      expect((files.first['cues'] as List).single['start'], 500);
      expect(
        await File(files.first['path'] as String).readAsString(),
        await source.readAsString(),
      );
    },
  );
  test('bad captions and traversal do not poison subsequent imports', () async {
    final bad = File('${temporary.path}/bad.srt');
    await bad.writeAsString('invalid timed caption');
    await expectLater(
      fixture.importFile(bad.path, 'bad.srt'),
      throwsFormatException,
    );
    await expectLater(
      fixture.importFile(bad.path, '../bad.srt'),
      throwsFormatException,
    );
    await bad.writeAsString('1\n00:00:00,000 --> 00:00:01,000\nRecovered\n');
    await fixture.importFile(bad.path, 'good.srt');
    final ledger =
        jsonDecode(
              await File('${fixture.root.path}/ledger.json').readAsString(),
            )
            as Map<String, dynamic>;
    expect(ledger['files'], hasLength(1));
  });
}
