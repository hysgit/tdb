import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'services/wifi_transfer.dart';

class WifiTransferPage extends StatelessWidget {
  const WifiTransferPage({
    super.key,
    required this.url,
    required this.transfer,
  });
  final String url;
  final WifiTransfer transfer;

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: const Color(0xFFF0F0F4),
    appBar: AppBar(title: const Text('批量上传'), backgroundColor: Colors.white),
    body: SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          const SizedBox(height: 36),
          const Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              Icon(Icons.smartphone, size: 80, color: Color(0xFF444444)),
              Icon(Icons.wifi, size: 70, color: Color(0xFF32A5CF)),
              Icon(Icons.desktop_mac, size: 100, color: Color(0xFF444444)),
            ],
          ),
          const SizedBox(height: 52),
          const Text(
            '1. 确保 iPhone 和电脑连接同一个 Wi-Fi 网络。\n2. 传输过程中保持此页面开启。退出或手动锁屏会中断传输。',
            style: TextStyle(
              color: Color(0xFF737378),
              height: 1.6,
              fontSize: 14,
            ),
          ),
          const SizedBox(height: 32),
          const Divider(),
          const SizedBox(height: 24),
          const Text('访问地址，点击复制：', textAlign: TextAlign.center),
          InkWell(
            onTap: () async {
              await Clipboard.setData(ClipboardData(text: url));
              if (context.mounted) {
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(const SnackBar(content: Text('地址已复制')));
              }
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(
                url,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 21,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
          const SizedBox(height: 28),
          StreamBuilder<void>(
            stream: transfer.changes,
            builder: (context, _) => Column(
              children: [
                Text(
                  transfer.requestsReceived == 0
                      ? '等待电脑连接'
                      : '已收到 ${transfer.requestsReceived} 次连接请求',
                  style: const TextStyle(color: Color(0xFF777777)),
                ),
                if (transfer.filesImported > 0)
                  Text(
                    '已导入 ${transfer.filesImported} 个文件',
                    style: const TextStyle(color: Color(0xFFDC601D)),
                  ),
                if (transfer.lastError != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(
                      transfer.lastError!,
                      style: const TextStyle(color: Colors.red),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 28),
          const Divider(),
        ],
      ),
    ),
  );
}
