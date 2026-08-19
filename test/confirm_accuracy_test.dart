import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seechess/screens/confirm.dart';
import 'package:seechess/services/recognizer.dart';
import 'package:shared_preferences/shared_preferences.dart';

RecognitionResult _result(String fen) => RecognitionResult(
  fen: fen,
  confidence: List.filled(64, 0.99),
  warnings: const [],
  inputType: 'photo',
);

void main() {
  setUp(() {
    // consent already declined: confirm must not reach the network
    SharedPreferences.setMockInitialValues({'feedback_consent': false});
  });

  testWidgets('a perfect detection gets the accurate-detection popup', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: ConfirmScreen(
          photoPath: '/nonexistent.jpg',
          recognition: _result('rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR'),
        ),
      ),
    );
    // the Confirm button pulses forever — pumpAndSettle would never settle
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('Confirm'));
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }

    expect(find.text('Detection was accurate'), findsOneWidget);
    await tester.tap(find.text('OK'));
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }
    expect(find.text('Confirmed'), findsOneWidget);
  });

  test('fixedSquares counts per-square differences', () {
    const start = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR';
    expect(fixedSquares(start, '$start w KQkq - 0 1'), 0);
    // king and queen swapped = 2 fixed squares
    expect(
      fixedSquares('rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBKQBNR', start),
      2,
    );
    // an entire missing back rank = 8, well past the apology threshold
    expect(
      fixedSquares('rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/8', start),
      greaterThanOrEqualTo(badDetectionThreshold),
    );
    // malformed prediction counts as fully wrong, not a crash
    expect(fixedSquares('8/8', start), 64);
  });
}
