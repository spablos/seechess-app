import 'engine.dart';
import 'wasm_engine.dart';

/// Web: stockfish.js in a Worker (single-thread build — no
/// SharedArrayBuffer requirement, works behind any headers).
AnalysisEngine sharedAnalysisEngine() => WasmStockfishEngine.shared;
