import 'package:chess/chess.dart' as ch;
import 'package:flutter/foundation.dart';

/// One move in the game's move list, kept in both notations.
class PlayedMove {
  PlayedMove({required this.san, required this.uci, required this.fenAfter});
  final String san;
  final String uci;
  final String fenAfter;
}

/// The position + move list + a navigation pointer (for stepping back and
/// forward through the game, chess.com-style). The engine and the board both
/// observe this.
class GameState extends ChangeNotifier {
  GameState({String? fen})
    : startFen = fen ?? ch.Chess.DEFAULT_POSITION,
      _game = fen == null ? ch.Chess() : ch.Chess.fromFEN(fen);

  final String startFen;
  ch.Chess _game;
  final List<PlayedMove> moves = [];

  /// How many moves of [moves] are currently applied on the board.
  int ply = 0;

  String get fen => _viewGame().fen;
  bool get atLatest => ply == moves.length;
  bool get whiteToMove => _viewGame().turn == ch.Color.WHITE;

  ch.Chess _viewGame() {
    if (atLatest) return _game;
    return ch.Chess.fromFEN(ply == 0 ? startFen : moves[ply - 1].fenAfter);
  }

  /// Squares (algebraic) the piece on [from] may move to in the shown position.
  Set<String> legalTargets(String from) {
    final g = _viewGame();
    final verbose = g.moves({'asObjects': true});
    return verbose
        .whereType<ch.Move>()
        .where((m) => m.fromAlgebraic == from)
        .map((m) => m.toAlgebraic)
        .toSet();
  }

  /// Piece placement for the shown position: square -> "wP", "bK", ...
  Map<String, String> pieceMap() {
    final g = _viewGame();
    final result = <String, String>{};
    for (final square in ch.Chess.SQUARES.keys) {
      final piece = g.get(square);
      if (piece != null) {
        result[square] =
            '${piece.color == ch.Color.WHITE ? 'w' : 'b'}${piece.type.toUpperCase()}';
      }
    }
    return result;
  }

  /// Play a move in the shown position. If we're back in the move list, the
  /// tail is discarded (variation replaces it — v1 keeps a single line).
  /// Returns the move's SAN, or null if illegal.
  String? tryMove(String from, String to, {String promotion = 'q'}) {
    if (!atLatest) {
      moves.removeRange(ply, moves.length);
      _game = ch.Chess.fromFEN(ply == 0 ? startFen : moves.last.fenAfter);
    }
    final ok = _game.move({'from': from, 'to': to, 'promotion': promotion});
    if (!ok) return null;
    final san = (_game.san_moves().last ?? '').split(RegExp(r'\s+')).last;
    moves.add(
      PlayedMove(
        san: san,
        uci: '$from$to${_needsPromotion(san) ? promotion : ''}',
        fenAfter: _game.fen,
      ),
    );
    ply = moves.length;
    notifyListeners();
    return san;
  }

  bool _needsPromotion(String san) => san.contains('=');

  void stepTo(int newPly) {
    ply = newPly.clamp(0, moves.length);
    notifyListeners();
  }

  void stepBack() => stepTo(ply - 1);
  void stepForward() => stepTo(ply + 1);

  bool get gameOver => _viewGame().game_over;
  bool get inCheck => _viewGame().in_check;

  String? resultText() {
    final g = _viewGame();
    if (g.in_checkmate) {
      return g.turn == ch.Color.WHITE ? '0–1 mate' : '1–0 mate';
    }
    if (g.in_stalemate) return '½–½ stalemate';
    if (g.in_draw) return '½–½ draw';
    return null;
  }
}
