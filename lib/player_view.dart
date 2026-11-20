import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:just_audio/just_audio.dart';
import 'package:material_ui/material_ui.dart';
import 'package:record/record.dart';
import 'package:video_player/video_player.dart';

import 'library.dart';
import 'models.dart';
import 'services/player.dart';
import 'services/waveform.dart';
import 'waveform_view.dart';

typedef RecognizeSegments =
    Future<List<Cue>?> Function(MediaItem item, Cue? segment);

class PlayerView extends StatefulWidget {
  const PlayerView({
    super.key,
    required this.player,
    required this.onSave,
    required this.onMessage,
    this.onRecognize,
    this.waveformService,
  });
  final StudyPlayer player;
  final Future<void> Function() onSave;
  final void Function(String) onMessage;
  final RecognizeSegments? onRecognize;
  final WaveformService? waveformService;
  @override
  PlayerViewState createState() => PlayerViewState();
}

class PlayerViewState extends State<PlayerView> {
  static const _orange = Color(0xFFF58425);
  static const _grey = Color(0xFF808580);
  final _scroll = ScrollController();
  final _recorder = AudioRecorder();
  final _recordPlayer = AudioPlayer();
  final Map<String, GlobalKey> _rowKeys = {};
  final Set<String> _hiddenText = {};
  MediaItem? _knownItem;
  MediaItem? _recordingItem;
  String? _selectedId, _expandedId, _recordingCueId, _playingRecording;
  Cue? _comparingCue;
  Completer<void>? _compareEnd;
  Future<void>? _endingRecording;
  int _auxEpoch = 0, _editRevision = 0, _lastActive = -1;
  bool _recording = false, _recordBusy = false, _recognizing = false;
  bool _showTranslation = false,
      _showText = true,
      _intensive = false,
      _importing = false;
  double? _scrubbing;
  StudyPlayer get _player => widget.player;
  MediaItem? get _item => _player.item;
  Cue? get _selected => (_item?.cues ?? <Cue>[])
      .where((cue) => cue.id == _selectedId)
      .firstOrNull;
  List<String> _recordings(Cue cue) => _item?.cueRecordings[cue.id] ?? const [];

  @override
  void initState() {
    super.initState();
    _knownItem = _item;
    _selectedId = _item?.cues.firstOrNull?.id;
    _player.addListener(_onPlayer);
  }

  @override
  void didUpdateWidget(covariant PlayerView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.player != widget.player) {
      oldWidget.player.removeListener(_onPlayer);
      _player.addListener(_onPlayer);
      _syncItem();
    }
  }

  void _cancelComparison() {
    _auxEpoch++;
    _comparingCue = null;
    _playingRecording = null;
    final end = _compareEnd;
    _compareEnd = null;
    if (end != null && !end.isCompleted) end.complete();
  }

  void _syncItem() {
    _cancelComparison();
    _knownItem = _item;
    _selectedId = _item?.cues.firstOrNull?.id;
    _expandedId = null;
    _lastActive = -1;
    _scrubbing = null;
    _hiddenText.clear();
    _rowKeys.clear();
    _editRevision++;
    unawaited(_run(() => _recordPlayer.stop()));
    if (_recording) unawaited(_finishRecording());
  }

  void _onPlayer() {
    if (!mounted) return;
    if (_knownItem?.id != _item?.id) _syncItem();
    final end = _compareEnd;
    if (_comparingCue != null &&
        end != null &&
        !end.isCompleted &&
        (_player.position >= _comparingCue!.end || _player.error != null)) {
      end.complete();
    }
    final cues = _item?.cues ?? <Cue>[];
    final active = cues.indexWhere(
      (cue) => _player.position >= cue.start && _player.position < cue.end,
    );
    if (active != _lastActive) {
      _lastActive = active;
      if (active >= 0 && _player.playing) {
        _selectedId = cues[active].id;
        _expandedId = _selectedId;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          final row = _rowKeys[_selectedId]?.currentContext;
          if (row != null) {
            unawaited(
              Scrollable.ensureVisible(
                row,
                alignment: .35,
                duration: const Duration(milliseconds: 220),
              ),
            );
          }
        });
      }
    }
    setState(() {});
  }

  Future<void> _run(Future<void> Function() action) async {
    try {
      await action();
    } catch (error) {
      widget.onMessage('操作失败：$error');
    }
  }

  Future<void> _save() => widget.onSave();

  Future<void> _playCue(
    Cue cue, {
    bool once = false,
    bool cancelAuxiliary = true,
  }) async {
    if (cancelAuxiliary) _cancelComparison();
    if (_recording) await _finishRecording();
    await _recordPlayer.stop();
    final b = _player.duration > Duration.zero && cue.end > _player.duration
        ? _player.duration
        : cue.end;
    if (b <= cue.start) throw const FormatException('片段时间超出媒体长度，请编辑 AB 时间');
    _selectedId = cue.id;
    _expandedId = cue.id;
    final item = _item;
    _player.repeat.setRange(
      cue.start,
      b,
      count: once
          ? 1
          : item?.singleSentence == true
          ? item!.repeatCount
          : 1,
      gap: Duration(milliseconds: once ? 0 : item?.repeatGapMs ?? 0),
    );
    await _player.seek(cue.start);
    await _player.play();
    if (mounted) setState(() {});
  }

  Future<void> _updateRange(MediaItem item, Cue cue, Duration a, Duration b) =>
      _run(() async {
        if (a.isNegative ||
            b <= a ||
            (_player.duration > Duration.zero && b > _player.duration)) {
          throw const FormatException('请保持 0 ≤ A < B，且 B 不超过媒体长度');
        }
        item.replaceCue(cue.copyWith(start: a, end: b, inferredTiming: false));
        _editRevision++;
        if (_item?.id == item.id) {
          _player.repeat.setRange(
            a,
            b,
            count: item.singleSentence ? item.repeatCount : 1,
            gap: Duration(milliseconds: item.repeatGapMs),
          );
          if (mounted) setState(() {});
        }
        await _save();
      });
  Future<void> _changeBoundary(bool start) async {
    final item = _item;
    final cue = _selected;
    if (item != null && cue != null) {
      await _updateRange(
        item,
        cue,
        start ? _player.position : cue.start,
        start ? cue.end : _player.position,
      );
    }
  }

  Future<void> _addRow() => _run(() async {
    final item = _item;
    if (item == null) return;
    final a = _player.position;
    final duration = _player.duration;
    if (duration <= Duration.zero || a >= duration) {
      throw const FormatException('请等待媒体加载，或跳到文件结束前再添加');
    }
    final cue = Cue(
      id: 'manual-${DateTime.now().microsecondsSinceEpoch}',
      start: a,
      end:
          a +
          Duration(milliseconds: math.min(5000, (duration - a).inMilliseconds)),
      text: '',
    );
    item.replaceCue(cue);
    _editRevision++;
    if (mounted && _item?.id == item.id) {
      setState(() {
        _selectedId = cue.id;
        _expandedId = cue.id;
      });
    }
    await _save();
  });
  Future<void> _deleteRow() async {
    final item = _item;
    final cue = _selected;
    if (item == null || cue == null) return;
    final remove = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除这行？'),
        content: const Text('删除 AB 片段及本行收藏，原媒体和已保存录音仍保留。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (remove != true || !mounted) return;
    await _run(() async {
      _cancelComparison();
      if (_recording) await _finishRecording();
      await _player.pause();
      item.removeCue(cue.id);
      _editRevision++;
      _player.repeat.clear();
      if (_item?.id == item.id) {
        setState(() {
          _selectedId = item.cues.firstOrNull?.id;
          _expandedId = null;
        });
      }
      await _save();
    });
  }

  Future<void> _toggleFavorite(Cue cue) async {
    final item = _item;
    if (item == null) return;
    setState(() {
      final favorites = {...item.favorites};
      if (!favorites.add(cue.id)) favorites.remove(cue.id);
      item.favorites = favorites;
    });
    await _run(_save);
  }

  Future<void> _toggleSingle() async {
    final item = _item;
    if (item == null) return;
    setState(() => item.singleSentence = !item.singleSentence);
    final cue = _selected;
    if (item.singleSentence && cue != null) {
      _player.repeat.setRange(
        cue.start,
        cue.end,
        count: item.repeatCount,
        gap: Duration(milliseconds: item.repeatGapMs),
      );
    } else {
      _player.repeat.clear();
    }
    await _run(_save);
  }

  Future<void> _recognize(Cue? cue) async {
    final item = _item;
    if (item == null || _recognizing) return;
    if (widget.onRecognize == null) {
      widget.onMessage('尚未配置语音识别服务，可以手动分句或导入字幕');
      return;
    }
    final revision = _editRevision;
    setState(() => _recognizing = true);
    await _run(() async {
      if (_recording) await _finishRecording();
      await _player.pause();
      final result = await widget.onRecognize!(item, cue);
      if (result == null) return;
      if (revision != _editRevision || _item?.id != item.id) {
        throw const FormatException('字幕或文件已更改，识别结果未覆盖当前内容，请重新识别');
      }
      if (result.isEmpty) throw const FormatException('未识别到语音，原有字幕已保留');
      if (cue == null) {
        final ids = result.map((entry) => entry.id).toSet();
        if (ids.length != result.length) {
          throw const FormatException('识别返回了重复片段标识');
        }
        item.cues = [...result]..sort((a, b) => a.start.compareTo(b.start));
        item.favorites = item.favorites.intersection(ids);
        item.cueRecordings = Map.fromEntries(
          item.cueRecordings.entries.where((entry) => ids.contains(entry.key)),
        );
        _selectedId = item.cues.first.id;
      } else {
        item.replaceCue(
          cue.copyWith(
            text: result.map((entry) => entry.text).join(' '),
            translation: result
                .map((entry) => entry.translation)
                .where((text) => text.isNotEmpty)
                .join(' '),
            inferredTiming: false,
          ),
        );
      }
      _editRevision++;
      await _save();
    });
    if (mounted) setState(() => _recognizing = false);
  }

  Future<void> _importSubtitles() async {
    final item = _item;
    if (item == null || _importing) return;
    setState(() => _importing = true);
    await _run(() async {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['lrc', 'srt', 'vtt', 'json', 'txt'],
      );
      if (result == null) return;
      final selected = result.files.single;
      final bytes =
          selected.bytes ??
          (selected.path == null
              ? null
              : await File(selected.path!).readAsBytes());
      if (bytes == null) throw const FormatException('无法读取字幕');
      final cues = parseSubtitles(utf8.decode(bytes), format: selected.name);
      if (cues.isEmpty) throw const FormatException('没有有效字幕，原字幕已保留');
      if (_recording) await _finishRecording();
      item.cues = cues;
      final ids = cues.map((cue) => cue.id).toSet();
      item.favorites = item.favorites.intersection(ids);
      item.cueRecordings = Map.fromEntries(
        item.cueRecordings.entries.where((entry) => ids.contains(entry.key)),
      );
      _editRevision++;
      if (_item?.id == item.id && mounted) {
        setState(() {
          _selectedId = cues.first.id;
          _expandedId = null;
        });
      }
      await _save();
      widget.onMessage(
        '已导入 ${cues.length} 行${cues.any((cue) => cue.inferredTiming) ? '，纯文本时间为推定值，点击铅笔可编辑' : ''}',
      );
    });
    if (mounted) setState(() => _importing = false);
  }

  Future<void> _exportSubtitles(String format) async {
    final item = _item;
    if (item == null) return;
    await _run(() async {
      final path = await FilePicker.platform.saveFile(
        dialogTitle: '导出字幕',
        fileName: '${item.name}.$format',
        type: FileType.custom,
        allowedExtensions: [format],
        bytes: utf8.encode(encodeSubtitles(item.cues, format: format)),
      );
      if (path != null) widget.onMessage('字幕已导出');
    });
  }

  Future<void> _importExport() async {
    final option = await _choose('导入 / 导出', const [
      '导入字幕',
      '导出 JSON',
      '导出 SRT',
    ]);
    if (option == '导入字幕') await _importSubtitles();
    if (option == '导出 JSON') await _exportSubtitles('json');
    if (option == '导出 SRT') await _exportSubtitles('srt');
  }

  Future<String?> _choose(String title, List<String> options) =>
      showModalBottomSheet<String>(
        context: context,
        showDragHandle: true,
        builder: (context) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  title,
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              for (final option in options)
                ListTile(
                  title: Text(option),
                  onTap: () => Navigator.pop(context, option),
                ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      );
  Future<void> showMore() async {
    final option = await _choose('更多', const [
      '听写',
      '复读设置',
      '导入 / 导出',
      '自定义速度',
    ]);
    if (!mounted) return;
    if (option == '听写') await showDictation();
    if (option == '复读设置') await _repeatSettings();
    if (option == '导入 / 导出') await _importExport();
    if (option == '自定义速度') await showCustomSpeeds();
  }

  Future<void> _repeatSettings() async {
    final item = _item;
    if (item == null) return;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('复读设置', style: TextStyle(fontSize: 18)),
                Row(
                  children: [
                    const Expanded(child: Text('重复次数')),
                    DropdownButton<int>(
                      value: item.repeatCount,
                      items: [
                        for (final n in [0, 1, 2, 3, 5])
                          DropdownMenuItem(
                            value: n,
                            child: Text(n == 0 ? '无限' : '$n 次'),
                          ),
                      ],
                      onChanged: (n) {
                        if (n != null) {
                          update(() => item.repeatCount = n);
                          unawaited(_run(_save));
                        }
                      },
                    ),
                  ],
                ),
                Row(
                  children: [
                    const Expanded(child: Text('重复间隔')),
                    DropdownButton<int>(
                      value: item.repeatGapMs,
                      items: [
                        for (final n in [0, 1000, 2000, 3000, 5000])
                          DropdownMenuItem(
                            value: n,
                            child: Text('${n ~/ 1000} 秒'),
                          ),
                      ],
                      onChanged: (n) {
                        if (n != null) {
                          update(() => item.repeatGapMs = n);
                          unawaited(_run(_save));
                        }
                      },
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
    final cue = _selected;
    if (mounted && _item?.id == item.id && cue != null && item.singleSentence) {
      _player.repeat.setRange(
        cue.start,
        cue.end,
        count: item.repeatCount,
        gap: Duration(milliseconds: item.repeatGapMs),
      );
      setState(() {});
    }
  }

  Future<void> showCustomSpeeds() async {
    final item = _item;
    if (item == null) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(30)),
      ),
      builder: (context) => StatefulBuilder(
        builder: (context, update) => SafeArea(
          child: SizedBox(
            height: MediaQuery.sizeOf(context).height * .9,
            child: Column(
              children: [
                SizedBox(
                  height: 62,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      const Text(
                        '自定义速度',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: IconButton(
                          tooltip: '关闭速度设置',
                          onPressed: () => Navigator.pop(context),
                          icon: const Icon(Icons.close),
                        ),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: ListView.builder(
                    itemCount: item.customSpeeds.length,
                    itemBuilder: (context, index) => Column(
                      children: [
                        ListTile(
                          title: Text(
                            item.customSpeeds[index].toStringAsFixed(2),
                          ),
                          trailing: DecoratedBox(
                            decoration: BoxDecoration(
                              color: const Color(0xFFEFF0F1),
                              borderRadius: BorderRadius.circular(22),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  tooltip: '速度 ${index + 1} 减少',
                                  onPressed: () =>
                                      _adjustSpeed(item, index, -.05, update),
                                  icon: const Icon(Icons.remove),
                                ),
                                const SizedBox(
                                  height: 22,
                                  child: VerticalDivider(width: 1),
                                ),
                                IconButton(
                                  tooltip: '速度 ${index + 1} 增加',
                                  onPressed: () =>
                                      _adjustSpeed(item, index, .05, update),
                                  icon: const Icon(Icons.add),
                                ),
                              ],
                            ),
                          ),
                        ),
                        const Divider(height: 1, indent: 16, endIndent: 16),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (mounted) setState(() {});
  }

  void _adjustSpeed(
    MediaItem item,
    int index,
    double delta,
    StateSetter update,
  ) {
    final next = double.parse(
      (item.customSpeeds[index] + delta).clamp(.1, 5).toStringAsFixed(2),
    );
    update(() {
      item.customSpeeds = [...item.customSpeeds]..[index] = next;
    });
    unawaited(_run(_save));
  }

  Future<void> _startRecording(Cue cue) async {
    final item = _item;
    if (item == null || _recordBusy) return;
    _cancelComparison();
    setState(() => _recordBusy = true);
    await _run(() async {
      await _player.pause();
      await _recordPlayer.stop();
      if (!await _recorder.hasPermission()) {
        widget.onMessage('请允许麦克风权限后再录音');
        return;
      }
      if (!mounted || _item?.id != item.id) return;
      final path =
          '${File(item.path).parent.path}/record_${DateTime.now().microsecondsSinceEpoch}.m4a';
      await _recorder.start(const RecordConfig(), path: path);
      _recordingItem = item;
      _recordingCueId = cue.id;
      _recording = true;
      if (!mounted || _item?.id != item.id) await _finishRecording();
    });
    if (mounted) setState(() => _recordBusy = false);
  }

  Future<void> _finishRecording() {
    if (_endingRecording != null) return _endingRecording!;
    if (!_recording) return Future.value();
    final item = _recordingItem;
    final cueId = _recordingCueId;
    _recording = false;
    _recordBusy = true;
    final operation = _run(() async {
      final path = await _recorder.stop();
      if (path == null || item == null || cueId == null) return;
      if (!await File(path).exists()) throw const FileSystemException('录音未生成');
      item.attachRecording(cueId, path);
      await _save();
    });
    _endingRecording = operation.whenComplete(() {
      _endingRecording = null;
      _recordingItem = null;
      _recordingCueId = null;
      _recordBusy = false;
      if (mounted) setState(() {});
    });
    return _endingRecording!;
  }

  Future<void> _toggleRecording(Cue cue) async {
    if (_recordBusy) return;
    if (_recording) {
      await _finishRecording();
    } else {
      await _startRecording(cue);
    }
  }

  Future<void> _playRecording(Cue cue) async {
    final paths = _recordings(cue);
    if (paths.isEmpty) return;
    if (_playingRecording == cue.id && _recordPlayer.playing) {
      _cancelComparison();
      await _run(() => _recordPlayer.stop());
      if (mounted) setState(() {});
      return;
    }
    _cancelComparison();
    final epoch = _auxEpoch;
    await _run(() async {
      await _player.pause();
      if (_recording) await _finishRecording();
      await _recordPlayer.setFilePath(paths.last);
      if (!mounted || epoch != _auxEpoch) return;
      setState(() => _playingRecording = cue.id);
      await _recordPlayer.play();
      if (mounted && epoch == _auxEpoch) {
        setState(() => _playingRecording = null);
      }
    });
  }

  Future<void> _compare(Cue cue) async {
    final item = _item;
    final paths = _recordings(cue);
    if (item == null || paths.isEmpty) return;
    if (_comparingCue?.id == cue.id) {
      _cancelComparison();
      await _run(() async {
        await _player.pause();
        await _recordPlayer.stop();
      });
      if (mounted) setState(() {});
      return;
    }
    _cancelComparison();
    final epoch = _auxEpoch;
    await _run(() async {
      if (!await File(paths.last).exists()) {
        throw const FileSystemException('该片段录音文件不存在');
      }
      final completed = Completer<void>();
      _compareEnd = completed;
      _comparingCue = cue;
      await _playCue(cue, once: true, cancelAuxiliary: false);
      await completed.future;
      if (!mounted || epoch != _auxEpoch || _item?.id != item.id) return;
      if (_player.error != null) throw StateError(_player.error!);
      await _player.pause();
      _comparingCue = null;
      await _recordPlayer.setFilePath(paths.last);
      if (epoch != _auxEpoch) return;
      setState(() => _playingRecording = cue.id);
      await _recordPlayer.play();
      if (mounted && epoch == _auxEpoch) {
        setState(() => _playingRecording = null);
      }
    });
  }

  Future<void> _editCue(Cue cue) async {
    final item = _item;
    if (item == null) return;
    final original = TextEditingController(text: cue.text),
        translation = TextEditingController(text: cue.translation);
    final start = TextEditingController(
          text: (cue.start.inMilliseconds / 1000).toString(),
        ),
        end = TextEditingController(
          text: (cue.end.inMilliseconds / 1000).toString(),
        );
    final form = GlobalKey<FormState>();
    final duration = _player.duration;
    final route = DialogRoute<Cue>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('编辑字幕'),
        scrollable: true,
        content: Form(
          key: form,
          child: SizedBox(
            width: 320,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  controller: original,
                  minLines: 2,
                  maxLines: 5,
                  decoration: const InputDecoration(labelText: '正文'),
                ),
                TextFormField(
                  controller: translation,
                  minLines: 1,
                  maxLines: 4,
                  decoration: const InputDecoration(labelText: '译文'),
                ),
                TextFormField(
                  controller: start,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: const InputDecoration(labelText: '开始秒'),
                  validator: (value) {
                    final a = double.tryParse(value ?? '');
                    return a == null || !a.isFinite || a < 0
                        ? '开始时间须为非负秒数'
                        : null;
                  },
                ),
                TextFormField(
                  controller: end,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: const InputDecoration(labelText: '结束秒'),
                  validator: (value) {
                    final a = double.tryParse(start.text),
                        b = double.tryParse(value ?? '');
                    if (a == null ||
                        !a.isFinite ||
                        b == null ||
                        !b.isFinite ||
                        (b * 1000).round() <= (a * 1000).round()) {
                      return '结束时间须晚于开始时间';
                    }
                    if (duration > Duration.zero &&
                        b * 1000 > duration.inMilliseconds) {
                      return '结束时间不能超过媒体长度';
                    }
                    return null;
                  },
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              if (form.currentState!.validate()) {
                Navigator.pop(
                  context,
                  cue.copyWith(
                    start: Duration(
                      milliseconds: (double.parse(start.text) * 1000).round(),
                    ),
                    end: Duration(
                      milliseconds: (double.parse(end.text) * 1000).round(),
                    ),
                    text: original.text.trim(),
                    translation: translation.text.trim(),
                    inferredTiming: false,
                  ),
                );
              }
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
    final edited = await Navigator.of(context, rootNavigator: true).push(route);
    await route.completed;
    original.dispose();
    translation.dispose();
    start.dispose();
    end.dispose();
    if (edited == null || !mounted) return;
    item.replaceCue(edited);
    _editRevision++;
    if (_item?.id == item.id) setState(() {});
    await _run(_save);
  }

  Future<void> showDictation() async {
    final item = _item;
    if (item == null || item.cues.isEmpty) {
      widget.onMessage('请先添加或导入字幕');
      return;
    }
    var index = item.cues.indexWhere((cue) => cue.id == _selectedId);
    if (index < 0) index = 0;
    final answer = TextEditingController();
    int? score;
    var showAnswer = false;
    final route = DialogRoute<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) {
          final cue = item.cues[index];
          void change(int next) {
            update(() {
              index = next;
              answer.clear();
              score = null;
              showAnswer = false;
            });
            unawaited(_run(() => _playCue(item.cues[index], once: true)));
          }

          return AlertDialog(
            title: const Text('听写'),
            scrollable: true,
            content: SizedBox(
              width: 340,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      IconButton(
                        tooltip: '上一句',
                        onPressed: index == 0 ? null : () => change(index - 1),
                        icon: const Icon(Icons.chevron_left),
                      ),
                      Expanded(
                        child: Text(
                          '第 ${index + 1} / ${item.cues.length} 句',
                          textAlign: TextAlign.center,
                        ),
                      ),
                      IconButton(
                        tooltip: '下一句',
                        onPressed: index == item.cues.length - 1
                            ? null
                            : () => change(index + 1),
                        icon: const Icon(Icons.chevron_right),
                      ),
                    ],
                  ),
                  TextButton.icon(
                    onPressed: () => _run(() => _playCue(cue, once: true)),
                    icon: const Icon(Icons.replay),
                    label: const Text('再听一次'),
                  ),
                  TextField(
                    controller: answer,
                    minLines: 3,
                    maxLines: 6,
                    decoration: const InputDecoration(
                      labelText: '写下听到的内容',
                      border: OutlineInputBorder(),
                    ),
                    onChanged: (_) => update(() => score = null),
                  ),
                  if (score != null)
                    Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text(
                        '文字匹配 $score 分',
                        style: const TextStyle(color: _orange),
                      ),
                    ),
                  if (showAnswer)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: SelectableText(cue.text),
                    ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => update(() {
                  score = dictationScore(cue.text, answer.text);
                  showAnswer = true;
                }),
                child: const Text('对照答案'),
              ),
              TextButton(
                onPressed: () => update(() => showAnswer = !showAnswer),
                child: Text(showAnswer ? '隐藏原文' : '显示原文'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('完成'),
              ),
            ],
          );
        },
      ),
    );
    await _run(() => _playCue(item.cues[index], once: true));
    if (!mounted) {
      answer.dispose();
      return;
    }
    await Navigator.of(context, rootNavigator: true).push(route);
    await route.completed;
    answer.dispose();
  }

  @override
  void dispose() {
    _player.removeListener(_onPlayer);
    _cancelComparison();
    _scroll.dispose();
    unawaited(
      _run(() async {
        await _finishRecording();
        await _recorder.dispose();
        await _recordPlayer.dispose();
      }),
    );
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final item = _item;
    if (item == null) return const Center(child: Text('选择一个音频或视频开始听读'));
    return LayoutBuilder(
      builder: (context, constraints) {
        final content = ColoredBox(
          color: Colors.white,
          child: Column(
            children: [
              if (_player.loading)
                const LinearProgressIndicator(color: _orange),
              if (_player.error != null)
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: Row(
                    children: [
                      Expanded(child: Text(_player.error!, maxLines: 2)),
                      TextButton(
                        onPressed: () => _run(() => _player.open(item)),
                        child: const Text('重试'),
                      ),
                    ],
                  ),
                ),
              _progress(),
              _toolbar(),
              if ((_player.video?.value.isInitialized ?? false) &&
                  constraints.maxHeight > 600)
                SizedBox(
                  height: 140,
                  child: AspectRatio(
                    aspectRatio: _player.video!.value.aspectRatio,
                    child: VideoPlayer(_player.video!),
                  ),
                ),
              Expanded(
                child: item.cues.isEmpty ? _emptyRows() : _cueList(item),
              ),
              StudyWaveform(
                player: _player,
                waveformService: widget.waveformService,
                a: _selected?.start,
                b: _selected?.end,
                height: 66,
                onSeek: (position) {
                  _cancelComparison();
                  unawaited(_run(() => _player.seek(position)));
                },
                onRangeChanged: (a, b) {
                  final cue = _selected;
                  if (cue != null) unawaited(_updateRange(item, cue, a, b));
                },
              ),
              _transport(item),
            ],
          ),
        );
        return constraints.maxHeight < 380
            ? SingleChildScrollView(
                child: SizedBox(height: 380, child: content),
              )
            : content;
      },
    );
  }

  Widget _progress() {
    final total = _player.duration.inMilliseconds.toDouble();
    final value = (_scrubbing ?? _player.position.inMilliseconds.toDouble())
        .clamp(0.0, total);
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 10, 6, 4),
      child: Column(
        children: [
          SizedBox(
            height: 32,
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 4,
                activeTrackColor: _orange,
                inactiveTrackColor: _grey,
                thumbColor: Colors.white,
                thumbShape: const RoundSliderThumbShape(
                  enabledThumbRadius: 11,
                  elevation: 3,
                ),
              ),
              child: Slider(
                value: value,
                max: total > 0 ? total : 1,
                onChanged: total <= 0 || _recording
                    ? null
                    : (value) => setState(() => _scrubbing = value),
                onChangeEnd: (value) => _run(() async {
                  _cancelComparison();
                  await _player.seek(Duration(milliseconds: value.round()));
                  if (mounted) setState(() => _scrubbing = null);
                }),
              ),
            ),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                formatTime(Duration(milliseconds: value.round())),
                style: const TextStyle(fontSize: 13),
              ),
              Text(
                formatTime(_player.duration),
                style: const TextStyle(fontSize: 13),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _toolbar() => Padding(
    padding: const EdgeInsets.fromLTRB(30, 6, 30, 8),
    child: Column(
      children: [
        Row(
          children: [
            _tool(
              '设置 A',
              _selected == null ? null : () => _changeBoundary(true),
              active: _selected != null,
            ),
            _tool(
              '设置 B',
              _selected == null ? null : () => _changeBoundary(false),
              active: _selected != null,
            ),
            _tool('添加行', _recording ? null : _addRow),
            _tool('删除行', _selected == null || _recording ? null : _deleteRow),
          ],
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            _tool('分句/识别', _recognizing ? null : () => _recognize(null)),
            _tool('导入/导出', _importing ? null : _importExport),
            _tool(
              '精听',
              _selected == null
                  ? null
                  : () => setState(() => _intensive = !_intensive),
              active: _intensive,
            ),
            _tool(
              '单句重复',
              _toggleSingle,
              active: _item?.singleSentence ?? false,
            ),
          ],
        ),
      ],
    ),
  );
  Widget _tool(String label, VoidCallback? action, {bool active = false}) =>
      Expanded(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2),
          child: SizedBox(
            height: 29,
            child: OutlinedButton(
              onPressed: action,
              style: OutlinedButton.styleFrom(
                foregroundColor: active ? Colors.white : _orange,
                backgroundColor: active ? _orange : Colors.white,
                side: BorderSide(
                  color: action == null
                      ? const Color(0xFFE8E8E8)
                      : const Color(0xFFE5CDAF),
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(5),
                ),
                padding: EdgeInsets.zero,
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                textStyle: Theme.of(
                  context,
                ).textTheme.labelSmall?.copyWith(fontSize: 11),
              ),
              child: FittedBox(child: Text(label)),
            ),
          ),
        ),
      );
  Widget _emptyRows() => ColoredBox(
    color: const Color(0xFFEDEEF4),
    child: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          FilledButton(
            onPressed: _recognizing ? null : () => _recognize(null),
            style: FilledButton.styleFrom(
              backgroundColor: _orange,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(5),
              ),
            ),
            child: Text(_recognizing ? '正在识别…' : '自动分句、语音识别'),
          ),
          const SizedBox(height: 6),
          FilledButton(
            onPressed: _addRow,
            style: FilledButton.styleFrom(
              backgroundColor: _orange,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(5),
              ),
            ),
            child: const Text('手动分句'),
          ),
        ],
      ),
    ),
  );
  Widget _cueList(MediaItem item) {
    final cues = _intensive && _selected != null ? [_selected!] : item.cues;
    return ListView(
      controller: _scroll,
      children: [for (final cue in cues) _cueRow(item, cue)],
    );
  }

  Widget _cueRow(MediaItem item, Cue cue) {
    final expanded = _expandedId == cue.id;
    final index = item.cues.indexWhere((entry) => entry.id == cue.id);
    final paths = _recordings(cue);
    final key = _rowKeys.putIfAbsent(cue.id, GlobalKey.new);
    return Material(
      key: key,
      color: expanded ? const Color(0xFFFBF7F2) : Colors.white,
      child: InkWell(
        overlayColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.pressed)
              ? _orange.withValues(alpha: .05)
              : Colors.transparent,
        ),
        onTap: () => _run(() => _playCue(cue)),
        onLongPress: () => _run(() => _editCue(cue)),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 4, 10, 0),
          child: Column(
            children: [
              Row(
                children: [
                  SizedBox(
                    width: 28,
                    child: expanded
                        ? Icon(
                            Icons.keyboard_arrow_up,
                            size: 23,
                            color: _orange,
                          )
                        : null,
                  ),
                  Expanded(
                    child: Text(
                      '${formatABTime(cue.start)} ~ ${formatABTime(cue.end)}',
                      maxLines: 1,
                      style: TextStyle(
                        fontSize: 12,
                        color: expanded ? const Color(0xFFC4935E) : _grey,
                      ),
                    ),
                  ),
                  if (expanded) ...[
                    _icon(
                      _hiddenText.contains(cue.id)
                          ? Icons.visibility_off_outlined
                          : Icons.visibility_outlined,
                      '显示或隐藏原文',
                      () => setState(() {
                        if (!_hiddenText.add(cue.id)) {
                          _hiddenText.remove(cue.id);
                        }
                      }),
                    ),
                    _icon(
                      Icons.language,
                      '显示或隐藏译文',
                      () =>
                          setState(() => _showTranslation = !_showTranslation),
                    ),
                  ],
                  _icon(
                    item.favorites.contains(cue.id)
                        ? Icons.star
                        : Icons.star_border,
                    item.favorites.contains(cue.id) ? '取消收藏' : '收藏语句',
                    () => _toggleFavorite(cue),
                    color: item.favorites.contains(cue.id) ? _orange : null,
                  ),
                  _icon(
                    Icons.edit_outlined,
                    '编辑字幕',
                    () => _run(() => _editCue(cue)),
                  ),
                ],
              ),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 28,
                    child: Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: Text(
                        '${index + 1}',
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Color(0xFFB4B7B2),
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(0, 6, 0, 20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (_showText && !_hiddenText.contains(cue.id))
                            Text(
                              cue.text.isEmpty ? ' ' : cue.text,
                              style: const TextStyle(
                                fontSize: 16,
                                height: 1.22,
                                color: Color(0xFF252A25),
                              ),
                            ),
                          if (_showTranslation && cue.translation.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(top: 7),
                              child: Text(
                                cue.translation,
                                style: const TextStyle(
                                  color: _grey,
                                  fontSize: 14,
                                ),
                              ),
                            ),
                          if (cue.inferredTiming)
                            const Text(
                              '推定时间',
                              style: TextStyle(fontSize: 10, color: _grey),
                            ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
              if (expanded)
                Padding(
                  padding: const EdgeInsets.only(left: 28, bottom: 6),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      _rowButton(
                        Icon(
                          _playingRecording == cue.id
                              ? Icons.stop
                              : Icons.volume_up_outlined,
                          size: 23,
                        ),
                        '回听录音',
                        paths.isEmpty || _recording
                            ? null
                            : () => _playRecording(cue),
                      ),
                      _rowButton(
                        Icon(
                          _recording && _recordingCueId == cue.id
                              ? Icons.stop
                              : Icons.mic_none,
                          size: 24,
                        ),
                        _recording ? '结束录音' : '跟读录音',
                        _recordBusy ? null : () => _toggleRecording(cue),
                        selected: _recording && _recordingCueId == cue.id,
                      ),
                      _rowButton(
                        const Text('VS', style: TextStyle(fontSize: 12)),
                        '原音与录音对比',
                        paths.isEmpty || _recording
                            ? null
                            : () => _compare(cue),
                        selected: _comparingCue?.id == cue.id,
                      ),
                      _rowButton(
                        const Text('原声', style: TextStyle(fontSize: 11)),
                        '播放片段原音',
                        () => _run(() => _playCue(cue, once: true)),
                        orange: true,
                      ),
                      _rowButton(
                        Text(
                          _recognizing ? '…' : '识别',
                          style: const TextStyle(fontSize: 11),
                        ),
                        '识别这一行',
                        _recognizing || _recording
                            ? null
                            : () => _recognize(cue),
                        orange: true,
                      ),
                    ],
                  ),
                ),
              const Divider(height: 1, indent: 28, color: Color(0xFFE9E8E5)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _icon(
    IconData icon,
    String tooltip,
    VoidCallback action, {
    Color? color,
  }) => SizedBox(
    width: 29,
    height: 29,
    child: IconButton(
      tooltip: tooltip,
      onPressed: action,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints.tightFor(width: 29, height: 29),
      icon: Icon(icon, size: 20, color: color ?? const Color(0xFFB5B9B5)),
    ),
  );
  Widget _rowButton(
    Widget child,
    String tooltip,
    VoidCallback? action, {
    bool orange = false,
    bool selected = false,
  }) => Tooltip(
    message: tooltip,
    child: SizedBox(
      width: 38,
      height: 38,
      child: TextButton(
        onPressed: action,
        style: TextButton.styleFrom(
          padding: EdgeInsets.zero,
          foregroundColor: orange || selected ? _orange : _grey,
          disabledForegroundColor: const Color(0xFFD4D3CD),
          backgroundColor: orange || selected
              ? const Color(0xFFFBE5D0)
              : const Color(0xFFF1EEEA),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
          minimumSize: Size.zero,
        ),
        child: child,
      ),
    ),
  );
  Widget _transport(MediaItem item) => SafeArea(
    top: false,
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Divider(height: 1, color: Color(0xFFE4E6E2)),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 8),
          child: Row(
            children: [
              SizedBox(
                width: 33,
                child: TextButton(
                  onPressed: () => setState(() => _showText = !_showText),
                  style: TextButton.styleFrom(
                    padding: EdgeInsets.zero,
                    foregroundColor: _grey,
                  ),
                  child: const Text(
                    '字幕\n模式',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 10, height: 1.1),
                  ),
                ),
              ),
              Expanded(
                child: TextButton(
                  onPressed: () => _run(
                    () => _player.seek(
                      _player.position - const Duration(seconds: 5),
                    ),
                  ),
                  child: const Text(
                    '--',
                    style: TextStyle(color: _grey, fontSize: 18),
                  ),
                ),
              ),
              Expanded(
                child: IconButton(
                  tooltip: '快退 5 秒',
                  onPressed: () {
                    _cancelComparison();
                    unawaited(
                      _run(
                        () => _player.seek(
                          _player.position - const Duration(seconds: 5),
                        ),
                      ),
                    );
                  },
                  icon: const Icon(Icons.replay, color: _grey, size: 30),
                ),
              ),
              Expanded(
                child: IconButton(
                  tooltip: _player.playing ? '暂停' : '播放',
                  onPressed: _recording || _player.loading
                      ? null
                      : () => _run(() async {
                          _cancelComparison();
                          await _recordPlayer.stop();
                          await _player.toggle();
                        }),
                  icon: Icon(
                    _player.playing ? Icons.pause : Icons.play_arrow,
                    color: _grey,
                    size: 43,
                  ),
                ),
              ),
              Expanded(
                child: IconButton(
                  tooltip: '快进 5 秒',
                  onPressed: () {
                    _cancelComparison();
                    unawaited(
                      _run(
                        () => _player.seek(
                          _player.position + const Duration(seconds: 5),
                        ),
                      ),
                    );
                  },
                  icon: const Icon(Icons.rotate_right, color: _grey, size: 30),
                ),
              ),
              Expanded(
                child: TextButton(
                  onPressed: () => _run(
                    () => _player.seek(
                      _player.position + const Duration(seconds: 5),
                    ),
                  ),
                  child: const Text(
                    '++',
                    style: TextStyle(color: _grey, fontSize: 18),
                  ),
                ),
              ),
              SizedBox(
                width: 38,
                child: PopupMenuButton<String>(
                  tooltip: '播放速度',
                  padding: EdgeInsets.zero,
                  onSelected: (value) {
                    if (value == 'settings') {
                      unawaited(showCustomSpeeds());
                    } else {
                      unawaited(
                        _run(() => _player.setSpeed(double.parse(value))),
                      );
                    }
                  },
                  itemBuilder: (context) => [
                    const PopupMenuItem(value: 'settings', child: Text('设置')),
                    const PopupMenuItem(enabled: false, child: Text('复读速度')),
                    for (final speed in item.customSpeeds)
                      PopupMenuItem(
                        value: '$speed',
                        child: Text(
                          speed.toStringAsFixed(
                            speed == speed.roundToDouble() ? 0 : 2,
                          ),
                        ),
                      ),
                  ],
                  child: Container(
                    width: 29,
                    height: 29,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(color: _grey),
                    ),
                    child: Text(
                      _player.speed.toStringAsFixed(1),
                      style: const TextStyle(fontSize: 11, color: _grey),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (var i = 0; i < 3; i++)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Container(
                    width: 5,
                    height: 5,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: i == 0 ? _orange : _grey,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    ),
  );
}
