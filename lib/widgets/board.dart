import 'package:flutter/material.dart';

/// chess.com-inspired board colors (their green theme).
const kLightSquare = Color(0xFFEBECD0);
const kDarkSquare = Color(0xFF739552);
const kSelected = Color(0x80F6F669);
const kLastMove = Color(0x66F6F669);
const kLegalDot = Color(0x59000000);

/// Piece sprites (cburnett set via python-chess, CC BY-SA 3.0 — the set
/// lichess ships; consistent proportions in both colors, unlike Unicode
/// glyphs which iOS renders as mismatched emoji).
Widget pieceImage(String piece, double size) => Image.asset(
  'assets/pieces/$piece.png',
  width: size,
  height: size,
  filterQuality: FilterQuality.medium,
);

/// An arrow drawn over the board (coach overlays: best move, threats).
class BoardArrow {
  const BoardArrow(this.from, this.to, this.color);
  final String from;
  final String to;
  final Color color;
}

class _ArrowPainter extends CustomPainter {
  const _ArrowPainter(this.arrows, this.flipped);
  final List<BoardArrow> arrows;
  final bool flipped;

  Offset _center(String square, double s) {
    var x = square.codeUnitAt(0) - 97; // a..h
    var y = square.codeUnitAt(1) - 49; // 1..8
    if (!flipped) y = 7 - y;
    if (flipped) x = 7 - x;
    return Offset((x + 0.5) * s, (y + 0.5) * s);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 8;
    for (final a in arrows) {
      final from = _center(a.from, s);
      final to = _center(a.to, s);
      final dir = (to - from);
      final len = dir.distance;
      if (len == 0) continue;
      final unit = dir / len;
      // start off-center so the piece stays visible; stop before the head
      final start = from + unit * (s * 0.30);
      final headBase = to - unit * (s * 0.30);
      final paint = Paint()
        ..color = a.color
        ..strokeWidth = s * 0.22
        ..strokeCap = StrokeCap.round;
      canvas.drawLine(start, headBase, paint);
      final normal = Offset(-unit.dy, unit.dx);
      final head = Path()
        ..moveTo(to.dx - unit.dx * s * 0.12, to.dy - unit.dy * s * 0.12)
        ..lineTo(
          headBase.dx + normal.dx * s * 0.24,
          headBase.dy + normal.dy * s * 0.24,
        )
        ..lineTo(
          headBase.dx - normal.dx * s * 0.24,
          headBase.dy - normal.dy * s * 0.24,
        )
        ..close();
      canvas.drawPath(head, Paint()..color = a.color);
    }
  }

  @override
  bool shouldRepaint(covariant _ArrowPainter old) =>
      old.arrows != arrows || old.flipped != flipped;
}

/// Interactive 8x8 board. Pure view: position comes in via [pieces],
/// move attempts go out via [onMove]. Supports tap-tap and drag, legal-move
/// dots, selection + last-move highlights, and flipping.
class ChessBoard extends StatefulWidget {
  const ChessBoard({
    super.key,
    required this.pieces,
    required this.onMove,
    required this.legalTargetsFor,
    this.flipped = false,
    this.lastMoveFrom,
    this.lastMoveTo,
    this.interactive = true,
    this.freeMove = false,
    this.onTap,
    this.onDoubleTap,
    this.onPlace,
    this.arrows = const [],
  });

  final Map<String, String> pieces;
  final void Function(String from, String to) onMove;
  final Set<String> Function(String square) legalTargetsFor;
  final bool flipped;
  final String? lastMoveFrom;
  final String? lastMoveTo;
  final bool interactive;

  /// Setup mode: drags may go anywhere and taps are delegated to [onTap]
  /// (the confirm screen's palette logic) instead of move selection.
  final bool freeMove;
  final void Function(String square)? onTap;

  /// Setup mode: double-tap on a square (e.g. to flip a piece's color).
  final void Function(String square)? onDoubleTap;

  /// Setup mode: a palette piece (drag data "new:<code>") dropped on a square.
  final void Function(String piece, String square)? onPlace;

  /// Coach overlays painted over the squares (best move, expected reply).
  final List<BoardArrow> arrows;

  @override
  State<ChessBoard> createState() => _ChessBoardState();
}

class _ChessBoardState extends State<ChessBoard> {
  String? _selected;
  Set<String> _targets = const {};

  String _squareAt(int index) {
    var file = index % 8;
    var rank = index ~/ 8; // 0 = top row as drawn
    if (widget.flipped) {
      file = 7 - file;
      rank = 7 - rank;
    }
    return '${'abcdefgh'[file]}${8 - rank}';
  }

  void _tap(String square) {
    if (!widget.interactive) return;
    if (widget.freeMove) {
      widget.onTap?.call(square);
      return;
    }
    setState(() {
      if (_selected == null) {
        if (widget.pieces.containsKey(square)) {
          _selected = square;
          _targets = widget.legalTargetsFor(square);
        }
      } else if (square == _selected) {
        _selected = null;
        _targets = const {};
      } else if (_targets.contains(square)) {
        widget.onMove(_selected!, square);
        _selected = null;
        _targets = const {};
      } else if (widget.pieces.containsKey(square)) {
        _selected = square;
        _targets = widget.legalTargetsFor(square);
      } else {
        _selected = null;
        _targets = const {};
      }
    });
  }

  void _drop(String from, String to) {
    if (from.startsWith('new:')) {
      widget.onPlace?.call(from.substring(4), to);
    } else if (from != to &&
        (widget.freeMove || widget.legalTargetsFor(from).contains(to))) {
      widget.onMove(from, to);
    }
    setState(() {
      _selected = null;
      _targets = const {};
    });
  }

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: 1,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final squareSize = constraints.maxWidth / 8;
          final grid = GridView.builder(
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 8,
            ),
            itemCount: 64,
            itemBuilder: (context, index) {
              final square = _squareAt(index);
              final isDark = (index % 8 + index ~/ 8) % 2 == 1;
              final piece = widget.pieces[square];
              final highlight = square == _selected
                  ? kSelected
                  : (square == widget.lastMoveFrom ||
                        square == widget.lastMoveTo)
                  ? kLastMove
                  : null;

              final glyph = piece == null
                  ? null
                  : pieceImage(piece, squareSize * 0.92);

              return DragTarget<String>(
                onAcceptWithDetails: (details) => _drop(details.data, square),
                builder: (context, candidates, rejected) => GestureDetector(
                  onTap: () => _tap(square),
                  onDoubleTap: widget.freeMove && widget.onDoubleTap != null
                      ? () => widget.onDoubleTap!(square)
                      : null,
                  child: Container(
                    color: isDark ? kDarkSquare : kLightSquare,
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        if (highlight != null)
                          Positioned.fill(child: ColoredBox(color: highlight)),
                        if (_targets.contains(square) && piece == null)
                          Container(
                            width: squareSize * 0.3,
                            height: squareSize * 0.3,
                            decoration: const BoxDecoration(
                              color: kLegalDot,
                              shape: BoxShape.circle,
                            ),
                          ),
                        if (_targets.contains(square) && piece != null)
                          Positioned.fill(
                            child: Container(
                              decoration: BoxDecoration(
                                border: Border.all(
                                  color: kLegalDot,
                                  width: squareSize * 0.08,
                                ),
                              ),
                            ),
                          ),
                        if (glyph != null)
                          widget.interactive
                              ? Draggable<String>(
                                  data: square,
                                  onDragStarted: () => setState(() {
                                    _selected = square;
                                    _targets = widget.freeMove
                                        ? const {}
                                        : widget.legalTargetsFor(square);
                                  }),
                                  feedback: Material(
                                    color: Colors.transparent,
                                    child: SizedBox(
                                      width: squareSize,
                                      height: squareSize,
                                      child: Center(child: glyph),
                                    ),
                                  ),
                                  childWhenDragging: const SizedBox.shrink(),
                                  child: glyph,
                                )
                              : glyph,
                        if ('abcdefgh'.contains(square[0]) &&
                            square[1] == (widget.flipped ? '8' : '1'))
                          Positioned(
                            right: 2,
                            bottom: 1,
                            child: Text(
                              square[0],
                              style: TextStyle(
                                fontSize: squareSize * 0.18,
                                fontWeight: FontWeight.bold,
                                color: isDark ? kLightSquare : kDarkSquare,
                              ),
                            ),
                          ),
                        if (square[0] == (widget.flipped ? 'h' : 'a'))
                          Positioned(
                            left: 2,
                            top: 1,
                            child: Text(
                              square[1],
                              style: TextStyle(
                                fontSize: squareSize * 0.18,
                                fontWeight: FontWeight.bold,
                                color: isDark ? kLightSquare : kDarkSquare,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              );
            },
          );
          return Stack(
            children: [
              grid,
              if (widget.arrows.isNotEmpty)
                IgnorePointer(
                  child: CustomPaint(
                    size: Size.square(constraints.maxWidth),
                    painter: _ArrowPainter(widget.arrows, widget.flipped),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}
