import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:tingdubao/services/transfer_wake.dart';

void main() {
  test(
    'WiFi releasing its compatibility flag does not release recognition lease',
    () async {
      final writes = <bool>[];
      final wake = TransferWakeController((active) async {
        writes.add(active);
      });
      await wake.setActive(true);
      final recognition = await wake.acquire();
      await wake.setActive(false);
      expect(writes, [true]);
      await recognition.release();
      expect(writes, [true, false]);
    },
  );
  test(
    'overlapping leases release only after the last owner and are idempotent',
    () async {
      final writes = <bool>[];
      final wake = TransferWakeController((active) async {
        writes.add(active);
      });
      final first = await wake.acquire();
      final second = await wake.acquire();
      await Future.wait([first.release(), first.release()]);
      expect(writes, [true]);
      await second.release();
      await second.release();
      expect(writes, [true, false]);
    },
  );
  test(
    'activation is serialized while another owner joins during native await',
    () async {
      final activated = Completer<void>();
      final writes = <bool>[];
      final wake = TransferWakeController((active) async {
        writes.add(active);
        if (active) await activated.future;
      });
      final first = wake.acquire();
      await Future<void>.delayed(Duration.zero);
      final second = wake.acquire();
      activated.complete();
      final owners = await Future.wait([first, second]);
      expect(writes, [true]);
      await owners.first.release();
      expect(writes, [true]);
      await owners.last.release();
      expect(writes, [true, false]);
    },
  );
  test(
    'failed release remains retryable without removing the lease twice',
    () async {
      final writes = <bool>[];
      var fail = true;
      final wake = TransferWakeController((active) async {
        writes.add(active);
        if (!active && fail) {
          fail = false;
          throw StateError('native release failed');
        }
      });
      final lease = await wake.acquire();
      await expectLater(lease.release(), throwsStateError);
      await lease.release();
      final next = await wake.acquire();
      await next.release();
      expect(writes, [true, false, false, true, false]);
    },
  );
  test(
    'failed acquisition rolls back an uncertain native state and future work recovers',
    () async {
      final writes = <bool>[];
      var fail = true;
      final wake = TransferWakeController((active) async {
        writes.add(active);
        if (active && fail) {
          fail = false;
          throw StateError('native activation failed');
        }
      });
      await expectLater(wake.acquire(), throwsStateError);
      final next = await wake.acquire();
      await next.release();
      expect(writes, [true, false, true, false]);
    },
  );
}
