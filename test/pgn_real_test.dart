import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:seechess/services/pgn.dart';

/// Real production PGNs captured from the public APIs — the parser must
/// swallow them exactly as served.
void main() {
  for (final site in ['chesscom', 'lichess']) {
    test('a real $site PGN parses, replays, and keeps no clk noise', () {
      final text = File('test/fixtures/${site}_real.pgn').readAsStringSync();
      final game = parsePgn(text);
      expect(game.white, isNotNull);
      expect(game.sanMoves, isNotEmpty);
      final replay = replayPgn(game);
      expect(replay.uci.length, game.sanMoves.length);
      for (final c in game.comments.values) {
        expect(c, isNot(contains('%clk')));
      }
    });
  }
}
