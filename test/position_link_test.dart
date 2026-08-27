import 'package:flutter_test/flutter_test.dart';
import 'package:seechess/utils/position_link.dart';

void main() {
  const fen = 'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1';

  test('link round-trips a FEN', () {
    final link = positionLink(fen);
    expect(link, startsWith('https://seechess.nopatos.com/p/'));
    expect(link.contains(' '), isFalse);
    expect(fenFromLink(Uri.parse(link)), fen);
  });

  test('foreign links are ignored', () {
    expect(fenFromLink(Uri.parse('https://example.com/p/x')), isNull);
    expect(
      fenFromLink(Uri.parse('https://seechess.nopatos.com/privacy')),
      isNull,
    );
    expect(fenFromLink(Uri.parse('seechess://192.168.1.2:5000')), isNull);
  });
}
