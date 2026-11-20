import 'dart:async';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'audio_tools_page.dart';
import 'home_sections.dart';
import 'import_page.dart';
import 'library.dart';
import 'library_state.dart';
import 'models.dart';
import 'player_view.dart';
import 'recognition_workflow.dart';
import 'recordings_page.dart';
import 'services/device_tools.dart';
import 'services/player.dart';
import 'services/speech_recognition.dart';
import 'services/transfer_wake.dart';
import 'services/wifi_transfer.dart';
import 'wifi_transfer_page.dart';

const orange = Color(0xFFD68C42);
const paper = Color(0xFFFCFDFC);
final appMessenger = GlobalKey<ScaffoldMessengerState>();
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const TingdubaoApp());
}

class TingdubaoApp extends StatelessWidget {
  const TingdubaoApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Tdb',
    scaffoldMessengerKey: appMessenger,
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
        centerTitle: true,
        titleTextStyle: TextStyle(
          fontSize: 17,
          color: Colors.black,
          fontWeight: FontWeight.w600,
        ),
      ),
      dividerTheme: const DividerThemeData(
        color: Color(0xFFE8EBE9),
        thickness: .6,
      ),
      useMaterial3: true,
    ),
    home: const StudyHome(),
  );
}

class StudyHome extends StatefulWidget {
  const StudyHome({super.key, this.initialLibrary, this.studyPlayer});
  final LibraryState? initialLibrary;
  final StudyPlayer? studyPlayer;
  @override
  State<StudyHome> createState() => _StudyHomeState();
}

class _StudyHomeState extends State<StudyHome> with WidgetsBindingObserver {
  late final StudyPlayer player = widget.studyPlayer ?? StudyPlayer();
  final speech = SpeechRecognitionService();
  final tools = DeviceTools();
  final transfer = WifiTransfer();
  final recordingsKey = GlobalKey<RecordingsPageState>();
  final playerKey = GlobalKey<PlayerViewState>();
  LibraryState? library;
  String? folder, initError;
  int page = 0;
  bool booting = true, importing = false, editing = false;
  bool _wifiOpening = false, _playerOpening = false, _playerVisible = false;
  final selected = <String>{};
  final _deletingIds = <String>{};
  Timer? autosave;
  final _studyClock = Stopwatch();
  int _accountedMs = 0, _remainderMs = 0;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    player.addListener(_accountStudy);
    if (tools.supported) tools.setActionHandler(_deviceAction);
    unawaited(initialize());
    autosave = Timer.periodic(const Duration(seconds: 10), (_) {
      if (!booting && initError == null) unawaited(guard(save));
    });
  }

  Future<void> initialize() async {
    try {
      library = widget.initialLibrary;
      if (library == null) {
        final repository = await LibraryRepository.open();
        final state = LibraryState(repository);
        final data = await repository.read();
        if (data != null) {
          state.restore(data);
        } else {
          state.items.add(
            MediaItem(
              id: 'introduction',
              name: '听力练习.mp3',
              path: await repository.installAsset('Introduction.mp3'),
              cues: parseSubtitles(
                await rootBundle.loadString('assets/demo/Introduction.json'),
                format: 'json',
              ),
            ),
          );
          await state.save();
        }
        library = state;
      }
      player.speed = library!.speed;
      library!.addListener(_refresh);
      initError = null;
    } catch (e) {
      initError = '无法读取学习资料：$e';
    }
    if (!mounted) return;
    setState(() => booting = false);
    if (initError == null && tools.supported) {
      await guard(() async {
        final pending = await tools.pendingAction();
        if (pending != null) await _deviceAction(pending);
      });
    }
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  void _accountStudy() {
    final elapsed = _studyClock.elapsedMilliseconds;
    _remainderMs += elapsed - _accountedMs;
    _accountedMs = elapsed;
    if (_remainderMs >= 1000 && library != null) {
      library!.addStudy(_remainderMs ~/ 1000, DateTime.now());
      _remainderMs %= 1000;
    }
    if (player.playing) {
      _studyClock.start();
    } else {
      _studyClock.stop();
    }
  }

  Future<void> save() async {
    _accountStudy();
    if (library == null || initError != null) return;
    library!.speed = player.speed;
    await library!.save();
  }

  void message(String text) {
    if (!mounted) return;
    appMessenger.currentState?.hideCurrentSnackBar();
    appMessenger.currentState?.showSnackBar(SnackBar(content: Text(text)));
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
    player.removeListener(_accountStudy);
    unawaited(save().catchError((Object _) {}));
    library?.removeListener(_refresh);
    tools.dispose();
    unawaited(transfer.dispose());
    player.dispose();
    super.dispose();
  }

  Future<String?> input(String title, {String initial = ''}) async {
    final controller = TextEditingController(text: initial);
    final route = DialogRoute<String>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(title),
        content: TextField(controller: controller, autofocus: true),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialog, controller.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    final value = await Navigator.of(context).push(route);
    await route.completed;
    controller.dispose();
    return value;
  }

  Future<void> info(String title, String text) => showDialog<void>(
    context: context,
    builder: (dialog) => AlertDialog(
      title: Text(title),
      content: Text(text),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialog),
          child: const Text('知道了'),
        ),
      ],
    ),
  );
  Future<bool> confirm(String title, String text) async =>
      await showDialog<bool>(
        context: context,
        builder: (dialog) => AlertDialog(
          title: Text(title),
          content: Text(text),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialog, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialog, true),
              child: const Text('确定'),
            ),
          ],
        ),
      ) ??
      false;
  Future<void> pushPage(String title, Widget body) async {
    if (!mounted) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => Scaffold(
          appBar: AppBar(title: Text(title)),
          body: SafeArea(top: false, child: body),
        ),
      ),
    );
    _refresh();
  }

  Future<void> importMedia() async {
    if (importing) return;
    final destination = folder ?? '';
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
        'srt',
        'lrc',
        'vtt',
        'json',
        'txt',
      ],
    );
    if (result == null || !mounted) return;
    setState(() => importing = true);
    var count = 0;
    try {
      for (final file in result.files) {
        if (file.path == null) continue;
        await library!.importFile(file.path!, file.name, folder: destination);
        count++;
      }
      message('已导入 $count 个文件');
    } finally {
      if (mounted) setState(() => importing = false);
    }
  }

  Future<void> showImport() => pushPage(
    '添加',
    ImportPage(
      onSelect: (source) => unawaited(
        guard(() async {
          switch (source) {
            case ImportSource.wifi:
              await showWifi();
            case ImportSource.music:
              await info(
                'Apple Music',
                '曲库导入尚未接入。无保护的音频可导出到“文件”后，通过 iCloud 导入。',
              );
            case ImportSource.album:
              await info('相册导入', '先在“照片”中将视频存储到“文件”，然后选择该视频导入。');
              if (mounted) await importMedia();
            case ImportSource.icloud:
            case ImportSource.onedrive:
            case ImportSource.nas:
            case ImportSource.itunes:
              await importMedia();
          }
        }),
      ),
      onHelp: () => unawaited(
        info(
          '导入帮助',
          'Wi-Fi：电脑与手机连接同一路由器，打开手机显示的地址上传。\n\n云盘或 NAS：在系统“文件”的“浏览”中启用对应位置，再选择资料。\n\niTunes：拷贝到 Tdb 共享目录后，从“我的 iPhone / Tdb”导入。\n\n同名字幕与音频放在同一文件夹时自动关联，已有字幕不会被覆盖。',
        ),
      ),
    ),
  );
  Future<void> showWifi() async {
    if (_wifiOpening) return;
    _wifiOpening = true;
    final destination = folder ?? '';
    try {
      await TransferWake.setActive(true);
      final urls = await transfer.start(
        (path, name) => library!.importFile(path, name, folder: destination),
      );
      if (!mounted) return;
      await Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) =>
              WifiTransferPage(url: urls.single, transfer: transfer),
        ),
      );
    } finally {
      try {
        await transfer.stop();
      } finally {
        try {
          await TransferWake.setActive(false);
        } finally {
          _wifiOpening = false;
        }
      }
    }
  }

  Future<void> changeTab(int value) async {
    if (page == value) return;
    await recordingsKey.currentState?.finishRecording();
    if (mounted) {
      setState(() {
        page = value;
        editing = false;
        selected.clear();
      });
    }
  }

  Future<void> open(MediaItem item, {Cue? cue, bool play = false}) async {
    if (_deletingIds.contains(item.id)) throw StateError('此文件正在删除，请稍后重试');
    if (_playerOpening) return;
    _playerOpening = true;
    try {
      await recordingsKey.currentState?.finishRecording();
      if (player.item != item) await player.open(item);
      if (!mounted) return;
      library!.opened(item);
      await save();
      if (cue != null) await player.seek(cue.start);
      if (cue != null || play) await player.play();
      if (_playerVisible || !mounted) return;
      _playerVisible = true;
      try {
        await Navigator.of(context).push<void>(
          MaterialPageRoute(
            builder: (routeContext) => StatefulBuilder(
              builder: (context, update) => ListenableBuilder(
                listenable: player,
                builder: (_, _) => Scaffold(
                  appBar: AppBar(
                    title: Text(
                      player.item?.name ?? '',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    actions: [
                      IconButton(
                        tooltip: '全曲循环',
                        icon: Icon(
                          Icons.repeat,
                          color: player.repeat.enabled ? orange : null,
                        ),
                        onPressed: () => update(() {
                          if (player.repeat.enabled) {
                            player.repeat.clear();
                          } else if (player.duration > Duration.zero) {
                            player.repeat.setRange(
                              Duration.zero,
                              player.duration,
                            );
                          }
                        }),
                      ),
                      IconButton(
                        tooltip: '更多播放操作',
                        icon: const Icon(Icons.more_horiz),
                        onPressed: () => playerKey.currentState?.showMore(),
                      ),
                    ],
                  ),
                  body: SafeArea(
                    top: false,
                    child: PlayerView(
                      key: playerKey,
                      player: player,
                      onSave: save,
                      onMessage: message,
                      onRecognize: (media, segment) =>
                          recognizeMedia(routeContext, media, segment, speech),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      } finally {
        _playerVisible = false;
        await save();
      }
    } finally {
      _playerOpening = false;
      _refresh();
    }
  }

  Future<void> _deviceAction(DeviceAction action) async {
    if (booting || library == null) throw StateError('资料尚未读取完成');
    switch (action.type) {
      case DeviceActionType.pause:
        await player.pause();
      case DeviceActionType.upload:
        // Native acknowledgement must not wait until this pushed page closes.
        unawaited(guard(showWifi));
      case DeviceActionType.play:
        final media = action.mediaId == null
            ? player.item ?? library!.items.firstOrNull
            : library!.items.where((i) => i.id == action.mediaId).firstOrNull;
        if (media == null) throw StateError('未找到要播放的文件');
        if (_deletingIds.contains(media.id)) throw StateError('此文件正在删除');
        await recordingsKey.currentState?.finishRecording();
        if (player.item != media) await player.open(media);
        if (player.error != null) throw StateError(player.error!);
        library!.opened(media);
        await player.play();
        await save();
    }
  }

  List<MediaItem> get visible =>
      library!.items.where((i) => i.folder == (folder ?? '')).toList();
  List<String> get childFolders =>
      library!.folders
          .where(
            (f) =>
                (f.contains('/') ? f.substring(0, f.lastIndexOf('/')) : '') ==
                (folder ?? ''),
          )
          .toList()
        ..sort();
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: player,
    builder: (context, _) => PopScope(
      canPop: folder == null || page != 0,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) backFolder();
      },
      child: Scaffold(
        appBar: AppBar(
          leading: page == 0 && folder != null
              ? IconButton(
                  tooltip: '上一级',
                  onPressed: backFolder,
                  icon: const Icon(Icons.chevron_left),
                )
              : page == 0
              ? IconButton(
                  tooltip: '我的',
                  onPressed: () => unawaited(guard(() => changeTab(4))),
                  icon: const Icon(Icons.person, color: orange),
                )
              : null,
          title: Text(
            page == 0
                ? folder?.split('/').last ?? '文件'
                : ['文件', '录音', '更多', '听力', '我的'][page],
          ),
          actions: page == 0 && !booting && initError == null
              ? [
                  if (folder != null || editing)
                    TextButton(
                      onPressed: () => setState(() {
                        editing = !editing;
                        selected.clear();
                      }),
                      child: Text(editing ? '完成' : '编辑列表'),
                    ),
                  PopupMenuButton<String>(
                    tooltip: '添加',
                    icon: const Icon(Icons.add, color: orange),
                    onSelected: (action) => unawaited(
                      guard(() async {
                        if (action == 'import') {
                          await showImport();
                        } else if (action == 'folder') {
                          await addFolder();
                        } else {
                          setState(() => editing = true);
                        }
                      }),
                    ),
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'import', child: Text('导入文件')),
                      PopupMenuItem(value: 'folder', child: Text('新建文件夹')),
                      PopupMenuItem(value: 'edit', child: Text('编辑列表')),
                    ],
                  ),
                ]
              : null,
        ),
        body: booting
            ? const Center(child: CircularProgressIndicator())
            : initError != null
            ? Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(initError!),
                    TextButton(
                      onPressed: () => unawaited(initialize()),
                      child: const Text('重试'),
                    ),
                  ],
                ),
              )
            : homeBody,
        bottomNavigationBar: booting || initError != null
            ? null
            : Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (editing && page == 0)
                    batchBar
            else if (player.item != null && (page == 0 || page == 3))
                    miniPlayer,
                  TdbBottomBar(
                    index: page,
                    onChanged: (value) =>
                        unawaited(guard(() => changeTab(value))),
                  ),
                ],
              ),
      ),
    ),
  );
  Widget get homeBody => switch (page) {
    0 => libraryView,
    1 => RecordingsPage(
      key: recordingsKey,
      entries: [
        for (final path in library!.standaloneRecordings)
          (
            path: path,
            title:
                '录音 ${File(path).parent.uri.pathSegments.where((s) => s.isNotEmpty).last}',
          ),
        for (final item in library!.items)
          for (final path in item.recordings)
            (path: path, title: '${item.name} · 跟读'),
      ],
      createPath: () async {
        final directory = await library!.repository.root.createTemp(
          'recording_',
        );
        return '${directory.path}/recording.m4a';
      },
      onSaved: library!.addRecording,
      onDelete: library!.deleteRecording,
      beforeRecording: player.pause,
    ),
    2 => TdbMorePage(
      totalStudy: Duration(
        seconds: library!.studySeconds.values.fold(0, (a, b) => a + b),
      ),
      todayStudy: Duration(
        seconds:
            library!.studySeconds[LibraryState.dateKey(DateTime.now())] ?? 0,
      ),
      reviewCount: library!.items.fold(0, (n, i) => n + i.favorites.length),
      weekMinutes: [
        for (var day = 6; day >= 0; day--)
          (library!.studySeconds[LibraryState.dateKey(
                    DateTime.now().subtract(Duration(days: day)),
                  )] ??
                  0) ~/
              60,
      ],
      onAction: (action) => unawaited(guard(() => homeAction(action))),
    ),
    3 => hearingView,
    _ => TdbMyPage(
      onAction: (action) => unawaited(guard(() => homeAction(action))),
      version: 'Tdb 1.1.0',
      cacheLabel: '本地资料保留',
    ),
  };
  Widget get libraryView {
    final entries = visible;
    return Column(
      children: [
        if (importing) const LinearProgressIndicator(),
        Expanded(
          child: editing
              ? ReorderableListView.builder(
                  buildDefaultDragHandles: false,
                  itemCount: entries.length,
                  onReorderItem: (from, to) => unawaited(
                    guard(() async {
                      final ids = entries.map((i) => i.id).toList();
                      ids.insert(to, ids.removeAt(from));
                      await library!.reorder(ids);
                    }),
                  ),
                  itemBuilder: (_, n) => mediaTile(
                    entries[n],
                    key: ValueKey(entries[n].id),
                    reorderIndex: n,
                  ),
                )
              : ListView(
                  children: [
                    if (folder == null) ...[
                      ListTile(
                        leading: const Icon(
                          Icons.podcasts,
                          color: Colors.blue,
                          size: 32,
                        ),
                        title: const Text('播客'),
                        trailing: const Icon(Icons.chevron_right, size: 19),
                        onTap: () => unawaited(
                          guard(() => homeAction(HomeAction.podcasts)),
                        ),
                      ),
                      const Divider(height: 1, indent: 65),
                      ListTile(
                        leading: const Icon(
                          Icons.cloud,
                          color: Colors.lightBlue,
                          size: 32,
                        ),
                        title: const Text('iCloud'),
                        trailing: const Icon(Icons.chevron_right, size: 19),
                        onTap: () => unawaited(guard(importMedia)),
                      ),
                      const Divider(height: 1, indent: 65),
                    ],
                    for (final child in childFolders) ...[
                      ListTile(
                        leading: const Icon(
                          Icons.folder_outlined,
                          color: orange,
                          size: 30,
                        ),
                        title: Text(child.split('/').last),
                        trailing: Text(
                          '${library!.items.where((i) => i.folder == child || i.folder.startsWith('$child/')).length} ›',
                          style: const TextStyle(color: Colors.grey),
                        ),
                        onTap: () => setState(() => folder = child),
                        onLongPress: () =>
                            unawaited(guard(() => folderActions(child))),
                      ),
                      const Divider(height: 1, indent: 65),
                    ],
                    for (final item in entries) ...[
                      mediaTile(item),
                      const Divider(height: 1, indent: 65),
                    ],
                    if (entries.isEmpty &&
                        childFolders.isEmpty &&
                        folder != null)
                      const Padding(
                        padding: EdgeInsets.all(40),
                        child: Center(child: Text('此文件夹为空')),
                      ),
                    if (library!.sidecars.any(
                      (s) => s['folder'] == (folder ?? ''),
                    ))
                      ListTile(
                        leading: const Icon(Icons.subtitles_outlined),
                        title: const Text('已导入字幕'),
                        onTap: () => unawaited(showSidecars()),
                      ),
                  ],
                ),
        ),
      ],
    );
  }

  Widget mediaTile(MediaItem item, {Key? key, int? reorderIndex}) => ListTile(
    key: key,
    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
    leading: editing
        ? Checkbox(
            value: selected.contains(item.id),
            onChanged: (_) => toggleSelection(item.id),
          )
        : Container(
            width: 45,
            height: 49,
            decoration: BoxDecoration(
              color: const Color(0xFFF0F2F0),
              borderRadius: BorderRadius.circular(3),
            ),
            child: Icon(
              item.isVideo ? Icons.videocam_outlined : Icons.music_note,
              size: 31,
              color: const Color(0xFFBFC4C0),
            ),
          ),
    title: Text(
      item.name,
      maxLines: 3,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: 15,
        color: player.item == item ? orange : const Color(0xFF303530),
      ),
    ),
    trailing: editing
        ? ReorderableDragStartListener(
            index: reorderIndex!,
            child: const Padding(
              padding: EdgeInsets.all(10),
              child: Icon(Icons.drag_handle),
            ),
          )
        : Text(
            '${item.cues.length} ›',
            style: const TextStyle(color: Colors.grey),
          ),
    onTap: () {
      if (editing) {
        toggleSelection(item.id);
      } else {
        unawaited(guard(() => open(item)));
      }
    },
    onLongPress: editing
        ? null
        : () => unawaited(guard(() => fileActions(item))),
  );
  void toggleSelection(String id) => setState(() {
    if (!selected.add(id)) selected.remove(id);
  });
  void backFolder() => setState(() {
    if (folder != null) {
      folder = folder!.contains('/')
          ? folder!.substring(0, folder!.lastIndexOf('/'))
          : null;
    }
    editing = false;
    selected.clear();
  });
  Future<void> addFolder() async {
    final name = await input('文件夹名称');
    if (name == null || name.isEmpty) return;
    if (name.contains('/') ||
        name.contains('\\') ||
        name == '.' ||
        name == '..') {
      throw const FormatException('文件夹名不能包含路径分隔符');
    }
    final path = folder == null ? name : '$folder/$name';
    if (library!.folders.contains(path)) throw StateError('同名文件夹已存在');
    library!.folders.add(path);
    try {
      await save();
    } catch (_) {
      library!.folders.remove(path);
      rethrow;
    }
    _refresh();
  }

  Future<void> folderActions(String path) async {
    final descendants =
        library!.items.any(
          (i) => i.folder == path || i.folder.startsWith('$path/'),
        ) ||
        library!.folders.any((f) => f.startsWith('$path/')) ||
        library!.sidecars.any((s) => s['folder'] == path);
    if (descendants) {
      await info('文件夹', '移动或删除文件后，可长按删除空文件夹。');
      return;
    }
    if (await confirm('删除空文件夹？', path.split('/').last)) {
      library!.folders.remove(path);
      try {
        await save();
      } catch (_) {
        library!.folders.add(path);
        rethrow;
      }
      _refresh();
    }
  }

  Widget get batchBar => Row(
    mainAxisAlignment: MainAxisAlignment.spaceAround,
    children: [
      TextButton(
        onPressed: () => setState(() {
          if (selected.length == visible.length) {
            selected.clear();
          } else {
            selected.addAll(visible.map((i) => i.id));
          }
        }),
        child: const Text('全选'),
      ),
      TextButton(
        onPressed: selected.isEmpty
            ? null
            : () => unawaited(guard(() => moveFiles({...selected}))),
        child: const Text('移动'),
      ),
      TextButton(
        onPressed: selected.isEmpty
            ? null
            : () => unawaited(guard(() => deleteFiles({...selected}))),
        child: Text('删除 (${selected.length})'),
      ),
    ],
  );
  Future<void> moveFiles(Set<String> ids) async {
    final target = await showDialog<String>(
      context: context,
      builder: (dialog) => SimpleDialog(
        title: const Text('移动到'),
        children: [
          for (final name in ['', ...library!.folders])
            SimpleDialogOption(
              onPressed: () => Navigator.pop(dialog, name),
              child: Text(name.isEmpty ? '根目录' : name),
            ),
        ],
      ),
    );
    if (target == null) return;
    await library!.move(ids, target);
    selected.clear();
    _refresh();
  }

  Future<void> deleteFiles(Set<String> ids) async {
    if (!await confirm('删除 ${ids.length} 个文件？', '将删除应用内的资料及跟读录音。原始导入文件不受影响。')) {
      return;
    }
    _deletingIds.addAll(ids);
    try {
      await library!.delete(ids, activeIdProvider: () => player.item?.id);
    } finally {
      _deletingIds.removeAll(ids);
    }
    selected.clear();
    _refresh();
  }

  Future<void> fileActions(MediaItem item) async {
    final result = await showModalBottomSheet<String>(
      context: context,
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final entry in [
              ('rename', '重命名'),
              ('move', '移动到文件夹'),
              ('delete', '删除'),
            ])
              ListTile(
                title: Text(entry.$2),
                onTap: () => Navigator.pop(sheet, entry.$1),
              ),
          ],
        ),
      ),
    );
    if (result == 'rename') {
      final name = await input('重命名', initial: item.name);
      if (name != null && name.isNotEmpty) {
        final old = item.name;
        item.name = name;
        try {
          await save();
        } catch (_) {
          item.name = old;
          rethrow;
        }
        _refresh();
      }
    } else if (result == 'move') {
      await moveFiles({item.id});
    } else if (result == 'delete') {
      await deleteFiles({item.id});
    }
  }

  Future<void> showSidecars() => pushPage(
    '已导入字幕',
    ListView(
      children: [
        for (final sidecar in library!.sidecars.where(
          (s) => s['folder'] == (folder ?? ''),
        ))
          ListTile(
            title: Text(sidecar['name']!),
            subtitle: const Text('同名音频自动关联；已有字幕保留'),
          ),
      ],
    ),
  );
  Widget get miniPlayer => Material(
    color: Colors.white,
    child: SizedBox(
      height: 57,
      child: Row(
        children: [
          const SizedBox(width: 16),
          const Icon(Icons.music_note, size: 31, color: Color(0xFFBFC4C0)),
          const SizedBox(width: 12),
          Expanded(
            child: InkWell(
              onTap: () => unawaited(guard(() => open(player.item!))),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    player.item!.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13),
                  ),
                  Text(
                    '${formatTime(player.position)} / ${formatTime(player.duration)}',
                    style: const TextStyle(fontSize: 11, color: Colors.grey),
                  ),
                ],
              ),
            ),
          ),
          IconButton(
            tooltip: '上一首',
            onPressed: () => unawaited(guard(() => skip(-1))),
            icon: const Icon(Icons.chevron_left, color: orange),
          ),
          IconButton(
            tooltip: player.playing ? '暂停' : '播放',
            onPressed: () => unawaited(guard(player.toggle)),
            icon: Icon(
              player.playing
                  ? Icons.pause_circle_outline
                  : Icons.play_circle_outline,
              color: orange,
            ),
          ),
          IconButton(
            tooltip: '下一首',
            onPressed: () => unawaited(guard(() => skip(1))),
            icon: const Icon(Icons.chevron_right, color: orange),
          ),
          IconButton(
            tooltip: '播放列表',
            onPressed: () =>
                unawaited(guard(() => homeAction(HomeAction.playlist))),
            icon: const Icon(Icons.queue_music, color: orange),
          ),
        ],
      ),
    ),
  );
  Future<void> skip(int step) async {
    final entries = library!.items
        .where((i) => i.folder == player.item?.folder)
        .toList();
    final index = entries.indexOf(player.item!);
    if (index < 0 || entries.isEmpty) return;
    final target = entries[(index + step) % entries.length];
    if (_deletingIds.contains(target.id)) throw StateError('此文件正在删除');
    await player.open(target);
    library!.opened(target);
    await player.play();
    await save();
  }

  Future<void> homeAction(HomeAction action) async {
    switch (action) {
      case HomeAction.importFiles:
        await showImport();
      case HomeAction.sync:
        await info('同步音频', '设备间同步协议尚未接入。目前可使用 Wi-Fi 批量导入传送音频与字幕。');
      case HomeAction.playlist:
        await showMediaList('播放列表', library!.items, reorder: true);
      case HomeAction.recent:
        await showMediaList('最近播放', [
          for (final id in library!.recent)
            ...library!.items.where((i) => i.id == id),
        ]);
      case HomeAction.favorites:
        await showCues('我的收藏', onlyFavorites: true);
      case HomeAction.notes:
        await showCues('AB 笔记');
      case HomeAction.words:
        await showWords();
      case HomeAction.reminder:
        await schedule(false);
      case HomeAction.timedPlay:
        await schedule(true);
      case HomeAction.sleep:
        await showSleep();
      case HomeAction.studyTime:
        await pushPage(
          '学习时长',
          ListView(
            children: [
              for (final key
                  in (library!.studySeconds.keys.toList()
                    ..sort((a, b) => b.compareTo(a))))
                ListTile(
                  title: Text(key),
                  trailing: Text(
                    '${(library!.studySeconds[key]! / 60).toStringAsFixed(1)} 分钟',
                  ),
                ),
            ],
          ),
        );
      case HomeAction.speed:
        await audioTool(false);
      case HomeAction.videoAudio:
        await audioTool(true);
      case HomeAction.podcasts:
        await info('播客', '播客订阅与更新尚未恢复。已下载的播客音频可从“添加”导入学习。');
      case HomeAction.settings:
        await showSettings();
      case HomeAction.clearCache:
        await info('清理缓存', '音频、字幕和录音属于学习资料，不作为缓存清除。系统临时导入文件会在传输结束后清理。');
      case HomeAction.interfaces:
        await info(
          '指令接口',
          'tdb://play\ntdb://pause\ntdb://upload\n\n播放指定文件：tdb://play?mediaId=文件ID\n\n系统提醒需要点击通知才会播放，iOS 不允许本应用保证在后台按时自动开播。',
        );
      case HomeAction.instructions:
      case HomeAction.help:
        await info(
          '使用帮助',
          '添加：Wi-Fi 上传或系统“文件”导入。\n文件夹：右上角 ＋ 新建；长按文件可重命名、移动、删除。\n编辑列表：勾选后批量移动、删除，拖动手柄排序。\n播放器：设置 A/B 后添加行；分句/识别可选静音分句或系统语音识别。\n录音：录制、播放与删除；语句可单独跟读并对照原声。\n\n在线听力资源、云同步、播客服务及自动翻译尚未接入。',
        );
      case HomeAction.feedback:
        await tools.openUrl(Uri.parse('https://github.com/hysgit/tdb/issues'));
      case HomeAction.share:
        await tools.share('Tdb · 本地音视频听读与复读练习');
    }
  }

  Future<void> showMediaList(
    String title,
    List<MediaItem> entries, {
    bool reorder = false,
  }) async {
    final ids = entries.map((i) => i.id).toList();
    await pushPage(
      title,
      StatefulBuilder(
        builder: (context, update) {
          final current = [
            for (final id in ids) ...library!.items.where((i) => i.id == id),
          ];
          if (current.isEmpty) return const Center(child: Text('暂无文件'));
          if (!reorder) {
            return ListView(
              children: [
                for (final item in current)
                  ListTile(
                    title: Text(item.name),
                    onTap: () => unawaited(guard(() => open(item))),
                  ),
              ],
            );
          }
          return ReorderableListView(
            children: [
              for (final item in current)
                ListTile(
                  key: ValueKey(item.id),
                  title: Text(item.name),
                  onTap: () => unawaited(guard(() => open(item))),
                ),
            ],
            onReorderItem: (from, to) => unawaited(
              guard(() async {
                final before = [...ids];
                ids.insert(to, ids.removeAt(from));
                try {
                  await library!.reorder(ids);
                } catch (_) {
                  ids.setAll(0, before);
                  rethrow;
                }
                update(() {});
              }),
            ),
          );
        },
      ),
    );
  }

  Future<void> showCues(String title, {bool onlyFavorites = false}) => pushPage(
    title,
    StatefulBuilder(
      builder: (context, update) {
        final entries = [
          for (final item in library!.items)
            for (final cue in item.cues)
              if (!onlyFavorites || item.favorites.contains(cue.id))
                (item, cue),
        ];
        return entries.isEmpty
            ? const Center(child: Text('暂无笔记'))
            : ListView(
                children: [
                  for (final (item, cue) in entries)
                    ListTile(
                      title: Text(cue.text.isEmpty ? 'AB 片段' : cue.text),
                      subtitle: Text('${item.name} · ${formatTime(cue.start)}'),
                      onTap: () => unawaited(guard(() => open(item, cue: cue))),
                      trailing: onlyFavorites
                          ? IconButton(
                              icon: const Icon(Icons.star, color: orange),
                              tooltip: '取消收藏',
                              onPressed: () => unawaited(
                                guard(() async {
                                  item.favorites = {...item.favorites}
                                    ..remove(cue.id);
                                  await save();
                                  update(() {});
                                }),
                              ),
                            )
                          : null,
                    ),
                ],
              );
      },
    ),
  );
  Future<void> showWords() => pushPage(
    '单词本',
    StatefulBuilder(
      builder: (context, update) => ListView(
        children: [
          ListTile(
            leading: const Icon(Icons.add),
            title: const Text('添加单词'),
            onTap: () => unawaited(
              guard(() async {
                final word = await input('单词');
                if (word == null || word.isEmpty) return;
                if (!library!.words.contains(word)) {
                  library!.words.add(word);
                  await save();
                  update(() {});
                }
              }),
            ),
          ),
          for (final word in [...library!.words])
            ListTile(
              title: Text(word),
              onTap: () => unawaited(guard(() => tools.lookup(word))),
              trailing: IconButton(
                tooltip: '删除单词',
                icon: const Icon(Icons.close),
                onPressed: () => unawaited(
                  guard(() async {
                    library!.words.remove(word);
                    await save();
                    update(() {});
                  }),
                ),
              ),
            ),
        ],
      ),
    ),
  );
  Future<void> audioTool(bool video) async {
    final entries = library!.items.where((i) => !video || i.isVideo).toList();
    if (entries.isEmpty) {
      await info(video ? '视频转 mp3' : '音频加减速', '请先导入${video ? '视频' : '音频'}文件。');
      return;
    }
    final media = await showDialog<MediaItem>(
      context: context,
      builder: (dialog) => SimpleDialog(
        title: const Text('选择文件'),
        children: [
          for (final item in entries)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(dialog, item),
              child: Text(item.name),
            ),
        ],
      ),
    );
    if (media == null || !mounted) return;
    await player.pause();
    await pushPage(
      video ? '视频转 mp3' : '音频加减速',
      AudioToolsPage(
        item: media,
        videoMode: video,
        onExported: (path, name) =>
            library!.importFile(path, name, folder: media.folder),
      ),
    );
  }

  Future<void> schedule(bool playback) async {
    final now = DateTime.now();
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(now.add(const Duration(minutes: 5))),
    );
    if (time == null) return;
    var at = DateTime(now.year, now.month, now.day, time.hour, time.minute);
    if (!at.isAfter(now)) at = at.add(const Duration(days: 1));
    MediaItem? media;
    if (playback) {
      media = player.item ?? library!.items.firstOrNull;
      if (media == null) throw StateError('请先导入并打开要播放的文件');
    }
    await tools.schedule(
      id: playback ? 'timed-play' : 'study-reminder',
      title: playback ? 'Tdb 定时播放' : 'Tdb 学习提醒',
      body: playback ? '点击播放 ${media!.name}' : '开始今天的听读练习',
      at: at,
      mediaId: media?.id,
    );
    message(
      '已设置 ${at.month}/${at.day} ${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')} 提醒${playback ? '，点击通知开播' : ''}',
    );
  }

  Future<void> showSleep() => showModalBottomSheet<void>(
    context: context,
    builder: (sheet) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final n in [0, 5, 10, 15, 30, 60])
            ListTile(
              title: Text(n == 0 ? '关闭定时' : '$n 分钟后暂停'),
              onTap: () {
                player.setSleep(n == 0 ? null : Duration(minutes: n));
                Navigator.pop(sheet);
              },
            ),
        ],
      ),
    ),
  );
  Future<void> showSettings() => pushPage(
    '设置',
    StatefulBuilder(
      builder: (context, update) => ListView(
        children: [
          ListTile(
            title: const Text('播放速度'),
            trailing: Text('${player.speed.toStringAsFixed(2)}×'),
            subtitle: Slider(
              value: player.speed,
              min: .1,
              max: 5,
              divisions: 49,
              onChanged: (v) => unawaited(
                guard(() async {
                  await player.setSpeed(v);
                  update(() {});
                }),
              ),
              onChangeEnd: (_) => unawaited(guard(save)),
            ),
          ),
          ListTile(
            title: const Text('音量'),
            subtitle: Slider(
              value: player.volume,
              onChanged: (v) => unawaited(
                guard(() async {
                  await player.setVolume(v);
                  update(() {});
                }),
              ),
            ),
          ),
          ListTile(
            title: const Text('取消学习提醒'),
            onTap: () => unawaited(
              guard(() => tools.cancelNotification('study-reminder')),
            ),
          ),
          ListTile(
            title: const Text('取消定时播放'),
            onTap: () =>
                unawaited(guard(() => tools.cancelNotification('timed-play'))),
          ),
          const AboutListTile(
            applicationName: 'Tdb',
            applicationVersion: '1.1.0',
            applicationLegalese: '开源组件许可见应用许可页与源码仓库 THIRD_PARTY_NOTICES.md',
          ),
        ],
      ),
    ),
  );
  Widget get hearingView => ListView(
    children: [
      const Padding(
        padding: EdgeInsets.all(20),
        child: Text(
          '在线听力资源服务尚未恢复。已导入的资料可直接播放学习。',
          style: TextStyle(color: Colors.grey),
        ),
      ),
      for (final name in library!.folders)
        ListTile(
          leading: const Icon(Icons.folder_outlined, color: orange),
          title: Text(name),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => setState(() {
            folder = name;
            page = 0;
          }),
        ),
      ListTile(
        leading: const Icon(Icons.file_download_outlined, color: orange),
        title: const Text('导入听力资料'),
        onTap: () => unawaited(guard(showImport)),
      ),
    ],
  );
}
