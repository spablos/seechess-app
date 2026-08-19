import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seechess/engine/engine.dart';
import 'package:seechess/screens/analysis.dart';

/// Hermetic engine: no lines, no FFI.
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
  Future<void> pump(WidgetTester tester, {required bool editable}) async {
    await tester.pumpWidget(
      MaterialApp(
        home: AnalysisScreen(
          editable: editable,
          engineFactory: () => _StubEngine(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('edit action only offered on an editable board', (tester) async {
    await pump(tester, editable: false);
    expect(find.byIcon(Icons.edit_outlined), findsNothing);

    await pump(tester, editable: true);
    expect(find.byIcon(Icons.edit_outlined), findsOneWidget);
  });

  testWidgets('editor opens, and Done returns to analysis', (tester) async {
    await pump(tester, editable: true);
    await tester.tap(find.byIcon(Icons.edit_outlined));
    await tester.pumpAndSettle();

    expect(find.text('Set up position'), findsOneWidget);
    expect(find.text('Done'), findsOneWidget);

    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(find.text('Analysis'), findsOneWidget);
  });

  testWidgets('an invalid position cannot leave the editor', (tester) async {
    await pump(tester, editable: true);
    await tester.tap(find.byIcon(Icons.edit_outlined));
    await tester.pumpAndSettle();

    // wipe the board — no kings is not a legal position
    await tester.tap(find.byIcon(Icons.layers_clear_outlined));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();

    expect(find.text('Each side needs exactly one king.'), findsOneWidget);
    expect(find.text('Set up position'), findsOneWidget); // still editing
  });
}
