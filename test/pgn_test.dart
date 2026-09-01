import 'package:flutter_test/flutter_test.dart';
import 'package:seechess/services/pgn.dart';

const _scholars = '''
[Event "Casual game"]
[White "Anna"]
[Black "Ben"]
[Result "1-0"]

1. e4 e5 2. Qh5 Nc6 3. Bc4 Nf6 4. Qxf7# 1-0
''';

const _annotated = '''
[Event "Live Chess"]
[Site "Chess.com"]
[White "pablo"]
[Black "rival"]
[Result "0-1"]
[UTCDate "2026.08.30"]

1. d4 {[%clk 0:02:59.9] solid} d5 {[%clk 0:02:58]} 2. c4 \$1 (2. Nf3 {a
quieter path} Nf6) 2... e6! 3. Nc3 Nf6 0-1
''';

const _fromFen = '''
[FEN "4k3/8/8/8/6P1/8/8/4K3 w - - 0 1"]
[White "Endgame"]
[Black "Study"]

1. g5 Kd7 2. g6
''';

const _promotion = '''
[White "A"]
[Black "B"]

1. e4 d5 2. exd5 c6 3. dxc6 Qd7 4. cxb7 Qc7 5. bxa8=Q
''';

void main() {
  test('a plain game parses and replays to UCI', () {
    final g = parsePgn(_scholars);
    expect(g.white, 'Anna');
    expect(g.result, '1-0');
    expect(g.sanMoves, ['e4', 'e5', 'Qh5', 'Nc6', 'Bc4', 'Nf6', 'Qxf7#']);
    final r = replayPgn(g);
    expect(r.uci.first, 'e2e4');
    expect(r.uci.last, 'h5f7');
    expect(r.finalFen, contains(' b '));
  });

  test('clock tags are stripped, human comments kept, variations dropped', () {
    final g = parsePgn(_annotated);
    expect(g.sanMoves, ['d4', 'd5', 'c4', 'e6', 'Nc3', 'Nf6']);
    expect(g.comments[1], 'solid'); // after White's d4
    expect(g.comments.containsKey(2), isFalse); // clk-only comment dropped
    expect(replayPgn(g).uci.length, 6);
  });

  test('a [FEN] start position is honored', () {
    final r = replayPgn(parsePgn(_fromFen));
    expect(r.uci, ['g4g5', 'e8d7', 'g5g6']);
  });

  test('promotion carries the piece into UCI', () {
    final r = replayPgn(parsePgn(_promotion));
    expect(r.uci.last, 'b7a8q');
  });

  test('a wrong move fails with its number and SAN', () {
    // Qd4 is blocked by Black's own d-pawn — genuinely illegal
    final g = parsePgn('[White "A"]\n[Black "B"]\n\n1. e4 e5 2. Nf3 Qd4');
    expect(
      () => replayPgn(g),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('"Qd4"'),
        ),
      ),
    );
  });

  test('multi-game text splits on new header blocks', () {
    final games = splitPgn('$_scholars\n$_promotion');
    expect(games, hasLength(2));
    expect(parsePgn(games[1]).sanMoves.last, 'bxa8=Q');
  });

  test('looksLikePgn separates PGN from FEN', () {
    expect(looksLikePgn(_scholars), isTrue);
    expect(looksLikePgn('1.e4 c5 2.Nf3'), isTrue);
    expect(
      looksLikePgn('rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1'),
      isFalse,
    );
  });

  test('variants are refused, garbage is refused', () {
    expect(
      () => replayPgn(parsePgn('[Variant "Chess960"]\n\n1. e4')),
      throwsA(isA<FormatException>()),
    );
    expect(() => parsePgn('   \n \n'), throwsA(isA<FormatException>()));
  });
}
