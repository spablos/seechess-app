import 'package:chess/chess.dart' as ch;
import 'package:flutter/foundation.dart';

const files = 'abcdefgh';

/// Editable position for the confirm screen: a free-placement board (no
/// legality rules — the photo shows whatever it shows) plus whose turn.
class SetupState extends ChangeNotifier {
  SetupState({Map<String, String>? pieces})
    : pieces = Map.of(pieces ?? const {});

  /// square -> "wP".."bK"
  final Map<String, String> pieces;
  bool whiteToMove = true;

  /// Currently selected palette tool: a piece code, 'erase', or null (move).
  String? tool;

  /// Which color the (single-color) palette currently offers.
  bool paletteWhite = true;

  /// Flip the palette's color; a selected piece tool follows the flip.
  void togglePaletteColor() {
    paletteWhite = !paletteWhite;
    if (tool != null && tool != 'erase') {
      tool = (paletteWhite ? 'w' : 'b') + tool!.substring(1);
    }
    notifyListeners();
  }

  /// Flip the color of the piece standing on [square], if any.
  void flipPiece(String square) {
    final piece = pieces[square];
    if (piece == null) return;
    pieces[square] = (piece[0] == 'w' ? 'b' : 'w') + piece.substring(1);
    notifyListeners();
  }

  static SetupState fromFen(String placement) {
    final map = <String, String>{};
    final ranks = placement.split(' ').first.split('/');
    for (var r = 0; r < 8; r++) {
      var file = 0;
      for (final ch in ranks[r].split('')) {
        final digit = int.tryParse(ch);
        if (digit != null) {
          file += digit;
        } else {
          final square = '${files[file]}${8 - r}';
          map[square] = (ch == ch.toUpperCase() ? 'w' : 'b') + ch.toUpperCase();
          file++;
        }
      }
    }
    return SetupState(pieces: map);
  }

  void selectTool(String? newTool) {
    tool = (tool == newTool) ? null : newTool;
    notifyListeners();
  }

  void tapSquare(String square) {
    if (tool == 'erase') {
      pieces.remove(square);
    } else if (tool != null) {
      pieces[square] = tool!;
    } else {
      return;
    }
    notifyListeners();
  }

  void move(String from, String to) {
    final piece = pieces.remove(from);
    if (piece != null) pieces[to] = piece;
    notifyListeners();
  }

  /// Drag-off-board delete.
  void remove(String square) {
    if (pieces.remove(square) != null) notifyListeners();
  }

  /// Drag-from-palette placement.
  void place(String piece, String square) {
    pieces[square] = piece;
    notifyListeners();
  }

  /// Rotate the whole position 90° clockwise (a1 -> a8). For when
  /// recognition read the board in the wrong orientation; tap up to three
  /// times to reach any of the four orientations.
  void rotate90() {
    final rotated = <String, String>{};
    pieces.forEach((square, piece) {
      final f = files.indexOf(square[0]);
      final r = int.parse(square[1]) - 1;
      rotated['${files[r]}${8 - f}'] = piece;
    });
    pieces
      ..clear()
      ..addAll(rotated);
    notifyListeners();
  }

  void setTurn(bool white) {
    whiteToMove = white;
    notifyListeners();
  }

  void clear() {
    pieces.clear();
    notifyListeners();
  }

  bool get hasBothKings =>
      pieces.containsValue('wK') && pieces.containsValue('bK');

  /// Human-readable reason this position is not a legal chess position, or
  /// null if it's fine. Stockfish runs in-process and an illegal position
  /// (duplicate kings, back-rank pawn, capturable king) crashes the whole
  /// app — so nothing invalid may reach confirm/analyze.
  String? validationError() {
    // validate_fen accepts a fully EMPTY board (its king check only fires
    // when some piece exists) — catch missing kings of any flavor first
    if (!hasBothKings) return 'Each side needs exactly one king.';
    final result = ch.Chess.validate_fen(toFen());
    if (result['valid'] as bool) return null;
    switch (result['error_number'] as int) {
      case 11:
        return 'Each side needs exactly one king.';
      case 12:
        return 'The two kings can\'t stand on adjacent squares.';
      case 13:
        return 'Pawns can\'t stand on the first or last rank.';
      case 14:
        final checked = whiteToMove ? 'Black' : 'White';
        final mover = whiteToMove ? 'White' : 'Black';
        return '$checked is in check but it\'s $mover\'s turn — switch '
            'whose turn it is, or fix the position.';
      default:
        return 'This isn\'t a valid position: ${result['error']}';
    }
  }

  /// The side that must be to move because its king stands in check —
  /// the other side to move would be an illegal position. Null when
  /// neither king is attacked (or kings are missing/adjacent).
  String? impliedTurn() {
    if (!hasBothKings) return null;
    final placement = toFen().split(' ').first;
    bool attacked(String turn, ch.Color color) {
      try {
        final g = ch.Chess.fromFEN('$placement $turn - - 0 1');
        return g.king_attacked(color);
      } catch (_) {
        return false;
      }
    }

    // with White to move, a Black king already under attack is impossible
    final whiteInCheck = attacked('w', ch.Color.WHITE);
    final blackInCheck = attacked('b', ch.Color.BLACK);
    if (whiteInCheck && !blackInCheck) return 'w';
    if (blackInCheck && !whiteInCheck) return 'b';
    return null; // neither, or both (broken position) — no inference
  }

  /// Reachability nudge: material no legal game can produce, or null.
  /// Extra pieces beyond the starting set only come from promotion, and
  /// every promotion consumes a pawn — so surplus can never exceed the
  /// number of missing pawns. Static legality is checked elsewhere
  /// ([validationError]); this is advisory only — on a photo of a real
  /// game, impossible material usually means a misread piece.
  String? materialWarning() {
    for (final color in ['w', 'b']) {
      final side = color == 'w' ? 'White' : 'Black';
      int count(String kind) =>
          pieces.values.where((p) => p == '$color$kind').length;
      final pawns = count('P');
      if (pawns > 8) {
        return '$side has $pawns pawns — a game can never have more '
            'than eight.';
      }
      var promotions = 0;
      for (final e in {'Q': 1, 'R': 2, 'B': 2, 'N': 2}.entries) {
        promotions += (count(e.key) - e.value).clamp(0, 64);
      }
      if (promotions > 8 - pawns) {
        return '$side\'s extra pieces would need $promotions '
            'promotion${promotions == 1 ? '' : 's'}, but only '
            '${8 - pawns} pawn${8 - pawns == 1 ? ' is' : 's are'} missing — '
            'this material can\'t arise from a real game.';
      }
    }
    return null;
  }

  /// Full FEN with heuristic castling rights (rook+king on start squares)
  /// and no en-passant — the chess.com-style default for imported positions.
  String toFen() {
    final rows = <String>[];
    for (var r = 8; r >= 1; r--) {
      var row = '';
      var empty = 0;
      for (var f = 0; f < 8; f++) {
        final piece = pieces['${files[f]}$r'];
        if (piece == null) {
          empty++;
        } else {
          if (empty > 0) row += '$empty';
          empty = 0;
          final letter = piece[1];
          row += piece[0] == 'w' ? letter : letter.toLowerCase();
        }
      }
      if (empty > 0) row += '$empty';
      rows.add(row);
    }
    var castling = '';
    if (pieces['e1'] == 'wK') {
      if (pieces['h1'] == 'wR') castling += 'K';
      if (pieces['a1'] == 'wR') castling += 'Q';
    }
    if (pieces['e8'] == 'bK') {
      if (pieces['h8'] == 'bR') castling += 'k';
      if (pieces['a8'] == 'bR') castling += 'q';
    }
    if (castling.isEmpty) castling = '-';
    final turn = whiteToMove ? 'w' : 'b';
    return '${rows.join('/')} $turn $castling - 0 1';
  }
}
