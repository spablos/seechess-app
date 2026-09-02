import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seechess/engine/engine.dart';
import 'package:seechess/models/game_state.dart';
import 'package:seechess/screens/analysis.dart';

class _StubEngine extends AnalysisEngine {
  @override
  List<EngineLine> get lines => const [];
  @override
  bool get ready => true;
  @override
  Future<void> start() async {}
  @override
  void analyze(String fen) {}
  @override
  void stop() {}
}

void main() {
  group('offLineStatus', () {
    final original = ['e2e4', 'e7e5', 'g1f3'];

    GameState play(List<String> uci, {int? ply}) {
      final g = GameState();
      for (final u in uci) {
        g.tryMove(u.substring(0, 2), u.substring(2, 4));
      }
      if (ply != null) g.stepTo(ply);
      return g;
    }

    test('anywhere along the original line is on-line', () {
      final g = play(original);
      for (var ply = 0; ply <= 3; ply++) {
        expect(offLineStatus(g.moves, ply, original), isNull);
      }
    });

    test('a differing move is a sideline', () {
      final g = play(['e2e4', 'c7c5']); // Sicilian instead of e5
      expect(offLineStatus(g.moves, 2, original), 'sideline');
      // stepping back before the divergence is on-line again
      expect(offLineStatus(g.moves, 1, original), isNull);
    });

    test('continuing past the original end is beyond', () {
      final g = play([...original, 'b8c6']);
      expect(offLineStatus(g.moves, 4, original), 'beyond');
      expect(offLineStatus(g.moves, 3, original), isNull);
    });

    test('no original game means never off-line', () {
      final g = play(['e2e4']);
      expect(offLineStatus(g.moves, 1, null), isNull);
    });
  });

  testWidgets('replaying the imported line never shows the banner', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: AnalysisScreen(
          movesUci: const ['e2e4', 'e7e5', 'g1f3'],
          initialPly: 0,
          comments: const {1: 'king pawn'},
          engineFactory: () => _StubEngine(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // the line icon shows (we have an original game), without the off mark
    expect(find.byIcon(Icons.timeline), findsOneWidget);
    expect(find.text('off'), findsNothing);

    // step to the tip via the move list; the comment shows after ply 1
    await tester.tap(find.text('1. e4'));
    await tester.pumpAndSettle();
    expect(find.text('king pawn'), findsOneWidget);
    await tester.tap(find.text('2. Nf3'));
    await tester.pumpAndSettle();
    expect(find.text('off'), findsNothing);
  });

  testWidgets('a plain board shows neither line icon nor turn words', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: AnalysisScreen(
          editable: true,
          engineFactory: () => _StubEngine(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.timeline), findsNothing);
    expect(find.text('White to move'), findsNothing);
  });
}
