import 'package:flutter/material.dart';

import '../services/photo_bytes.dart';

/// Floating photo panel: drag the handle bar to move the whole rectangle
/// (to uncover the board behind it); pan/pinch inside to move the photo
/// within it. Two independent gestures on purpose. Owns its position —
/// place inside a Stack and pass the Stack's bounds.
class FloatingPhotoPanel extends StatefulWidget {
  const FloatingPhotoPanel({
    super.key,
    required this.photoPath,
    required this.bounds,
    required this.onClose,
  });

  final String photoPath;
  final Size bounds;
  final VoidCallback onClose;

  @override
  State<FloatingPhotoPanel> createState() => _FloatingPhotoPanelState();
}

class _FloatingPhotoPanelState extends State<FloatingPhotoPanel> {
  Offset? _offset; // null until first shown: placed top-right in build
  Size? _size; // null until first shown: sized to bounds in build

  void _resize(Offset delta, {required bool left, required bool top}) {
    setState(() {
      final s = _size!;
      final maxW = widget.bounds.width;
      final maxH = widget.bounds.height;
      final w = (s.width + (left ? -delta.dx : delta.dx)).clamp(170.0, maxW);
      final h = (s.height + (top ? -delta.dy : delta.dy)).clamp(170.0, maxH);
      var o = _offset!;
      if (left) o = o.translate(s.width - w, 0);
      if (top) o = o.translate(0, s.height - h);
      _offset = o;
      _size = Size(w, h);
    });
  }

  /// Corner grip that resizes the panel (the X owns the fourth corner).
  Widget _resizeHandle({required bool left, required bool top}) {
    return Positioned(
      left: left ? 0 : null,
      right: left ? null : 0,
      top: top ? 0 : null,
      bottom: top ? null : 0,
      child: MouseRegion(
        cursor: (left == top)
            ? SystemMouseCursors.resizeUpLeftDownRight
            : SystemMouseCursors.resizeUpRightDownLeft,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanUpdate: (d) => _resize(d.delta, left: left, top: top),
          child: const SizedBox(width: 22, height: 22),
        ),
      ),
    );
  }

  /// An edge strip that moves the whole panel when dragged — the panel is
  /// grabbable from all four sides; only the photo itself pans/zooms.
  Widget _dragZone({
    double? width,
    double? height,
    required Offset pos,
    Widget? child,
  }) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onPanUpdate: (d) => setState(() => _offset = pos + d.delta),
      child: SizedBox(width: width, height: height, child: child),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bounds = widget.bounds;
    _size ??= () {
      final w = (bounds.width * 0.72).clamp(220.0, 360.0);
      return Size(w, w);
    }();
    final width = _size!.width;
    final height = _size!.height;
    // first appearance: hug the content column's top-right (where the
    // photo toggle lives), not the window's far corner — content is
    // centered and capped at ~900 on wide screens
    _offset ??= Offset(
      (bounds.width + 900) / 2 < bounds.width - 8
          ? (bounds.width + 900) / 2 - width / 2
          : bounds.width - width - 8,
      8,
    );
    final pos = Offset(
      _offset!.dx.clamp(40.0 - width, bounds.width - 40.0),
      _offset!.dy.clamp(0.0, bounds.height - 48.0),
    );
    return Positioned(
      left: pos.dx,
      top: pos.dy,
      child: Material(
        elevation: 10,
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        color: theme.colorScheme.surfaceContainerHighest,
        child: SizedBox(
          width: width,
          height: height,
          child: Stack(
            children: [
              Column(
                children: [
                  _dragZone(
                    height: 36,
                    child: Stack(
                      children: [
                        Center(
                          child: CustomPaint(
                            size: const Size(96, 14),
                            painter: GripPainter(theme.colorScheme.outline),
                          ),
                        ),
                        Positioned(
                          right: 0,
                          top: 0,
                          bottom: 0,
                          child: InkWell(
                            onTap: widget.onClose,
                            child: const Padding(
                              padding: EdgeInsets.all(8),
                              child: Icon(Icons.close, size: 20),
                            ),
                          ),
                        ),
                      ],
                    ),
                    pos: pos,
                  ),
                  Expanded(
                    child: Row(
                      children: [
                        _dragZone(width: 18, pos: pos),
                        Expanded(
                          child: InteractiveViewer(
                            maxScale: 8,
                            child: SizedBox.expand(
                              child: photoImage(
                                widget.photoPath,
                                fit: BoxFit.contain,
                              ),
                            ),
                          ),
                        ),
                        _dragZone(width: 18, pos: pos),
                      ],
                    ),
                  ),
                  _dragZone(
                    height: 22,
                    pos: pos,
                    child: Center(
                      child: CustomPaint(
                        size: const Size(64, 14),
                        painter: GripPainter(theme.colorScheme.outline),
                      ),
                    ),
                  ),
                ],
              ),
              // pull a corner to grow/shrink the panel; top-right stays
              // the close button
              _resizeHandle(left: true, top: true),
              _resizeHandle(left: true, top: false),
              _resizeHandle(left: false, top: false),
            ],
          ),
        ),
      ),
    );
  }
}

/// Continuous 2-row dot grid with uniform pitch — one grip texture, not a
/// row of icon glyphs with gaps between them.
class GripPainter extends CustomPainter {
  const GripPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    const pitch = 7.0;
    final cols = (size.width / pitch).floor();
    final x0 = (size.width - (cols - 1) * pitch) / 2;
    for (var row = 0; row < 2; row++) {
      final y = size.height / 2 + (row - 0.5) * pitch;
      for (var col = 0; col < cols; col++) {
        canvas.drawCircle(Offset(x0 + col * pitch, y), 1.6, paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant GripPainter old) => old.color != color;
}
