import 'dart:io';
import 'package:flutter/services.dart';

class TransferWake {
  static const _channel = MethodChannel('tingdubao/transfer');
  static Future<void> setActive(bool active) async {
    if (Platform.isIOS || Platform.isAndroid) {
      await _channel.invokeMethod<void>('setActive', active);
    }
  }
}
