import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'models.dart';

class MediaItem {
  MediaItem({
    required this.id,
    required this.name,
    required this.path,
    this.folder = '',
    this.positionMs = 0,
    this.cues = const [],
    this.favorites = const {},
    this.recordings = const [],
    this.cueRecordings = const {},
    this.customSpeeds = const [.4, .5, .6, .7, .8, .9, 1, 1.8],
    this.singleSentence = true,
    this.repeatCount = 0,
    this.repeatGapMs = 0,
  });
  final String id;
  String name;
  final String path;
  String folder;
  int positionMs;
  List<Cue> cues;
  Set<String> favorites;
  List<String> recordings;
  Map<String, List<String>> cueRecordings;
  List<double> customSpeeds;
  bool singleSentence;
  int repeatCount;
  int repeatGapMs;
  bool get isVideo =>
      RegExp(r'\.(mp4|m4v|mov|webm)$', caseSensitive: false).hasMatch(path);
  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'path': path,
    'folder': folder,
    'positionMs': positionMs,
    'cues': cues.map((c) => c.toJson()).toList(),
    'favorites': favorites.toList(),
    'recordings': [...recordings],
    'cueRecordings': cueRecordings.map((id, paths) => MapEntry(id, [...paths])),
    'customSpeeds': [...customSpeeds],
    'singleSentence': singleSentence,
    'repeatCount': repeatCount,
    'repeatGapMs': repeatGapMs,
  };
  factory MediaItem.fromJson(Map<String, dynamic> j) => MediaItem(
    id: j['id'] as String,
    name: j['name'] as String,
    path: j['path'] as String,
    folder: j['folder'] as String? ?? '',
    positionMs: j['positionMs'] as int? ?? 0,
    cues: (j['cues'] as List? ?? [])
        .map((c) => Cue.fromJson(Map<String, dynamic>.from(c as Map)))
        .toList(),
    favorites: Set<String>.from(j['favorites'] as List? ?? []),
    recordings: List<String>.from(j['recordings'] as List? ?? []),
    cueRecordings: (j['cueRecordings'] as Map<String, dynamic>? ?? {}).map(
      (id, paths) => MapEntry(id, List<String>.from(paths as List)),
    ),
    customSpeeds: j['customSpeeds'] == null
        ? const [.4, .5, .6, .7, .8, .9, 1, 1.8]
        : (j['customSpeeds'] as List)
              .map((value) => (value as num).toDouble())
              .where((value) => value.isFinite && value >= .1 && value <= 5)
              .toList(),
    singleSentence: j['singleSentence'] as bool? ?? true,
    repeatCount: j['repeatCount'] as int? ?? 0,
    repeatGapMs: j['repeatGapMs'] as int? ?? 0,
  );

  void replaceCue(Cue cue) {
    cues = [...cues.where((entry) => entry.id != cue.id), cue]
      ..sort((a, b) => a.start.compareTo(b.start));
  }

  void removeCue(String cueId) {
    cues = cues.where((cue) => cue.id != cueId).toList();
    favorites = {...favorites}..remove(cueId);
    cueRecordings = {...cueRecordings}..remove(cueId);
  }

  void attachRecording(String cueId, String path) {
    recordings = {...recordings, path}.toList();
    if (!cues.any((cue) => cue.id == cueId)) return;
    cueRecordings = {
      ...cueRecordings,
      cueId: {...?cueRecordings[cueId], path}.toList(),
    };
  }

  void detachRecording(String path) {
    recordings = recordings.where((entry) => entry != path).toList();
    cueRecordings = cueRecordings.map(
      (id, paths) =>
          MapEntry(id, paths.where((entry) => entry != path).toList()),
    );
  }
}

class LibraryRepository {
  LibraryRepository(this.root);
  final Directory root;
  Future<void> _writes = Future.value();
  static Future<LibraryRepository> open() async => LibraryRepository(
    Directory('${(await getApplicationDocumentsDirectory()).path}/tingdubao')
      ..createSync(recursive: true),
  );

  Future<Map<String, dynamic>?> read() async {
    await _writes;
    var found = false;
    // Both generations are retained so an interrupted replacement is recoverable.
    for (final name in ['library.json', 'library.previous.json']) {
      final file = File('${root.path}/$name');
      if (!await file.exists()) {
        continue;
      }
      found = true;
      try {
        final decoded = jsonDecode(await file.readAsString());
        if (decoded is! Map<String, dynamic>) {
          throw const FormatException('资料格式错误');
        }
        return decoded;
      } on FormatException {
        continue;
      }
    }
    if (found) {
      throw const FormatException('存档及备份无法读取，已保留原文件，请先备份应用资料');
    }
    return null;
  }

  Future<void> write(Map<String, dynamic> value) {
    // Capture before queueing: later UI mutations cannot alter this generation.
    final snapshot = jsonEncode(value);
    final next = _writes.then((_) async {
      final current = File('${root.path}/library.json');
      final previous = File('${root.path}/library.previous.json');
      final temporary = File('${root.path}/library.next.json');
      await temporary.writeAsString(snapshot, flush: true);
      if (await current.exists()) {
        if (await previous.exists()) {
          await previous.delete();
        }
        await current.rename(previous.path);
      }
      await temporary.rename(current.path);
    });
    _writes = next.catchError((Object _) {});
    return next;
  }

  Future<String> importFile(String source, String name) async {
    final directory = await root.createTemp('media_');
    final safeName = name.replaceAll(
      RegExp(r'[^a-zA-Z0-9.\u4e00-\u9fff_-]'),
      '_',
    );
    final target = '${directory.path}/$safeName';
    try {
      await File(source).copy(target);
      return target;
    } catch (_) {
      await directory.delete(recursive: true);
      rethrow;
    }
  }

  Future<String> installAsset(String name) async {
    final target = File('${root.path}/$name');
    if (!await target.exists()) {
      final bytes = await rootBundle.load('assets/demo/$name');
      await target.writeAsBytes(
        bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
        flush: true,
      );
    }
    return target.path;
  }
}
