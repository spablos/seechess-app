import 'dart:js_interop';

import 'package:chess/chess.dart' as ch;
import 'package:web/web.dart' as web;

import 'engine.dart';

/// Stockfish compiled to JS/WASM running in a Web Worker — the browser
/// twin of [StockfishEngine]. Same UCI conversation, same MultiPV lines;
/// the transport is postMessage instead of FFI. The single-threaded build
/// is deliberate: no SharedArrayBuffer, so no COOP/COEP fragility, and
/// coaching arrows don't need 3500 Elo.
class WasmStockfishEngine extends AnalysisEngine {
  WasmStockfishEngine({this.multiPv = 3});

  static final WasmStockfishEngine shared = WasmStockfishEngine();

  final int multiPv;
  web.Worker? _worker;
  bool _started = false;
  bool _ready = false;
  bool _searching = false;
  String? _pendingFen;
  String _currentFen = ch.Chess.DEFAULT_POSITION;

  final Map<int, EngineLine> _byPv = {};

  @override
  List<EngineLine> get lines {
    final sorted = _byPv.values.toList()
      ..sort((a, b) => a.multipv.compareTo(b.multipv));
    return sorted;
  }

  @override
  bool get ready => _ready;

  void _send(String cmd) => _worker?.postMessage(cmd.toJS);

  @override
  Future<void> start() async {
    if (_started) {
      if (_pendingFen != null && _ready) analyze(_pendingFen!);
      return;
    }
    _started = true;
    try {
      // served alongside the app bundle (web/stockfish.js)
      final worker = web.Worker('stockfish.js'.toJS);
      _worker = worker;
      worker.onmessage = ((web.MessageEvent e) {
        final data = e.data;
        if (data.isA<JSString>()) {
          _onLine((data as JSString).toDart);
        }
      }).toJS;
      worker.onerror = ((web.Event e) {
        _ready = false;
        notifyListeners();
      }).toJS;
      _send('uci');
      _send('setoption name MultiPV value $multiPv');
      _send('isready');
    } catch (_) {
      _started = false; // engine unavailable: analysis still works engineless
    }
  }

  @override
  void analyze(String fen) {
    if (fen != _currentFen && _byPv.isNotEmpty) {
      _byPv.clear();
      notifyListeners();
    }
    if (!_ready) {
      _pendingFen = fen;
      return;
    }
    if (_searching) {
      _pendingFen = fen;
      _send('stop');
      return;
    }
    _startSearch(fen);
  }

  void _startSearch(String fen) {
    _pendingFen = null;
    _currentFen = fen;
    _byPv.clear();
    notifyListeners();
    _send('position fen $fen');
    _send('go infinite');
    _searching = true;
  }

  @override
  void stop() {
    _pendingFen = null;
    if (_searching) _send('stop');
  }

  void _onLine(String line) {
    if (line.startsWith('uciok') || line.startsWith('readyok')) {
      if (!_ready) {
        _ready = true;
        notifyListeners();
        if (_pendingFen != null) _startSearch(_pendingFen!);
      }
      return;
    }
    if (line.startsWith('bestmove')) {
      _searching = false;
      final next = _pendingFen;
      if (next != null) _startSearch(next);
      return;
    }
    if (!line.startsWith('info ') || !line.contains(' pv ')) return;
    final tokens = line.split(RegExp(r'\s+'));
    int? depth, mpv = 1, cp, mate;
    List<String> pv = const [];
    for (var i = 0; i < tokens.length; i++) {
      switch (tokens[i]) {
        case 'depth':
          depth = int.tryParse(tokens[i + 1]);
        case 'multipv':
          mpv = int.tryParse(tokens[i + 1]);
        case 'score':
          if (tokens[i + 1] == 'cp') cp = int.tryParse(tokens[i + 2]);
          if (tokens[i + 1] == 'mate') mate = int.tryParse(tokens[i + 2]);
        case 'pv':
          pv = tokens.sublist(i + 1);
      }
      if (pv.isNotEmpty) break;
    }
    if (depth == null || pv.isEmpty || mpv == null) return;
    final sans = _pvToSan(pv);
    if (sans.isEmpty) return; // stale flush from the previous position
    final blackToMove = _currentFen.split(' ')[1] == 'b';
    if (blackToMove) {
      if (cp != null) cp = -cp;
      if (mate != null) mate = -mate;
    }
    _byPv[mpv] = EngineLine(
      multipv: mpv,
      depth: depth,
      scoreCp: cp,
      mateIn: mate,
      pvUci: pv,
      pvSan: sans,
    );
    notifyListeners();
  }

  List<String> _pvToSan(List<String> pvUci) {
    final g = ch.Chess.fromFEN(_currentFen);
    final sans = <String>[];
    for (final uci in pvUci.take(24)) {
      final ok = g.move({
        'from': uci.substring(0, 2),
        'to': uci.substring(2, 4),
        if (uci.length > 4) 'promotion': uci.substring(4),
      });
      if (!ok) break;
      final history = g.san_moves();
      final last = history.isEmpty ? null : history.last;
      if (last == null) break;
      // san_moves() rows are numbered move pairs ("1. e4 e6") — keep only
      // the SAN just played, matching the FFI engine
      sans.add(last.split(RegExp(r'\s+')).last);
    }
    return sans;
  }
}
