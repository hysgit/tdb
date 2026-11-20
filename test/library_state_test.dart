import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tingdubao/library.dart';
import 'package:tingdubao/library_state.dart';
import 'package:tingdubao/models.dart';

/// Keep real filesystem generations while making one write fail or pause.
class ControlledRepository extends LibraryRepository {
  ControlledRepository(super.root);
  int writes = 0;
  Future<void> Function(int call, Map<String, dynamic> snapshot)? beforeWrite;
  Future<void> _pending = Future.value();

  @override
  Future<void> write(Map<String, dynamic> value) {
    final snapshot = jsonDecode(jsonEncode(value)) as Map<String, dynamic>;
    final call = ++writes;
    final next = _pending.then((_) async {
      await beforeWrite?.call(call, snapshot);
      await super.write(snapshot);
    });
    _pending = next.then<void>((_) {}, onError: (Object _) {});
    return next;
  }
}

void main() {
  late Directory directory;
  late ControlledRepository repository;
  late LibraryState state;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('tdb-library-state-');
    final root = await Directory('${directory.path}/owned').create();
    repository = ControlledRepository(root);
    state = LibraryState(repository);
  });
  tearDown(() async {
    state.dispose();
    await directory.delete(recursive: true);
  });

  Future<String> fixture(
    String name, [
    String content = 'media fixture',
  ]) async {
    final source = await Directory('${directory.path}/sources').create();
    final file = File('${source.path}/$name');
    await file.writeAsString(content, encoding: utf8);
    return file.path;
  }

  Future<MediaItem> media(String name, {String folder = ''}) async {
    final path = await fixture(name);
    await state.importFile(path, name, folder: folder);
    return state.items.last;
  }

  Cue cue(String id, String text) => Cue(
    id: id,
    start: Duration.zero,
    end: const Duration(seconds: 2),
    text: text,
  );

  for (final subtitleFirst in [true, false]) {
    test(
      'concurrent matching imports associate safely, subtitleFirst=$subtitleFirst',
      () async {
        final audio = await fixture('lesson.mp3');
        final subtitle = await fixture('lesson.lrc', '[00:01.00]real caption');
        final tasks = <Future<void>>[];
        if (subtitleFirst) {
          tasks.add(state.importFile(subtitle, 'lesson.lrc'));
          tasks.add(state.importFile(audio, 'lesson.mp3'));
        } else {
          tasks.add(state.importFile(audio, 'lesson.mp3'));
          tasks.add(state.importFile(subtitle, 'lesson.lrc'));
        }
        await Future.wait(tasks);
        expect(state.items.single.cues.single.text, 'real caption');
        expect(state.sidecars, hasLength(1));
        expect(await File(audio).exists(), isTrue);
        expect(state.items.single.path, isNot(audio));
        final saved = await repository.read();
        expect((saved!['items'] as List).single['cues'], hasLength(1));
      },
    );
  }

  test(
    'standalone subtitles persist without a selected or existing media item',
    () async {
      final subtitle = await fixture(
        'future.srt',
        '1\n00:00:01,000 --> 00:00:02,000\nfuture caption',
      );
      await state.importFile(subtitle, 'future.srt');
      expect(state.items, isEmpty);
      expect(state.sidecars, hasLength(1));
      expect(await File(state.sidecars.single['path']!).exists(), isTrue);
      final restored = LibraryState(repository)
        ..restore((await repository.read())!);
      expect(restored.sidecars.single['name'], 'future.srt');
      restored.dispose();
      await media('future.mp3');
      expect(state.items.single.cues.single.text, 'future caption');
    },
  );

  test(
    'matching subtitle never overwrites edited captions or favorites',
    () async {
      final item = await media('lesson.mp3');
      item.cues = [cue('edited', 'my edit')];
      item.favorites = {'edited'};
      final subtitle = await fixture(
        'lesson.lrc',
        '[00:01.00]incoming caption',
      );
      await state.importFile(subtitle, 'lesson.lrc');
      expect(item.cues.single.text, 'my edit');
      expect(item.favorites, {'edited'});
      expect(state.sidecars, hasLength(1));
    },
  );

  test(
    'same names in different folders cannot attach to the other folder',
    () async {
      state.folders = {'A', 'B'};
      final a = await fixture('a.lrc', '[00:01.00]caption A');
      final b = await fixture('b.lrc', '[00:01.00]caption B');
      final audio = await fixture('lesson.mp3');
      await Future.wait([
        state.importFile(a, 'lesson.lrc', folder: 'A'),
        state.importFile(b, 'lesson.lrc', folder: 'B'),
        state.importFile(audio, 'lesson.mp3', folder: 'B'),
        state.importFile(audio, 'lesson.mp3', folder: 'A'),
      ]);
      expect(
        state.items.firstWhere((i) => i.folder == 'A').cues.single.text,
        'caption A',
      );
      expect(
        state.items.firstWhere((i) => i.folder == 'B').cues.single.text,
        'caption B',
      );
      expect(state.items.map((i) => i.path).toSet(), hasLength(2));
    },
  );

  test('ambiguous same-stem media leaves subtitles independent', () async {
    await media('lesson.mp3');
    await media('lesson.m4a');
    final subtitle = await fixture('lesson.lrc', '[00:01.00]ambiguous');
    await state.importFile(subtitle, 'lesson.lrc');
    expect(state.items.every((i) => i.cues.isEmpty), isTrue);
    expect(state.sidecars, hasLength(1));
  });

  test(
    'failed subtitle import cannot erase an edit or persist a deleted sidecar',
    () async {
      final item = await media('lesson.mp3');
      final subtitle = await fixture('lesson.lrc', '[00:01.00]incoming');
      final entered = Completer<void>();
      final release = Completer<void>();
      final blocked = repository.writes + 1;
      repository.beforeWrite = (call, _) async {
        if (call == blocked) {
          entered.complete();
          await release.future;
          throw const FileSystemException('injected write failure');
        }
      };
      final importing = state.importFile(subtitle, 'lesson.lrc');
      final failed = expectLater(
        importing,
        throwsA(isA<FileSystemException>()),
      );
      await entered.future;
      final importedId = item.cues.single.id;
      item.replaceCue(cue(importedId, 'edited during pending save'));
      item.favorites = {importedId};
      final savingEdit = state.save();
      release.complete();
      await failed;
      await savingEdit;
      expect(item.cues.single.text, 'edited during pending save');
      expect(item.favorites, {importedId});
      expect(state.sidecars, isEmpty);
      final saved = (await repository.read())!;
      expect(saved['sidecars'], isEmpty);
      expect(
        (saved['items'] as List).single['cues'].single['text'],
        'edited during pending save',
      );
    },
  );

  test('delete write failure rolls back items, order and files', () async {
    final a = await media('a.mp3');
    final b = await media('b.mp3');
    a.cues = [cue('a', 'keep')];
    a.favorites = {'a'};
    await state.save();
    repository.beforeWrite = (_, _) async =>
        throw const FileSystemException('write failed');
    await expectLater(
      state.delete({a.id}),
      throwsA(isA<FileSystemException>()),
    );
    expect(state.items.map((i) => i.id), [a.id, b.id]);
    expect(a.favorites, {'a'});
    expect(await File(a.path).exists(), isTrue);
    expect(await File(b.path).exists(), isTrue);
    expect(((await repository.read())!['items'] as List), hasLength(2));
  });

  test(
    'queued move and reorder freeze caller-owned selection collections',
    () async {
      final a = await media('a.mp3');
      final b = await media('b.mp3');
      final c = await media('c.mp3');
      state.folders = {'B', 'C'};
      final entered = Completer<void>();
      final release = Completer<void>();
      final blocked = repository.writes + 1;
      repository.beforeWrite = (call, _) async {
        if (call == blocked) {
          entered.complete();
          await release.future;
        }
      };
      final first = state.move({a.id}, 'B');
      await entered.future;
      final selection = {b.id};
      final moving = state.move(selection, 'C');
      selection
        ..clear()
        ..add(c.id);
      final order = [c.id, b.id, a.id];
      final reordering = state.reorder(order);
      order
        ..clear()
        ..addAll([a.id, b.id, c.id]);
      release.complete();
      await Future.wait([first, moving, reordering]);
      expect(b.folder, 'C');
      expect(c.folder, '');
      expect(state.items.map((i) => i.id), [c.id, b.id, a.id]);
    },
  );

  test(
    'queued deletion freezes selection and preserves the active item',
    () async {
      final a = await media('a.mp3');
      final b = await media('b.mp3');
      final c = await media('c.mp3');
      state.folders = {'holding'};
      final entered = Completer<void>();
      final release = Completer<void>();
      final blocked = repository.writes + 1;
      repository.beforeWrite = (call, _) async {
        if (call == blocked) {
          entered.complete();
          await release.future;
        }
      };
      final first = state.move({a.id}, 'holding');
      await entered.future;
      final selection = {b.id};
      final deleting = state.delete(selection, activeId: c.id);
      selection
        ..clear()
        ..add(c.id);
      release.complete();
      await first;
      await deleting;
      expect(state.items.map((i) => i.id), [a.id, c.id]);
      expect(await File(c.path).exists(), isTrue);
      expect(await File(b.path).exists(), isFalse);
    },
  );

  test(
    'partial reorder is stable and repeated move/reorder is idempotent',
    () async {
      final a = await media('a.mp3');
      final b = await media('b.mp3');
      final c = await media('c.mp3');
      state.folders = {'target'};
      await state.reorder([c.id, a.id]);
      await state.reorder([c.id, a.id]);
      expect(state.items.map((i) => i.id), [c.id, b.id, a.id]);
      await state.move({b.id}, 'target');
      await state.move({b.id}, 'target');
      expect(b.folder, 'target');
      expect(state.items, hasLength(3));
      await expectLater(state.reorder([a.id, a.id]), throwsArgumentError);
    },
  );

  test(
    'snapshot collections cannot mutate live state or change after capture',
    () async {
      state.sidecars = [
        {'name': 'caption.txt', 'path': '/caption', 'folder': ''},
      ];
      state.standaloneRecordings = ['recording'];
      state.recent = ['first'];
      state.words = ['word'];
      state.studySeconds = {'2026-11-20': 5};
      final snapshot = state.snapshot();
      (snapshot['sidecars'] as List).single['name'] = 'changed';
      (snapshot['recordings'] as List).clear();
      expect(state.sidecars.single['name'], 'caption.txt');
      expect(state.standaloneRecordings, ['recording']);
      state.recent.add('second');
      state.words.add('new');
      state.studySeconds['2026-11-20'] = 20;
      expect(snapshot['recent'], ['first']);
      expect(snapshot['words'], ['word']);
      expect(snapshot['studySeconds'], {'2026-11-20': 5});
    },
  );

  test(
    'recording attach and detach are idempotent and keep standalone takes',
    () {
      final item = MediaItem(
        id: 'a',
        name: 'a',
        path: '/a',
        cues: [cue('sentence', 'text')],
      );
      item.attachRecording('sentence', '/recording');
      item.attachRecording('sentence', '/recording');
      expect(item.recordings, ['/recording']);
      expect(item.cueRecordings['sentence'], ['/recording']);
      item.favorites = {'sentence'};
      item.removeCue('sentence');
      expect(item.favorites, isEmpty);
      expect(item.cueRecordings, isEmpty);
      expect(item.recordings, ['/recording']);
      item.detachRecording('/recording');
      item.detachRecording('/recording');
      expect(item.recordings, isEmpty);
    },
  );

  test(
    'recording deletion rollback restores flat and per-cue references',
    () async {
      final item = await media('a.mp3');
      item.cues = [cue('sentence', 'text')];
      final recording = File('${repository.root.path}/recording.m4a');
      await recording.writeAsString('take');
      item.attachRecording('sentence', recording.path);
      await state.addRecording(recording.path);
      repository.beforeWrite = (_, _) async =>
          throw const FileSystemException('write failed');
      await expectLater(
        state.deleteRecording(recording.path),
        throwsA(isA<FileSystemException>()),
      );
      expect(item.recordings, [recording.path]);
      expect(item.cueRecordings['sentence'], [recording.path]);
      expect(state.standaloneRecordings, [recording.path]);
      expect(await recording.exists(), isTrue);
    },
  );

  test(
    'failed recording deletion preserves a take attached while saving',
    () async {
      final item = await media('a.mp3');
      item.cues = [cue('sentence', 'text')];
      final old = File('${repository.root.path}/old.m4a');
      await old.writeAsString('old');
      final fresh = File('${repository.root.path}/fresh.m4a');
      await fresh.writeAsString('fresh');
      item.attachRecording('sentence', old.path);
      await state.addRecording(old.path);
      final entered = Completer<void>();
      final release = Completer<void>();
      final blocked = repository.writes + 1;
      repository.beforeWrite = (call, _) async {
        if (call == blocked) {
          entered.complete();
          await release.future;
          throw const FileSystemException('write failed');
        }
      };
      final deletion = state.deleteRecording(old.path);
      final failed = expectLater(deletion, throwsA(isA<FileSystemException>()));
      await entered.future;
      item.attachRecording('sentence', fresh.path);
      final savingTake = state.save();
      release.complete();
      await failed;
      await savingTake;
      expect(item.recordings, [old.path, fresh.path]);
      expect(item.cueRecordings['sentence'], [old.path, fresh.path]);
      expect(await old.exists(), isTrue);
      expect(await fresh.exists(), isTrue);
      final saved = (await repository.read())!;
      expect((saved['items'] as List).single['recordings'], [
        old.path,
        fresh.path,
      ]);
    },
  );

  test(
    'deleting a recording never removes a surviving media file sharing its path',
    () async {
      final item = await media('recording.m4a');
      item.cues = [cue('sentence', 'text')];
      item.attachRecording('sentence', item.path);
      await state.addRecording(item.path);
      await state.addRecording(item.path);
      expect(state.standaloneRecordings, hasLength(1));
      await state.deleteRecording(item.path);
      await state.deleteRecording(item.path);
      expect(state.standaloneRecordings, isEmpty);
      expect(item.recordings, isEmpty);
      expect(await File(item.path).exists(), isTrue);
    },
  );

  test(
    'old schema restores defaults without losing existing recordings and favorites',
    () async {
      state.restore({
        'items': [
          {
            'id': 'old',
            'name': 'old.mp3',
            'path': '/old',
            'cues': [cue('old-cue', 'old text').toJson()],
            'favorites': ['old-cue'],
            'recordings': ['/take'],
          },
        ],
        'folders': ['folder'],
        'speed': 1.5,
      });
      final item = state.items.single;
      expect(item.favorites, {'old-cue'});
      expect(item.recordings, ['/take']);
      expect(item.cueRecordings, isEmpty);
      expect(item.customSpeeds, contains(.4));
      expect(item.singleSentence, isTrue);
      expect(item.repeatCount, 0);
      expect(item.repeatGapMs, 0);
      expect(state.sidecars, isEmpty);
      expect(state.standaloneRecordings, isEmpty);
      await state.save();
      final restored = LibraryState(repository)
        ..restore((await repository.read())!);
      expect(restored.items.single.cues.single.text, 'old text');
      expect(restored.speed, 1.5);
      restored.dispose();
    },
  );

  test(
    'delete leaves source files and files outside the owned root intact',
    () async {
      final outside = await fixture('original.mp3');
      final item = MediaItem(id: 'external', name: 'external', path: outside);
      state.items = [item];
      await state.delete({item.id});
      expect(await File(outside).exists(), isTrue);
    },
  );

  test(
    'directory symlink cannot make deletion escape the owned root',
    () async {
      final outside = await Directory('${directory.path}/outside').create();
      final original = File('${outside.path}/keep.mp3');
      await original.writeAsString('keep');
      final link = Link('${repository.root.path}/linked');
      try {
        await link.create(outside.path);
      } on FileSystemException {
        markTestSkipped(
          'This Windows account cannot create directory symbolic links.',
        );
        return;
      }
      final item = MediaItem(
        id: 'linked',
        name: 'linked',
        path: '${link.path}/keep.mp3',
      );
      state.items = [item];
      await state.delete({item.id});
      expect(await original.exists(), isTrue);
    },
  );
}
