import 'dart:async';
import 'dart:io';

import 'package:just_audio/just_audio.dart';
import 'package:material_ui/material_ui.dart';
import 'package:record/record.dart';

typedef RecordingEntry = ({String path, String title});

class RecordingsPage extends StatefulWidget {
  const RecordingsPage({
    super.key,
    required this.entries,
    required this.createPath,
    required this.onSaved,
    required this.onDelete,
    required this.beforeRecording,
  });

  final List<RecordingEntry> entries;
  final Future<String> Function() createPath;
  final Future<void> Function(String) onSaved;
  final Future<void> Function(String) onDelete;
  final Future<void> Function() beforeRecording;

  @override
  RecordingsPageState createState() => RecordingsPageState();
}

class RecordingsPageState extends State<RecordingsPage> {
  static const _orange = Color(0xFFF58425);
  final _recorder = AudioRecorder();
  final _player = AudioPlayer();
  final _elapsed = Stopwatch();
  Timer? _clock;
  StreamSubscription<PlayerState>? _playState;
  StreamSubscription<PlayerException>? _playErrors;
  Future<void>? _starting;
  Future<void>? _stopping;
  Future<void>? _saving;
  String? _activePath;
  String? _pendingPath;
  String? _saveError;
  String? _error;
  String? _loadedPath;
  String? _playingPath;
  String? _loadingPath;
  bool _recording = false;
  bool _closing = false;
  int _playEpoch = 0;

  bool get _busy => _starting != null || _stopping != null || _saving != null;
  void _refresh() {
    if (mounted && !_closing) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    _playState = _player.playerStateStream.listen((state) {
      if (!state.playing ||
          state.processingState == ProcessingState.completed) {
        _playingPath = null;
      } else {
        _playingPath = _loadedPath;
      }
      _refresh();
    });
    _playErrors = _player.errorStream.listen((error) {
      _error = '录音播放失败：${error.message}';
      _playingPath = null;
      _loadingPath = null;
      _refresh();
    });
  }

  Future<void> _stopPlayback() async {
    _playEpoch++;
    _playingPath = null;
    _loadingPath = null;
    await _player.stop();
  }

  /// Stop a pending/active recording before another page starts audio playback.
  /// A failed save retains its path in this page and can be retried later.
  Future<void> finishRecording() async {
    await _starting;
    await _stopAndSave();
    await _stopPlayback();
    if (_recording) throw StateError(_error ?? '录音未能停止');
  }

  Future<void> _start() {
    if (_busy || _recording || _pendingPath != null || _closing) {
      return Future.value();
    }
    final operation = _begin();
    _starting = operation.whenComplete(() {
      _starting = null;
      _refresh();
    });
    _refresh();
    return _starting!;
  }

  Future<void> _begin() async {
    _error = null;
    try {
      if (!await _recorder.hasPermission()) {
        throw StateError('请在系统设置中允许麦克风权限后再录音');
      }
      if (_closing) return;
      await _stopPlayback();
      await widget.beforeRecording();
      if (_closing) return;
      final path = await widget.createPath();
      if (path.trim().isEmpty) throw const FileSystemException('无法创建录音路径');
      if (_closing) return;
      _activePath = path;
      await _recorder.start(const RecordConfig(), path: path);
      _recording = true;
      _elapsed
        ..reset()
        ..start();
      _clock?.cancel();
      _clock = Timer.periodic(
        const Duration(milliseconds: 250),
        (_) => _refresh(),
      );
    } catch (error) {
      _error = '无法开始录音：$error';
    }
    _refresh();
  }

  Future<void> _stopAndSave() {
    if (_stopping != null) return _stopping!;
    final operation = _finish();
    _stopping = operation.whenComplete(() {
      _stopping = null;
      _refresh();
    });
    _refresh();
    return _stopping!;
  }

  Future<void> _finish() async {
    try {
      if (_recording) {
        final path = await _recorder.stop();
        _recording = false;
        _elapsed.stop();
        _clock?.cancel();
        _pendingPath = path ?? _activePath;
        _activePath = null;
        if (_pendingPath == null) throw const FileSystemException('录音未返回文件路径');
      }
      await _savePending();
    } catch (error) {
      _error = '停止录音失败：$error';
    }
    _refresh();
  }

  Future<void> _savePending() {
    if (_saving != null) return _saving!;
    final path = _pendingPath;
    if (path == null) return Future.value();
    final operation = _persist(path);
    _saving = operation.whenComplete(() {
      _saving = null;
      _refresh();
    });
    _refresh();
    return _saving!;
  }

  Future<void> _persist(String path) async {
    _saveError = null;
    try {
      final file = File(path);
      if (!await file.exists() || await file.length() == 0) {
        throw FileSystemException('录音文件不存在或为空，路径已保留', path);
      }
      await widget.onSaved(path);
      if (_pendingPath == path) _pendingPath = null;
      _error = null;
    } catch (error) {
      _saveError = '$error';
    }
    _refresh();
  }

  Future<void> _play(String path) async {
    if (_recording || _busy || _closing) return;
    final epoch = ++_playEpoch;
    _error = null;
    try {
      if (_loadedPath == path && _player.playing) {
        await _player.pause();
        return;
      }
      _loadingPath = path;
      _refresh();
      if (_loadedPath != path) {
        _loadedPath = null;
        await _player.setFilePath(path);
        if (_closing || epoch != _playEpoch) return;
        _loadedPath = path;
      } else if (_player.processingState == ProcessingState.completed) {
        await _player.seek(Duration.zero);
      }
      if (_closing || epoch != _playEpoch) return;
      _loadingPath = null;
      _playingPath = path;
      _refresh();
      await _player.play();
    } catch (error) {
      if (epoch == _playEpoch) _error = '无法回放录音：$error';
    } finally {
      if (epoch == _playEpoch) {
        _loadingPath = null;
        _playingPath = null;
        _refresh();
      }
    }
  }

  Future<void> _delete(RecordingEntry entry) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除录音？'),
        content: Text(entry.title),
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
    if (confirmed != true || !mounted || _closing) return;
    try {
      if (_loadedPath == entry.path || _loadingPath == entry.path) {
        await _stopPlayback();
        _loadedPath = null;
      }
      await widget.onDelete(entry.path);
    } catch (error) {
      _error = '删除录音失败：$error';
      _refresh();
    }
  }

  Future<void> _close() async {
    try {
      await _starting;
      await _stopAndSave();
    } finally {
      await _playState?.cancel();
      await _playErrors?.cancel();
      // Closing an unrelated playback backend must not delay releasing the
      // microphone after the recording has already been stopped and saved.
      await Future.wait([_recorder.dispose(), _player.dispose()]);
    }
  }

  @override
  void dispose() {
    _closing = true;
    _playEpoch++;
    _clock?.cancel();
    unawaited(
      _close().catchError((Object _) {
        // Source files are owned by the caller and are never removed on failure.
      }),
    );
    super.dispose();
  }

  String get _time {
    final total = _elapsed.elapsed.inSeconds;
    return '${(total ~/ 60).toString().padLeft(2, '0')}:${(total % 60).toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) => ListView(
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(18),
          ),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              children: [
                Text(
                  _time,
                  style: Theme.of(context).textTheme.headlineLarge?.copyWith(
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  _recording
                      ? '正在录音'
                      : _busy
                      ? '处理中…'
                      : _pendingPath != null
                      ? '录音待保存'
                      : '准备录音',
                  style: TextStyle(
                    color: _recording ? _orange : Colors.grey.shade600,
                  ),
                ),
                const SizedBox(height: 18),
                FilledButton.icon(
                  onPressed: _busy || _pendingPath != null
                      ? null
                      : _recording
                      ? _stopAndSave
                      : _start,
                  style: FilledButton.styleFrom(
                    backgroundColor: _recording ? Colors.red.shade600 : _orange,
                    minimumSize: const Size(170, 50),
                  ),
                  icon: Icon(
                    _recording ? Icons.stop_rounded : Icons.mic_rounded,
                  ),
                  label: Text(_recording ? '停止并保存' : '开始录音'),
                ),
              ],
            ),
          ),
        ),
      ),
      if (_error != null)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
          child: Text(_error!, style: TextStyle(color: Colors.red.shade700)),
        ),
      if (_pendingPath != null)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
          child: Card(
            color: const Color(0xFFFFF5E9),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _saveError == null ? '正在保存录音' : '保存失败，录音文件已保留',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 6),
                  SelectableText(
                    _pendingPath!,
                    style: const TextStyle(fontSize: 12),
                  ),
                  if (_saveError != null) ...[
                    const SizedBox(height: 6),
                    Text(_saveError!, style: const TextStyle(fontSize: 12)),
                    TextButton(
                      onPressed: _busy ? null : _savePending,
                      child: const Text('重试保存'),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text(
            '我的录音（${widget.entries.length}）',
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          ),
        ),
      ),
      SizedBox(
        child: widget.entries.isEmpty
            ? const Center(child: Text('还没有录音'))
            : ListView.separated(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: widget.entries.length,
                separatorBuilder: (_, _) =>
                    const Divider(height: 1, indent: 64),
                itemBuilder: (context, index) {
                  final entry = widget.entries[index];
                  return ListTile(
                    leading: _loadingPath == entry.path
                        ? const SizedBox(
                            width: 28,
                            height: 28,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : IconButton(
                            tooltip: _playingPath == entry.path
                                ? '暂停录音回放'
                                : '回放录音',
                            onPressed: _recording || _busy
                                ? null
                                : () => _play(entry.path),
                            icon: Icon(
                              _playingPath == entry.path
                                  ? Icons.pause_circle_outline
                                  : Icons.play_circle_outline,
                              color: _orange,
                            ),
                          ),
                    title: Text(
                      entry.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: IconButton(
                      tooltip: '删除录音',
                      onPressed: _recording || _busy
                          ? null
                          : () => _delete(entry),
                      icon: const Icon(Icons.delete_outline),
                    ),
                  );
                },
              ),
      ),
    ],
  );
}
