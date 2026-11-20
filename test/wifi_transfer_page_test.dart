import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:tingdubao/services/wifi_transfer.dart';
import 'package:tingdubao/wifi_transfer_page.dart';

void main() {
  testWidgets('one tap copies exactly the advertised single URL', (
    tester,
  ) async {
    String? copied;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData')
            copied = (call.arguments as Map)['text'] as String;
          return null;
        });
    const url = 'http://192.168.0.134:8080/';
    final transfer = WifiTransfer();
    await tester.pumpWidget(
      MaterialApp(
        home: WifiTransferPage(url: url, transfer: transfer),
      ),
    );
    await tester.tap(find.text(url));
    await tester.pumpAndSettle();
    expect(copied, url);
    expect(find.text('地址已复制'), findsOneWidget);
    expect(find.text('等待电脑连接'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await transfer.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });
}
