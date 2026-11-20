import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:tingdubao/library.dart';
import 'package:tingdubao/models.dart';

void main() {
  Cue cue(String id, int start) => Cue(
    id: id,
    start: Duration(seconds: start),
    end: Duration(seconds: start + 2),
    text: id,
  );
  test('old stores retain recordings and receive current defaults', () {
    final item = MediaItem.fromJson({
      'id': 'old',
      'name': 'sample',
      'path': 'sample.mp3',
      'recordings': ['legacy.m4a'],
    });
    expect(item.recordings, ['legacy.m4a']);
    expect(item.cueRecordings, isEmpty);
    expect(item.customSpeeds, [.4, .5, .6, .7, .8, .9, 1, 1.8]);
    expect(item.singleSentence, isTrue);
  });
  test(
    'custom speeds up to five survive JSON storage and reject outside values',
    () {
      final item = MediaItem(
        id: 'speed',
        name: 'sample',
        path: 'sample.mp3',
        customSpeeds: [.05, .1, 3, 4.5, 5, 5.05],
      );
      final restored = MediaItem.fromJson(
        jsonDecode(jsonEncode(item.toJson())) as Map<String, dynamic>,
      );
      expect(restored.customSpeeds, [.1, 3, 4.5, 5]);
    },
  );
  test(
    'AB rows, cue recordings and custom speeds round trip independently',
    () {
      final item = MediaItem(
        id: 'test',
        name: 'sample',
        path: 'sample.mp3',
        cues: [cue('a', 0), cue('b', 4)],
        favorites: {'a'},
      );
      item.attachRecording('a', 'a.m4a');
      item.attachRecording('b', 'b.m4a');
      item.customSpeeds = [.45, .8, 1.2];
      item.singleSentence = false;
      final saved = MediaItem.fromJson(
        jsonDecode(jsonEncode(item.toJson())) as Map<String, dynamic>,
      );
      expect(saved.cueRecordings, {
        'a': ['a.m4a'],
        'b': ['b.m4a'],
      });
      expect(saved.customSpeeds, [.45, .8, 1.2]);
      expect(saved.singleSentence, isFalse);
      saved.removeCue('a');
      expect(saved.cues.single.id, 'b');
      expect(saved.favorites, isEmpty);
      expect(saved.cueRecordings, {
        'b': ['b.m4a'],
      });
      expect(saved.recordings, ['a.m4a', 'b.m4a']);
    },
  );
  test(
    'subtitle edits keep identity, sort by start and snapshots do not alias lists',
    () {
      final item = MediaItem(
        id: 'test',
        name: 'sample',
        path: 'sample.mp3',
        cues: [cue('a', 0), cue('b', 4)],
      );
      item.attachRecording('a', 'first.m4a');
      final snapshot = item.toJson();
      item.attachRecording('a', 'second.m4a');
      item.replaceCue(cue('a', 8));
      expect(item.cues.map((entry) => entry.id), ['b', 'a']);
      expect((snapshot['recordings'] as List), ['first.m4a']);
      expect((snapshot['cueRecordings'] as Map)['a'], ['first.m4a']);
      item.detachRecording('first.m4a');
      expect(item.cueRecordings['a'], ['second.m4a']);
    },
  );
  test(
    'a recording completed after cue removal remains in the global library',
    () {
      final item = MediaItem(id: 'test', name: 'sample', path: 'sample.mp3');
      item.attachRecording('removed', 'retained.m4a');
      expect(item.recordings, ['retained.m4a']);
      expect(item.cueRecordings, isEmpty);
    },
  );
  test('JSON and SRT exports use actual edited times and source text', () {
    final original = Cue(
      id: 'a',
      start: const Duration(milliseconds: 597),
      end: const Duration(milliseconds: 1948),
      text: 'One line',
      translation: '一行',
    );
    final encoded = encodeSubtitles([original]);
    expect(parseSubtitles(encoded).single.toJson(), original.toJson());
    final srt = encodeSubtitles([original], format: 'srt');
    expect(srt, contains('00:00:00,597 --> 00:00:01,948'));
    expect(parseSubtitles(srt, format: 'srt').single.text, 'One line\n一行');
  });
}
