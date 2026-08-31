import 'dart:io';

import 'package:flutter/material.dart';

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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bounds = widget.bounds;
    final width = (bounds.width * 0.72).clamp(220.0, 360.0);
    final height = width * 1.0;
    _offset ??= Offset(bounds.width - width - 8, 8);
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
          child: Column(
            children: [
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onPanUpdate: (d) => setState(() => _offset = pos + d.delta),
                child: SizedBox(
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
                ),
              ),
              Expanded(
                child: InteractiveViewer(
                  maxScale: 8,
                  child: SizedBox.expand(
                    child: Image.file(
                      File(widget.photoPath),
                      fit: BoxFit.contain,
                    ),
                  ),
                ),
              ),
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
