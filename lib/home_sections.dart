import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:material_ui/material_ui.dart';

enum HomeAction {
  importFiles,
  sync,
  playlist,
  recent,
  favorites,
  words,
  notes,
  reminder,
  timedPlay,
  sleep,
  studyTime,
  speed,
  videoAudio,
  podcasts,
  settings,
  clearCache,
  interfaces,
  instructions,
  help,
  feedback,
  share,
}

const _ink = Color(0xFF202421);
const _muted = Color(0xFF939895);
const _orange = Color(0xFFD68C42);
const _surface = Color(0xFFF1F4F5);

class TdbBottomBar extends StatelessWidget {
  const TdbBottomBar({super.key, required this.index, required this.onChanged});
  final int index;
  final ValueChanged<int> onChanged;

  static const _labels = ['文件', '录音', '更多', '听力', '我的'];
  static const _icons = [
    Icons.insert_drive_file_outlined,
    Icons.mic_none_outlined,
    Icons.grid_view_outlined,
    Icons.headphones_outlined,
    Icons.person_outline,
  ];

  @override
  Widget build(BuildContext context) => SafeArea(
    top: false,
    minimum: const EdgeInsets.fromLTRB(16, 4, 16, 8),
    child: DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(36),
        boxShadow: const [
          BoxShadow(
            color: Color(0x14000000),
            blurRadius: 22,
            offset: Offset(0, 5),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(36),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(36),
              border: Border.all(color: Colors.white.withValues(alpha: 0.96)),
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.white.withValues(alpha: 0.91),
                  Colors.white.withValues(alpha: 0.73),
                ],
              ),
            ),
            child: Material(
              color: Colors.transparent,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
                child: Row(
                  children: List.generate(
                    5,
                    (i) => Expanded(
                      child: Semantics(
                        selected: i == index,
                        button: true,
                        label: _labels[i],
                        child: InkWell(
                          key: ValueKey('home-tab-$i'),
                          borderRadius: BorderRadius.circular(30),
                          onTap: () => onChanged(i),
                          child: ExcludeSemantics(
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 160),
                              height: 54,
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(30),
                                color: i == index
                                    ? const Color(0xCCE7E9E6)
                                    : Colors.transparent,
                              ),
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(
                                    _icons[i],
                                    size: 23,
                                    color: i == index ? _orange : _ink,
                                  ),
                                  const SizedBox(height: 3),
                                  Text(
                                    _labels[i],
                                    style: TextStyle(
                                      fontSize: 10,
                                      color: i == index ? _orange : _ink,
                                      fontWeight: i == index
                                          ? FontWeight.w600
                                          : FontWeight.w400,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

class TdbMorePage extends StatelessWidget {
  const TdbMorePage({
    super.key,
    required this.totalStudy,
    required this.todayStudy,
    required this.reviewCount,
    required this.weekMinutes,
    required this.onAction,
  });
  final Duration totalStudy;
  final Duration todayStudy;
  final int reviewCount;
  final List<int> weekMinutes;
  final ValueChanged<HomeAction> onAction;

  @override
  Widget build(BuildContext context) {
    final recent = weekMinutes.length > 7
        ? weekMinutes.sublist(weekMinutes.length - 7)
        : weekMinutes;
    final days = List<int>.generate(
      7,
      (i) => i < 7 - recent.length
          ? 0
          : math.max(0, recent[i - (7 - recent.length)]),
    );
    final weeklyMinutes = days.fold(0, (sum, value) => sum + value);
    final maximum = math.max(1, days.reduce(math.max));
    return ColoredBox(
      color: Colors.white,
      child: SingleChildScrollView(
        key: const ValueKey('more-page-scroll'),
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 104),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const _SectionTitle('学习概览', subtitle: '累计 · 今日 · 待复习'),
            _Surface(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    Color(0xFFF9FCFC),
                    Color(0xFFF0F3F7),
                    Color(0xFFE9E9ED),
                  ],
                ),
                borderRadius: BorderRadius.all(Radius.circular(22)),
                border: Border.fromBorderSide(
                  BorderSide(color: Color(0xFFE8EAED)),
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 20),
                child: Row(
                  children: [
                    Expanded(
                      child: _Statistic(
                        (totalStudy.inSeconds / 3600).toStringAsFixed(1),
                        'h',
                        '累计学习',
                      ),
                    ),
                    const SizedBox(
                      height: 35,
                      child: VerticalDivider(
                        width: 1,
                        color: Color(0xFFE0E4E5),
                      ),
                    ),
                    Expanded(
                      child: _Statistic(
                        '${todayStudy.inMinutes}',
                        'min',
                        '今日学习',
                      ),
                    ),
                    const SizedBox(
                      height: 35,
                      child: VerticalDivider(
                        width: 1,
                        color: Color(0xFFE0E4E5),
                      ),
                    ),
                    Expanded(child: _Statistic('$reviewCount', '', '待复习')),
                  ],
                ),
              ),
            ),
            const _SectionTitle('文件导入', subtitle: '多端同步'),
            _Surface(
              child: Row(
                children: [
                  Expanded(
                    child: _ToolButton(
                      title: '导入文件',
                      detail: '本地 / 云盘 / WiFi',
                      icon: Icons.file_download_outlined,
                      colors: const [Color(0xFF359BF2), Color(0xFF2377D6)],
                      action: HomeAction.importFiles,
                      onAction: onAction,
                    ),
                  ),
                  Expanded(
                    child: _ToolButton(
                      title: '同步音频',
                      detail: '多端实时',
                      icon: Icons.sync,
                      colors: const [Color(0xFF27D0B6), Color(0xFF12B29A)],
                      action: HomeAction.sync,
                      onAction: onAction,
                    ),
                  ),
                ],
              ),
            ),
            const _SectionTitle('播放', subtitle: '列表与历史'),
            _Surface(
              child: Column(
                children: [
                  _ActionRow(
                    title: '播放列表',
                    detail: '自定义排序',
                    icon: Icons.queue_music,
                    colors: const [Color(0xFF5C51EA), Color(0xFF3F32C7)],
                    action: HomeAction.playlist,
                    onAction: onAction,
                  ),
                  const Padding(
                    padding: EdgeInsets.only(left: 70, right: 16),
                    child: Divider(height: 1, color: Color(0xFFE3E7E8)),
                  ),
                  _ActionRow(
                    title: '最近播放',
                    detail: '继续收听',
                    icon: Icons.history,
                    colors: const [Color(0xFFF22691), Color(0xFFD91471)],
                    action: HomeAction.recent,
                    onAction: onAction,
                  ),
                ],
              ),
            ),
            const _SectionTitle('学习', subtitle: '高效工具集'),
            Row(
              children: [
                Expanded(
                  flex: 3,
                  child: _LearningCard(
                    title: '我的收藏',
                    detail: '收藏的AB笔记',
                    icon: Icons.star_border_rounded,
                    colors: const [Color(0xFFFE872C), Color(0xFFED278D)],
                    action: HomeAction.favorites,
                    onAction: onAction,
                    height: 178,
                    large: true,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  flex: 2,
                  child: Column(
                    children: [
                      _LearningCard(
                        title: '单词本',
                        detail: '生词随时背',
                        icon: Icons.menu_book_outlined,
                        colors: const [Color(0xFF31D959), Color(0xFF21BF48)],
                        action: HomeAction.words,
                        onAction: onAction,
                        height: 84,
                      ),
                      const SizedBox(height: 10),
                      _LearningCard(
                        title: 'AB 笔记',
                        detail: '重点标记',
                        icon: Icons.edit_note,
                        colors: const [Color(0xFFFFC711), Color(0xFFEEB100)],
                        action: HomeAction.notes,
                        onAction: onAction,
                        height: 84,
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const _SectionTitle('时间'),
            _Surface(
              child: Row(
                children: [
                  Expanded(
                    child: _ToolButton(
                      title: '学习提醒',
                      detail: '到点提醒',
                      icon: Icons.notifications_none,
                      colors: const [Color(0xFFF62C97), Color(0xFFDD1682)],
                      action: HomeAction.reminder,
                      onAction: onAction,
                    ),
                  ),
                  Expanded(
                    child: _ToolButton(
                      title: '定时播放',
                      detail: '到点开播',
                      icon: Icons.alarm,
                      colors: const [Color(0xFF3F9CF2), Color(0xFF287AD4)],
                      action: HomeAction.timedPlay,
                      onAction: onAction,
                    ),
                  ),
                  Expanded(
                    child: _ToolButton(
                      title: '定时关闭',
                      detail: '到点停止',
                      icon: Icons.nightlight_outlined,
                      colors: const [Color(0xFF2DCEB9), Color(0xFF13AF9D)],
                      action: HomeAction.sleep,
                      onAction: onAction,
                    ),
                  ),
                  Expanded(
                    child: _ToolButton(
                      title: '学习时长',
                      detail: '每周统计',
                      icon: Icons.bar_chart,
                      colors: const [Color(0xFF35D657), Color(0xFF20B843)],
                      action: HomeAction.studyTime,
                      onAction: onAction,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            _Surface(
              child: InkWell(
                borderRadius: BorderRadius.circular(22),
                onTap: () => onAction(HomeAction.studyTime),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    children: [
                      Row(
                        children: [
                          const Expanded(
                            child: Text(
                              '最近7天的学习时长',
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                color: _ink,
                              ),
                            ),
                          ),
                          Text(
                            (weeklyMinutes / 60).toStringAsFixed(1),
                            key: const ValueKey('week-total-hours'),
                            style: const TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.w600,
                              color: Color(0xFF48C96A),
                            ),
                          ),
                          const Text(
                            'h',
                            style: TextStyle(fontSize: 10, color: _muted),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      SizedBox(
                        height: 50,
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: List.generate(
                            7,
                            (i) => Expanded(
                              child: Semantics(
                                label:
                                    '${i == 6 ? '今日' : '第${i + 1}天'}：${days[i]} 分钟',
                                child: Align(
                                  alignment: Alignment.bottomCenter,
                                  child: Container(
                                    key: ValueKey('week-bar-$i'),
                                    width: 20,
                                    height: math.max(
                                      3.0,
                                      days[i] / maximum * 50,
                                    ),
                                    decoration: BoxDecoration(
                                      color: i == 6
                                          ? const Color(0xFFE28032)
                                          : const Color(0xFFDDE1E4),
                                      borderRadius: BorderRadius.circular(3),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 10),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            '今日 ${todayStudy.inMinutes} 分钟',
                            style: const TextStyle(fontSize: 10, color: _muted),
                          ),
                          Text(
                            '日均 ${(weeklyMinutes / 7).round()} 分钟',
                            style: const TextStyle(fontSize: 10, color: _muted),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const _SectionTitle('工具'),
            _Surface(
              child: Row(
                children: [
                  Expanded(
                    child: _ToolButton(
                      title: '音频加减速',
                      detail: '变速不变调',
                      icon: Icons.speed,
                      colors: const [Color(0xFFFB8D1E), Color(0xFFEF6E10)],
                      action: HomeAction.speed,
                      onAction: onAction,
                    ),
                  ),
                  Expanded(
                    child: _ToolButton(
                      title: '视频转 mp3',
                      detail: '提取音频',
                      icon: Icons.audio_file_outlined,
                      colors: const [Color(0xFFF02639), Color(0xFFD80E20)],
                      action: HomeAction.videoAudio,
                      onAction: onAction,
                    ),
                  ),
                  Expanded(
                    child: _ToolButton(
                      title: '播客',
                      detail: '订阅更新',
                      icon: Icons.podcasts,
                      colors: const [Color(0xFFA82EEE), Color(0xFF840BCB)],
                      action: HomeAction.podcasts,
                      onAction: onAction,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class TdbMyPage extends StatelessWidget {
  const TdbMyPage({
    super.key,
    required this.onAction,
    required this.version,
    required this.cacheLabel,
  });
  final ValueChanged<HomeAction> onAction;
  final String version;
  final String cacheLabel;

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: Colors.white,
    child: SingleChildScrollView(
      padding: const EdgeInsets.only(top: 20, bottom: 104),
      child: Column(
        children: [
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(17),
              color: const Color(0xFFF47B1D),
            ),
            child: const Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.play_circle_outline, color: Colors.white, size: 30),
                Text(
                  '听',
                  style: TextStyle(
                    fontSize: 26,
                    color: Colors.white,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 9),
          const Text(
            'Tdb',
            style: TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w600,
              color: _ink,
            ),
          ),
          const SizedBox(height: 4),
          const Text('测试版', style: TextStyle(fontSize: 13, color: _muted)),
          const SizedBox(height: 22),
          _MyRow('反馈', HomeAction.feedback, onAction),
          _MyRow('分享', HomeAction.share, onAction),
          const _GroupGap(),
          _MyRow('设置', HomeAction.settings, onAction),
          _MyRow('清除缓存', HomeAction.clearCache, onAction, trailing: cacheLabel),
          _MyRow('开放接口', HomeAction.interfaces, onAction),
          const _GroupGap(),
          _MyRow('使用说明', HomeAction.instructions, onAction),
          _MyRow('帮助', HomeAction.help, onAction, trailing: '版本：$version'),
        ],
      ),
    ),
  );
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.title, {this.subtitle});
  final String title;
  final String? subtitle;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 22, bottom: 12),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Text(
          title,
          style: const TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w600,
            color: _ink,
          ),
        ),
        if (subtitle != null) ...[
          const SizedBox(width: 8),
          Text(subtitle!, style: const TextStyle(fontSize: 10, color: _muted)),
        ],
      ],
    ),
  );
}

class _Surface extends StatelessWidget {
  const _Surface({required this.child, this.decoration});
  final Widget child;
  final BoxDecoration? decoration;
  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration:
        (decoration ??
                BoxDecoration(
                  color: _surface,
                  borderRadius: BorderRadius.circular(22),
                ))
            .copyWith(
              boxShadow: const [
                BoxShadow(
                  color: Color(0x06000000),
                  blurRadius: 8,
                  offset: Offset(0, 3),
                ),
              ],
            ),
    child: Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(22),
      child: child,
    ),
  );
}

class _Statistic extends StatelessWidget {
  const _Statistic(this.value, this.unit, this.label);
  final String value, unit, label;
  @override
  Widget build(BuildContext context) => Column(
    children: [
      FittedBox(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              value,
              style: const TextStyle(
                fontSize: 23,
                fontWeight: FontWeight.w600,
                color: _ink,
              ),
            ),
            Text(
              unit,
              style: const TextStyle(fontSize: 11, color: Color(0xFF505851)),
            ),
          ],
        ),
      ),
      const SizedBox(height: 7),
      Text(label, style: const TextStyle(fontSize: 11, color: _muted)),
    ],
  );
}

class _ColorIcon extends StatelessWidget {
  const _ColorIcon(this.icon, this.colors, {this.size = 50});
  final IconData icon;
  final List<Color> colors;
  final double size;
  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(size * 0.29),
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: colors,
      ),
      boxShadow: [
        BoxShadow(
          color: colors.last.withValues(alpha: 0.16),
          blurRadius: 7,
          offset: const Offset(0, 4),
        ),
      ],
    ),
    child: Icon(icon, color: Colors.white, size: size * 0.55),
  );
}

class _ToolButton extends StatelessWidget {
  const _ToolButton({
    required this.title,
    required this.detail,
    required this.icon,
    required this.colors,
    required this.action,
    required this.onAction,
  });
  final String title, detail;
  final IconData icon;
  final List<Color> colors;
  final HomeAction action;
  final ValueChanged<HomeAction> onAction;
  @override
  Widget build(BuildContext context) => InkWell(
    key: ValueKey('home-action-${action.name}'),
    borderRadius: BorderRadius.circular(20),
    onTap: () => onAction(action),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 16),
      child: Column(
        children: [
          _ColorIcon(icon, colors),
          const SizedBox(height: 8),
          Text(
            title,
            maxLines: 1,
            style: const TextStyle(fontSize: 12, color: _ink),
          ),
          const SizedBox(height: 3),
          Text(
            detail,
            maxLines: 1,
            style: const TextStyle(fontSize: 10, color: _muted),
          ),
        ],
      ),
    ),
  );
}

class _ActionRow extends StatelessWidget {
  const _ActionRow({
    required this.title,
    required this.detail,
    required this.icon,
    required this.colors,
    required this.action,
    required this.onAction,
  });
  final String title, detail;
  final IconData icon;
  final List<Color> colors;
  final HomeAction action;
  final ValueChanged<HomeAction> onAction;
  @override
  Widget build(BuildContext context) => InkWell(
    key: ValueKey('home-action-${action.name}'),
    borderRadius: BorderRadius.circular(22),
    onTap: () => onAction(action),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
      child: Row(
        children: [
          _ColorIcon(icon, colors, size: 43),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 14,
                    color: _ink,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  detail,
                  style: const TextStyle(fontSize: 11, color: _muted),
                ),
              ],
            ),
          ),
          const Icon(Icons.chevron_right, color: Color(0xFFA6ABA8), size: 18),
        ],
      ),
    ),
  );
}

class _LearningCard extends StatelessWidget {
  const _LearningCard({
    required this.title,
    required this.detail,
    required this.icon,
    required this.colors,
    required this.action,
    required this.onAction,
    required this.height,
    this.large = false,
  });
  final String title, detail;
  final IconData icon;
  final List<Color> colors;
  final HomeAction action;
  final ValueChanged<HomeAction> onAction;
  final double height;
  final bool large;
  @override
  Widget build(BuildContext context) => Container(
    height: height,
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(17),
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: colors,
      ),
    ),
    child: Material(
      color: Colors.transparent,
      child: InkWell(
        key: ValueKey('home-action-${action.name}'),
        borderRadius: BorderRadius.circular(17),
        onTap: () => onAction(action),
        child: Padding(
          padding: EdgeInsets.all(large ? 18 : 11),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, color: Colors.white, size: large ? 29 : 20),
              const Spacer(),
              Text(
                title,
                style: TextStyle(
                  fontSize: large ? 17 : 14,
                  color: Colors.white,
                  fontWeight: large ? FontWeight.w600 : FontWeight.w500,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                detail,
                style: const TextStyle(fontSize: 10, color: Color(0xDDFFFFFF)),
              ),
              if (large) ...[
                const SizedBox(height: 12),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 7,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.22),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: const Text(
                    '查看收藏 ›',
                    style: TextStyle(fontSize: 11, color: Colors.white),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    ),
  );
}

class _MyRow extends StatelessWidget {
  const _MyRow(this.title, this.action, this.onAction, {this.trailing});
  final String title;
  final HomeAction action;
  final ValueChanged<HomeAction> onAction;
  final String? trailing;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(left: 16),
    child: DecoratedBox(
      decoration: const BoxDecoration(
        border: Border(
          bottom: BorderSide(color: Color(0xFFE8EBE9), width: 0.6),
        ),
      ),
      child: InkWell(
        key: ValueKey('home-action-${action.name}'),
        onTap: () => onAction(action),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 52),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(0, 12, 12, 12),
            child: Row(
              children: [
                Text(title, style: const TextStyle(fontSize: 16, color: _ink)),
                const SizedBox(width: 12),
                if (trailing != null)
                  Expanded(
                    child: Text(
                      trailing!,
                      textAlign: TextAlign.right,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12, color: _muted),
                    ),
                  )
                else
                  const Spacer(),
                const SizedBox(width: 3),
                const Icon(
                  Icons.chevron_right,
                  color: Color(0xFFB7BDB9),
                  size: 19,
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

class _GroupGap extends StatelessWidget {
  const _GroupGap();
  @override
  Widget build(BuildContext context) =>
      const SizedBox(height: 18, child: ColoredBox(color: Color(0xFFFAFBFA)));
}
