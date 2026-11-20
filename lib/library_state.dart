import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'library.dart';
import 'models.dart';

/// Owns import and batch-edit ordering; repository writes retain their own
/// immutable, queued generations. User media is copied before it is indexed.
class LibraryState extends ChangeNotifier {
  LibraryState(this.repository);
  final LibraryRepository repository;
  List<MediaItem> items = [];
  Set<String> folders = {};
  List<Map<String, String>> sidecars = [];
  List<String> standaloneRecordings = [];
  List<String> recent = [];
  Map<String, int> studySeconds = {};
  List<String> words = [];
  double speed = 1;
  Future<void> _operations = Future.value();

  void restore(Map<String, dynamic> data) {
    items = (data['items'] as List? ?? [])
        .map((i) => MediaItem.fromJson(Map<String, dynamic>.from(i as Map)))
        .toList();
    folders = Set<String>.from(data['folders'] as List? ?? []);
    sidecars = (data['sidecars'] as List? ?? [])
        .map((i) => Map<String, String>.from(i as Map))
        .toList();
    standaloneRecordings = List<String>.from(data['recordings'] as List? ?? []);
    recent = List<String>.from(data['recent'] as List? ?? []);
    words = List<String>.from(data['words'] as List? ?? []);
    studySeconds = (data['studySeconds'] as Map? ?? {}).map(
      (key, value) => MapEntry(key as String, (value as num).toInt()),
    );
    speed = (data['speed'] as num? ?? 1).toDouble().clamp(.1, 5);
  }

  Map<String, dynamic> snapshot() => {
    'version': 2,
    'items': items.map((i) => i.toJson()).toList(),
    'folders': folders.toList(),
    'sidecars': sidecars.map((s) => Map<String, String>.from(s)).toList(),
    'recordings': [...standaloneRecordings],
    'recent': [...recent],
    'words': [...words],
    'studySeconds': {...studySeconds},
    'speed': speed,
  };

  Future<void> save() => _ordered(_persist);
  Future<void> _persist() => repository.write(snapshot());
  Future<T> _ordered<T>(Future<T> Function() action) {
    final next = _operations.then((_) => action());
    _operations = next.then<void>((_) {}, onError: (Object _) {});
    return next;
  }

  static String stem(String name) =>
      name.replaceFirst(RegExp(r'\.[^.]+$'), '').toLowerCase();
  static const subtitleExtensions = {'lrc', 'srt', 'vtt', 'txt', 'json'};

  Future<void> importFile(
    String source,
    String name, {
    String folder = '',
  }) => _ordered(() async {
    final extension = name.split('.').last.toLowerCase();
    final isSubtitle = subtitleExtensions.contains(extension);
    final cues = isSubtitle
        ? parseSubtitles(await File(source).readAsString(), format: extension)
        : <Cue>[];
    if (isSubtitle && cues.isEmpty) throw const FormatException('文件中没有有效字幕');
    final path = await repository.importFile(source, name);
    final previousSidecars = [...sidecars];
    MediaItem? added;
    MediaItem? associated;
    try {
      if (isSubtitle) {
        sidecars = [
          ...sidecars,
          {'name': name, 'path': path, 'folder': folder},
        ];
        final matches = items
            .where((i) => i.folder == folder && stem(i.name) == stem(name))
            .toList();
        if (matches.length == 1 && matches.single.cues.isEmpty) {
          associated = matches.single;
          associated.cues = [...cues];
        }
      } else {
        final matching = sidecars
            .where(
              (s) => s['folder'] == folder && stem(s['name']!) == stem(name),
            )
            .toList();
        List<Cue> captions = [];
        if (matching.length == 1) {
          final s = matching.single;
          captions = parseSubtitles(
            await File(s['path']!).readAsString(),
            format: s['name']!.split('.').last,
          );
        }
        added = MediaItem(
          id: path,
          name: name,
          path: path,
          folder: folder,
          cues: captions,
        );
        items.add(added);
      }
      await _persist();
    } catch (_) {
      if (added != null) items.remove(added);
      if (associated != null && listEquals(associated.cues, cues)) {
        associated.cues = [];
      }
      sidecars = previousSidecars;
      await _deleteOwned(path);
      rethrow;
    }
    notifyListeners();
  });

  Future<void> move(Set<String> ids, String target) {
    final selectedIds = {...ids};
    return _ordered(() async {
      if (target.isNotEmpty && !folders.contains(target)) {
        throw StateError('目标文件夹不存在');
      }
      final previous = {
        for (final i in items.where((i) => selectedIds.contains(i.id)))
          i: i.folder,
      };
      for (final i in previous.keys) {
        i.folder = target;
      }
      try {
        await _persist();
      } catch (_) {
        for (final entry in previous.entries) {
          entry.key.folder = entry.value;
        }
        rethrow;
      }
      notifyListeners();
    });
  }

  Future<void> delete(
    Set<String> ids, {
    String? activeId,
    String? Function()? activeIdProvider,
  }) {
    final selectedIds = {...ids};
    return _ordered(() async {
      final currentActiveId = activeIdProvider == null
          ? activeId
          : activeIdProvider();
      if (selectedIds.contains(currentActiveId))
        throw StateError('正在使用此文件，请先打开其他文件');
      final before = [...items];
      final deleted = items.where((i) => selectedIds.contains(i.id)).toList();
      items.removeWhere((i) => selectedIds.contains(i.id));
      try {
        await _persist();
      } catch (_) {
        items = before;
        rethrow;
      }
      notifyListeners();
      for (final item in deleted) {
        for (final path in {
          item.path,
          ...item.recordings,
          ...item.cueRecordings.values.expand((paths) => paths),
        }) {
          if (!_referencesPath(path)) {
            await _deleteOwned(path);
          }
        }
      }
    });
  }

  Future<void> reorder(List<String> ids) {
    final orderedIds = [...ids];
    return _ordered(() async {
      final selected = {for (final i in items) i.id: i};
      if (orderedIds.toSet().length != orderedIds.length ||
          orderedIds.any((id) => !selected.containsKey(id))) {
        throw ArgumentError('文件列表已变化，请重试');
      }
      final positions = items.indexed
          .where((e) => orderedIds.contains(e.$2.id))
          .map((e) => e.$1)
          .toList();
      final before = [...items];
      for (var n = 0; n < positions.length; n++) {
        items[positions[n]] = selected[orderedIds[n]]!;
      }
      try {
        await _persist();
      } catch (_) {
        items = before;
        rethrow;
      }
      notifyListeners();
    });
  }

  Future<void> addRecording(String path) => _ordered(() async {
    if (standaloneRecordings.contains(path)) return;
    standaloneRecordings.add(path);
    try {
      await _persist();
    } catch (_) {
      standaloneRecordings.remove(path);
      rethrow;
    }
    notifyListeners();
  });

  Future<void> deleteRecording(String path) => _ordered(() async {
    if (!standaloneRecordings.contains(path) &&
        !items.any(
          (i) =>
              i.recordings.contains(path) ||
              i.cueRecordings.values.any((paths) => paths.contains(path)),
        )) {
      return;
    }
    final recordings = [...standaloneRecordings];
    final previous = {
      for (final i in items)
        i: (
          recordings: [...i.recordings],
          cueRecordings: i.cueRecordings.map(
            (id, paths) => MapEntry(id, [...paths]),
          ),
          cueIds: i.cues.map((cue) => cue.id).toSet(),
        ),
    };
    standaloneRecordings.remove(path);
    for (final item in items) {
      item.detachRecording(path);
    }
    try {
      await _persist();
    } catch (_) {
      standaloneRecordings = _restorePath(
        standaloneRecordings,
        recordings,
        path,
      );
      for (final entry in previous.entries) {
        final item = entry.key;
        item.recordings = _restorePath(
          item.recordings,
          entry.value.recordings,
          path,
        );
        final references = {...item.cueRecordings};
        for (final cue in entry.value.cueRecordings.entries) {
          if (entry.value.cueIds.contains(cue.key) &&
              !item.cues.any((c) => c.id == cue.key)) {
            continue;
          }
          if (cue.value.contains(path)) {
            references[cue.key] = _restorePath(
              references[cue.key] ?? [],
              cue.value,
              path,
            );
          }
        }
        item.cueRecordings = references;
      }
      rethrow;
    }
    notifyListeners();
    if (!_referencesPath(path)) await _deleteOwned(path);
  });

  bool _referencesPath(String path) =>
      standaloneRecordings.contains(path) ||
      sidecars.any((s) => s['path'] == path) ||
      items.any(
        (i) =>
            i.path == path ||
            i.recordings.contains(path) ||
            i.cueRecordings.values.any((paths) => paths.contains(path)),
      );

  static List<String> _restorePath(
    List<String> current,
    List<String> before,
    String path,
  ) {
    if (!before.contains(path) || current.contains(path)) return current;
    final restored = [...current];
    final index = before.indexOf(path);
    restored.insert(index < restored.length ? index : restored.length, path);
    return restored;
  }

  Future<void> _deleteOwned(String path) async {
    final file = File(path);
    if (!await file.exists()) return;
    final root = await repository.root.resolveSymbolicLinks();
    final resolved = await file.resolveSymbolicLinks();
    if (!resolved.startsWith('$root${Platform.pathSeparator}') ||
        resolved.split(Platform.pathSeparator).contains('..')) {
      return;
    }
    if (await file.exists()) await file.delete();
  }

  void opened(MediaItem item) {
    recent = [
      item.id,
      ...recent.where((id) => id != item.id),
    ].take(100).toList();
  }

  static String dateKey(DateTime at) =>
      '${at.year}-${at.month.toString().padLeft(2, '0')}-${at.day.toString().padLeft(2, '0')}';
  void addStudy(int seconds, DateTime at) {
    if (seconds <= 0) return;
    final key = dateKey(at);
    studySeconds[key] = (studySeconds[key] ?? 0) + seconds;
  }
}
