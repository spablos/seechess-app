import 'engine.dart';
import 'stockfish_engine.dart';

/// Native platforms: the FFI Stockfish, shared process-wide.
AnalysisEngine sharedAnalysisEngine() => StockfishEngine.shared;
