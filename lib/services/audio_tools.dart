import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:shine_dart/shine_dart.dart';

enum AudioOutputFormat { m4a, mp3 }

class AudioToolsService {
  AudioToolsService({
    MethodChannel channel = const MethodChannel('tingdubao/audio_tools'),
  }) : _channel = channel;

  final MethodChannel _channel;
  Completer<void>? _finished;
  SendPort? _encoderControl;
  bool _cancelled = false;
  bool _saving = false;
  bool get running => _finished != null;

  Future<void> export(
    String source, {
    required String name,
    required AudioOutputFormat format,
    double speed = 1,
    int bitrate = 128,
    required Future<void> Function(String path, String name) onExported,
  }) async {
    if (running) throw StateError('已有音频处理正在进行。');
    if (!speed.isFinite ||
        speed < .1 ||
        speed > 5 ||
        ![96, 128, 192].contains(bitrate)) {
      throw ArgumentError('请选择有效的速度和音质。');
    }
    _finished = Completer<void>();
    _cancelled = false;
    String? id;
    try {
      final prepared = await _channel
          .invokeMapMethod<String, Object?>('prepare', {
            'path': source,
            'speed': speed,
            'bitrate': bitrate,
            'format': format == AudioOutputFormat.mp3 ? 'wav' : 'm4a',
          });
      id = prepared?['id'] as String?;
      final path = prepared?['path'];
      if (id == null || path is! String || !await File(path).exists()) {
        throw const FormatException('系统没有生成有效音频。');
      }
      _checkCancellation();
      var output = path;
      if (format == AudioOutputFormat.mp3) {
        output = '${File(path).parent.path}${Platform.pathSeparator}audio.mp3';
        await _encode(path, output, bitrate);
        _checkCancellation();
        await _channel.invokeMethod<void>('verifyMp3', {
          'id': id,
          'duration': prepared?['duration'],
        });
      }
      _checkCancellation();
      if (await File(output).length() == 0) {
        throw const FormatException('输出音频为空。');
      }
      _checkCancellation();
      _saving = true;
      await onExported(output, audioExportName(name, format, speed));
    } finally {
      try {
        if (id != null) {
          await _channel.invokeMethod<void>('release', {'id': id});
        }
      } finally {
        _encoderControl = null;
        _saving = false;
        final done = _finished;
        _finished = null;
        done?.complete();
      }
    }
  }

  Future<void> cancel() async {
    final done = _finished;
    if (done == null) return;
    // Once the caller is copying into its library, wait rather than delete its input.
    if (!_saving) {
      _cancelled = true;
      _encoderControl?.send('cancel');
      await _channel.invokeMethod<void>('cancel');
    }
    await done.future;
  }

  void _checkCancellation() {
    if (_cancelled) {
      throw PlatformException(code: 'cancelled', message: '已取消音频处理。');
    }
  }

  Future<void> _encode(String input, String output, int bitrate) async {
    final messages = ReceivePort();
    final errors = ReceivePort();
    final exit = ReceivePort();
    final done = Completer<void>();
    final subscriptions = <StreamSubscription<dynamic>>[];
    var receivedResult = false;
    subscriptions.add(
      messages.listen((message) {
        if (message is SendPort) {
          _encoderControl = message;
          if (_cancelled) message.send('cancel');
        } else if (message is Map && !done.isCompleted) {
          receivedResult = true;
          _encoderControl?.send('finish');
          if (message['ok'] == true) {
            done.complete();
          } else {
            done.completeError(
              PlatformException(
                code: message['cancelled'] == true ? 'cancelled' : 'mp3_failed',
                message: message['cancelled'] == true
                    ? '已取消音频处理。'
                    : 'MP3 编码失败，请检查音频文件。',
              ),
            );
          }
        }
      }),
    );
    subscriptions.add(
      errors.listen((_) {
        if (!done.isCompleted) done.completeError(StateError('MP3 编码进程异常结束。'));
      }),
    );
    final exited = Completer<void>();
    subscriptions.add(
      exit.listen((_) {
        if (!exited.isCompleted) exited.complete();
        // Result and onExit use different ports; allow the result event to arrive first.
        scheduleMicrotask(() {
          if (!receivedResult && !done.isCompleted) {
            done.completeError(StateError('MP3 编码进程未返回有效结果。'));
          }
        });
      }),
    );
    try {
      await Isolate.spawn(
        _mp3Worker,
        [messages.sendPort, input, output, bitrate],
        onError: errors.sendPort,
        onExit: exit.sendPort,
      );
      try {
        await done.future;
      } finally {
        // All file handles must close before the caller releases the temp directory.
        await exited.future;
      }
    } finally {
      _encoderControl = null;
      for (final subscription in subscriptions) {
        await subscription.cancel();
      }
      messages.close();
      errors.close();
      exit.close();
    }
  }
}

String audioExportName(String source, AudioOutputFormat format, double speed) {
  final basename = source.replaceAll(r'\', '/').split('/').last;
  final stem = basename.replaceFirst(RegExp(r'\.[^.]+$'), '');
  final suffix = speed == 1 ? '' : '_${speed.toStringAsFixed(1)}x';
  return '${stem.isEmpty ? '音频' : stem}$suffix.${format.name}';
}

class PcmWavInfo {
  const PcmWavInfo(
    this.sampleRate,
    this.channels,
    this.dataOffset,
    this.dataLength,
  );
  final int sampleRate;
  final int channels;
  final int dataOffset;
  final int dataLength;
}

/// Parse RIFF chunks instead of assuming every WAV has a 44-byte header.
Future<PcmWavInfo> readPcmWav(String path) async {
  final input = await File(path).open();
  try {
    final length = await input.length();
    final header = await input.read(12);
    if (header.length != 12 ||
        String.fromCharCodes(header.sublist(0, 4)) != 'RIFF' ||
        String.fromCharCodes(header.sublist(8, 12)) != 'WAVE') {
      throw const FormatException('需要 RIFF/WAVE PCM 音频。');
    }
    int? sampleRate, channels, dataOffset, dataLength;
    while (await input.position() + 8 <= length) {
      final chunk = await input.read(8);
      final name = String.fromCharCodes(chunk.sublist(0, 4));
      final size = ByteData.sublistView(chunk).getUint32(4, Endian.little);
      final position = await input.position();
      if (position + size > length) throw const FormatException('WAV 数据不完整。');
      if (name == 'fmt ') {
        if (size < 16) throw const FormatException('WAV 格式头无效。');
        final bytes = await input.read(math.min(size, 40));
        final fmt = ByteData.sublistView(bytes);
        var codec = fmt.getUint16(0, Endian.little);
        if (codec == 0xfffe && bytes.length >= 40) {
          codec = fmt.getUint16(24, Endian.little);
        }
        channels = fmt.getUint16(2, Endian.little);
        sampleRate = fmt.getUint32(4, Endian.little);
        if (codec != 1 ||
            ![1, 2].contains(channels) ||
            fmt.getUint16(14, Endian.little) != 16 ||
            fmt.getUint16(12, Endian.little) != channels * 2) {
          throw const FormatException('仅支持单/双声道 16 位整数 PCM。');
        }
      } else if (name == 'data') {
        dataOffset = position;
        dataLength = size;
      }
      if (sampleRate != null &&
          channels != null &&
          dataOffset != null &&
          dataLength != null) {
        break;
      }
      await input.setPosition(position + size + (size & 1));
    }
    if (sampleRate == null ||
        channels == null ||
        dataOffset == null ||
        dataLength == null ||
        dataLength == 0 ||
        dataLength % (channels * 2) != 0) {
      throw const FormatException('没有找到有效 PCM 音频数据。');
    }
    return PcmWavInfo(sampleRate, channels, dataOffset, dataLength);
  } finally {
    await input.close();
  }
}

Future<void> encodeWavToMp3(
  String wav,
  String mp3, {
  int bitrate = 128,
  bool Function()? cancelled,
}) async {
  if (![96, 128, 192].contains(bitrate)) throw ArgumentError('不支持的 MP3 码率。');
  if (File(wav).absolute.path == File(mp3).absolute.path ||
      (await File(mp3).exists() &&
          await FileSystemEntity.identical(wav, mp3))) {
    throw ArgumentError('输出路径不能覆盖源音频。');
  }
  final info = await readPcmWav(wav);
  final encoder = shineInitialise(
    ShineConfig(
      wave: ShineWave(
        channels: info.channels == 2 ? Channels.pcmStereo : Channels.pcmMono,
        samplerate: info.sampleRate,
      ),
      mpeg: ShineMpeg(
        mode: info.channels == 1 ? StereoMode.mono : StereoMode.stereo,
        bitr: bitrate,
      ),
    ),
  );
  if (encoder == null) throw const FormatException('MP3 编码器不支持此采样率或声道。');
  RandomAccessFile? input;
  IOSink? sink;
  try {
    input = await File(wav).open();
    await input.setPosition(info.dataOffset);
    final output = File(mp3).openWrite();
    sink = output;
    final samples = shineSamplesPerPass(encoder) * info.channels;
    var remaining = info.dataLength;
    var frames = 0;
    while (remaining > 0) {
      if (cancelled?.call() == true) throw const _EncodingCancelled();
      final bytes = await input.read(math.min(samples * 2, remaining));
      if (bytes.isEmpty) throw const FormatException('PCM 数据提前结束。');
      remaining -= bytes.length;
      final pcm = Int16List(samples);
      final data = ByteData.sublistView(bytes);
      for (var i = 0; i < bytes.length ~/ 2; i++) {
        pcm[i] = data.getInt16(i * 2, Endian.little);
      }
      final frame = shineEncodeBufferInterleaved(encoder, pcm);
      output.add(Uint8List.fromList(frame.buffer.sublist(0, frame.length)));
      if (++frames % 32 == 0) await output.flush();
    }
    if (cancelled?.call() == true) throw const _EncodingCancelled();
    final tail = shineFlush(encoder);
    output.add(Uint8List.fromList(tail.buffer.sublist(0, tail.length)));
    await output.close();
    sink = null;
  } finally {
    try {
      await sink?.close();
    } finally {
      try {
        await input?.close();
      } finally {
        shineClose(encoder);
      }
    }
  }
}

class _EncodingCancelled implements Exception {
  const _EncodingCancelled();
}

void _mp3Worker(List<Object> arguments) async {
  final reply = arguments[0] as SendPort;
  final control = ReceivePort();
  var cancelled = false;
  final acknowledged = Completer<void>();
  final subscription = control.listen((message) {
    if (message == 'cancel') cancelled = true;
    if (message == 'finish' && !acknowledged.isCompleted) {
      acknowledged.complete();
    }
  });
  reply.send(control.sendPort);
  try {
    await encodeWavToMp3(
      arguments[1] as String,
      arguments[2] as String,
      bitrate: arguments[3] as int,
      cancelled: () => cancelled,
    );
    reply.send({'ok': true});
  } catch (error) {
    reply.send({'ok': false, 'cancelled': error is _EncodingCancelled});
  } finally {
    // Do not exit until the parent has received the result on its separate port.
    await acknowledged.future;
    await subscription.cancel();
    control.close();
  }
}
