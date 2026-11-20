import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';

import 'library.dart';
import 'services/audio_tools.dart';

class AudioToolsPage extends StatefulWidget {
  const AudioToolsPage({
    super.key,
    required this.item,
    required this.videoMode,
    required this.onExported,
  });
  final MediaItem item;
  final bool videoMode;
  final Future<void> Function(String path, String name) onExported;

  @override
  State<AudioToolsPage> createState() => _AudioToolsPageState();
}

class _AudioToolsPageState extends State<AudioToolsPage> {
  final _service = AudioToolsService();
  AudioOutputFormat _format = AudioOutputFormat.mp3;
  double _speed = 1;
  int _bitrate = 128;
  bool _busy = false;
  bool _leaving = false;
  bool _popScheduled = false;
  String? _error;

  Future<void> _run() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _service.export(
        widget.item.path,
        name: widget.item.name,
        format: _format,
        speed: _speed,
        bitrate: _bitrate,
        onExported: widget.onExported,
      );
      if (mounted && !_leaving) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('音频已导入文件列表')));
        _pop(true);
      }
    } catch (error) {
      if (mounted &&
          !(error is PlatformException && error.code == 'cancelled')) {
        setState(
          () => _error = error is PlatformException
              ? error.message ?? '音频处理失败，请重试。'
              : error is FormatException
              ? error.message
              : error is MissingPluginException
              ? '此设备暂不支持音频处理。'
              : '音频处理失败，请检查文件后重试。',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _leave() async {
    if (_leaving) return;
    setState(() => _leaving = true);
    try {
      await _service.cancel();
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = '无法停止音频处理，请稍后重试。';
          _leaving = false;
        });
      }
      return;
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _leaving = false;
    });
    _pop(false);
  }

  void _pop(bool exported) {
    if (_popScheduled) return;
    _popScheduled = true;
    setState(() => _busy = false);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.pop(context, exported);
    });
  }

  @override
  void dispose() {
    unawaited(_service.cancel().catchError((Object _) {}));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop && _busy) unawaited(_leave());
    },
    child: Scaffold(
      appBar: AppBar(title: Text(widget.videoMode ? '视频转音频' : '音频变速导出')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(
              widget.videoMode
                  ? Icons.video_file_outlined
                  : Icons.audio_file_outlined,
              color: const Color(0xffee8c36),
              size: 36,
            ),
            title: Text(
              widget.item.name,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(height: 24),
          DropdownButtonFormField<AudioOutputFormat>(
            initialValue: _format,
            decoration: const InputDecoration(
              labelText: '输出格式',
              border: OutlineInputBorder(),
            ),
            items: const [
              DropdownMenuItem(
                value: AudioOutputFormat.mp3,
                child: Text('MP3'),
              ),
              DropdownMenuItem(
                value: AudioOutputFormat.m4a,
                child: Text('M4A（AAC）'),
              ),
            ],
            onChanged: _busy
                ? null
                : (value) => setState(() => _format = value!),
          ),
          const SizedBox(height: 20),
          DropdownButtonFormField<int>(
            initialValue: _bitrate,
            decoration: const InputDecoration(
              labelText: '音质',
              border: OutlineInputBorder(),
            ),
            items: const [
              DropdownMenuItem(value: 96, child: Text('96 kbps · 较小文件')),
              DropdownMenuItem(value: 128, child: Text('128 kbps · 标准')),
              DropdownMenuItem(value: 192, child: Text('192 kbps · 较高音质')),
            ],
            onChanged: _busy
                ? null
                : (value) => setState(() => _bitrate = value!),
          ),
          const SizedBox(height: 28),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('播放速度'),
              Text('${_speed.toStringAsFixed(1)}×'),
            ],
          ),
          Slider(
            value: _speed,
            min: .1,
            max: 5,
            divisions: 49,
            label: '${_speed.toStringAsFixed(1)}×',
            onChanged: _busy ? null : (value) => setState(() => _speed = value),
          ),
          const Text(
            '导出会调整时长并保留音高。极慢或极快速度可能降低清晰度。',
            style: TextStyle(color: Colors.black54, height: 1.5),
          ),
          const SizedBox(height: 28),
          if (_busy) ...[
            const LinearProgressIndicator(),
            const SizedBox(height: 12),
            Text(_leaving ? '正在停止并清理临时文件…' : '正在处理音轨并编码，请保持页面开启…'),
            const SizedBox(height: 20),
          ],
          if (_error != null) ...[
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
            const SizedBox(height: 16),
          ],
          FilledButton.icon(
            onPressed: _busy ? null : _run,
            icon: const Icon(Icons.save_alt),
            label: const Text('生成并导入文件列表'),
          ),
          if (_busy)
            TextButton(
              onPressed: _leaving ? null : _leave,
              child: const Text('取消处理并返回'),
            ),
        ],
      ),
    ),
  );
}
