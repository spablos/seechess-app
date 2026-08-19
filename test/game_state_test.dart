import 'package:flutter_test/flutter_test.dart';
import 'package:seechess/models/game_state.dart';

void main() {
  group('GameState', () {
    test('legal move is applied and recorded', () {
      final game = GameState();
      final san = game.tryMove('e2', 'e4');
      expect(san, 'e4');
      expect(game.moves, hasLength(1));
      expect(game.fen, startsWith('rnbqkbnr/pppppppp/8/8/4P3'));
      expect(game.whiteToMove, isFalse);
    });

    test('illegal move is rejected', () {
      final game = GameState();
      expect(game.tryMove('e2', 'e5'), isNull);
      expect(game.moves, isEmpty);
    });

    test('legal targets for a knight on the start position', () {
      final game = GameState();
      expect(game.legalTargets('g1'), {'f3', 'h3'});
      expect(game.legalTargets('e1'), isEmpty);
    });

    test('step navigation shows earlier positions without losing the line', () {
      final game = GameState();
      game.tryMove('e2', 'e4');
      game.tryMove('e7', 'e5');
      game.stepBack();
      expect(game.ply, 1);
      expect(game.atLatest, isFalse);
      expect(game.fen, contains('4P3'));
      game.stepForward();
      expect(game.atLatest, isTrue);
    });

    test('moving from an earlier ply replaces the tail', () {
      final game = GameState();
      game.tryMove('e2', 'e4');
      game.tryMove('e7', 'e5');
      game.stepTo(1);
      final san = game.tryMove('c7', 'c5');
      expect(san, 'c5');
      expect(game.moves.map((m) => m.san), ['e4', 'c5']);
    });

    test('imports a FEN (position from a photo)', () {
      // Italian game. NOTE: a photographed position without both kings (it
      // happens — Pablo's own sample board has none) fails FEN validation;
      // the confirm screen must surface that before reaching analysis.
      const fen =
          'r1bqkbnr/pppp1ppp/2n5/4p3/2B1P3/5N2/PPPP1PPP/RNBQK2R b KQkq - 3 3';
      final game = GameState(fen: fen);
      expect(game.pieceMap()['c4'], 'wB');
      expect(game.pieceMap()['e5'], 'bP');
      expect(game.whiteToMove, isFalse);
      expect(game.legalTargets('g8'), {'e7', 'f6', 'h6'});
    });

    test('checkmate is detected', () {
      final game = GameState();
      game.tryMove('f2', 'f3');
      game.tryMove('e7', 'e5');
      game.tryMove('g2', 'g4');
      game.tryMove('d8', 'h4');
      expect(game.gameOver, isTrue);
      expect(game.resultText(), '0–1 mate');
    });
  });
}
