import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tingdubao/services/wifi_transfer.dart';

void main() {
  late WifiTransfer transfer;
  late HttpClient client;

  setUp(() {
    transfer = WifiTransfer();
    client = HttpClient()..findProxy = (_) => 'DIRECT';
  });

  tearDown(() async {
    client.close(force: true);
    await transfer.stop();
  });

  Future<Uri> start(Future<void> Function(String, String) onFile) async {
    final addresses = await transfer.start(onFile);
    expect(addresses, isNotEmpty);
    final address = Uri.parse(addresses.first);
    return address.replace(host: InternetAddress.loopbackIPv4.address);
  }

  Future<HttpClientResponse> upload(
    Uri base,
    String name,
    List<int> bytes,
  ) async {
    final uri = base.resolve('upload').replace(queryParameters: {'name': name});
    final request = await client.putUrl(uri);
    request.add(bytes);
    return request.close();
  }

  Future<void> eventually(bool Function() condition) async {
    for (var attempt = 0; attempt < 100 && !condition(); attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(condition(), isTrue);
  }

  Future<String> readOversizedReply(Socket socket) {
    final result = Completer<String>();
    final buffer = StringBuffer();
    utf8.decoder
        .bind(socket)
        .listen(
          (chunk) {
            buffer.write(chunk);
            if (!result.isCompleted && buffer.toString().contains('256 MiB')) {
              result.complete(buffer.toString());
            }
          },
          onError: (Object error) {
            if (!result.isCompleted) result.completeError(error);
          },
          onDone: () {
            if (!result.isCompleted) result.complete(buffer.toString());
          },
        );
    return result.future;
  }

  test(
    'serves a Chinese upload page without opening CORS or directory listings',
    () async {
      final base = await start((_, _) async {});
      expect(transfer.running, isTrue);
      final request = await client.getUrl(base);
      final response = await request.close();
      final page = await utf8.decoder.bind(response).join();
      expect(response.statusCode, HttpStatus.ok);
      expect(response.headers.contentType?.mimeType, 'text/html');
      expect(response.headers.value('access-control-allow-origin'), isNull);
      expect(response.headers.value('cache-control'), 'no-store');
      expect(page, contains('听读宝 Wi-Fi 传输'));
      expect(page, contains('multiple'));
      expect(page, contains('textContent'));
      expect(page, isNot(contains('innerHTML')));
      expect(base.pathSegments.first.length, greaterThanOrEqualTo(40));

      for (final path in ['/', '/wrong-token/', '${base.path}anything']) {
        final denied = await client.getUrl(base.replace(path: path));
        final result = await denied.close();
        expect(result.statusCode, HttpStatus.notFound);
        await result.drain<void>();
      }
    },
  );

  test(
    'uploads exact bytes and waits for import before acknowledging success',
    () async {
      final entered = Completer<void>();
      final release = Completer<void>();
      String? temporaryPath;
      final content = utf8.encode('[00:01.00]你好');
      final base = await start((path, filename) async {
        temporaryPath = path;
        expect(filename, '字幕.LRC');
        expect(await File(path).readAsBytes(), content);
        entered.complete();
        await release.future;
      });
      var acknowledged = false;
      final pending = upload(base, '字幕.LRC', content).then((value) {
        acknowledged = true;
        return value;
      });
      await entered.future;
      expect(acknowledged, isFalse);
      expect(File(temporaryPath!).existsSync(), isTrue);
      release.complete();
      final response = await pending;
      expect(response.statusCode, HttpStatus.ok);
      await response.drain<void>();
      await eventually(() => !File(temporaryPath!).existsSync());
    },
  );

  test('rejects unsupported and unsafe filenames without importing', () async {
    var imported = false;
    final base = await start((_, _) async => imported = true);
    for (final name in [
      '../escape.mp3',
      r'folder\escape.mp3',
      'a/b.mp3',
      'a..mp3',
      '.mp3',
      'script.html',
      'archive.zip',
      '',
      'bad\u0000.mp3',
    ]) {
      final response = await upload(base, name, [1, 2, 3]);
      expect(response.statusCode, HttpStatus.badRequest, reason: name);
      await response.drain<void>();
    }
    expect(imported, isFalse);
  });

  test('rejects an empty file and unsupported request methods', () async {
    var imports = 0;
    final base = await start((_, _) async => imports++);
    final response = await upload(base, 'empty.mp3', []);
    expect(response.statusCode, HttpStatus.badRequest);
    await response.drain<void>();
    final request = await client.openUrl('OPTIONS', base.resolve('upload'));
    final options = await request.close();
    expect(options.statusCode, HttpStatus.methodNotAllowed);
    expect(options.headers.value('access-control-allow-origin'), isNull);
    await options.drain<void>();
    expect(imports, 0);
  });

  test(
    'rejects a declared file over 256 MiB before receiving its complete body',
    () async {
      var imported = false;
      final base = await start((_, _) async => imported = true);
      final socket = await Socket.connect(base.host, base.port);
      final reply = readOversizedReply(socket);
      socket.write(
        'PUT ${base.path}upload?name=large.mp3 HTTP/1.1\r\n'
        'Host: ${base.host}:${base.port}\r\n'
        'Content-Length: 268435457\r\nConnection: close\r\n\r\n',
      );
      socket.add([0]);
      await socket.flush();
      final response = await reply.timeout(const Duration(seconds: 10));
      expect(response, startsWith('HTTP/1.1 413'));
      expect(response, contains('256 MiB'));
      expect(imported, isFalse);
      socket.destroy();
    },
  );

  test(
    'concurrent files use distinct temporary paths and clean after import',
    () async {
      final paths = <String>[];
      final names = <String>[];
      final gate = Completer<void>();
      final base = await start((path, name) async {
        paths.add(path);
        names.add(name);
        if (paths.length == 2) gate.complete();
        await gate.future;
        expect(await File(path).readAsBytes(), name == 'first.mp3' ? [1] : [2]);
      });
      final results = await Future.wait([
        upload(base, 'first.mp3', [1]),
        upload(base, 'second.wav', [2]),
      ]);
      expect(paths.toSet(), hasLength(2));
      expect(names.toSet(), {'first.mp3', 'second.wav'});
      for (final response in results) {
        expect(response.statusCode, HttpStatus.ok);
        await response.drain<void>();
      }
      await eventually(() => paths.every((path) => !File(path).existsSync()));
    },
  );

  test(
    'import errors are readable, hide local paths, and remove temporary files',
    () async {
      String? path;
      final base = await start((temporary, _) async {
        path = temporary;
        throw FileSystemException('private error', temporary);
      });
      final response = await upload(base, 'example.mp3', [1]);
      expect(response.statusCode, HttpStatus.internalServerError);
      final message = await utf8.decoder.bind(response).join();
      expect(message, contains('上传或导入失败'));
      expect(message, isNot(contains('private error')));
      expect(message, isNot(contains(path!)));
      await eventually(() => !File(path!).existsSync());
    },
  );

  test(
    'an interrupted client removes its partial upload without importing it',
    () async {
      late Directory sessionDirectory;
      var imports = 0;
      final base = await start((path, _) async {
        sessionDirectory = File(path).parent.parent;
        imports++;
      });
      final warmup = await upload(base, 'warmup.mp3', [1]);
      await warmup.drain<void>();
      await eventually(() => sessionDirectory.listSync().isEmpty);

      final socket = await Socket.connect(base.host, base.port);
      socket.listen((_) {}, onError: (Object _) {});
      socket.write(
        'PUT ${base.path}upload?name=partial.mp3 HTTP/1.1\r\n'
        'Host: ${base.host}:${base.port}\r\nContent-Length: 1024\r\n\r\n',
      );
      socket.add([1, 2, 3]);
      await socket.flush();
      await eventually(() => sessionDirectory.listSync().isNotEmpty);
      socket.destroy();
      await eventually(() => sessionDirectory.listSync().isEmpty);
      expect(imports, 1);
    },
  );

  test('a chunked upload cannot bypass the streaming size limit', () async {
    late Directory sessionDirectory;
    var imports = 0;
    final base = await start((path, _) async {
      sessionDirectory = File(path).parent.parent;
      imports++;
    });
    final warmup = await upload(base, 'warmup.mp3', [1]);
    await warmup.drain<void>();
    await eventually(() => sessionDirectory.listSync().isEmpty);
    final socket = await Socket.connect(base.host, base.port);
    final reply = readOversizedReply(socket);
    socket.write(
      'PUT ${base.path}upload?name=chunked.mp3 HTTP/1.1\r\n'
      'Host: ${base.host}:${base.port}\r\n'
      'Transfer-Encoding: chunked\r\nConnection: close\r\n\r\n',
    );
    // Reuse one block so the test itself does not buffer a 257 MiB file.
    final block = List<int>.filled(1024 * 1024, 1);
    try {
      for (var index = 0; index < 257; index++) {
        socket.write('100000\r\n');
        socket.add(block);
        socket.write('\r\n');
        await socket.flush();
      }
      socket.write('0\r\n\r\n');
      await socket.flush();
    } on SocketException {
      // The receiver may close immediately after sending 413.
    }
    final response = await reply.timeout(const Duration(seconds: 30));
    expect(response, startsWith('HTTP/1.1 413'));
    expect(imports, 1);
    await eventually(() => sessionDirectory.listSync().isEmpty);
    socket.destroy();
  }, timeout: const Timeout(Duration(minutes: 1)));

  test(
    'stopping invalidates the old URL and restarting creates a new token',
    () async {
      final first = await start((_, _) async {});
      await transfer.stop();
      expect(transfer.running, isFalse);
      await expectLater(client.getUrl(first), throwsA(isA<SocketException>()));
      final second = await start((_, _) async {});
      expect(transfer.running, isTrue);
      expect(second.path, isNot(first.path));
      final request = await client.getUrl(second.replace(path: first.path));
      final response = await request.close();
      expect(response.statusCode, HttpStatus.notFound);
      await response.drain<void>();
    },
  );
}
