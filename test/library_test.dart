import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tingdubao/library.dart';

void main() {
  late Directory directory;
  late LibraryRepository repository;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'tingdubao_library_test_',
    );
    repository = LibraryRepository(directory);
  });
  tearDown(() async {
    await directory.delete(recursive: true);
  });

  test(
    'queued writes preserve call order and snapshot values immediately',
    () async {
      final value = <String, dynamic>{'revision': 0, 'favorites': <String>[]};
      final writes = <Future<void>>[];
      for (var i = 0; i < 100; i++) {
        value['revision'] = i;
        (value['favorites'] as List<String>).add('$i');
        writes.add(repository.write(value));
      }
      value['revision'] = 1000;
      await Future.wait(writes);
      final result = await repository.read();
      expect(result!['revision'], 99);
      expect(result['favorites'], hasLength(100));
    },
  );
  test(
    'read waits for writes and corruption falls back to previous generation',
    () async {
      await repository.write({'revision': 1});
      final writing = repository.write({'revision': 2});
      expect((await repository.read())!['revision'], 2);
      await writing;
      await File('${directory.path}/library.json').writeAsString('{incomplete');
      expect((await repository.read())!['revision'], 1);
    },
  );
  test('damaged existing data is never mistaken for first launch', () async {
    expect(await repository.read(), isNull);
    await File('${directory.path}/library.json').writeAsString('{');
    await File('${directory.path}/library.previous.json').writeAsString('[]');
    await expectLater(repository.read(), throwsFormatException);
  });
  test('a failed write does not poison the queue', () async {
    final blocked = Directory('${directory.path}/library.next.json');
    await blocked.create();
    await expectLater(
      repository.write({'revision': 1}),
      throwsA(isA<FileSystemException>()),
    );
    await blocked.delete();
    await repository.write({'revision': 2});
    expect((await repository.read())!['revision'], 2);
  });
  test(
    'concurrent imports of identical names retain independent bytes',
    () async {
      final source = File('${directory.path}/source.mp3');
      await source.writeAsBytes([1, 2, 3, 4]);
      final paths = await Future.wait(
        List.generate(
          12,
          (_) => repository.importFile(source.path, '../same.mp3'),
        ),
      );
      expect(paths.toSet(), hasLength(12));
      for (final path in paths) {
        expect(File(path).parent.parent.path, directory.path);
        expect(await File(path).readAsBytes(), [1, 2, 3, 4]);
      }
    },
  );
}
