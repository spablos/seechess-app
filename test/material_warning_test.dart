import 'package:flutter_test/flutter_test.dart';
import 'package:seechess/models/setup_state.dart';

void main() {
  test('the starting position raises no material warning', () {
    final s = SetupState.fromFen('rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR');
    expect(s.materialWarning(), isNull);
  });

  test('four bishops with all eight pawns is impossible', () {
    // Pablo's original repro: extra bishops need promotions, but no pawn
    // is missing to have promoted
    final s = SetupState.fromFen(
      'rnbqkbnr/pppppppp/8/8/2BB4/8/PPPPPPPP/RNBQKBNR',
    );
    expect(s.materialWarning(), contains('White'));
    expect(s.materialWarning(), contains('2 promotions'));
  });

  test('an extra queen with a missing pawn is a legal promotion', () {
    final s = SetupState.fromFen(
      'rnbqkbnr/pppppppp/8/8/3QQ3/8/PPPPPPP1/RNB1KBNR',
    );
    // 2 queens = 1 promotion, 1 pawn missing — fine
    expect(s.materialWarning(), isNull);
  });

  test('three queens with only one missing pawn is impossible', () {
    final s = SetupState.fromFen(
      'rnbqkbnr/pppppppp/8/8/3QQQ2/8/PPPPPPP1/RNB1KBNR',
    );
    expect(s.materialWarning(), contains('2 promotions'));
  });

  test('nine pawns is impossible outright', () {
    final s = SetupState.fromFen(
      'rnbqkbnr/pppppppp/8/8/4P3/8/PPPPPPPP/RNBQKBNR',
    );
    expect(s.materialWarning(), contains('9 pawns'));
  });

  test('black surplus is accounted independently', () {
    final s = SetupState.fromFen(
      'rnbqkbnr/pppppppp/8/3nn3/8/8/PPPPPPPP/RNBQKBNR',
    );
    expect(s.materialWarning(), contains('Black'));
  });
}
