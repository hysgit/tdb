// Run with the Dart VM, not Flutter: dart scripts/wifi_browser_fixture.dart
// LibraryState imports dart:ui, so this fixture deliberately uses a copy ledger.
// The real WifiTransfer server and its default LAN-address selection are used.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:tingdubao/models.dart';
import 'package:tingdubao/services/wifi_transfer.dart';

class WifiFixtureLibrary {
  WifiFixtureLibrary._(this.root, this._files);
  final Directory root;
  List<Map<String, dynamic>> _files;
  Future<void> _imports = Future.value();

  static Future<WifiFixtureLibrary> open(Directory directory) async {
    await directory.create(recursive: true);
    for (final name in ['ledger.json', 'ledger.previous.json']) {
      final file = File('${directory.path}/$name');
      if (!await file.exists()) continue;
      try {
        final ledger =
            jsonDecode(await file.readAsString()) as Map<String, dynamic>;
        if (ledger['backend'] != 'pure-dart-copy-ledger') {
          throw const FormatException('Wrong fixture ledger');
        }
        return WifiFixtureLibrary._(
          directory,
          (ledger['files'] as List)
              .map((entry) => Map<String, dynamic>.from(entry as Map))
              .toList(),
        );
      } on FormatException {
        continue;
      }
    }
    return WifiFixtureLibrary._(directory, []);
  }

  Future<void> importFile(String source, String filename) {
    final next = _imports.then((_) => _importFile(source, filename));
    _imports = next.catchError((Object _) {});
    return next;
  }

  Future<void> _importFile(String source, String filename) async {
    if (filename.isEmpty ||
        filename.contains('..') ||
        filename.contains('/') ||
        filename.contains(r'\') ||
        filename.runes.any((rune) => rune < 32 || rune == 127)) {
      throw const FormatException('Invalid filename');
    }
    final extension = filename.split('.').last.toLowerCase();
    final subtitle = {'lrc', 'srt', 'vtt', 'txt', 'json'}.contains(extension);
    final cues = subtitle
        ? parseSubtitles(await File(source).readAsString(), format: extension)
        : <Cue>[];
    if (subtitle && cues.isEmpty) {
      throw const FormatException('No valid subtitles');
    }
    final directory = await root.createTemp('file_');
    final copied = await File(
      source,
    ).copy('${directory.path}${Platform.pathSeparator}$filename');
    final next = [
      ..._files,
      <String, dynamic>{
        'name': filename,
        'path': copied.absolute.path,
        'kind': subtitle ? 'subtitle' : 'media',
        'bytes': await copied.length(),
        if (subtitle) 'cues': cues.map((cue) => cue.toJson()).toList(),
      },
    ];
    final snapshot = jsonEncode({
      'version': 1,
      'backend': 'pure-dart-copy-ledger',
      'files': next,
    });
    final temporary = File('${root.path}/ledger.next.json');
    final current = File('${root.path}/ledger.json');
    final previous = File('${root.path}/ledger.previous.json');
    await temporary.writeAsString(snapshot, flush: true);
    if (await current.exists()) {
      if (await previous.exists()) await previous.delete();
      await current.rename(previous.path);
    }
    await temporary.rename(current.path);
    _files = next;
  }
}

Future<void> main() async {
  final directory = Directory.fromUri(
    Platform.script.resolve('../dist/wifi-browser-smoke/'),
  );
  final transfer = WifiTransfer(preferredPort: 0, isIOS: false);
  try {
    final library = await WifiFixtureLibrary.open(directory);
    final urls = await transfer.start((path, name) async {
      await library.importFile(path, name);
      stdout.writeln(name);
    });
    stdout.writeln(urls.single);
    await ProcessSignal.sigint.watch().first;
  } catch (error) {
    await directory.create(recursive: true);
    await File('${directory.path}/fixture-error.txt').writeAsString('$error');
    exitCode = 1;
  } finally {
    await transfer.dispose();
  }
}
