library;

/// Platform selector: FFI Stockfish on mobile/desktop, a Web Worker
/// running stockfish.js in the browser. Both satisfy [AnalysisEngine].
export 'shared_engine_io.dart'
    if (dart.library.js_interop) 'shared_engine_web.dart';
