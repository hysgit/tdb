import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:tingdubao/import_page.dart';

void main() {
  for (final width in [320.0, 390.0]) {
    testWidgets(
      'all current import choices dispatch their source at width $width',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = Size(width, 844);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final selected = <ImportSource>[];
        var help = 0;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              appBar: AppBar(title: const Text('添加')),
              body: ImportPage(onSelect: selected.add, onHelp: () => help++),
            ),
          ),
        );
        expect(find.text('推荐'), findsOneWidget);
        for (final text in [
          'WiFi批量导入',
          '从 Apple Music 应用导入',
          'iCloud 导入',
          'OneDrive',
          '相册导入',
          '从 iTunes 导入',
          '从 NAS 下载',
        ]) {
          await tester.tap(find.text(text));
        }
        expect(selected, ImportSource.values);
        await tester.tap(find.text('帮助'));
        expect(help, 1);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}
