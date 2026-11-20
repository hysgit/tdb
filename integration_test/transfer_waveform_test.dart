import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path_provider/path_provider.dart';
import 'package:tingdubao/library.dart';
import 'package:tingdubao/services/transfer_wake.dart';
import 'package:tingdubao/services/waveform.dart';
import 'package:tingdubao/services/wifi_transfer.dart';

/// Run through scripts/run_ios_transfer_probe.py on a booted iOS simulator.
/// The host must use the LAN URL published by the app, without loopback rewriting.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'Darwin LAN upload persists original bytes and decodes a real waveform',
    (tester) async {
      expect(
        Platform.isIOS,
        isTrue,
        reason: 'This probe requires the real iOS runtime.',
      );
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Center(child: Text('Tdb iOS transfer and waveform probe')),
          ),
        ),
      );
      await tester.pump();

      await tester.runAsync(() async {
        final asset = await rootBundle.load('assets/demo/Introduction.mp3');
        final expected = asset.buffer.asUint8List(
          asset.offsetInBytes,
          asset.lengthInBytes,
        );
        expect(expected, isNotEmpty);
        final root = await (await getTemporaryDirectory()).createTemp(
          'tdb-ios-probe-',
        );
        final repository = LibraryRepository(root);
        final transfer = WifiTransfer(preferredPort: 0);
        final received = Completer<String>();
        var activeImports = 0;
        var wakeAttempted = false;
        var stopped = false;
        var waveformStarted = false;
        var waveformFinished = false;
        try {
          wakeAttempted = true;
          await TransferWake.setActive(
            true,
          ).timeout(const Duration(seconds: 15));
          final urls = await transfer
              .start((temporaryPath, filename) async {
                activeImports++;
                try {
                  if (received.isCompleted) {
                    throw StateError('The probe accepts exactly one upload.');
                  }
                  expect(filename, 'Introduction.mp3');
                  final path = await repository.importFile(
                    temporaryPath,
                    filename,
                  );
                  final item = MediaItem(
                    id: 'ios-transfer-probe',
                    name: filename,
                    path: path,
                  );
                  await repository.write({
                    'items': [item.toJson()],
                  });
                  final saved = await repository.read();
                  expect(saved, isNotNull);
                  final items = saved!['items'] as List;
                  expect(items, hasLength(1));
                  final restored = MediaItem.fromJson(
                    Map<String, dynamic>.from(items.single as Map),
                  );
                  expect(restored.name, filename);
                  expect(restored.path, path);
                  expect(
                    listEquals(
                      await File(restored.path).readAsBytes(),
                      expected,
                    ),
                    isTrue,
                    reason:
                        'The saved media must preserve every original byte.',
                  );
                  received.complete(restored.path);
                } catch (error, stack) {
                  if (!received.isCompleted) {
                    received.completeError(error, stack);
                  }
                  rethrow;
                } finally {
                  activeImports--;
                }
              })
              .timeout(const Duration(seconds: 30));
          expect(urls, hasLength(1));
          final uri = Uri.parse(urls.single);
          expect(uri.path, '/');
          expect(uri.query, isEmpty);
          expect(
            InternetAddress(uri.host).isLoopback,
            isFalse,
            reason: 'The host must reach the discovered LAN address.',
          );
          debugPrint('TDB_WIFI_E2E_URL=${urls.single}');
          final imported = await received.future.timeout(
            const Duration(seconds: 90),
          );
          // Host performs this final GET only after receiving the upload's 200.
          // Waiting before decoding avoids closing the server ahead of its PUT reply.
          if (transfer.requestsReceived < 3) {
            await transfer.changes
                .firstWhere((_) => transfer.requestsReceived >= 3)
                .timeout(const Duration(seconds: 30));
          }
          expect(transfer.filesImported, 1);
          expect(activeImports, 0);
          waveformStarted = true;
          final waveform = await WaveformService()
              .load(imported)
              .timeout(const Duration(seconds: 90));
          waveformFinished = true;
          expect(waveform.length, greaterThan(0));
          expect(waveform.sampleRate, greaterThan(0));
          expect(
            waveform.data.length,
            greaterThanOrEqualTo(waveform.length * 2),
          );
          expect(
            waveform.data.any((sample) => sample != 0),
            isTrue,
            reason:
                'The bundled spoken audio must decode to nonzero native samples.',
          );
          debugPrint(
            'TDB_WIFI_E2E_OK bytes=${expected.length} samples=${waveform.length}',
          );
        } finally {
          try {
            await transfer.dispose().timeout(const Duration(seconds: 15));
            stopped = true;
          } finally {
            try {
              if (wakeAttempted) {
                await TransferWake.setActive(
                  false,
                ).timeout(const Duration(seconds: 15));
              }
            } finally {
              // A timed-out native decoder may still read the source. In that
              // failure case retain this isolated OS-temp directory for safety.
              if (stopped &&
                  activeImports == 0 &&
                  (!waveformStarted || waveformFinished)) {
                if (await root.exists()) await root.delete(recursive: true);
              }
            }
          }
        }
      });
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
