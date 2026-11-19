import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:tingdubao/models.dart';

void main() {
  test('SRT preserves multiple lines and sorts source timestamps', () {
    final cues = parseSubtitles('''2
00:01:02,300 --> 00:01:05,123
Second sentence
第二句话

1
00:00:01,040 --> 00:00:03,700
First sentence
''', format: '.srt');
    expect(cues, hasLength(2));
    expect(cues.first.start, const Duration(milliseconds: 1040));
    expect(cues.last.end, const Duration(milliseconds: 65123));
    expect(cues.last.text, 'Second sentence\n第二句话');
  });

  test('VTT supports header, cue settings and minute timestamps', () {
    final cues = parseSubtitles('''WEBVTT

first
00:01.250 --> 00:03.500 align:start
Hello world
''', format: 'vtt');
    expect(cues.single.start.inMilliseconds, 1250);
    expect(cues.single.end.inMilliseconds, 3500);
  });

  test('LRC applies global offset, repeated tags and fractional seconds', () {
    final cues = parseSubtitles('''[ar:Someone]
[00:10.25][00:20.100]Repeated line
[00:00.01]First line
[offset:-1000]
''', format: 'lrc');
    expect(cues.map((cue) => cue.start.inMilliseconds), [0, 9250, 19100]);
    expect(cues[0].end, cues[1].start);
    expect(cues[1].text, 'Repeated line');
    expect(cues[2].end.inMilliseconds, 24100);
  });

  test('simultaneous LRC tags have valid end times', () {
    final cues = parseSubtitles('[00:01]A\n[00:01]B\n[00:03]C');
    expect(cues.map((cue) => cue.text), ['A', 'B', 'C']);
    expect(cues.take(2).map((cue) => cue.end.inSeconds), [3, 3]);
  });

  test('invalid timed segments do not become valid subtitles', () {
    final cues = parseSubtitles('''1
00:00:03,000 --> 00:00:01,000
Reversed

2
00:61:00,000 --> 00:62:00,000
Invalid minutes

3
00:00:01,000 --> 00:00:01,000
Zero length
''', format: 'srt');
    expect(cues, isEmpty);
    expect(parseSubtitles('[00:90]Invalid', format: 'lrc'), isEmpty);
    expect(
      () => Cue(
        id: 'bad',
        start: const Duration(seconds: -1),
        end: const Duration(seconds: 2),
        text: '',
      ),
      throwsArgumentError,
    );
  });

  test('IPA Introduction JSON retains source identities and translation', () {
    final cues = parseSubtitles(
      jsonEncode([
        {
          'ATime': 0.59727895259857178,
          'BTime': 1.9476189613342285,
          'content': 'We had a theory about China.',
          'translation': '我们有一个关于中国的设想。',
          'itemID': '2FFDDADA-857C-40C7-B3B8-E22655542723',
        },
        {'ATime': -1, 'BTime': 2, 'content': 'Invalid'},
        {'ATime': 'bad', 'BTime': 2, 'content': 'Invalid'},
      ]),
      format: 'txt',
    );
    expect(cues, hasLength(1));
    expect(cues.single.start.inMilliseconds, 597);
    expect(cues.single.end.inMilliseconds, 1948);
    expect(cues.single.translation, '我们有一个关于中国的设想。');
    expect(cues.single.id, '2FFDDADA-857C-40C7-B3B8-E22655542723');
    expect(Cue.fromJson(cues.single.toJson()).toJson(), cues.single.toJson());
  });

  test('plain text explicitly marks assigned timing as inferred', () {
    final cues = parseSubtitles('\uFEFF第一句\r\n\r\nSecond line');
    expect(cues, hasLength(2));
    expect(cues.every((cue) => cue.inferredTiming), isTrue);
    expect(cues[1].start.inSeconds, 5);
    expect(parseSubtitles('  '), isEmpty);
  });

  test('dictation compares words rather than character positions', () {
    expect(dictationScore('Hello, WORLD!', 'hello world'), 100);
    expect(dictationScore("Don't stop.", 'dont stop'), 100);
    expect(
      dictationScore(
        'We had a theory about China.',
        'We had a plan about China.',
      ),
      83,
    );
    expect(dictationScore('one two three', 'one three'), 67);
    expect(dictationScore('one two', 'one two three four'), 50);
    expect(dictationScore('one two', 'red blue'), 0);
    expect(dictationScore('hello', ''), 0);
    expect(dictationScore('', 'hello'), 0);
    expect(dictationScore('', ''), 100);
    expect(dictationScore('你好，世界！', '你好 世界'), 100);
  });

  test('time display handles hours and negative positions', () {
    expect(formatTime(const Duration(seconds: 5)), '00:05');
    expect(formatTime(const Duration(seconds: 3605)), '1:00:05');
    expect(formatTime(const Duration(seconds: -2)), '00:00');
  });
}
