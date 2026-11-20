import 'package:material_ui/material_ui.dart';

enum ImportSource { wifi, music, icloud, onedrive, album, itunes, nas }

class ImportPage extends StatelessWidget {
  const ImportPage({super.key, required this.onSelect, this.onHelp});

  final void Function(ImportSource) onSelect;
  final VoidCallback? onHelp;

  static const _sources = [
    (ImportSource.wifi, 'WiFi批量导入', Icons.wifi, Color(0xFF1476D8)),
    (
      ImportSource.music,
      '从 Apple Music 应用导入',
      Icons.music_note,
      Color(0xFFDC1955),
    ),
    (ImportSource.icloud, 'iCloud 导入', Icons.cloud_outlined, Color(0xFF1975CC)),
    (
      ImportSource.onedrive,
      'OneDrive',
      Icons.cloud_outlined,
      Color(0xFF196E9C),
    ),
    (
      ImportSource.album,
      '相册导入',
      Icons.photo_library_outlined,
      Color(0xFF4BC561),
    ),
    (
      ImportSource.itunes,
      '从 iTunes 导入',
      Icons.desktop_windows_outlined,
      Color(0xFF5B44BA),
    ),
    (ImportSource.nas, '从 NAS 下载', Icons.dns_outlined, Color(0xFFD99020)),
  ];

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: Colors.white,
    child: CustomScrollView(
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          sliver: SliverList.separated(
            itemCount: _sources.length,
            separatorBuilder: (_, _) => const Divider(
              height: 1,
              thickness: .6,
              color: Color(0xFFECEFEB),
            ),
            itemBuilder: (context, index) {
              final (source, title, icon, color) = _sources[index];
              return Semantics(
                button: true,
                child: InkWell(
                  onTap: () => onSelect(source),
                  child: SizedBox(
                    height: 59,
                    child: Row(
                      children: [
                        SizedBox(
                          width: 30,
                          child: Icon(icon, color: color, size: 28),
                        ),
                        const SizedBox(width: 15),
                        Expanded(
                          child: Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 16,
                              color: Color(0xFF171B17),
                            ),
                          ),
                        ),
                        if (source == ImportSource.wifi) ...[
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: const Color(0xFFF58425),
                              borderRadius: BorderRadius.circular(3),
                            ),
                            child: const Text(
                              '推荐',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 10,
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                        ],
                        const Icon(
                          Icons.chevron_right,
                          color: Color(0xFF949B94),
                          size: 22,
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        SliverFillRemaining(
          hasScrollBody: false,
          child: Align(
            alignment: Alignment.bottomCenter,
            child: SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.only(top: 40, bottom: 22),
                child: TextButton(
                  onPressed: onHelp,
                  style: TextButton.styleFrom(
                    foregroundColor: const Color(0xFF666C66),
                  ),
                  child: const Text('帮助', style: TextStyle(fontSize: 13)),
                ),
              ),
            ),
          ),
        ),
      ],
    ),
  );
}
