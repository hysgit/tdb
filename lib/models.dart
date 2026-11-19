import 'dart:convert';
import 'dart:math' as math;

/// One timed subtitle or AB study segment. Times are relative to the media.
class Cue {
  final String id;
  final Duration start;
  final Duration end;
  final String text;
  final String translation;
  final bool inferredTiming;

  Cue({
    required this.id,
    required this.start,
    required this.end,
    required this.text,
    this.translation = '',
    this.inferredTiming = false,
  }) {
    if (start.isNegative || end <= start) {
      throw ArgumentError('字幕结束时间必须晚于开始时间，开始时间不能为负数');
    }
  }

  factory Cue.fromJson(Map<String, dynamic> json) => Cue(
    id: json['id'] as String,
    start: Duration(milliseconds: (json['start'] as num).round()),
    end: Duration(milliseconds: (json['end'] as num).round()),
    text: json['text'] as String,
    translation: json['translation'] as String? ?? '',
    inferredTiming: json['inferredTiming'] as bool? ?? false,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'start': start.inMilliseconds,
    'end': end.inMilliseconds,
    'text': text,
    'translation': translation,
    'inferredTiming': inferredTiming,
  };
}

/// Parses timed captions, or assigns explicitly inferred five-second text cues.
/// Invalid timed entries are omitted; malformed JSON throws [FormatException].
List<Cue> parseSubtitles(String source, {String format = ''}) {
  final text = source
      .replaceFirst('\uFEFF', '')
      .replaceAll('\r\n', '\n')
      .trim();
  if (text.isEmpty) return [];
  final extension = format.toLowerCase().split('.').last;
  if (extension == 'json' || RegExp(r'^\[\s*(?:\{|\]|$)').hasMatch(text)) {
    return _parseJson(text);
  }
  if (extension == 'srt' || extension == 'vtt' || text.contains('-->')) {
    return _parseSrt(text);
  }
  if (extension == 'lrc' ||
      RegExp(r'\[\d+:\d{2}(?:[.:]\d+)?\]').hasMatch(text)) {
    return _parseLrc(text);
  }
  final lines = text
      .split('\n')
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty);
  return [
    for (final (index, line) in lines.indexed)
      Cue(
        id: 'text-$index',
        start: Duration(seconds: index * 5),
        end: Duration(seconds: (index + 1) * 5),
        text: line,
        inferredTiming: true,
      ),
  ];
}

List<Cue> _parseJson(String text) {
  final decoded = jsonDecode(text);
  if (decoded is! List) throw const FormatException('字幕 JSON 必须为数组');
  final cues = <Cue>[];
  for (final (index, value) in decoded.indexed) {
    if (value is! Map<String, dynamic>) continue;
    try {
      if (value.containsKey('ATime')) {
        final a = value['ATime'];
        final b = value['BTime'];
        if (a is! num || b is! num || !a.isFinite || !b.isFinite) continue;
        cues.add(
          Cue(
            id: value['itemID']?.toString() ?? 'json-$index',
            start: Duration(milliseconds: (a * 1000).round()),
            end: Duration(milliseconds: (b * 1000).round()),
            text: value['content']?.toString() ?? '',
            translation: value['translation']?.toString() ?? '',
          ),
        );
      } else {
        cues.add(Cue.fromJson(value));
      }
    } on ArgumentError {
      continue;
    } on TypeError {
      continue;
    }
  }
  return _sort(cues);
}

List<Cue> _parseSrt(String text) {
  final timestamp = RegExp(r'(?:(\d+):)?(\d{2}):(\d{2})[.,](\d{1,3})');
  final cues = <Cue>[];
  for (final block in text.split(RegExp(r'\n\s*\n'))) {
    final lines = block.split('\n');
    final timing = lines.indexWhere((line) => line.contains('-->'));
    if (timing < 0) continue;
    final parts = lines[timing].split('-->');
    if (parts.length != 2) continue;
    final a = timestamp.firstMatch(parts[0].trim());
    final b = timestamp.firstMatch(parts[1].trim());
    if (a == null || b == null) continue;
    final start = _subtitleTime(a);
    final end = _subtitleTime(b);
    if (start == null || end == null || end <= start) continue;
    final caption = lines.skip(timing + 1).join('\n').trim();
    if (caption.isEmpty) continue;
    cues.add(
      Cue(id: 'srt-${cues.length}', start: start, end: end, text: caption),
    );
  }
  return _sort(cues);
}

Duration? _subtitleTime(RegExpMatch match) {
  final hours = int.parse(match[1] ?? '0');
  final minutes = int.parse(match[2]!);
  final seconds = int.parse(match[3]!);
  if (minutes > 59 || seconds > 59) return null;
  return Duration(
    hours: hours,
    minutes: minutes,
    seconds: seconds,
    milliseconds: int.parse(match[4]!.padRight(3, '0')),
  );
}

List<Cue> _parseLrc(String text) {
  final offsetMatches = RegExp(
    r'\[offset:\s*([+-]?\d+)\]',
    caseSensitive: false,
  ).allMatches(text);
  final offset = offsetMatches.isEmpty ? 0 : int.parse(offsetMatches.last[1]!);
  final tags = RegExp(r'\[(\d+):(\d{2})(?:[.:](\d{1,3}))?\]');
  final entries = <({Duration start, String text, int order})>[];
  for (final line in text.split('\n')) {
    final matches = tags.allMatches(line).toList();
    if (matches.isEmpty) continue;
    final caption = line.substring(matches.last.end).trim();
    if (caption.isEmpty) continue;
    for (final match in matches) {
      final seconds = int.parse(match[2]!);
      if (seconds > 59) continue;
      final millis =
          int.parse(match[1]!) * 60000 +
          seconds * 1000 +
          int.parse((match[3] ?? '0').padRight(3, '0')) +
          offset;
      entries.add((
        start: Duration(milliseconds: math.max(0, millis)),
        text: caption,
        order: entries.length,
      ));
    }
  }
  entries.sort((a, b) {
    final comparison = a.start.compareTo(b.start);
    return comparison == 0 ? a.order.compareTo(b.order) : comparison;
  });
  return [
    for (var index = 0; index < entries.length; index++)
      Cue(
        id: 'lrc-$index',
        start: entries[index].start,
        end:
            entries
                .skip(index + 1)
                .where((item) => item.start > entries[index].start)
                .firstOrNull
                ?.start ??
            entries[index].start + const Duration(seconds: 5),
        text: entries[index].text,
      ),
  ];
}

List<Cue> _sort(List<Cue> cues) {
  // Preserve source order for simultaneous captions.
  final indexed = cues.indexed.toList();
  indexed.sort((a, b) {
    final comparison = a.$2.start.compareTo(b.$2.start);
    return comparison == 0 ? a.$1.compareTo(b.$1) : comparison;
  });
  return indexed.map((entry) => entry.$2).toList();
}

String formatTime(Duration duration) {
  final total = math.max(0, duration.inSeconds);
  final seconds = (total % 60).toString().padLeft(2, '0');
  final minutes = ((total ~/ 60) % 60).toString().padLeft(2, '0');
  return total >= 3600
      ? '${total ~/ 3600}:$minutes:$seconds'
      : '$minutes:$seconds';
}

/// A text comparison score, not a pronunciation or speech recognition score.
int dictationScore(String expected, String actual) {
  List<String> words(String text) => RegExp(r'[\p{L}\p{N}]+', unicode: true)
      .allMatches(text.toLowerCase().replaceAll(RegExp("['’]"), ''))
      .map((match) => match[0]!)
      .toList();
  final reference = words(expected);
  final answer = words(actual);
  if (reference.isEmpty && answer.isEmpty) return 100;
  if (reference.isEmpty || answer.isEmpty) return 0;
  var previous = List<int>.generate(answer.length + 1, (index) => index);
  for (var i = 1; i <= reference.length; i++) {
    final current = <int>[i];
    for (var j = 1; j <= answer.length; j++) {
      current.add(
        math.min(
          math.min(previous[j] + 1, current[j - 1] + 1),
          previous[j - 1] + (reference[i - 1] == answer[j - 1] ? 0 : 1),
        ),
      );
    }
    previous = current;
  }
  return ((1 - previous.last / math.max(reference.length, answer.length)) * 100)
      .round()
      .clamp(0, 100);
}
