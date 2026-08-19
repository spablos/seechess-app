import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seechess/engine/engine.dart';
import 'package:seechess/screens/analysis.dart';

/// Hermetic engine: one line with a fixed eval, no FFI.
class _StubEngine extends AnalysisEngine {
  _StubEngine(this.scoreCp, {this.noLines = false});
  final int scoreCp;
  final bool noLines; // a finished game yields no engine lines

  @override
  List<EngineLine> get lines => noLines
      ? const []
      : [
          EngineLine(
            multipv: 1,
            depth: 20,
            scoreCp: scoreCp,
            mateIn: null,
            pvUci: const ['e2e4'],
            pvSan: const ['e4'],
          ),
        ];

  @override
  bool get ready => true;
  @override
  Future<void> start() async {}
  @override
  void analyze(String fen) {}
  @override
  void stop() {}
}

/// Width of the white segment of the eval bar, found as the white ColoredBox
/// inside the screen (the board squares are images, not ColoredBoxes).
double _whiteBarWidth(WidgetTester tester) {
  final finder = find.byWidgetPredicate(
    (w) => w is ColoredBox && w.color == Colors.white,
  );
  expect(
    finder,
    findsOneWidget,
    reason: 'the white eval-bar segment must exist and have size',
  );
  return tester.getSize(finder).width;
}

void main() {
  Future<void> pump(WidgetTester tester, int scoreCp) async {
    await tester.pumpWidget(
      MaterialApp(
        home: AnalysisScreen(
          // remount per scenario — otherwise the first stub engine is kept
          key: ValueKey(scoreCp),
          fen: 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1',
          engineFactory: () => _StubEngine(scoreCp),
        ),
      ),
    );
    // let the eval-bar animation settle
    await tester.pumpAndSettle();
  }

  testWidgets('checkmate shows the result, not an even bar', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: AnalysisScreen(
          // fool's mate: white is checkmated
          fen: 'rnb1kbnr/pppp1ppp/8/4p3/6Pq/5P2/PPPPP2P/RNBQKBNR w KQkq - 1 3',
          engineFactory: () => _StubEngine(0, noLines: true),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('0–1 mate'), findsOneWidget);
    // decided game: the bar is FULLY black — no white sliver at all
    expect(_whiteBarWidth(tester), lessThan(1));
  });

  testWidgets('material diff shows surplus glyphs and point lead', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: AnalysisScreen(
          // white up the exchange: R-for-N imbalance -> white leads by +2
          fen: '1nbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/R1BQKBNR w KQk - 0 1',
          engineFactory: () => _StubEngine(0),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('+2'), findsOneWidget);
    expect(find.textContaining('♞'), findsOneWidget); // black's surplus knight
  });

  testWidgets('eval bar shows a proportional white segment', (tester) async {
    await pump(tester, 0); // equal position -> white half
    final equalWidth = _whiteBarWidth(tester);
    expect(
      equalWidth,
      greaterThan(0),
      reason: 'regression: white segment once collapsed to zero height',
    );

    await pump(tester, 300); // +3 for white -> clearly more than half
    expect(_whiteBarWidth(tester), greaterThan(equalWidth * 1.2));

    await pump(tester, -300); // -3 -> clearly less than half
    expect(_whiteBarWidth(tester), lessThan(equalWidth * 0.8));
  });
}
