import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

typedef TransferAddress = ({String name, String address});

/// Foreground LAN uploads. The page supplies the session token to its client.
class WifiTransfer {
  WifiTransfer({
    Future<List<TransferAddress>> Function()? addressProvider,
    int? preferredPort,
    bool? isIOS,
  }) : _addressProvider = addressProvider ?? _interfaceAddresses,
       _preferredPort = preferredPort ?? (Platform.isIOS ? 80 : 8080),
       _isIOS = isIOS ?? Platform.isIOS;

  final Future<List<TransferAddress>> Function() _addressProvider;
  final int _preferredPort;
  final bool _isIOS;
  final _changes = StreamController<void>.broadcast();
  Stream<void> get changes => _changes.stream;
  int requestsReceived = 0;
  int filesImported = 0;
  String? lastError;

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
    final existing = _starting;
    if (existing != null) return existing;
    final operation = _start(onFile);
    _starting = operation;
    try {
      return await operation;
    } catch (_) {
      if (identical(_starting, operation)) _starting = null;
      rethrow;
    }
  }

  Future<List<String>> _start(
    Future<void> Function(String temporaryPath, String filename) onFile,
  ) async {
    try {
      final address = chooseLanAddress(await _addressProvider(), isIOS: _isIOS);
      if (address == null) {
        throw StateError('未检测到可供电脑访问的 Wi-Fi 地址，请连接 Wi-Fi 后重试。');
      }
      final root = await Directory.systemTemp.createTemp('tingdubao-wifi-');
      _temporaryRoot = root;
      HttpServer server;
      try {
        server = await HttpServer.bind(address, _preferredPort);
      } on SocketException {
        if (_preferredPort == 0) rethrow;
        server = await HttpServer.bind(address, 0);
      }
      _server = server;
      requestsReceived = 0;
      filesImported = 0;
      lastError = null;
      _notify();
      final random = Random.secure();
      final token = base64Url
          .encode(List.generate(32, (_) => random.nextInt(256)))
          .replaceAll('=', '');
      server.listen((request) {
        final operation = _handle(request, token, root, onFile);
        _requests.add(operation);
        unawaited(operation.whenComplete(() => _requests.remove(operation)));
      }, onError: (Object _) {});

      return ['http://$address${server.port == 80 ? '' : ':${server.port}'}/'];
    } catch (_) {
      await _server?.close(force: true);
      _server = null;
      final root = _temporaryRoot;
      _temporaryRoot = null;
      if (root != null && await root.exists()) {
        await root.delete(recursive: true);
      }
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
    _notify();
  }

  Future<void> dispose() async {
    await stop();
    await _changes.close();
  }

  void _notify() {
    if (!_changes.isClosed) _changes.add(null);
  }

  static Future<List<TransferAddress>> _interfaceAddresses() async => [
    for (final network in await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
    ))
      for (final address in network.addresses)
        (name: network.name, address: address.address),
  ];

  static String? chooseLanAddress(
    List<TransferAddress> interfaces, {
    required bool isIOS,
  }) {
    final candidates = interfaces.where((entry) {
      final name = entry.name.toLowerCase();
      if (RegExp(
            r'^(lo\d*|pdp_ip|rmnet|utun|tun|tap|wg\d|ipsec)',
          ).hasMatch(name) ||
          RegExp(
            r'vethernet|virtualbox|vmware|wireguard|tailscale',
          ).hasMatch(name)) {
        return false;
      }
      final ip = InternetAddress.tryParse(entry.address);
      if (ip == null || ip.type != InternetAddressType.IPv4 || ip.isLoopback) {
        return false;
      }
      if (!_isLocal(ip) || ip.rawAddress[0] == 169) return false;
      return !isIOS || name == 'en0' || name == 'ap1' || name == 'bridge100';
    }).toList();
    int rank(String name) =>
        RegExp(
          r'^(en0|wlan|wifi)|wi-fi|wireless|无线',
          caseSensitive: false,
        ).hasMatch(name)
        ? 0
        : 1;
    candidates.sort((a, b) => rank(a.name).compareTo(rank(b.name)));
    return candidates.isEmpty ? null : candidates.first.address;
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
      requestsReceived++;
      _notify();
      if (address == null ||
          !_isLocal(address) ||
          (path != '/' && path != '/$token/' && path != '/$token/upload')) {
        await _reply(response, HttpStatus.notFound, '地址无效，请使用当前传输页面显示的地址。');
        return;
      }
      if (request.method == 'GET' && (path == '/' || path == '/$token/')) {
        response.headers.contentType = ContentType.html;
        response.headers.set(
          'Content-Security-Policy',
          "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'; base-uri 'none'; frame-ancestors 'none'",
        );
        response.write(_page.replaceAll('__UPLOAD_PATH__', '/$token/upload'));
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
      filesImported++;
      lastError = null;
      _notify();
      await _reply(response, HttpStatus.ok, '导入完成。');
    } catch (error) {
      final message = error is StateError
          ? error.message.toString()
          : error is FormatException
          ? '字幕格式无法识别，请使用 UTF-8 字幕文件。'
          : '上传或导入失败，请重新上传。';
      lastError = message;
      _notify();
      try {
        await _reply(
          response,
          error is StateError || error is FormatException
              ? HttpStatus.badRequest
              : HttpStatus.internalServerError,
          message,
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
<title>Tdb Wi-Fi 传输</title>
<style>body{font:17px system-ui;max-width:640px;margin:60px auto;padding:0 24px;color:#252525}h1{font-size:28px}input,button{font:inherit;margin:12px 0}button{background:#ff902c;border:0;border-radius:10px;padding:12px 24px}li{margin:12px 0;overflow-wrap:anywhere}</style>
</head><body data-upload-path="__UPLOAD_PATH__"><h1>Tdb Wi-Fi 传输</h1>
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
    const response=await fetch(document.body.dataset.uploadPath+'?name='+encodeURIComponent(file.name),{method:'PUT',body:file});
    const message=await response.text();
    row.textContent=file.name+'：'+(response.ok?message:'失败，'+message);
   }catch(error){row.textContent=file.name+'：连接中断，请确认手机仍在传输页面后重试';}
  }
 }finally{send.disabled=false;}
});
</script></body></html>''';
}
