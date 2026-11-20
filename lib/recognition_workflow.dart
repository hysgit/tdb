import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:just_waveform/just_waveform.dart';
import 'library.dart';
import 'models.dart';
import 'services/speech_recognition.dart';
import 'services/transfer_wake.dart';
import 'services/waveform.dart';

Future<List<Cue>?> recognizeMedia(
  BuildContext context,
  MediaItem item,
  Cue? segment,
  SpeechRecognitionService service,
) async {
  var speech = Platform.isIOS;
  var offline = true;
  var locale = 'en_US';
  var locales = <String>[
    'en_US',
    'zh_CN',
    'ja_JP',
    'ko_KR',
    'fr_FR',
    'de_DE',
    'es_ES',
  ];
  if (Platform.isIOS) {
    final supported = await service.supportedLocales();
    if (supported.isNotEmpty) {
      locales = supported;
      locale = supported.firstWhere(
        (l) => l.replaceAll('-', '_') == 'en_US',
        orElse: () => supported.first,
      );
    }
  }
  if (!context.mounted) return null;
  final accepted = await showDialog<bool>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, update) => AlertDialog(
        title: Text(segment == null ? '自动分句、语音识别' : '识别这一段'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('语音识别'),
              value: speech,
              onChanged: Platform.isIOS
                  ? (v) => update(() => speech = v)
                  : null,
            ),
            if (speech) ...[
              DropdownButtonFormField<String>(
                initialValue: locale,
                isExpanded: true,
                decoration: const InputDecoration(labelText: '识别语言'),
                items: locales
                    .map(
                      (l) => DropdownMenuItem(
                        value: l,
                        child: Text(_languageName(l)),
                      ),
                    )
                    .toList(),
                onChanged: (l) {
                  if (l != null) update(() => locale = l);
                },
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('仅在设备上识别'),
                subtitle: const Text('关闭后可使用 Apple 联网识别'),
                value: offline,
                onChanged: (v) => update(() => offline = v),
              ),
            ] else
              const Text('按实际音频中的停顿生成 AB 区间，可逐行补充字幕。'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('开始'),
          ),
        ],
      ),
    ),
  );
  if (accepted != true || !context.mounted) return null;
  return showDialog<List<Cue>>(
    context: context,
    barrierDismissible: false,
    builder: (_) => RecognitionProgressDialog(
      item: item,
      segment: segment,
      service: service,
      speech: speech,
      offline: offline,
      locale: locale,
    ),
  );
}

String _languageName(String locale) {
  const names = {
    'en_US': 'English (United States)',
    'zh_CN': '中文（普通话）',
    'zh_TW': '中文（台湾）',
    'en_GB': 'English (United Kingdom)',
    'ja_JP': '日本語',
    'ko_KR': '한국어',
    'fr_FR': 'Français',
    'de_DE': 'Deutsch',
    'es_ES': 'Español',
  };
  return names[locale.replaceAll('-', '_')] ?? locale;
}

class RecognitionProgressDialog extends StatefulWidget {
  const RecognitionProgressDialog({
    super.key,
    required this.item,
    required this.segment,
    required this.service,
    required this.speech,
    required this.offline,
    required this.locale,
  });
  final MediaItem item;
  final Cue? segment;
  final SpeechRecognitionService service;
  final bool speech, offline;
  final String locale;
  @override
  State<RecognitionProgressDialog> createState() => _RecognitionProgressState();
}

class _RecognitionProgressState extends State<RecognitionProgressDialog> {
  bool _cancelled = false, _busy = true;
  bool _closeScheduled = false;
  late final Future<void> _operation;
  String? _error;
  @override
  void initState() {
    super.initState();
    _operation = _run();
    unawaited(_operation);
  }

  Future<void> _run() async {
    TransferWakeLease? wake;
    List<Cue>? result;
    var nativeCancelled = false;
    try {
      wake = await TransferWake.acquire();
      if (_cancelled) return;
      List<Cue> cues;
      if (widget.speech) {
        cues = await widget.service.transcribe(
          widget.item.path,
          locale: widget.locale,
          start: widget.segment?.start,
          end: widget.segment?.end,
          offline: widget.offline,
        );
      } else {
        final wave = await WaveformService.shared.load(widget.item.path);
        cues = splitWaveform(
          wave,
          start: widget.segment?.start,
          end: widget.segment?.end,
        );
      }
      if (cues.isEmpty) throw const FormatException('这段音频没有识别到有效内容。');
      result = cues;
    } catch (e) {
      if (mounted && !_cancelled) {
        if (e is PlatformException && e.code.toLowerCase() == 'cancelled') {
          nativeCancelled = true;
        } else {
          setState(() {
            _error = e is PlatformException
                ? e.message ?? '语音识别不可用'
                : e.toString();
          });
        }
      }
    } finally {
      try {
        await wake?.release();
      } catch (e) {
        if (mounted && !_closeScheduled) {
          setState(() => _error = '无法恢复屏幕休眠设置：$e');
        }
      }
      if (mounted && !_closeScheduled) setState(() => _busy = false);
    }
    if (!_cancelled && nativeCancelled) _close();
    if (!_cancelled && _error == null && result != null) _close(result);
  }

  Future<void> _cancel() async {
    if (_cancelled) return;
    setState(() => _cancelled = true);
    try {
      if (widget.speech) await widget.service.cancel();
      // Native cancellation acknowledges that an audio slice is no longer
      // being exported; the job also owns its wake lease until it has settled.
      await _operation;
      _close();
    } catch (e) {
      if (mounted && !_closeScheduled) {
        setState(() {
          _cancelled = false;
          _error = '取消失败：$e';
        });
      }
    }
  }

  void _close([List<Cue>? result]) {
    if (_closeScheduled || !mounted) return;
    _closeScheduled = true;
    final route = ModalRoute.of(context);
    final navigator = Navigator.of(context);
    setState(() => _busy = false);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || route == null || !route.isActive) return;
      if (route.isCurrent) {
        navigator.pop(result);
      } else {
        navigator.removeRoute(route, result);
      }
    });
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy && (!_cancelled || _closeScheduled),
    child: AlertDialog(
      title: Text(widget.speech ? '正在识别语音' : '正在按停顿分句'),
      content: _error != null
          ? Text(_error!)
          : const Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(),
                SizedBox(height: 20),
                Text('保持此页面开启，完成后会显示分句。'),
              ],
            ),
      actions: [
        TextButton(
          onPressed: _cancelled
              ? null
              : _busy
              ? () => unawaited(_cancel())
              : _close,
          child: Text(
            _cancelled
                ? '正在取消…'
                : _busy
                ? '取消'
                : '关闭',
          ),
        ),
      ],
    ),
  );
}

List<Cue> splitWaveform(Waveform wave, {Duration? start, Duration? end}) {
  final from = (start ?? Duration.zero).inMicroseconds;
  if (from < 0 || (end != null && end.inMicroseconds <= from)) {
    throw ArgumentError('分句区间须满足 0 ≤ 开始 < 结束');
  }
  if (from >= wave.duration.inMicroseconds) return [];
  final until = (end ?? wave.duration).inMicroseconds.clamp(
    from,
    wave.duration.inMicroseconds,
  );
  if (until <= from) return [];
  final step = wave.samplesPerPixel * 1000000 / wave.sampleRate;
  final left = (from / step).floor().clamp(0, wave.length - 1);
  final right = (until / step).ceil().clamp(left + 1, wave.length);
  var peak = 0;
  for (var i = left; i < right; i++) {
    peak = math.max(
      peak,
      math.max(wave.getPixelMin(i).abs(), wave.getPixelMax(i).abs()),
    );
  }
  if (peak == 0) return [];
  final threshold = peak * .04;
  final spans = <({int a, int b})>[];
  int? beginning, lastSound;
  for (var i = left; i < right; i++) {
    final audible =
        math.max(wave.getPixelMin(i).abs(), wave.getPixelMax(i).abs()) >
        threshold;
    if (audible) {
      beginning ??= i;
      lastSound = i;
    }
    if (beginning != null &&
        lastSound != null &&
        (!audible && (i - lastSound) * step >= 450000 || i == right - 1)) {
      final a = math.max(from, (beginning * step).round() - 50000);
      final b = math.min(until, ((lastSound + 1) * step).round() + 100000);
      if (b - a >= 200000) spans.add((a: a, b: b));
      beginning = null;
      lastSound = null;
    }
  }
  return [
    for (var i = 0; i < spans.length; i++)
      Cue(
        id: 'split-${DateTime.now().microsecondsSinceEpoch}-$i',
        start: Duration(microseconds: spans[i].a),
        end: Duration(microseconds: spans[i].b),
        text: '',
      ),
  ];
}
