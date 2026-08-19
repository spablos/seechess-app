import 'dart:async';

import 'package:chess/chess.dart' as ch;
import 'package:stockfish_chess_engine/stockfish_chess_engine.dart';
import 'package:stockfish_chess_engine/stockfish_chess_engine_state.dart';

import 'engine.dart';

/// Real Stockfish over FFI (the same engine binary lichess ships).
///
/// UCI in one paragraph: we write text commands ("position fen ...",
/// "go infinite") and the engine streams back "info ..." lines carrying the
/// current best variations; "stop" ends a search. MultiPV = how many best
/// lines it maintains at once.
class StockfishEngine extends AnalysisEngine {
  StockfishEngine({this.multiPv = 3});

  /// Process-wide shared engine. Creating and destroying the in-process
  /// engine per screen races its native teardown against the next
  /// startup — quick exit/re-enter of analysis crashed the app — so
  /// screens borrow this one long-lived instance and never dispose it.
  static final StockfishEngine shared = StockfishEngine();

  final int multiPv;
  bool _started = false;
  Stockfish? _sf;
  StreamSubscription<String>? _sub;
  Timer? _stopRetry;
  String? _pendingFen;
  String _currentFen = ch.Chess.DEFAULT_POSITION;
  bool _searching = false;

  final Map<int, EngineLine> _byPv = {};
  @override
  List<EngineLine> get lines {
    final sorted = _byPv.values.toList()
      ..sort((a, b) => a.multipv.compareTo(b.multipv));
    return sorted;
  }

  @override
  bool get ready => _sf?.state.value == StockfishState.ready;

  @override
  Future<void> start() async {
    // idempotent: the shared engine is started once and reused
    if (_started) {
      if (_pendingFen != null && ready) analyze(_pendingFen!);
      return;
    }
    _started = true;
    // the plugin allows one instance at a time; re-entering the analysis
    // screen right after leaving it can race the old engine's teardown
    // start() is fire-and-forget from initState, so it must never throw —
    // an unhandled async error takes the app down. Failure here resets
    // _started so the next screen entry simply tries again.
    Stockfish? created;
    for (var attempt = 0; created == null; attempt++) {
      try {
        created = Stockfish();
      } on StateError {
        if (attempt >= 20) {
          _started = false;
          return;
        }
        await Future.delayed(const Duration(milliseconds: 100));
      }
    }
    final sf = created;
    _sf = sf;
    // Wait for the process to come up before speaking UCI to it.
    if (sf.state.value != StockfishState.ready) {
      final completer = Completer<void>();
      void listener() {
        if (sf.state.value == StockfishState.ready && !completer.isCompleted) {
          completer.complete();
        }
      }

      sf.state.addListener(listener);
      try {
        await completer.future.timeout(const Duration(seconds: 10));
      } on TimeoutException {
        sf.state.removeListener(listener);
        _started = false;
        _sf = null;
        return;
      }
      sf.state.removeListener(listener);
    }
    _sub = sf.stdout.listen(_onLine);
    sf.stdin = 'uci';
    sf.stdin = 'setoption name MultiPV value $multiPv';
    sf.stdin = 'isready';
    notifyListeners();
    if (_pendingFen != null) {
      analyze(_pendingFen!);
    }
  }

  @override
  void analyze(String fen) {
    // a new position invalidates whatever lines are on display — clear
    // immediately so a reused engine never shows the previous screen's
    // lines against the new board
    if (fen != _currentFen && _byPv.isNotEmpty) {
      _byPv.clear();
      notifyListeners();
    }
    final sf = _sf;
    if (sf == null || sf.state.value != StockfishState.ready) {
      _pendingFen = fen;
      return;
    }
    if (_searching) {
      // UCI handshake: halt the running search and start the new one only
      // after its 'bestmove' acknowledgment. Writing 'position'/'go' into a
      // live search wedges the engine into permanent silence.
      _pendingFen = fen;
      sf.stdin = 'stop';
      // safety: if the acknowledgment never arrives, nudge again instead
      // of staying silent forever (stop is idempotent)
      _stopRetry?.cancel();
      _stopRetry = Timer(const Duration(seconds: 2), () {
        if (_searching && _pendingFen != null) {
          try {
            _sf?.stdin = 'stop';
          } on StateError {
            // engine gone; dispose() handles teardown
          }
        }
      });
      return;
    }
    _startSearch(fen);
  }

  void _startSearch(String fen) {
    _pendingFen = null;
    _currentFen = fen;
    _byPv.clear();
    notifyListeners();
    final sf = _sf!;
    sf.stdin = 'position fen $fen';
    sf.stdin = 'go infinite';
    _searching = true;
  }

  @override
  void stop() {
    _pendingFen = null;
    if (_searching) _sf?.stdin = 'stop';
  }

  void _onLine(String line) {
    if (line.startsWith('bestmove')) {
      _searching = false;
      _stopRetry?.cancel();
      final next = _pendingFen;
      if (next != null && _sf?.state.value == StockfishState.ready) {
        _startSearch(next);
      }
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

    // A search being stopped still flushes info lines for the OLD position;
    // their moves are illegal in the current one. Storing them showed
    // frozen scores with no move chips — drop them instead.
    final sans = _pvToSan(pv);
    if (sans.isEmpty) return;

    // Scores arrive from the side-to-move's perspective; normalize to White's.
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
      sans.add(last.split(RegExp(r'\s+')).last);
    }
    return sans;
  }

  @override
  void dispose() {
    stop();
    _stopRetry?.cancel();
    _sub?.cancel();
    _sf?.dispose();
    super.dispose();
  }
}
