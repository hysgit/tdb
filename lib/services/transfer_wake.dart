import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';

/// One operation's ownership of the idle-timer suppression request.
class TransferWakeLease {
  TransferWakeLease._(this._release);
  final Future<void> Function() _release;
  Future<void>? _releasing;
  bool _released = false;

  Future<void> release() {
    if (_released) return Future.value();
    return _releasing ??= _release()
        .then((_) {
          _released = true;
        })
        .whenComplete(() {
          _releasing = null;
        });
  }
}

/// Serializes native updates while each asynchronous task owns its own lease.
class TransferWakeController {
  TransferWakeController(this._writeActive);
  final Future<void> Function(bool) _writeActive;
  Future<void>? _updates;
  int _leases = 0;
  bool _legacyActive = false;
  bool? _applied = false;

  Future<void> _sync() {
    final next = (_updates ?? Future<void>.value()).then((_) async {
      final active = _legacyActive || _leases > 0;
      if (active == _applied) return;
      try {
        await _writeActive(active);
        _applied = active;
      } catch (_) {
        // An error does not prove the native side kept its previous state.
        _applied = null;
        rethrow;
      }
    });
    final recovered = next.catchError((Object _) {});
    _updates = recovered;
    unawaited(
      recovered.then((_) {
        if (identical(_updates, recovered)) _updates = null;
      }),
    );
    return next;
  }

  /// Compatibility ownership for the existing single WiFi-transfer page.
  Future<void> setActive(bool active) {
    _legacyActive = active;
    return _sync();
  }

  Future<TransferWakeLease> acquire() async {
    _leases++;
    try {
      await _sync();
    } catch (_) {
      _leases--;
      await _sync().catchError((Object _) {});
      rethrow;
    }
    var removed = false;
    return TransferWakeLease._(() {
      if (!removed) {
        removed = true;
        _leases--;
      }
      return _sync();
    });
  }
}

class TransferWake {
  static const _channel = MethodChannel('tingdubao/transfer');
  static final _controller = TransferWakeController((active) async {
    if (Platform.isIOS || Platform.isAndroid) {
      await _channel.invokeMethod<void>('setActive', active);
    }
  });

  static Future<void> setActive(bool active) => _controller.setActive(active);
  static Future<TransferWakeLease> acquire() => _controller.acquire();
}
