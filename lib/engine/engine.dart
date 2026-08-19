import 'dart:math' as math;

import 'package:flutter/foundation.dart';

/// One engine line (a MultiPV entry) in UI-ready form.
class EngineLine {
  EngineLine({
    required this.multipv,
    required this.depth,
    required this.scoreCp,
    required this.mateIn,
    required this.pvUci,
    this.pvSan = const [],
  });

  final int multipv;
  final int depth;

  /// Centipawns from White's perspective; null when [mateIn] is set.
  final int? scoreCp;

  /// Moves to mate from White's perspective (negative = Black mates).
  final int? mateIn;
  final List<String> pvUci;
  final List<String> pvSan;

  /// "+1.4", "-0.3", "M5", "-M2" — chess.com-style display.
  String get displayScore {
    if (mateIn != null) return mateIn! >= 0 ? 'M$mateIn' : '-M${-mateIn!}';
    final pawns = (scoreCp ?? 0) / 100.0;
    return pawns >= 0
        ? '+${pawns.toStringAsFixed(1)}'
        : pawns.toStringAsFixed(1);
  }

  /// 0..1 for the eval bar (White's share), squashed like chess.com's bar.
  double get whiteShare {
    if (mateIn != null) return mateIn! >= 0 ? 1.0 : 0.0;
    final pawns = (scoreCp ?? 0) / 100.0;
    return 0.5 + 0.5 * (2 / (1 + math.exp(-pawns / 3)) - 1);
  }
}

/// Abstract analysis engine: feed positions, observe lines. Implemented by
/// StockfishEngine (FFI); a stub implementation keeps widget tests hermetic.
abstract class AnalysisEngine extends ChangeNotifier {
  /// Latest lines, best first (multipv 1..n).
  List<EngineLine> get lines;
  bool get ready;

  Future<void> start();
  void analyze(String fen);
  void stop();
}
