import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

/// Manually started, token-protected uploads from the local network.
class WifiTransfer {
  static const _maximumBytes = 256 * 1024 * 1024;
  static const _extensions = {
    'mp3',
    'm4a',
    'wav',
    'flac',
    'aac',
    'ogg',
    'opus',
    'mp4',
    'mov',
    'm4v',
    'webm',
    'lrc',
    'srt',
    'vtt',
    'txt',
    'json',
  };

  HttpServer? _server;
  Directory? _temporaryRoot;
  Future<List<String>>? _starting;
  Future<void>? _stopping;
  final Set<Future<void>> _requests = {};

  bool get running => _server != null;

  Future<List<String>> start(
    Future<void> Function(String temporaryPath, String filename) onFile,
  ) async {
    if (_stopping != null) await _stopping;
    return _starting ??= _start(onFile);
  }

  Future<List<String>> _start(
    Future<void> Function(String temporaryPath, String filename) onFile,
  ) async {
    try {
      final root = await Directory.systemTemp.createTemp('tingdubao-wifi-');
      _temporaryRoot = root;
      final server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
      _server = server;
      final random = Random.secure();
      final token = base64Url
          .encode(List.generate(32, (_) => random.nextInt(256)))
          .replaceAll('=', '');
      server.listen((request) {
        final operation = _handle(request, token, root, onFile);
        _requests.add(operation);
        unawaited(operation.whenComplete(() => _requests.remove(operation)));
      }, onError: (Object _) {});

      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      final addresses = interfaces
          .expand((network) => network.addresses)
          .where(_isLocal)
          .map((address) => address.address)
          .toSet();
      if (addresses.isEmpty) {
        addresses.add(InternetAddress.loopbackIPv4.address);
      }
      return [
        for (final address in addresses)
          'http://$address:${server.port}/$token/',
      ];
    } catch (_) {
      await _server?.close(force: true);
      _server = null;
      final root = _temporaryRoot;
      _temporaryRoot = null;
      if (root != null && await root.exists()) {
        await root.delete(recursive: true);
      }
      _starting = null;
      rethrow;
    }
  }

  Future<void> stop() async {
    if (_stopping != null) return _stopping;
    final operation = _stop();
    _stopping = operation;
    try {
      await operation;
    } finally {
      _stopping = null;
    }
  }

  Future<void> _stop() async {
    try {
      await _starting;
    } catch (_) {
      // A failed start already cleans its temporary directory.
    }
    final server = _server;
    _server = null;
    await server?.close(force: true);
    while (_requests.isNotEmpty) {
      await Future.wait(_requests.toList());
    }
    final root = _temporaryRoot;
    _temporaryRoot = null;
    if (root != null && await root.exists()) await root.delete(recursive: true);
    _starting = null;
  }

  static bool _isLocal(InternetAddress address) {
    if (address.type != InternetAddressType.IPv4) return false;
    final bytes = address.rawAddress;
    return bytes[0] == 10 ||
        bytes[0] == 127 ||
        (bytes[0] == 172 && bytes[1] >= 16 && bytes[1] <= 31) ||
        (bytes[0] == 192 && bytes[1] == 168) ||
        (bytes[0] == 169 && bytes[1] == 254);
  }

  Future<void> _handle(
    HttpRequest request,
    String token,
    Directory root,
    Future<void> Function(String temporaryPath, String filename) onFile,
  ) async {
    Directory? uploadDirectory;
    IOSink? sink;
    final response = request.response;
    response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
    response.headers.set('X-Content-Type-Options', 'nosniff');
    response.headers.set('Referrer-Policy', 'no-referrer');
    try {
      final address = request.connectionInfo?.remoteAddress;
      final path = request.uri.path;
      if (address == null ||
          !_isLocal(address) ||
          (path != '/$token/' && path != '/$token/upload')) {
        await _reply(response, HttpStatus.notFound, '地址无效，请使用当前传输页面显示的地址。');
        return;
      }
      if (request.method == 'GET' && path == '/$token/') {
        response.headers.contentType = ContentType.html;
        response.headers.set(
          'Content-Security-Policy',
          "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'; base-uri 'none'; frame-ancestors 'none'",
        );
        response.write(_page);
        await response.close();
        return;
      }
      if (request.method != 'PUT' || path != '/$token/upload') {
        await _reply(response, HttpStatus.methodNotAllowed, '不支持此操作。');
        return;
      }
      final filename = request.uri.queryParameters['name'] ?? '';
      if (!_validFilename(filename)) {
        await _reply(response, HttpStatus.badRequest, '文件名或文件类型不支持。');
        return;
      }
      if (request.contentLength > _maximumBytes) {
        // HttpServer otherwise waits for its implicit drain before sending
        // response headers. Start discarding now so 413 can arrive promptly.
        unawaited(request.drain<void>().catchError((Object _) {}));
        await _reply(
          response,
          HttpStatus.requestEntityTooLarge,
          '文件超过 256 MiB 上限。',
        );
        return;
      }
      uploadDirectory = await root.createTemp('upload-');
      final file = File(
        '${uploadDirectory.path}${Platform.pathSeparator}upload',
      );
      final output = file.openWrite();
      sink = output;
      var size = 0;
      var buffered = 0;
      var oversized = false;
      await for (final bytes in request) {
        if (oversized) continue;
        size += bytes.length;
        if (size > _maximumBytes) {
          oversized = true;
          await output.close();
          sink = null;
          await uploadDirectory.delete(recursive: true);
          await _reply(
            response,
            HttpStatus.requestEntityTooLarge,
            '文件超过 256 MiB 上限。',
            finish: false,
          );
          // Keep draining so cancelling the request stream cannot reset the
          // connection before the client receives its 413 response.
          continue;
        }
        output.add(bytes);
        buffered += bytes.length;
        // Bound queued disk writes without forcing a flush for every packet.
        if (buffered >= 1024 * 1024) {
          await output.flush();
          buffered = 0;
        }
      }
      if (oversized) {
        await response.close();
        return;
      }
      await output.close();
      sink = null;
      if (size == 0) {
        await _reply(response, HttpStatus.badRequest, '文件为空，请重新选择文件。');
        return;
      }
      await onFile(file.path, filename);
      await _reply(response, HttpStatus.ok, '导入完成。');
    } catch (_) {
      try {
        await _reply(
          response,
          HttpStatus.internalServerError,
          '上传或导入失败，请重新上传。',
        );
      } catch (_) {
        // The client may have disconnected before receiving the response.
      }
    } finally {
      try {
        await sink?.close();
      } catch (_) {
        // An interrupted stream can have already closed its file sink.
      }
      if (uploadDirectory != null && await uploadDirectory.exists()) {
        await uploadDirectory.delete(recursive: true);
      }
    }
  }

  static bool _validFilename(String name) {
    if (name.isEmpty ||
        name.length > 255 ||
        name.contains('..') ||
        name.contains('/') ||
        name.contains(r'\') ||
        name.runes.any((value) => value < 32 || value == 127)) {
      return false;
    }
    final dot = name.lastIndexOf('.');
    return dot > 0 &&
        _extensions.contains(name.substring(dot + 1).toLowerCase());
  }

  static Future<void> _reply(
    HttpResponse response,
    int status,
    String message, {
    bool finish = true,
  }) async {
    response.statusCode = status;
    response.headers.contentType = ContentType(
      'text',
      'plain',
      charset: 'utf-8',
    );
    response.contentLength = utf8.encode(message).length;
    response.write(message);
    await response.flush();
    if (finish) await response.close();
  }

  static const _page = '''<!doctype html>
<html lang="zh-CN"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>听读宝 Wi-Fi 传输</title>
<style>body{font:17px system-ui;max-width:640px;margin:60px auto;padding:0 24px;color:#252525}h1{font-size:28px}input,button{font:inherit;margin:12px 0}button{background:#ff902c;border:0;border-radius:10px;padding:12px 24px}li{margin:12px 0;overflow-wrap:anywhere}</style>
</head><body><h1>听读宝 Wi-Fi 传输</h1>
<p>选择音视频或字幕文件，每个文件最多 256 MiB。请保持手机传输页面开启。</p>
<input id="files" type="file" multiple accept=".mp3,.m4a,.wav,.flac,.aac,.ogg,.opus,.mp4,.mov,.m4v,.webm,.lrc,.srt,.vtt,.txt,.json">
<br><button id="send">开始上传</button><ul id="results"></ul>
<script>
const input=document.getElementById('files');
const send=document.getElementById('send');
send.addEventListener('click',async()=>{
 send.disabled=true;
 try {
  for(const file of input.files){
   const row=document.createElement('li');
   document.getElementById('results').appendChild(row);
   row.textContent=file.name+'：上传中…';
   if(file.size>268435456){row.textContent=file.name+'：文件超过 256 MiB 上限';continue;}
   try {
    const response=await fetch('upload?name='+encodeURIComponent(file.name),{method:'PUT',body:file});
    const message=await response.text();
    row.textContent=file.name+'：'+(response.ok?message:'失败，'+message);
   }catch(error){row.textContent=file.name+'：连接中断，请确认手机仍在传输页面后重试';}
  }
 }finally{send.disabled=false;}
});
</script></body></html>''';
}
