import 'package:flutter_test/flutter_test.dart';
import 'package:seechess/models/setup_state.dart';

void main() {
  group('SetupState', () {
    test('round-trips a placement FEN', () {
      const placement = 'r1bqkbnr/pppp1ppp/2n5/4p3/2B1P3/5N2/PPPP1PPP/RNBQK2R';
      final s = SetupState.fromFen(placement);
      expect(s.pieces['c4'], 'wB');
      expect(s.pieces['c6'], 'bN');
      expect(s.toFen().split(' ').first, placement);
    });

    test('castling heuristics from king/rook start squares', () {
      final s = SetupState.fromFen('r3k2r/8/8/8/8/8/8/R3K2R');
      expect(s.toFen(), 'r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1');
      s.setTurn(false);
      expect(s.toFen().split(' ')[1], 'b');
    });

    test('no castling when pieces are elsewhere', () {
      final s = SetupState.fromFen('4k3/8/8/8/8/8/8/4K3');
      expect(s.toFen().split(' ')[2], '-');
    });

    test('palette placement and erase', () {
      final s = SetupState.fromFen('4k3/8/8/8/8/8/8/4K3');
      s.selectTool('wQ');
      s.tapSquare('d4');
      expect(s.pieces['d4'], 'wQ');
      s.selectTool('erase');
      s.tapSquare('d4');
      expect(s.pieces.containsKey('d4'), isFalse);
    });

    test('king guard', () {
      final s = SetupState.fromFen('4k3/8/8/8/8/8/8/8');
      expect(s.hasBothKings, isFalse);
      s.selectTool('wK');
      s.tapSquare('e1');
      expect(s.hasBothKings, isTrue);
    });

    test('validation catches positions that would crash the engine', () {
      // legal position: no complaint
      final ok = SetupState.fromFen('4k3/8/8/8/8/8/8/4K3');
      expect(ok.validationError(), isNull);

      // two white kings (the mislabel that once reached the feedback store)
      final twoKings = SetupState.fromFen('4k3/8/8/8/2K5/8/8/4K3');
      expect(twoKings.validationError(), isNotNull);

      // pawn on the last rank
      final backRankPawn = SetupState.fromFen('4k2P/8/8/8/8/8/8/4K3');
      expect(backRankPawn.validationError(), isNotNull);

      // black is in check but white is to move — fixed by switching turn
      final wrongTurn = SetupState.fromFen('7k/8/8/8/8/8/8/K6R');
      expect(wrongTurn.validationError(), contains('turn'));
      wrongTurn.setTurn(false);
      expect(wrongTurn.validationError(), isNull);
    });

    test('free move', () {
      final s = SetupState.fromFen('4k3/8/8/8/8/8/8/4K3');
      s.move('e1', 'a5');
      expect(s.pieces['a5'], 'wK');
      expect(s.pieces.containsKey('e1'), isFalse);
    });

    test('palette color flip follows selected tool', () {
      final s = SetupState.fromFen('4k3/8/8/8/8/8/8/4K3');
      s.selectTool('wQ');
      s.togglePaletteColor();
      expect(s.paletteWhite, isFalse);
      expect(s.tool, 'bQ');
    });

    test('rotate90 turns the position clockwise, four taps restore it', () {
      const placement = 'r1bqkbnr/pppp1ppp/2n5/4p3/2B1P3/5N2/PPPP1PPP/RNBQK2R';
      final s = SetupState.fromFen(placement);
      s.rotate90();
      expect(s.pieces['a8'], 'wR'); // a1 -> a8
      expect(s.pieces['h1'], 'bR'); // h8 -> h1
      expect(s.pieces['d6'], 'wB'); // c4 -> d6
      s.rotate90();
      s.rotate90();
      s.rotate90();
      expect(s.toFen().split(' ').first, placement);
    });

    test('double-tap flips a board piece color', () {
      final s = SetupState.fromFen('4k3/8/8/8/8/8/8/4K3');
      s.flipPiece('e1');
      expect(s.pieces['e1'], 'bK');
      s.flipPiece('d5'); // empty: no-op
      expect(s.pieces.containsKey('d5'), isFalse);
    });
  });
}
