import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

enum DeviceActionType { play, pause, upload }

class DeviceAction {
  const DeviceAction({required this.type, this.mediaId, this.id});
  final DeviceActionType type;
  final String? mediaId;
  final String? id;

  factory DeviceAction.fromMap(Map<Object?, Object?> value) {
    final type = value['type'];
    final mediaId = value['mediaId'];
    final id = value['id'];
    if (type is! String ||
        !DeviceActionType.values.any((entry) => entry.name == type) ||
        (mediaId != null && (mediaId is! String || mediaId.trim().isEmpty)) ||
        (id != null && (id is! String || id.isEmpty))) {
      throw const FormatException('系统返回的操作无效。');
    }
    return DeviceAction(
      type: DeviceActionType.values.byName(type),
      mediaId: mediaId as String?,
      id: id as String?,
    );
  }
}

/// iOS system tools. No constructor or handler registration asks permission.
/// Scheduled media only starts after the user taps its system notification.
class DeviceTools {
  DeviceTools({
    MethodChannel channel = const MethodChannel('tingdubao/utilities'),
  }) : _channel = channel;
  final MethodChannel _channel;

  bool get supported => !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  void _requireIOS() {
    if (!supported) throw UnsupportedError('此系统工具目前仅支持 iOS。');
  }

  Future<void> lookup(String word) async {
    final term = word.trim();
    if (term.isEmpty ||
        term.runes.length > 256 ||
        RegExp(r'[\x00-\x1f\x7f]').hasMatch(term)) {
      throw ArgumentError('请输入有效的查词内容。');
    }
    _requireIOS();
    await _channel.invokeMethod<void>('lookup', {'word': term});
  }

  /// Returns false when the user cancels the native share sheet.
  Future<bool> share(String text) async {
    if (text.trim().isEmpty) throw ArgumentError('分享内容不能为空。');
    _requireIOS();
    final completed = await _channel.invokeMethod<bool>('share', {
      'text': text,
    });
    if (completed == null) throw const FormatException('系统未返回分享结果。');
    return completed;
  }

  Future<void> openUrl(Uri uri) async {
    if (!['http', 'https'].contains(uri.scheme.toLowerCase()) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      throw ArgumentError('仅支持有效的 http 或 https 网页地址。');
    }
    _requireIOS();
    await _channel.invokeMethod<void>('openUrl', {'url': uri.toString()});
  }

  Future<void> schedule({
    required String id,
    required String title,
    required String body,
    required DateTime at,
    String? mediaId,
  }) async {
    final identifier = _notificationId(id);
    if (title.trim().isEmpty || !at.isAfter(DateTime.now())) {
      throw ArgumentError('通知标题不能为空，时间必须晚于当前时间。');
    }
    if (mediaId != null &&
        (mediaId.trim().isEmpty || mediaId.runes.length > 512)) {
      throw ArgumentError('媒体 ID 无效。');
    }
    _requireIOS();
    await _channel.invokeMethod<void>('schedule', {
      'id': identifier,
      'title': title,
      'body': body,
      'atMilliseconds': at.millisecondsSinceEpoch,
      'mediaId': ?mediaId,
    });
  }

  Future<void> cancelNotification(String id) async {
    final identifier = _notificationId(id);
    _requireIOS();
    await _channel.invokeMethod<void>('cancelNotification', {'id': identifier});
  }

  Future<DeviceAction?> pendingAction() async {
    _requireIOS();
    final action = await _channel.invokeMapMethod<Object?, Object?>(
      'pendingAction',
    );
    return action == null ? null : DeviceAction.fromMap(action);
  }

  /// Install before fetching pendingAction; successful completion acknowledges
  /// an incoming action. Native errors retain its latest pending action.
  void setActionHandler(FutureOr<void> Function(DeviceAction)? handler) {
    if (handler != null) _requireIOS();
    _channel.setMethodCallHandler(
      handler == null
          ? null
          : (call) async {
              if (call.method != 'action') {
                throw MissingPluginException('Unsupported device action.');
              }
              if (call.arguments is! Map) {
                throw const FormatException('系统返回的操作无效。');
              }
              await handler(
                DeviceAction.fromMap(
                  Map<Object?, Object?>.from(call.arguments as Map),
                ),
              );
            },
    );
  }

  void dispose() => _channel.setMethodCallHandler(null);

  static String _notificationId(String value) {
    final id = value.trim();
    if (id.isEmpty ||
        id.runes.length > 128 ||
        RegExp(r'[\x00-\x1f\x7f]').hasMatch(id)) {
      throw ArgumentError('通知 ID 无效。');
    }
    return id;
  }
}
