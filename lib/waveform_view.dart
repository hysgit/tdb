import 'dart:async';
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:just_waveform/just_waveform.dart';

import 'services/player.dart';
import 'services/waveform.dart';

class StudyWaveform extends StatefulWidget {
  const StudyWaveform({
    super.key,
    required this.player,
    this.a,
    this.b,
    required this.onSeek,
    required this.onRangeChanged,
    this.height = 76,
    this.waveformService,
  });

  final StudyPlayer player;
  final Duration? a;
  final Duration? b;
  final ValueChanged<Duration> onSeek;
  final void Function(Duration a, Duration b) onRangeChanged;
  final double height;
  final WaveformService? waveformService;

  @override
  State<StudyWaveform> createState() => _StudyWaveformState();
}

class _StudyWaveformState extends State<StudyWaveform> {
  static const _pixelsPerSecond = 48.0;
  final _scroll = ScrollController();
  Waveform? _waveform;
  String? _path;
  String? _error;
  int _generation = 0;
  bool _loading = false;
  bool _follow = true;
  bool _draggingBoundary = false;
  Duration? _dragA;
  Duration? _dragB;
  double _viewportWidth = 0;

  Duration get _duration {
    final actual = widget.player.duration;
    return actual > Duration.zero
        ? actual
        : _waveform?.duration ?? Duration.zero;
  }

  @override
  void initState() {
    super.initState();
    widget.player.addListener(_onPlayer);
    _scroll.addListener(_onScroll);
    _load();
  }

  @override
  void didUpdateWidget(covariant StudyWaveform oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.player != widget.player) {
      oldWidget.player.removeListener(_onPlayer);
      widget.player.addListener(_onPlayer);
      _load(force: true);
    } else if (_path != widget.player.item?.path) {
      _load();
    }
  }

  void _onScroll() {
    if (mounted) setState(() {});
  }

  void _onPlayer() {
    if (!mounted) return;
    if (_path != widget.player.item?.path) _load();
    if (_follow && !_draggingBoundary) _followPosition();
    setState(() {});
  }

  void _load({bool force = false}) {
    final path = widget.player.item?.path;
    if (!force && path == _path) return;
    final generation = ++_generation;
    _path = path;
    _waveform = null;
    _error = null;
    _follow = true;
    _draggingBoundary = false;
    _dragA = null;
    _dragB = null;
    _loading = path != null;
    if (path == null) return;
    unawaited(_resolve(path, generation));
  }

  Future<void> _resolve(String path, int generation) async {
    try {
      final waveform = await (widget.waveformService ?? WaveformService.shared)
          .load(path);
      if (!mounted || generation != _generation || path != _path) return;
      setState(() {
        _waveform = waveform;
        _loading = false;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _followPosition();
      });
    } catch (error) {
      if (!mounted || generation != _generation || path != _path) return;
      setState(() {
        _error = '无法生成波形：$error';
        _loading = false;
      });
    }
  }

  void _followPosition() {
    if (!_scroll.hasClients || _viewportWidth <= 0) return;
    final target =
        (widget.player.position.inMicroseconds / 1000000 * _pixelsPerSecond)
            .clamp(0.0, _scroll.position.maxScrollExtent);
    if ((_scroll.offset - target).abs() > 0.5) _scroll.jumpTo(target);
  }

  Duration _timeAt(double x) => Duration(
    microseconds: (((x - _viewportWidth / 2) / _pixelsPerSecond) * 1000000)
        .round()
        .clamp(0, _duration.inMicroseconds),
  );

  void _startBoundaryDrag() {
    _follow = false;
    _draggingBoundary = true;
    _dragA = widget.a;
    _dragB = widget.b;
    setState(() {});
  }

  void _dragBoundary(bool isA, double delta) {
    if (_dragA == null || _dragB == null) return;
    final deltaUs = (delta / _pixelsPerSecond * 1000000).round();
    const minimumSpanUs = 1000;
    setState(() {
      if (isA) {
        _dragA = Duration(
          microseconds: (_dragA!.inMicroseconds + deltaUs).clamp(
            0,
            math.max(0, _dragB!.inMicroseconds - minimumSpanUs),
          ),
        );
      } else {
        _dragB = Duration(
          microseconds: (_dragB!.inMicroseconds + deltaUs).clamp(
            math.min(
              _dragA!.inMicroseconds + minimumSpanUs,
              _duration.inMicroseconds,
            ),
            _duration.inMicroseconds,
          ),
        );
      }
    });
  }

  void _finishBoundaryDrag({bool cancelled = false}) {
    final a = _dragA;
    final b = _dragB;
    _draggingBoundary = false;
    _dragA = null;
    _dragB = null;
    if (!cancelled && a != null && b != null && a < b) {
      widget.onRangeChanged(a, b);
    }
    setState(() {});
  }

  Widget _handle(bool isA, Duration time, double origin) => Positioned(
    left: origin + time.inMicroseconds / 1000000 * _pixelsPerSecond - 22,
    top: 0,
    bottom: 0,
    width: 44,
    child: Semantics(
      label: isA ? '拖动 A 点' : '拖动 B 点',
      child: GestureDetector(
        key: ValueKey(isA ? 'waveform-a-handle' : 'waveform-b-handle'),
        behavior: HitTestBehavior.opaque,
        onHorizontalDragStart: (_) => _startBoundaryDrag(),
        onHorizontalDragUpdate: (event) => _dragBoundary(isA, event.delta.dx),
        onHorizontalDragEnd: (_) => _finishBoundaryDrag(),
        onHorizontalDragCancel: () => _finishBoundaryDrag(cancelled: true),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: widget.height,
      child: ColoredBox(
        color: Colors.white,
        child: LayoutBuilder(
          builder: (context, constraints) {
            _viewportWidth = constraints.maxWidth;
            if (_loading) {
              return const Center(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 1.5),
                    ),
                    SizedBox(width: 8),
                    Text(
                      '正在生成波形…',
                      style: TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                  ],
                ),
              );
            }
            if (_error != null) {
              return Tooltip(
                message: _error!,
                child: Center(
                  child: TextButton.icon(
                    onPressed: () {
                      setState(() => _load(force: true));
                    },
                    icon: const Icon(Icons.refresh, size: 16),
                    label: const Text(
                      '无法生成波形，点此重试',
                      style: TextStyle(fontSize: 12),
                    ),
                  ),
                ),
              );
            }
            final waveform = _waveform;
            if (waveform == null) {
              return const Center(
                child: Text(
                  '导入音频后显示波形',
                  style: TextStyle(fontSize: 12, color: Colors.grey),
                ),
              );
            }
            final origin = _viewportWidth / 2;
            final width = math.max(
              _viewportWidth,
              _duration.inMicroseconds / 1000000 * _pixelsPerSecond +
                  _viewportWidth,
            );
            final a = _dragA ?? widget.a;
            final b = _dragB ?? widget.b;
            final validRange =
                a != null &&
                b != null &&
                a >= Duration.zero &&
                a < b &&
                b <= _duration;
            return Stack(
              children: [
                NotificationListener<ScrollStartNotification>(
                  onNotification: (notification) {
                    if (notification.dragDetails != null &&
                        !_draggingBoundary) {
                      setState(() => _follow = false);
                    }
                    return false;
                  },
                  child: SingleChildScrollView(
                    key: const ValueKey('waveform-scroll'),
                    controller: _scroll,
                    scrollDirection: Axis.horizontal,
                    child: SizedBox(
                      width: width,
                      height: widget.height,
                      child: Stack(
                        children: [
                          Positioned.fill(
                            child: GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTapUp: (event) {
                                setState(() => _follow = true);
                                widget.onSeek(_timeAt(event.localPosition.dx));
                              },
                              child: CustomPaint(
                                painter: _WaveformPainter(
                                  waveform: waveform,
                                  origin: origin,
                                  pixelsPerSecond: _pixelsPerSecond,
                                  offset: _scroll.hasClients
                                      ? _scroll.offset
                                      : 0,
                                  viewportWidth: _viewportWidth,
                                  position: widget.player.position,
                                  a: validRange ? a : null,
                                  b: validRange ? b : null,
                                ),
                              ),
                            ),
                          ),
                          if (validRange) _handle(true, a, origin),
                          if (validRange) _handle(false, b, origin),
                        ],
                      ),
                    ),
                  ),
                ),
                if (!_follow && !_draggingBoundary)
                  Positioned(
                    right: 2,
                    top: 0,
                    child: TextButton(
                      style: TextButton.styleFrom(
                        backgroundColor: Colors.white.withValues(alpha: 0.9),
                        minimumSize: const Size(44, 44),
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                      ),
                      onPressed: () {
                        setState(() => _follow = true);
                        _followPosition();
                      },
                      child: const Text(
                        '自动滚动',
                        style: TextStyle(
                          fontSize: 11,
                          color: Color(0xFFBC8B4E),
                        ),
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }

  @override
  void dispose() {
    _generation++;
    widget.player.removeListener(_onPlayer);
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    // Native extraction continues until completion; its service owns cleanup.
    super.dispose();
  }
}

class _WaveformPainter extends CustomPainter {
  const _WaveformPainter({
    required this.waveform,
    required this.origin,
    required this.pixelsPerSecond,
    required this.offset,
    required this.viewportWidth,
    required this.position,
    this.a,
    this.b,
  });
  final Waveform waveform;
  final double origin;
  final double pixelsPerSecond;
  final double offset;
  final double viewportWidth;
  final Duration position;
  final Duration? a;
  final Duration? b;

  double _x(Duration time) =>
      origin + time.inMicroseconds / 1000000 * pixelsPerSecond;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.height / 2;
    final scale =
        (size.height / 2 - 5) / ((waveform.flags & 1) == 0 ? 32768 : 128);
    final startX = math.max(origin, offset).floorToDouble();
    final endX = math.min(
      origin + waveform.duration.inMicroseconds / 1000000 * pixelsPerSecond,
      offset + viewportWidth,
    );
    final wavePaint = Paint()
      ..color = const Color(0xFFE8D571)
      ..strokeWidth = 1;
    if (a != null && b != null) {
      canvas.drawRect(
        Rect.fromLTRB(_x(a!), 0, _x(b!), size.height),
        Paint()..color = const Color(0xFFFFF9E8),
      );
    }
    for (double x = startX; x <= endX; x += 2.4) {
      final startTime = Duration(
        microseconds: ((x - origin) / pixelsPerSecond * 1000000).round(),
      );
      final endTime = Duration(
        microseconds: ((x + 2.4 - origin) / pixelsPerSecond * 1000000).round(),
      );
      final from = waveform
          .positionToPixel(startTime)
          .floor()
          .clamp(0, waveform.length - 1);
      final to = waveform
          .positionToPixel(endTime)
          .ceil()
          .clamp(from + 1, waveform.length);
      var minimum = waveform.getPixelMin(from);
      var maximum = waveform.getPixelMax(from);
      for (var i = from + 1; i < to; i++) {
        minimum = math.min(minimum, waveform.getPixelMin(i));
        maximum = math.max(maximum, waveform.getPixelMax(i));
      }
      final top = (center - maximum * scale).clamp(4.0, size.height - 4);
      final bottom = (center - minimum * scale).clamp(4.0, size.height - 4);
      canvas.drawLine(Offset(x, top), Offset(x, bottom), wavePaint);
    }
    canvas.drawLine(
      Offset(_x(position), 0),
      Offset(_x(position), size.height),
      Paint()
        ..color = const Color(0xFF858585)
        ..strokeWidth = 1,
    );
    if (a != null && b != null) {
      _boundary(canvas, size, _x(a!), const Color(0xFF536EB6), true);
      _boundary(canvas, size, _x(b!), const Color(0xFFD87766), false);
    }
  }

  void _boundary(Canvas canvas, Size size, double x, Color color, bool isA) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1;
    canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    final direction = isA ? 1 : -1;
    for (final bottom in [false, true]) {
      final y = bottom ? size.height : 0.0;
      final triangle = Path()
        ..moveTo(x, y)
        ..lineTo(x + direction * 7, y)
        ..lineTo(x, y + (bottom ? -7 : 7))
        ..close();
      canvas.drawPath(triangle, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _WaveformPainter oldDelegate) =>
      oldDelegate.waveform != waveform ||
      oldDelegate.position != position ||
      oldDelegate.offset != offset ||
      oldDelegate.viewportWidth != viewportWidth ||
      oldDelegate.a != a ||
      oldDelegate.b != b;
}
