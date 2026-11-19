import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:just_audio/just_audio.dart';
import 'package:record/record.dart';
import 'package:video_player/video_player.dart';

import 'library.dart';
import 'models.dart';
import 'services/player.dart';

class PlayerView extends StatefulWidget {
  const PlayerView({
    super.key,
    required this.player,
    required this.onSave,
    required this.onMessage,
  });

  final StudyPlayer player;
  final Future<void> Function() onSave;
  final void Function(String) onMessage;

  @override
  State<PlayerView> createState() => _PlayerViewState();
}

class _PlayerViewState extends State<PlayerView> {
  static const _orange = Color(0xFFDC601D);
  final _scroll = ScrollController();
  final _answer = TextEditingController();
  final _recorder = AudioRecorder();
  final _recordingPlayer = AudioPlayer();
  MediaItem? _knownItem;
  MediaItem? _recordingItem;
  Duration? _a;
  Duration? _b;
  int _tab = 0;
  int _repeatCount = 1;
  int _gap = 0;
  int _activeIndex = -1;
  int? _practiceIndex;
  int? _score;
  bool _singleSentence = false;
  bool _showAnswer = false;
  bool _recording = false;
  bool _recordBusy = false;
  bool _importing = false;
  bool _showTranslation = true;
  double? _scrubPosition;
  String? _playingRecording;
  int _recordPlaybackGeneration = 0;

  StudyPlayer get _player => widget.player;

  @override
  void initState() {
    super.initState();
    _knownItem = _player.item;
    _player.addListener(_onPlayer);
  }

  @override
  void didUpdateWidget(covariant PlayerView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.player != widget.player) {
      oldWidget.player.removeListener(_onPlayer);
      _player.addListener(_onPlayer);
      _resetItem();
    }
  }

  int _findCue() {
    final cues = _player.item?.cues ?? <Cue>[];
    final position = _player.position;
    for (var i = cues.length - 1; i >= 0; i--) {
      if (position >= cues[i].start && position < cues[i].end) return i;
    }
    return -1;
  }

  void _resetItem() {
    _knownItem = _player.item;
    _a = null;
    _b = null;
    _activeIndex = -1;
    _practiceIndex = null;
    _score = null;
    _showAnswer = false;
    _scrubPosition = null;
    _answer.clear();
    _playingRecording = null;
    _recordPlaybackGeneration++;
    unawaited(_run(() => _recordingPlayer.stop()));
    if (_recording) unawaited(_finishRecording());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _scroll.hasClients) _scroll.jumpTo(0);
    });
  }

  void _onPlayer() {
    if (!mounted) return;
    if (_knownItem?.id != _player.item?.id) _resetItem();
    final next = _findCue();
    if (next != _activeIndex) {
      _activeIndex = next;
      if (next >= 0 && _tab == 0 && _player.playing) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || !_scroll.hasClients) return;
          final target = (next * 116.0 - 40).clamp(
            0.0,
            _scroll.position.maxScrollExtent,
          );
          unawaited(
            _scroll.animateTo(
              target,
              duration: const Duration(milliseconds: 250),
              curve: Curves.easeOut,
            ),
          );
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

  Future<void> _importSubtitles() async {
    final item = _player.item;
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
      if (bytes == null) throw const FormatException('无法读取所选字幕文件');
      final cues = parseSubtitles(utf8.decode(bytes), format: selected.name);
      if (cues.isEmpty) throw const FormatException('没有找到有效字幕');
      item.cues = cues;
      item.favorites = {};
      await widget.onSave();
      if (!mounted) return;
      setState(() {
        _activeIndex = -1;
        _practiceIndex = null;
        _score = null;
        _showAnswer = false;
        _answer.clear();
      });
      widget.onMessage(
        '已导入 ${cues.length} 句字幕${cues.any((cue) => cue.inferredTiming) ? '，纯文本时间为每句 5 秒推定，长按字幕可编辑时间' : ''}',
      );
    });
    if (mounted) setState(() => _importing = false);
  }

  Future<void> _selectCue(Cue cue, {bool oneShot = false}) async {
    await _run(() async {
      if (_recording) await _finishRecording();
      await _recordingPlayer.stop();
      if (_player.duration > Duration.zero && cue.start >= _player.duration) {
        widget.onMessage('这句字幕的时间超出了媒体长度，请检查字幕是否匹配');
        return;
      }
      if (_singleSentence || oneShot) {
        _a = cue.start;
        _b = _player.duration > Duration.zero && cue.end > _player.duration
            ? _player.duration
            : cue.end;
        if (oneShot) {
          _repeatCount = 1;
          _gap = 0;
        }
        _configureRepeat();
      }
      await _player.seek(cue.start);
      await _player.play();
    });
  }

  void _configureRepeat() {
    final a = _a;
    final b = _b;
    if (a == null || b == null) return;
    if (b <= a) {
      widget.onMessage('B 点必须晚于 A 点');
      return;
    }
    _player.repeat.setRange(
      a,
      b,
      count: _repeatCount,
      gap: Duration(seconds: _gap),
    );
  }

  void _markA() {
    setState(() {
      _a = _player.position;
      _b = null;
      _player.repeat.clear();
    });
  }

  void _markB() {
    if (_a == null) {
      widget.onMessage('请先设置 A 点');
      return;
    }
    if (_player.position <= _a!) {
      widget.onMessage('播放到 A 点之后，再设置 B 点');
      return;
    }
    setState(() {
      _b = _player.position;
      _configureRepeat();
    });
  }

  Future<void> _toggleFavorite(Cue cue) async {
    final item = _player.item;
    if (item == null) return;
    setState(() {
      final favorites = {...item.favorites};
      if (!favorites.add(cue.id)) favorites.remove(cue.id);
      item.favorites = favorites;
    });
    await _run(widget.onSave);
  }

  void _selectTab(int next) {
    setState(() {
      _tab = next;
      if (next == 1 &&
          _practiceIndex == null &&
          (_player.item?.cues.isNotEmpty ?? false)) {
        _practiceIndex = _activeIndex >= 0 ? _activeIndex : 0;
      }
    });
    if (next == 1 && _practiceIndex != null) {
      unawaited(_selectCue(_player.item!.cues[_practiceIndex!], oneShot: true));
    }
  }

  void _changePractice(int index) {
    setState(() {
      _practiceIndex = index;
      _answer.clear();
      _score = null;
      _showAnswer = false;
    });
    final cues = _player.item?.cues;
    if (cues != null && index >= 0 && index < cues.length) {
      unawaited(_selectCue(cues[index], oneShot: true));
    }
  }

  Future<void> _editCue(Cue cue) async {
    final item = _player.item;
    if (item == null) return;
    final original = TextEditingController(text: cue.text);
    final translation = TextEditingController(text: cue.translation);
    final start = TextEditingController(
      text: (cue.start.inMilliseconds / 1000).toString(),
    );
    final end = TextEditingController(
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
                  validator: (value) =>
                      value == null || value.trim().isEmpty ? '请输入字幕正文' : null,
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
                    final seconds = double.tryParse(value ?? '');
                    return seconds == null || !seconds.isFinite || seconds < 0
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
                    final a = double.tryParse(start.text);
                    final b = double.tryParse(value ?? '');
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
              if (!form.currentState!.validate()) return;
              Navigator.pop(
                context,
                Cue(
                  id: cue.id,
                  start: Duration(
                    milliseconds: (double.parse(start.text) * 1000).round(),
                  ),
                  end: Duration(
                    milliseconds: (double.parse(end.text) * 1000).round(),
                  ),
                  text: original.text.trim(),
                  translation: translation.text.trim(),
                ),
              );
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
    final practiceId =
        _practiceIndex != null && _practiceIndex! < item.cues.length
        ? item.cues[_practiceIndex!].id
        : null;
    item.cues =
        item.cues.map((entry) => entry.id == cue.id ? edited : entry).toList()
          ..sort((a, b) => a.start.compareTo(b.start));
    if (item.id == _player.item?.id) {
      setState(() {
        _activeIndex = _findCue();
        if (practiceId != null) {
          _practiceIndex = item.cues.indexWhere(
            (entry) => entry.id == practiceId,
          );
        }
        if (_a == cue.start && _b == cue.end) {
          _a = edited.start;
          _b = edited.end;
          _configureRepeat();
        }
      });
    }
    await _run(widget.onSave);
  }

  Future<void> _startRecording() async {
    final item = _player.item;
    if (item == null || _recordBusy || _recording) return;
    setState(() => _recordBusy = true);
    await _run(() async {
      await _player.pause();
      await _recordingPlayer.stop();
      if (!await _recorder.hasPermission()) {
        widget.onMessage('请在系统设置中允许麦克风权限后再跟读');
        return;
      }
      if (!mounted || _player.item?.id != item.id) return;
      final path =
          '${File(item.path).parent.path}/record_${DateTime.now().microsecondsSinceEpoch}.m4a';
      await _recorder.start(const RecordConfig(), path: path);
      _recordingItem = item;
      _recording = true;
      if (!mounted || _player.item?.id != item.id) await _finishRecording();
    });
    if (mounted) setState(() => _recordBusy = false);
  }

  Future<void> _finishRecording() async {
    if (!_recording) return;
    _recordBusy = true;
    final item = _recordingItem;
    _recording = false;
    _recordingItem = null;
    await _run(() async {
      final path = await _recorder.stop();
      if (path == null || item == null) return;
      if (!await File(path).exists()) {
        throw const FileSystemException('录音文件没有生成');
      }
      item.recordings = [...item.recordings, path];
      await widget.onSave();
    });
    if (mounted) setState(() => _recordBusy = false);
  }

  Future<void> _toggleRecording() async {
    if (_recordBusy) return;
    if (_recording) {
      setState(() => _recordBusy = true);
      await _finishRecording();
      if (mounted) setState(() => _recordBusy = false);
    } else {
      await _startRecording();
    }
  }

  Future<void> _playRecording(String path) async {
    final generation = ++_recordPlaybackGeneration;
    await _run(() async {
      await _player.pause();
      if (_recording) await _finishRecording();
      if (_playingRecording == path && _recordingPlayer.playing) {
        await _recordingPlayer.pause();
        if (mounted) setState(() => _playingRecording = null);
        return;
      }
      await _recordingPlayer.setFilePath(path);
      if (generation != _recordPlaybackGeneration) return;
      if (mounted) setState(() => _playingRecording = path);
      await _recordingPlayer.play();
      if (mounted && generation == _recordPlaybackGeneration) {
        setState(() => _playingRecording = null);
      }
    });
  }

  @override
  void dispose() {
    _player.removeListener(_onPlayer);
    _scroll.dispose();
    _answer.dispose();
    unawaited(
      _run(() async {
        await _finishRecording();
        await _recorder.dispose();
        await _recordingPlayer.dispose();
      }),
    );
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final item = _player.item;
    if (item == null) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.headphones_rounded, size: 64, color: _orange),
            SizedBox(height: 20),
            Text('选择一个音频或视频开始听读', style: TextStyle(fontSize: 18)),
            SizedBox(height: 8),
            Text('在文件页导入文件，也可以先打开示例'),
          ],
        ),
      );
    }
    final cues = item.cues;
    final cue = _activeIndex >= 0 && _activeIndex < cues.length
        ? cues[_activeIndex]
        : null;
    return LayoutBuilder(
      builder: (context, constraints) {
        final content = Column(
          children: [
            if (_player.loading) const LinearProgressIndicator(color: _orange),
            if (_player.error != null)
              MaterialBanner(
                content: Text(_player.error!, maxLines: 2),
                actions: [
                  TextButton(
                    onPressed: () => _run(() => _player.open(item)),
                    child: const Text('重试'),
                  ),
                ],
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 12, 0),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      item.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                  IconButton(
                    tooltip: '导入字幕',
                    onPressed: _importing ? null : _importSubtitles,
                    icon: _importing
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.subtitles_outlined),
                  ),
                  IconButton(
                    tooltip: _showTranslation ? '隐藏翻译' : '显示翻译',
                    onPressed: () =>
                        setState(() => _showTranslation = !_showTranslation),
                    icon: Icon(
                      Icons.translate,
                      color: _showTranslation ? _orange : null,
                    ),
                  ),
                ],
              ),
            ),
            if (constraints.maxHeight >= 520 &&
                (_player.video?.value.isInitialized ?? false))
              SizedBox(
                height: 135,
                child: AspectRatio(
                  aspectRatio: _player.video!.value.aspectRatio,
                  child: VideoPlayer(_player.video!),
                ),
              ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              child: SizedBox(
                width: double.infinity,
                child: SegmentedButton<int>(
                  segments: const [
                    ButtonSegment(value: 0, label: Text('听读')),
                    ButtonSegment(value: 1, label: Text('听写')),
                    ButtonSegment(value: 2, label: Text('跟读')),
                  ],
                  selected: {_tab},
                  onSelectionChanged: (values) => _selectTab(values.single),
                ),
              ),
            ),
            Expanded(
              child: switch (_tab) {
                1 => _dictation(
                  _practiceIndex != null &&
                          _practiceIndex! >= 0 &&
                          _practiceIndex! < cues.length
                      ? cues[_practiceIndex!]
                      : null,
                ),
                2 => _shadowing(cue, item),
                _ => _subtitleList(item),
              },
            ),
            _controls(),
          ],
        );
        return constraints.maxHeight < 420
            ? SingleChildScrollView(
                child: SizedBox(height: 420, child: content),
              )
            : content;
      },
    );
  }

  Widget _subtitleList(MediaItem item) {
    if (item.cues.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.subtitles_outlined, size: 44, color: Colors.grey),
            const SizedBox(height: 12),
            const Text('导入字幕，逐句听读'),
            const SizedBox(height: 8),
            TextButton(
              onPressed: _importSubtitles,
              child: const Text('选择 LRC / SRT / TXT 字幕'),
            ),
          ],
        ),
      );
    }
    return ListView.builder(
      controller: _scroll,
      itemCount: item.cues.length,
      itemExtent: 116,
      itemBuilder: (context, index) {
        final cue = item.cues[index];
        final active = index == _activeIndex;
        return Material(
          color: active ? const Color(0xFFFFF0E5) : Colors.transparent,
          child: InkWell(
            onTap: () => _selectCue(cue),
            onLongPress: () => _run(() => _editCue(cue)),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(18, 8, 6, 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 48,
                    child: Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        formatTime(cue.start),
                        style: TextStyle(
                          fontSize: 12,
                          color: active ? _orange : Colors.grey.shade600,
                        ),
                      ),
                    ),
                  ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          cue.text,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 16,
                            height: 1.4,
                            color: active ? _orange : null,
                            fontWeight: active
                                ? FontWeight.w600
                                : FontWeight.normal,
                          ),
                        ),
                        if (_showTranslation && cue.translation.isNotEmpty)
                          Text(
                            cue.translation,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 13,
                              height: 1.4,
                              color: Colors.grey.shade600,
                            ),
                          ),
                        if (cue.inferredTiming)
                          const Text(
                            '推定时间',
                            style: TextStyle(fontSize: 11, color: Colors.grey),
                          ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: item.favorites.contains(cue.id) ? '取消收藏' : '收藏语句',
                    onPressed: () => _toggleFavorite(cue),
                    icon: Icon(
                      item.favorites.contains(cue.id)
                          ? Icons.star_rounded
                          : Icons.star_border_rounded,
                      size: 22,
                      color: item.favorites.contains(cue.id)
                          ? _orange
                          : Colors.grey,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _dictation(Cue? cue) {
    if (cue == null) return const Center(child: Text('播放或点击一句字幕，开始听写'));
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Row(
          children: [
            IconButton(
              tooltip: '上一句',
              onPressed: (_practiceIndex ?? 0) > 0
                  ? () => _changePractice(_practiceIndex! - 1)
                  : null,
              icon: const Icon(Icons.chevron_left),
            ),
            Expanded(
              child: Text(
                '第 ${(_practiceIndex ?? 0) + 1} / ${_player.item!.cues.length} 句',
                textAlign: TextAlign.center,
              ),
            ),
            IconButton(
              tooltip: '下一句',
              onPressed: (_practiceIndex ?? 0) < _player.item!.cues.length - 1
                  ? () => _changePractice(_practiceIndex! + 1)
                  : null,
              icon: const Icon(Icons.chevron_right),
            ),
          ],
        ),
        Row(
          children: [
            Text(
              '${formatTime(cue.start)} — ${formatTime(cue.end)}',
              style: const TextStyle(color: _orange),
            ),
            const Spacer(),
            TextButton.icon(
              onPressed: () => _selectCue(cue, oneShot: true),
              icon: const Icon(Icons.replay, size: 18),
              label: const Text('再听一次'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _answer,
          minLines: 3,
          maxLines: 6,
          decoration: const InputDecoration(
            labelText: '写下听到的内容',
            alignLabelWithHint: true,
            border: OutlineInputBorder(),
          ),
          onChanged: (_) {
            if (_score != null) setState(() => _score = null);
          },
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            FilledButton(
              onPressed: () => setState(() {
                _score = dictationScore(cue.text, _answer.text);
                _showAnswer = true;
              }),
              child: const Text('对照答案'),
            ),
            const SizedBox(width: 12),
            TextButton(
              onPressed: () => setState(() => _showAnswer = !_showAnswer),
              child: Text(_showAnswer ? '隐藏原文' : '显示原文'),
            ),
          ],
        ),
        if (_score != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Text(
              '文字匹配 $_score 分',
              style: const TextStyle(
                color: _orange,
                fontSize: 22,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        if (_showAnswer) ...[
          const SizedBox(height: 12),
          SelectableText(
            cue.text,
            style: const TextStyle(fontSize: 18, height: 1.6),
          ),
          if (_showTranslation && cue.translation.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(cue.translation),
            ),
        ],
      ],
    );
  }

  Widget _shadowing(Cue? cue, MediaItem item) => ListView(
    padding: const EdgeInsets.all(20),
    children: [
      if (cue != null) ...[
        Text(cue.text, style: const TextStyle(fontSize: 18, height: 1.6)),
        if (_showTranslation && cue.translation.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(cue.translation),
          ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: _recording ? null : () => _selectCue(cue),
            icon: const Icon(Icons.headphones),
            label: const Text('听原音'),
          ),
        ),
      ] else
        const Text('听完原音，录下自己的跟读'),
      const SizedBox(height: 16),
      Center(
        child: FilledButton.icon(
          onPressed: _recordBusy ? null : _toggleRecording,
          icon: Icon(_recording ? Icons.stop_rounded : Icons.mic_rounded),
          label: Text(
            _recordBusy
                ? '处理中…'
                : _recording
                ? '结束并保存录音'
                : '开始录音',
          ),
          style: FilledButton.styleFrom(
            backgroundColor: _recording ? Colors.red.shade700 : _orange,
            minimumSize: const Size(190, 52),
          ),
        ),
      ),
      if (_recording)
        const Padding(
          padding: EdgeInsets.only(top: 12),
          child: Center(
            child: Text('正在录音…', style: TextStyle(color: Colors.red)),
          ),
        ),
      const SizedBox(height: 24),
      Text(
        '我的录音（${item.recordings.length}）',
        style: const TextStyle(fontWeight: FontWeight.bold),
      ),
      if (item.recordings.isEmpty)
        const Padding(
          padding: EdgeInsets.only(top: 12),
          child: Text('录音保存后可在这里回听。'),
        ),
      for (final (index, path) in item.recordings.indexed.toList().reversed)
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: IconButton(
            tooltip: _playingRecording == path ? '暂停回听' : '回听录音',
            onPressed: _recording ? null : () => _playRecording(path),
            icon: Icon(
              _playingRecording == path
                  ? Icons.pause_circle_filled
                  : Icons.play_circle_outline,
              color: _orange,
            ),
          ),
          title: Text('跟读录音 ${index + 1}'),
          trailing: IconButton(
            tooltip: '删除录音',
            onPressed: _recording ? null : () => _deleteRecording(item, path),
            icon: const Icon(Icons.delete_outline, size: 21),
          ),
        ),
    ],
  );

  Future<void> _deleteRecording(MediaItem item, String path) async {
    await _run(() async {
      if (_playingRecording == path) {
        await _recordingPlayer.stop();
        _playingRecording = null;
      }
      item.recordings = item.recordings
          .where((entry) => entry != path)
          .toList();
      await widget.onSave();
      final file = File(path);
      if (await file.exists()) await file.delete();
      if (mounted) setState(() {});
    });
  }

  Widget _controls() {
    final duration = _player.duration.inMilliseconds.toDouble();
    final position =
        (_scrubPosition ?? _player.position.inMilliseconds.toDouble()).clamp(
          0.0,
          duration,
        );
    final hasRange = _a != null && _b != null;
    return Material(
      color: Theme.of(context).colorScheme.surface,
      elevation: 4,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Text(
                    formatTime(Duration(milliseconds: position.round())),
                    style: const TextStyle(fontSize: 12),
                  ),
                  Expanded(
                    child: Slider(
                      min: 0,
                      max: duration > 0 ? duration : 1,
                      value: position,
                      onChangeStart: _recording
                          ? null
                          : (value) => setState(() => _scrubPosition = value),
                      onChanged: _recording || duration <= 0
                          ? null
                          : (value) => setState(() => _scrubPosition = value),
                      onChangeEnd: (value) => _run(() async {
                        await _player.seek(
                          Duration(milliseconds: value.round()),
                        );
                        if (mounted) setState(() => _scrubPosition = null);
                      }),
                    ),
                  ),
                  Text(
                    formatTime(_player.duration),
                    style: const TextStyle(fontSize: 12),
                  ),
                ],
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Expanded(
                    child: TextButton(
                      onPressed: _markA,
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          _a == null ? '设 A' : 'A ${formatTime(_a!)}',
                        ),
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: '快退 5 秒',
                    onPressed: _recording
                        ? null
                        : () => _run(
                            () => _player.seek(
                              _player.position - const Duration(seconds: 5),
                            ),
                          ),
                    icon: const Icon(Icons.replay_5_rounded, size: 29),
                  ),
                  FilledButton(
                    onPressed: _recording || _player.loading
                        ? null
                        : () => _run(() async {
                            await _recordingPlayer.stop();
                            if (!_player.playing &&
                                hasRange &&
                                !_player.repeat.enabled) {
                              _player.repeat.reset();
                              await _player.seek(_a!);
                            }
                            await _player.toggle();
                          }),
                    style: FilledButton.styleFrom(
                      shape: const CircleBorder(),
                      minimumSize: const Size(52, 52),
                      padding: EdgeInsets.zero,
                    ),
                    child: Icon(
                      _player.playing
                          ? Icons.pause_rounded
                          : Icons.play_arrow_rounded,
                      size: 32,
                    ),
                  ),
                  IconButton(
                    tooltip: '快进 5 秒',
                    onPressed: _recording
                        ? null
                        : () => _run(
                            () => _player.seek(
                              _player.position + const Duration(seconds: 5),
                            ),
                          ),
                    icon: const Icon(Icons.forward_5_rounded, size: 29),
                  ),
                  Expanded(
                    child: TextButton(
                      onPressed: _markB,
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          _b == null ? '设 B' : 'B ${formatTime(_b!)}',
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              Row(
                children: [
                  SizedBox(
                    width: 48,
                    child: Text(
                      '${_player.speed.toStringAsFixed(1)}×',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: _orange,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  Expanded(
                    child: Slider(
                      value: _player.speed,
                      min: 0.1,
                      max: 3,
                      divisions: 29,
                      label: '${_player.speed.toStringAsFixed(1)}×',
                      onChanged: (value) => _run(() => _player.setSpeed(value)),
                    ),
                  ),
                  TextButton(
                    onPressed: () => _run(() => _player.setSpeed(1)),
                    child: const Text('原速'),
                  ),
                ],
              ),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    const Text('单句', style: TextStyle(fontSize: 12)),
                    SizedBox(
                      height: 36,
                      child: Switch(
                        value: _singleSentence,
                        onChanged: (value) => setState(() {
                          _singleSentence = value;
                          if (!value) {
                            _player.repeat.clear();
                            _a = null;
                            _b = null;
                          }
                        }),
                      ),
                    ),
                    const Text('复读', style: TextStyle(fontSize: 12)),
                    _dropdown(_repeatCount, const [0, 1, 2, 3, 5], (value) {
                      _repeatCount = value;
                      _configureRepeat();
                    }, (value) => value == 0 ? '无限' : '$value 次'),
                    const Text('间隔', style: TextStyle(fontSize: 12)),
                    _dropdown(_gap, const [0, 1, 2, 3, 5], (value) {
                      _gap = value;
                      _configureRepeat();
                    }, (value) => '$value 秒'),
                    TextButton(
                      onPressed: _a == null && _b == null
                          ? null
                          : () => setState(() {
                              _a = null;
                              _b = null;
                              _player.repeat.clear();
                            }),
                      child: const Text('清除 AB'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _dropdown(
    int value,
    List<int> values,
    void Function(int) onChanged,
    String Function(int) label,
  ) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 8),
    child: DropdownButton<int>(
      value: value,
      underline: const SizedBox.shrink(),
      isDense: true,
      items: [
        for (final option in values)
          DropdownMenuItem(
            value: option,
            child: Text(label(option), style: const TextStyle(fontSize: 13)),
          ),
      ],
      onChanged: (next) {
        if (next != null) setState(() => onChanged(next));
      },
    ),
  );
}
