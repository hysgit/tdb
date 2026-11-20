import 'dart:io';

import 'package:just_waveform/just_waveform.dart';
import 'package:path_provider/path_provider.dart';

typedef WaveformExtractor = Future<Waveform> Function(File source, File output);

class WaveformService {
  WaveformService({
    WaveformExtractor? extractor,
    Future<Directory> Function()? temporaryDirectory,
  }) : _extractor = extractor ?? _extractNative,
       _temporaryDirectory = temporaryDirectory ?? getTemporaryDirectory;

  static final shared = WaveformService();
  final WaveformExtractor _extractor;
  final Future<Directory> Function() _temporaryDirectory;
  final _inFlight = <String, Future<Waveform>>{};

  Future<Waveform> load(String path) async {
    final source = File(path).absolute;
    final stat = await source.stat();
    if (stat.type != FileSystemEntityType.file) {
      throw FileSystemException('音频文件不存在', source.path);
    }
    final key =
        '${source.path}\n${stat.size}\n${stat.modified.microsecondsSinceEpoch}';
    final existing = _inFlight[key];
    if (existing != null) return existing;
    final task = _extract(source, stat);
    _inFlight[key] = task;
    try {
      return await task;
    } finally {
      if (identical(_inFlight[key], task)) _inFlight.remove(key);
    }
  }

  Future<Waveform> _extract(File source, FileStat before) async {
    final root = await _temporaryDirectory();
    final directory = await root.createTemp('tingdubao_wave_');
    var nativeCompleted = false;
    try {
      final waveform = await _extractor(
        source,
        File('${directory.path}/audio.wave'),
      );
      // A successful extractor result is delivered only after native output has
      // finished. Never unlink an output merely because its viewer was disposed.
      nativeCompleted = true;
      if (waveform.sampleRate <= 0 ||
          waveform.samplesPerPixel <= 0 ||
          waveform.length <= 0 ||
          waveform.data.length < waveform.length * 2) {
        throw const FormatException('音频未包含可显示的波形数据');
      }
      final after = await source.stat();
      if (after.type != FileSystemEntityType.file ||
          before.size != after.size ||
          before.modified != after.modified) {
        throw const FileSystemException('生成波形时音频文件发生变化，请重试');
      }
      return waveform;
    } finally {
      if (nativeCompleted && await directory.exists()) {
        await directory.delete(recursive: true);
      }
      // just_waveform exposes no native cancellation/completion acknowledgment
      // after errors. Keep failed outputs in the OS temp directory rather than
      // deleting a file that a native decoder may still be writing.
    }
  }

  static Future<Waveform> _extractNative(File source, File output) async {
    await for (final progress in JustWaveform.extract(
      audioInFile: source,
      waveOutFile: output,
      zoom: const WaveformZoom.pixelsPerSecond(80),
    )) {
      if (progress.waveform != null) return progress.waveform!;
    }
    throw const FormatException('无法读取此音频的波形，请确认文件格式受支持');
  }
}
