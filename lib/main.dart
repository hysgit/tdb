import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';

import 'library.dart';
import 'models.dart';
import 'player_view.dart';
import 'services/player.dart';
import 'services/wifi_transfer.dart';

const orange = Color(0xFFDC601D);
const paper = Color(0xFFF7F7F9);

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const TingdubaoApp());
}

class TingdubaoApp extends StatelessWidget {
  const TingdubaoApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Tdb',
    debugShowCheckedModeBanner: false,
    locale: const Locale('zh', 'CN'),
    supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    theme: ThemeData(
      colorScheme: ColorScheme.fromSeed(
        seedColor: orange,
        primary: orange,
        surface: Colors.white,
      ),
      scaffoldBackgroundColor: paper,
      appBarTheme: const AppBarTheme(
        backgroundColor: paper,
        surfaceTintColor: Colors.transparent,
      ),
      dividerTheme: const DividerThemeData(
        color: Color(0xFFE8E8ED),
        thickness: .7,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.white,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
      ),
      navigationBarTheme: const NavigationBarThemeData(
        backgroundColor: Colors.white,
        indicatorColor: Color(0xFFFFE8DA),
      ),
      useMaterial3: true,
    ),
    home: const StudyHome(),
  );
}

class StudyHome extends StatefulWidget {
  const StudyHome({super.key});
  @override
  State<StudyHome> createState() => _StudyHomeState();
}

class _StudyHomeState extends State<StudyHome> with WidgetsBindingObserver {
  final player = StudyPlayer();
  final transfer = WifiTransfer();
  final query = TextEditingController();
  final scaffoldKey = GlobalKey<ScaffoldMessengerState>();
  LibraryRepository? repository;
  List<MediaItem> items = [];
  Set<String> folders = {};
  String? folder, initError;
  bool booting = true, importing = false, reverseSort = false;
  int page = 0;
  Timer? autosave;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(initialize());
    autosave = Timer.periodic(const Duration(seconds: 10), (_) {
      if (!booting && initError == null) {
        unawaited(guard(save));
      }
    });
  }

  Future<void> initialize() async {
    try {
      repository ??= await LibraryRepository.open();
      final data = await repository!.read();
      if (data != null) {
        items = (data['items'] as List)
            .map((i) => MediaItem.fromJson(Map<String, dynamic>.from(i as Map)))
            .toList();
        folders = Set<String>.from(data['folders'] as List? ?? []);
        player.speed = (data['speed'] as num? ?? 1).toDouble().clamp(.1, 3);
      } else {
        final cues = parseSubtitles(
          await rootBundle.loadString('assets/demo/Introduction.json'),
          format: 'json',
        );
        items = [
          MediaItem(
            id: 'introduction',
            name: 'China · 听力练习',
            path: await repository!.installAsset('Introduction.mp3'),
            cues: cues,
          ),
          MediaItem(
            id: 'video-introduction',
            name: '视频教程',
            path: await repository!.installAsset('VideoIntroduction.mp4'),
          ),
        ];
        await repository!.write(snapshot());
      }
      initError = null;
    } catch (e) {
      initError = '无法读取学习资料：$e';
    }
    if (mounted) {
      setState(() {
        booting = false;
      });
    }
  }

  Map<String, dynamic> snapshot() => {
    'version': 1,
    'items': items.map((i) => i.toJson()).toList(),
    'folders': folders.toList(),
    'speed': player.speed,
  };
  Future<void> save() async {
    if (repository == null || initError != null) {
      return;
    }
    try {
      await repository!.write(snapshot());
    } catch (e) {
      throw FileSystemException('保存失败，请检查存储空间后重试：$e');
    }
  }

  void message(String text) {
    if (!mounted) {
      return;
    }
    scaffoldKey.currentState?.hideCurrentSnackBar();
    scaffoldKey.currentState?.showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> guard(Future<void> Function() action) async {
    try {
      await action();
    } catch (e) {
      message('操作未完成：$e');
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      unawaited(guard(save));
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    autosave?.cancel();
    unawaited(guard(save));
    unawaited(transfer.stop());
    player.dispose();
    query.dispose();
    super.dispose();
  }

  Future<String?> input(String title, {String initial = ''}) async {
    final controller = TextEditingController(text: initial);
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(labelText: title),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 300));
    controller.dispose();
    return result;
  }

  Future<void> importMedia() async {
    final result = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      type: FileType.custom,
      allowedExtensions: [
        'mp3',
        'm4a',
        'aac',
        'wav',
        'flac',
        'ogg',
        'opus',
        'mp4',
        'mov',
        'm4v',
        'webm',
      ],
    );
    if (result == null) {
      return;
    }
    if (!mounted) {
      return;
    }
    setState(() {
      importing = true;
    });
    try {
      for (final file in result.files) {
        if (file.path == null) {
          continue;
        }
        await receiveFile(file.path!, file.name);
      }
      message('已导入 ${result.files.length} 个文件');
    } finally {
      if (mounted) {
        setState(() {
          importing = false;
        });
      }
    }
  }

  Future<void> receiveFile(String source, String name) async {
    final ext = name.split('.').last.toLowerCase();
    if (['lrc', 'srt', 'vtt', 'txt', 'json'].contains(ext)) {
      final item = player.item;
      if (item == null) {
        throw StateError('请先在手机中打开需要添加字幕的文件');
      }
      final cues = parseSubtitles(
        await File(source).readAsString(),
        format: ext,
      );
      if (cues.isEmpty) {
        throw const FormatException('文件中没有有效字幕');
      }
      item.cues = cues;
      item.favorites = {};
      player.repeat.clear();
    } else {
      final path = await repository!.importFile(source, name);
      items.add(
        MediaItem(
          id: DateTime.now().microsecondsSinceEpoch.toString(),
          name: name,
          path: path,
          folder: folder ?? '',
        ),
      );
    }
    await save();
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> open(MediaItem item, {Cue? cue}) async {
    if (player.loading) {
      return;
    }
    await save();
    if (!mounted) {
      return;
    }
    setState(() {
      page = 1;
    });
    await player.open(item);
    if (cue != null) {
      await player.seek(cue.start);
      await player.play();
    }
  }

  @override
  Widget build(BuildContext context) => ScaffoldMessenger(
    key: scaffoldKey,
    child: ListenableBuilder(
      listenable: player,
      builder: (context, _) => Scaffold(
        appBar: AppBar(
          title: Text(
            ['Tdb', '播放', '收藏', '设置'][page],
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          actions: [
            if (page == 0)
              IconButton(
                tooltip: '新建文件夹',
                onPressed: booting
                    ? null
                    : () => guard(() async {
                        final name = await input('文件夹名称');
                        if (name != null && name.isNotEmpty && mounted) {
                          setState(() {
                            folders.add(name);
                          });
                          await save();
                        }
                      }),
                icon: const Icon(Icons.create_new_folder_outlined),
              ),
            if (page == 0)
              IconButton(
                tooltip: '导入音频或视频',
                onPressed: booting || importing
                    ? null
                    : () => guard(importMedia),
                icon: const Icon(Icons.add),
              ),
          ],
        ),
        body: SafeArea(
          top: false,
          child: booting
              ? const Center(child: CircularProgressIndicator())
              : initError != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(initError!),
                        const SizedBox(height: 16),
                        FilledButton(
                          onPressed: () => guard(initialize),
                          child: const Text('重试'),
                        ),
                      ],
                    ),
                  ),
                )
              : Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 900),
                    child: IndexedStack(
                      index: page,
                      children: [
                        libraryView,
                        PlayerView(
                          player: player,
                          onSave: save,
                          onMessage: message,
                        ),
                        favoritesView,
                        settingsView,
                      ],
                    ),
                  ),
                ),
        ),
        bottomNavigationBar: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (page != 1 && player.item != null) miniPlayer,
            NavigationBar(
              selectedIndex: page,
              onDestinationSelected: (value) => setState(() {
                page = value;
              }),
              destinations: const [
                NavigationDestination(
                  icon: Icon(Icons.folder_open_outlined),
                  selectedIcon: Icon(Icons.folder),
                  label: '文件',
                ),
                NavigationDestination(
                  icon: Icon(Icons.play_circle_outline),
                  selectedIcon: Icon(Icons.play_circle),
                  label: '播放',
                ),
                NavigationDestination(
                  icon: Icon(Icons.star_border_rounded),
                  selectedIcon: Icon(Icons.star_rounded),
                  label: '收藏',
                ),
                NavigationDestination(icon: Icon(Icons.tune), label: '设置'),
              ],
            ),
          ],
        ),
      ),
    ),
  );

  Widget get libraryView {
    final visible =
        items
            .where(
              (i) =>
                  (folder == null || i.folder == folder) &&
                  i.name.toLowerCase().contains(query.text.toLowerCase()),
            )
            .toList()
          ..sort(
            (a, b) => reverseSort
                ? b.name.compareTo(a.name)
                : a.name.compareTo(b.name),
          );
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
          child: TextField(
            controller: query,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
              hintText: '搜索音频、视频',
              prefixIcon: Icon(Icons.search),
            ),
          ),
        ),
        SizedBox(
          height: 48,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 20),
            children: [
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ChoiceChip(
                  label: const Text('全部文件'),
                  selected: folder == null,
                  onSelected: (_) => setState(() {
                    folder = null;
                  }),
                ),
              ),
              for (final name in folders)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(name),
                    selected: folder == name,
                    onSelected: (_) => setState(() {
                      folder = name;
                    }),
                  ),
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(left: 22, right: 10),
          child: Row(
            children: [
              Text(
                '${visible.length} 个文件',
                style: const TextStyle(color: Colors.black54),
              ),
              const Spacer(),
              TextButton.icon(
                onPressed: () => setState(() {
                  reverseSort = !reverseSort;
                }),
                icon: const Icon(Icons.sort_by_alpha, size: 18),
                label: Text(reverseSort ? '名称降序' : '名称升序'),
              ),
            ],
          ),
        ),
        if (importing) const LinearProgressIndicator(),
        Expanded(
          child: visible.isEmpty
              ? empty(Icons.library_music_outlined, '还没有文件', '点击右上角 ＋ 导入音频或视频')
              : ListView.separated(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  itemCount: visible.length,
                  separatorBuilder: (_, _) =>
                      const Divider(height: 1, indent: 72),
                  itemBuilder: (context, index) {
                    final item = visible[index];
                    return ListTile(
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 8,
                      ),
                      leading: Container(
                        width: 50,
                        height: 54,
                        decoration: BoxDecoration(
                          color: const Color(0xFFFFE8D8),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Icon(
                          item.isVideo
                              ? Icons.video_file_outlined
                              : Icons.audio_file_outlined,
                          color: orange,
                        ),
                      ),
                      title: Text(
                        item.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      subtitle: Text(
                        '${item.cues.isEmpty ? '无字幕' : '${item.cues.length} 句字幕'}  ·  ${item.positionMs == 0 ? '尚未播放' : '上次 ${formatTime(Duration(milliseconds: item.positionMs))}'}',
                        style: const TextStyle(
                          fontSize: 12,
                          color: Colors.black54,
                        ),
                      ),
                      onTap: () => guard(() => open(item)),
                      trailing: PopupMenuButton<String>(
                        tooltip: '文件操作',
                        onSelected: (value) =>
                            guard(() => fileAction(item, value)),
                        itemBuilder: (_) => const [
                          PopupMenuItem(value: 'rename', child: Text('重命名')),
                          PopupMenuItem(value: 'move', child: Text('移动到文件夹')),
                          PopupMenuItem(value: 'delete', child: Text('删除')),
                        ],
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Future<void> fileAction(MediaItem item, String action) async {
    if (action == 'rename') {
      final name = await input('重命名', initial: item.name);
      if (name != null && name.isNotEmpty && mounted) {
        setState(() {
          item.name = name;
        });
        await save();
      }
    } else if (action == 'move') {
      final result = await showDialog<String>(
        context: context,
        builder: (context) => SimpleDialog(
          title: const Text('移动到'),
          children: [
            for (final name in ['', ...folders])
              SimpleDialogOption(
                onPressed: () => Navigator.pop(context, name),
                child: Text(name.isEmpty ? '根目录' : name),
              ),
          ],
        ),
      );
      if (result != null && mounted) {
        setState(() {
          item.folder = result;
        });
        await save();
      }
    } else {
      if (item == player.item) {
        message('正在使用此文件，请先打开其他文件');
        return;
      }
      final yes = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('删除文件？'),
          content: Text('将删除“${item.name}”及其收藏和录音。导入前的原文件不受影响。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('删除'),
            ),
          ],
        ),
      );
      if (yes == true && mounted) {
        setState(() {
          items.remove(item);
        });
        await save();
        for (final path in [item.path, ...item.recordings]) {
          if (File(path).absolute.path.startsWith(
            '${repository!.root.absolute.path}${Platform.pathSeparator}',
          )) {
            final file = File(path);
            if (await file.exists()) {
              await file.delete();
            }
          }
        }
      }
    }
  }

  Widget get miniPlayer => Material(
    color: Colors.white,
    child: ListTile(
      dense: true,
      leading: const Icon(Icons.graphic_eq, color: orange),
      title: Text(
        player.item!.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        '${formatTime(player.position)} / ${formatTime(player.duration)}',
      ),
      onTap: () => setState(() {
        page = 1;
      }),
      trailing: IconButton(
        tooltip: player.playing ? '暂停' : '播放',
        onPressed: () => guard(player.toggle),
        icon: Icon(
          player.playing ? Icons.pause_circle : Icons.play_circle,
          color: orange,
          size: 36,
        ),
      ),
    ),
  );
  Widget get favoritesView {
    final favorites = [
      for (final item in items)
        for (final cue in item.cues)
          if (item.favorites.contains(cue.id)) (item, cue),
    ];
    if (favorites.isEmpty) {
      return empty(Icons.star_border_rounded, '把值得反复听的句子留下', '点击字幕旁的星标，随时回来复习');
    }
    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: favorites.length,
      separatorBuilder: (_, _) => const Divider(),
      itemBuilder: (_, index) {
        final (item, cue) = favorites[index];
        return ListTile(
          title: Text(cue.text, style: const TextStyle(height: 1.5)),
          subtitle: Text(
            '${cue.translation}\n${item.name} · ${formatTime(cue.start)}',
          ),
          onTap: () => guard(() => open(item, cue: cue)),
          trailing: IconButton(
            tooltip: '取消收藏',
            icon: const Icon(Icons.star_rounded, color: orange),
            onPressed: () {
              setState(() {
                item.favorites = {...item.favorites}..remove(cue.id);
              });
              unawaited(guard(save));
            },
          ),
        );
      },
    );
  }

  Widget get settingsView => ListView(
    padding: const EdgeInsets.all(20),
    children: [
      const Padding(
        padding: EdgeInsets.only(bottom: 16),
        child: Text(
          '听见，也读懂。',
          style: TextStyle(fontSize: 25, fontWeight: FontWeight.w700),
        ),
      ),
      section('播放', [
        ListTile(
          title: const Text('默认播放速度'),
          subtitle: Slider(
            value: player.speed,
            min: .1,
            max: 3,
            divisions: 58,
            onChanged: (value) => guard(() => player.setSpeed(value)),
            onChangeEnd: (_) => unawaited(guard(save)),
          ),
          trailing: Text('${player.speed.toStringAsFixed(2)}×'),
        ),
        ListTile(
          title: const Text('播放音量'),
          subtitle: Slider(
            value: player.volume,
            onChanged: (value) => guard(() => player.setVolume(value)),
          ),
        ),
        ListTile(
          title: const Text('定时关闭'),
          subtitle: Text(
            player.sleepAt == null
                ? '未开启'
                : '将在 ${player.sleepAt!.hour}:${player.sleepAt!.minute.toString().padLeft(2, '0')} 暂停',
          ),
          trailing: const Icon(Icons.timer_outlined),
          onTap: showSleep,
        ),
      ]),
      const SizedBox(height: 20),
      section('学习资料', [
        ListTile(
          leading: const Icon(Icons.file_open_outlined),
          title: const Text('导入音频或视频'),
          onTap: () => guard(importMedia),
        ),
        ListTile(
          leading: const Icon(Icons.wifi),
          title: const Text('Wi-Fi 传文件'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => guard(showWifi),
        ),
        ListTile(
          leading: const Icon(Icons.save_outlined),
          title: const Text('立即保存学习进度'),
          onTap: () => guard(() async {
            await save();
            message('学习进度已保存');
          }),
        ),
      ]),
      const SizedBox(height: 20),
      section('关于', [
        const ListTile(
          title: Text('Tdb'),
          subtitle: Text('1.0.0 · 本地听读与复读练习'),
        ),
        ListTile(
          title: const Text('功能与还原范围'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => showDialog<void>(
            context: context,
            builder: (context) => AlertDialog(
              title: const Text('还原范围'),
              content: const Text(
                '根据听读宝 7.8 安装包资源重建。\n\n支持本地音视频、变速、AB 复读、字幕、收藏、听写和跟读录音。\n\n原程序经过 App Store 加密，无法从此包恢复完整源码。云盘、购买、语音评分、自动分句和翻译尚未重建。',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('知道了'),
                ),
              ],
            ),
          ),
        ),
      ]),
    ],
  );
  void showSleep() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ListTile(
              title: Text(
                '定时关闭',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
            for (final n in [0, 5, 10, 15, 30, 60])
              ListTile(
                title: Text(n == 0 ? '关闭定时' : '$n 分钟后暂停'),
                onTap: () {
                  player.setSleep(n == 0 ? null : Duration(minutes: n));
                  Navigator.pop(context);
                },
              ),
          ],
        ),
      ),
    );
  }

  Future<void> showWifi() async {
    final urls = await transfer.start(receiveFile);
    if (!mounted) {
      await transfer.stop();
      return;
    }
    try {
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Wi-Fi 传文件'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('电脑与手机连接同一 Wi-Fi，在电脑浏览器中打开：'),
                const SizedBox(height: 12),
                for (final url in urls)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: SelectableText(
                      url,
                      style: const TextStyle(color: orange),
                    ),
                  ),
                const Text(
                  '保持应用在前台。关闭此窗口即停止传输。字幕将添加到当前打开的文件。',
                  style: TextStyle(color: Colors.black54, height: 1.5),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: urls.join('\n')));
              },
              child: const Text('复制地址'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('停止传输'),
            ),
          ],
        ),
      );
    } finally {
      await transfer.stop();
    }
  }

  Widget section(String title, List<Widget> children) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Padding(
        padding: const EdgeInsets.only(left: 4, bottom: 8),
        child: Text(
          title,
          style: const TextStyle(
            color: Colors.black54,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(children: children),
      ),
    ],
  );
  Widget empty(IconData icon, String title, String description) => Center(
    child: Padding(
      padding: const EdgeInsets.all(28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 52, color: orange),
          const SizedBox(height: 18),
          Text(
            title,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          Text(
            description,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.black54, height: 1.5),
          ),
        ],
      ),
    ),
  );
}
