import 'package:flutter/material.dart';

import '../models/setup_state.dart';
import 'board.dart';

/// Classic yin-yang: instantly reads as "swap black and white".
class _YinYangPainter extends CustomPainter {
  const _YinYangPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2);
    final r = size.width / 2 - 1;
    final white = Paint()..color = Colors.white;
    final black = Paint()..color = const Color(0xFF1E1E1E);
    final outline = Paint()
      ..color = const Color(0xFF1E1E1E)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;

    canvas.drawCircle(c, r, white);
    // black half: right semicircle, then S-curve through the two half-lobes
    final path = Path()
      ..moveTo(c.dx, c.dy - r)
      ..arcTo(
        Rect.fromCircle(center: c, radius: r),
        -3.14159 / 2,
        3.14159,
        false,
      )
      ..arcTo(
        Rect.fromCircle(center: Offset(c.dx, c.dy + r / 2), radius: r / 2),
        3.14159 / 2,
        -3.14159,
        false,
      )
      ..arcTo(
        Rect.fromCircle(center: Offset(c.dx, c.dy - r / 2), radius: r / 2),
        3.14159 / 2,
        3.14159,
        false,
      )
      ..close();
    canvas.drawPath(path, black);
    canvas.drawCircle(Offset(c.dx, c.dy - r / 2), r / 6, black);
    canvas.drawCircle(Offset(c.dx, c.dy + r / 2), r / 6, white);
    canvas.drawCircle(c, r, outline);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// Whose-turn selector: a white and a black disc; the highlighted one is to
/// move. Self-descriptive — the tiny "turn" caption appears in the selected
/// disc only.
class TurnDot extends StatelessWidget {
  const TurnDot({
    super.key,
    required this.white,
    required this.selected,
    required this.onTap,
  });

  final bool white;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: white ? Colors.white : const Color(0xFF1E1E1E),
          border: Border.all(
            color: selected
                ? theme.colorScheme.primary
                : theme.colorScheme.outlineVariant,
            width: selected ? 3 : 1,
          ),
        ),
        child: selected
            ? Center(
                child: Text(
                  'turn',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: white ? Colors.black54 : Colors.white70,
                  ),
                ),
              )
            : null,
      ),
    );
  }
}

/// Free-placement piece palette: six pieces of one color, an eraser, and a
/// color-swap chip. Shared by the confirm screen and the analysis-board
/// position editor.
class SetupPalette extends StatelessWidget {
  const SetupPalette({super.key, required this.setup});
  final SetupState setup;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = setup.paletteWhite ? 'w' : 'b';
    Widget chip(
      String code,
      Widget child, {
      String? tooltip,
      bool draggable = false,
    }) {
      final selected = setup.tool == code;
      Widget box = Container(
        width: 44,
        height: 44,
        margin: const EdgeInsets.symmetric(horizontal: 3),
        decoration: BoxDecoration(
          color: selected
              ? theme.colorScheme.primaryContainer
              : theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(8),
          border: selected
              ? Border.all(color: theme.colorScheme.primary, width: 2)
              : null,
        ),
        child: Center(child: child),
      );
      if (tooltip != null) box = Tooltip(message: tooltip, child: box);
      box = GestureDetector(onTap: () => setup.selectTool(code), child: box);
      if (draggable) {
        // drag a palette piece straight onto a square (tap-select works too)
        box = Draggable<String>(
          data: 'new:$code',
          feedback: pieceImage(code, 52),
          childWhenDragging: Opacity(opacity: 0.4, child: box),
          child: box,
        );
      }
      return box;
    }

    // one color at a time; double-tap the strip (or the swap chip) to flip
    return GestureDetector(
      onDoubleTap: setup.togglePaletteColor,
      behavior: HitTestBehavior.opaque,
      child: Container(
        margin: const EdgeInsets.fromLTRB(12, 4, 12, 2),
        padding: const EdgeInsets.symmetric(vertical: 6),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Wrap(
          alignment: WrapAlignment.center,
          runSpacing: 6,
          children: [
            for (final kind in ['K', 'Q', 'R', 'B', 'N', 'P'])
              chip(
                '$color$kind',
                pieceImage('$color$kind', 38),
                draggable: true,
              ),
            chip(
              'erase',
              Icon(
                Icons.cleaning_services_outlined,
                color: theme.colorScheme.error,
                size: 24,
              ),
              tooltip: 'Eraser: tap squares to clear them',
            ),
            GestureDetector(
              onTap: setup.togglePaletteColor,
              child: Tooltip(
                message: 'Flip palette color (or double-tap the strip)',
                child: Container(
                  width: 44,
                  height: 44,
                  margin: const EdgeInsets.symmetric(horizontal: 3),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Center(
                    child: CustomPaint(
                      size: Size(28, 28),
                      painter: _YinYangPainter(),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
