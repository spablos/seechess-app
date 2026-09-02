import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:seechess/services/pgn.dart';

/// Every bundled lesson must parse, replay legally, and actually teach —
/// each has remarks, and traps end decisively.
void main() {
  final lessons =
      jsonDecode(File('assets/learn/lessons.json').readAsStringSync()) as List;

  test(
    'the pack is non-trivial',
    () => expect(lessons.length, greaterThanOrEqualTo(8)),
  );

  for (final l in lessons.cast<Map<String, dynamic>>()) {
    test('lesson "${l['id']}" replays legally with remarks', () {
      final game = parsePgn(l['pgn'] as String);
      final replay = replayPgn(game);
      expect(replay.uci.length, greaterThanOrEqualTo(8));
      expect(
        game.comments.length,
        greaterThanOrEqualTo(4),
        reason: 'a lesson without remarks teaches nothing',
      );
      expect(['w', 'b'], contains(l['side']));
      expect(l['title'], isNotEmpty);
      // only lessons that PROMISE a mate must deliver one (scholars-mate
      // teaches the refutation and rightly ends mid-game)
      if (l['id'] == 'stafford-gambit' ||
          l['id'] == 'englund-gambit' ||
          l['id'] == 'legals-mate') {
        expect(
          game.sanMoves.last,
          endsWith('#'),
          reason: 'trap lessons should end in the mate they promise',
        );
      }
    });
  }
}
