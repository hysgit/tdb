import 'dart:math' as math;

import 'package:flutter/services.dart';

import '../models.dart';

/// System file recognition. Offline requests never silently opt into networking.
class SpeechRecognitionService {
  SpeechRecognitionService({
    MethodChannel channel = const MethodChannel('tingdubao/speech_recognition'),
  }) : _channel = channel;

  final MethodChannel _channel;
  bool _running = false;

  bool get running => _running;

  Future<List<String>> supportedLocales() async =>
      (await _channel.invokeListMethod<String>('locales')) ?? [];

  Future<bool> supportsOffline(String locale) async =>
      await _channel.invokeMethod<bool>('supportsOffline', {
        'locale': locale,
      }) ??
      false;

  Future<void> cancel() => _channel.invokeMethod<void>('cancel');

  Future<List<Cue>> transcribe(
    String path, {
    required String locale,
    Duration? start,
    Duration? end,
    bool offline = true,
  }) async {
    if (_running) throw StateError('已有语音识别正在进行，请先取消或等待完成。');
    final beginning = start ?? Duration.zero;
    if (beginning.isNegative || (end != null && end <= beginning)) {
      throw ArgumentError('识别结束时间须晚于开始时间，开始时间不能为负数。');
    }
    if (path.isEmpty || locale.trim().isEmpty) {
      throw ArgumentError('请选择媒体文件和识别语言。');
    }
    _running = true;
    try {
      final result = await _channel
          .invokeMapMethod<Object?, Object?>('transcribe', {
            'path': path,
            'locale': locale,
            'offline': offline,
            'startMilliseconds': beginning.inMilliseconds,
            if (end != null) 'endMilliseconds': end.inMilliseconds,
          });
      final words = result?['words'];
      if (words is! List) throw const FormatException('系统返回的识别结果无效。');
      return speechWordsToCues([
        for (final word in words)
          if (word is Map)
            SpeechWord.fromMap(Map<Object?, Object?>.from(word))
          else
            throw const FormatException('系统返回的识别词项无效。'),
      ]);
    } finally {
      _running = false;
    }
  }
}

class SpeechWord {
  const SpeechWord({
    required this.text,
    required this.start,
    required this.duration,
    required this.confidence,
  });

  factory SpeechWord.fromMap(Map<Object?, Object?> map) {
    final text = map['text'];
    final timestamp = map['timestamp'];
    final duration = map['duration'];
    final confidence = map['confidence'];
    if (text is! String ||
        timestamp is! num ||
        !timestamp.isFinite ||
        timestamp < 0 ||
        duration is! num ||
        !duration.isFinite ||
        duration <= 0 ||
        confidence is! num ||
        !confidence.isFinite ||
        confidence < 0 ||
        confidence > 1) {
      throw const FormatException('系统返回的识别时间或置信度无效。');
    }
    return SpeechWord(
      text: text.trim(),
      start: Duration(microseconds: (timestamp * 1000000).round()),
      duration: Duration(microseconds: (duration * 1000000).round()),
      confidence: confidence.toDouble(),
    );
  }

  final String text;
  final Duration start;
  final Duration duration;
  final double confidence;
  Duration get end => start + duration;
}

final _sentenceEnd = RegExp(r'''[.!?。！？；;]["'”’）)\]]*$''');
final _closingPunctuation = RegExp(r'''^[,.;:!?，。！？；：、…"'”’）)\]]''');
final _openingPunctuation = RegExp(r'''[“‘（(\[【《]$''');
final _chineseOrJapanese = RegExp(r'[\u2e80-\u9fff\uf900-\ufaff]');

/// Word timestamps already include the source-file offset supplied by iOS.
/// Group on punctuation, silence, or long uninterrupted speech; never invent a translation.
List<Cue> speechWordsToCues(
  Iterable<SpeechWord> source, {
  Duration silenceGap = const Duration(milliseconds: 700),
  Duration maximumDuration = const Duration(seconds: 12),
}) {
  if (silenceGap.isNegative || maximumDuration <= Duration.zero) {
    throw ArgumentError('分句间隔不能为负，最长语句时间须大于零。');
  }
  final words =
      source.indexed.where((entry) {
        final word = entry.$2;
        return word.text.trim().isNotEmpty &&
            !word.start.isNegative &&
            word.duration > Duration.zero;
      }).toList()..sort((a, b) {
        final order = a.$2.start.compareTo(b.$2.start);
        return order == 0 ? a.$1.compareTo(b.$1) : order;
      });
  final cues = <Cue>[];
  Duration? start;
  var end = Duration.zero;
  var text = '';
  void emit() {
    if (start == null) return;
    cues.add(
      Cue(
        id: 'speech-${start!.inMicroseconds}-${cues.length}',
        start: start!,
        end: end,
        text: text,
      ),
    );
    start = null;
    end = Duration.zero;
    text = '';
  }

  for (final (_, word) in words) {
    final token = word.text.trim();
    final closing = _closingPunctuation.hasMatch(token);
    if (start != null &&
        ((word.start - end >= silenceGap && word.start > end) ||
            word.end - start! > maximumDuration ||
            (_sentenceEnd.hasMatch(text) && !closing))) {
      emit();
    }
    start ??= word.start;
    final attach =
        text.isEmpty ||
        closing ||
        _openingPunctuation.hasMatch(text) ||
        _chineseOrJapanese.hasMatch(token[0]) ||
        (text.isNotEmpty && _chineseOrJapanese.hasMatch(text[text.length - 1]));
    text = '$text${attach ? '' : ' '}$token';
    end = Duration(
      microseconds: math.max(end.inMicroseconds, word.end.inMicroseconds),
    );
  }
  emit();
  return cues;
}
