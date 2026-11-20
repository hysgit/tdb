import 'dart:async';
import 'dart:io';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:video_player/video_player.dart';

import '../library.dart';
import '../repeat_plan.dart';

class StudyPlayer extends ChangeNotifier {
  StudyPlayer({AudioPlayer? audio}) : audio = audio ?? AudioPlayer() {
    _ticker = Timer.periodic(const Duration(milliseconds: 80), (_) => _tick());
    _errors = this.audio.errorStream.listen((e) {
      if (!_disposed && _ready && !loading) _fail('音频播放失败：${e.message}');
    });
  }

  final AudioPlayer audio;
  VideoPlayerController? video;
  final RepeatPlan repeat = RepeatPlan();
  MediaItem? item;
  bool loading = false;
  String? error;
  double speed = 1;
  double volume = 1;
  int _loadGeneration = 0;
  int _operation = 0;
  bool _handlingRepeat = false;
  int? _repeatRevision;
  bool _disposed = false;
  bool _ready = false;
  bool _wantsPlayback = false;
  bool _seeking = false;
  Future<void> _loads = Future.value();
  Timer? _sleep;
  DateTime? sleepAt;
  Timer? _ticker;
  Timer? _gapTimer;
  Completer<void>? _gap;
  late final StreamSubscription<PlayerException> _errors;

  Duration get position =>
      !_ready ? Duration.zero : video?.value.position ?? audio.position;
  Duration get duration => !_ready
      ? Duration.zero
      : video?.value.duration ?? audio.duration ?? Duration.zero;
  bool get playing =>
      _ready &&
      error == null &&
      (video?.value.isPlaying ??
          (audio.playing &&
              audio.processingState != ProcessingState.completed));

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _cancelRepeat() {
    _operation++;
    _gapTimer?.cancel();
    _gapTimer = null;
    final gap = _gap;
    _gap = null;
    if (gap != null && !gap.isCompleted) gap.complete();
    repeat.acknowledgeSeek();
  }

  void _fail(String message) {
    if (_disposed) return;
    _cancelRepeat();
    _wantsPlayback = false;
    error = message;
    _notify();
  }

  Future<void> open(MediaItem selected) {
    if (_disposed) return Future.value();
    final generation = ++_loadGeneration;
    _cancelRepeat();
    _wantsPlayback = false;
    _seeking = false;
    _ready = false;
    loading = true;
    error = null;
    item = selected;
    repeat.clear();
    _notify();
    // The native player has one source; serialize loads so an older load cannot
    // complete after the selected file and replace its source.
    final next = _loads.then((_) => _open(selected, generation));
    _loads = next.catchError((Object _) {});
    return next;
  }

  bool _currentLoad(int generation) =>
      !_disposed && generation == _loadGeneration;

  Future<void> _open(MediaItem selected, int generation) async {
    if (!_currentLoad(generation)) return;
    VideoPlayerController? candidate;
    final oldVideo = video;
    video = null;
    try {
      await audio.stop();
      await oldVideo?.dispose();
      if (!_currentLoad(generation)) return;
      if (!await File(selected.path).exists()) {
        throw FileSystemException('文件不存在', selected.path);
      }
      if (!_currentLoad(generation)) return;
      final session = await AudioSession.instance;
      await session.configure(const AudioSessionConfiguration.speech());
      if (!_currentLoad(generation)) return;
      if (selected.isVideo) {
        candidate = VideoPlayerController.file(File(selected.path));
        await candidate.initialize();
        if (!_currentLoad(generation)) return;
        await candidate.setPlaybackSpeed(speed);
        await candidate.setVolume(volume);
        final saved = Duration(milliseconds: selected.positionMs);
        await candidate.seekTo(
          saved < candidate.value.duration ? saved : Duration.zero,
        );
        if (!_currentLoad(generation)) return;
        video = candidate;
        candidate = null;
      } else {
        await audio.setFilePath(selected.path);
        if (!_currentLoad(generation)) return;
        await audio.setSpeed(speed);
        await audio.setVolume(volume);
        final saved = Duration(milliseconds: selected.positionMs);
        await audio.seek(
          saved < (audio.duration ?? Duration.zero) ? saved : Duration.zero,
        );
        if (!_currentLoad(generation)) return;
      }
      _ready = true;
    } catch (e) {
      if (_currentLoad(generation)) {
        _ready = false;
        _fail('无法打开文件 ${selected.path}：$e');
      }
    } finally {
      try {
        await candidate?.dispose();
      } finally {
        if (_currentLoad(generation)) {
          loading = false;
          _notify();
        }
      }
    }
  }

  Future<void> play() async {
    if (_disposed || !_ready || loading || error != null) return;
    _cancelRepeat();
    final operation = _operation;
    try {
      if (position >= duration && duration > Duration.zero) {
        await _seekBackend(Duration.zero);
      }
      if (_disposed || operation != _operation) return;
      _wantsPlayback = true;
      await _playBackend(operation);
      _notify();
    } catch (e) {
      if (operation == _operation) _fail('无法播放文件：$e');
    }
  }

  Future<void> _playBackend(int operation) async {
    final currentVideo = video;
    if (currentVideo != null) {
      await currentVideo.play();
    } else {
      // just_audio's play future ends when playback stops, rather than starts.
      unawaited(
        audio.play().catchError((Object e) {
          if (!_disposed && operation == _operation) _fail('无法播放音频：$e');
        }),
      );
    }
  }

  Future<void> pause() async {
    if (_disposed) return;
    _cancelRepeat();
    _wantsPlayback = false;
    _seeking = false;
    final operation = _operation;
    try {
      // Loading never auto-plays. Pause must not invalidate its generation and
      // prevent the matching finally block from clearing loading.
      if (_ready && !loading) await _pauseBackend();
    } catch (e) {
      if (operation == _operation) _fail('无法暂停播放：$e');
    }
    _notify();
  }

  Future<void> _pauseBackend() async {
    final currentVideo = video;
    if (currentVideo != null) {
      await currentVideo.pause();
    } else {
      await audio.pause();
    }
  }

  Future<void> toggle() => playing ? pause() : play();

  Future<void> seek(Duration target) async {
    if (_disposed || !_ready || loading) return;
    final wasPlaying = playing;
    _cancelRepeat();
    _wantsPlayback = wasPlaying;
    final operation = _operation;
    _seeking = true;
    try {
      await _seekBackend(target);
    } catch (e) {
      if (operation == _operation) _fail('无法跳转播放位置：$e');
    } finally {
      if (operation == _operation) _seeking = false;
      _notify();
    }
  }

  Future<void> _seekBackend(Duration target) async {
    final clamped = Duration(
      milliseconds: target.inMilliseconds.clamp(0, duration.inMilliseconds),
    );
    final currentVideo = video;
    if (currentVideo != null) {
      await currentVideo.seekTo(clamped);
    } else {
      await audio.seek(clamped);
    }
  }

  Future<void> setSpeed(double value) async {
    if (_disposed) return;
    speed = value.clamp(0.1, 5.0);
    try {
      if (_ready && !loading) {
        if (video != null) {
          await video!.setPlaybackSpeed(speed);
        } else {
          await audio.setSpeed(speed);
        }
      }
    } catch (e) {
      _fail('无法调整播放速度：$e');
    }
    _notify();
  }

  Future<void> setVolume(double value) async {
    if (_disposed) return;
    volume = value.clamp(0.0, 1.0);
    try {
      if (_ready && !loading) {
        if (video != null) {
          await video!.setVolume(volume);
        } else {
          await audio.setVolume(volume);
        }
      }
    } catch (e) {
      _fail('无法调整音量：$e');
    }
    _notify();
  }

  void setSleep(Duration? delay) {
    if (_disposed) return;
    _sleep?.cancel();
    sleepAt = delay == null ? null : DateTime.now().add(delay);
    if (delay != null) {
      _sleep = Timer(delay, () {
        sleepAt = null;
        _sleep = null;
        unawaited(pause());
      });
    }
    _notify();
  }

  void _tick() {
    if (_disposed) return;
    if (_handlingRepeat && _repeatRevision != repeat.revision) {
      _wantsPlayback = false;
      _cancelRepeat();
    }
    if (_ready && (video?.value.hasError ?? false) && error == null) {
      _fail('视频播放失败：${video!.value.errorDescription}');
    }
    if (item != null && _ready && !loading && error == null) {
      item!.positionMs = position.inMilliseconds;
    }
    if (_ready && _wantsPlayback && !_handlingRepeat && !_seeking) {
      // A range may end at duration, after native playback became completed.
      final completed =
          video?.value.isCompleted ??
          (audio.processingState == ProcessingState.completed);
      final decision = repeat.onPosition(completed ? duration : position);
      if (decision != null) {
        unawaited(_handleRepeat(decision));
      } else if (completed) {
        _wantsPlayback = false;
      }
    }
    _notify();
  }

  Future<void> _handleRepeat(RepeatDecision decision) async {
    _handlingRepeat = true;
    final operation = _operation;
    final revision = repeat.revision;
    _repeatRevision = revision;
    bool current() =>
        !_disposed &&
        _ready &&
        operation == _operation &&
        revision == repeat.revision;
    try {
      await _pauseBackend();
      if (!current()) return;
      await _seekBackend(decision.seekTo);
      if (!current()) return;
      if (decision.finished) {
        _wantsPlayback = false;
        return;
      }
      if (decision.wait > Duration.zero) {
        final gap = Completer<void>();
        _gap = gap;
        _gapTimer = Timer(decision.wait, () {
          if (!gap.isCompleted) gap.complete();
        });
        await gap.future;
        if (identical(_gap, gap)) {
          _gap = null;
          _gapTimer = null;
        }
      }
      if (current() && _wantsPlayback && repeat.enabled) {
        await _playBackend(operation);
      }
    } catch (e) {
      if (current()) _fail('AB 复读失败：$e');
    } finally {
      if (revision == repeat.revision) repeat.acknowledgeSeek();
      _handlingRepeat = false;
      _repeatRevision = null;
      _notify();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _loadGeneration++;
    _cancelRepeat();
    _ticker?.cancel();
    _sleep?.cancel();
    unawaited(_errors.cancel());
    unawaited(audio.dispose());
    unawaited(video?.dispose());
    super.dispose();
  }
}
