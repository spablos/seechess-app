import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../../models/game_state.dart';

/// Offline two-device match over a tiny LAN (PRD §4, "the plane feature").
///
/// One phone hosts a WebSocket server and is authoritative for move order,
/// clocks and results; the other mirrors state. Every host message carries
/// the FULL game (fen0 + uci list + clocks) — chess state is tiny, and full
/// mirroring makes reconnects trivial (the PRD's explicit call). Both sides
/// validate moves locally with the same rules code by construction (one
/// codebase). Fixed host, no migration; offline games are unranked.

/// Minutes + increment, chess.com-style presets.
class TimeControl {
  const TimeControl(this.minutes, this.incrementSec);
  final int minutes;
  final int incrementSec;

  int get baseMs => minutes * 60000;
  int get incMs => incrementSec * 1000;
  String get display =>
      incrementSec > 0 ? '$minutes + $incrementSec' : '$minutes min';

  static const presets = [
    (TimeControl(1, 0), 'Bullet'),
    (TimeControl(3, 2), 'Blitz'),
    (TimeControl(5, 0), 'Blitz'),
    (TimeControl(10, 0), 'Rapid'),
    (TimeControl(15, 10), 'Rapid'),
  ];
}

/// Shared face of the two session roles: everything the lobby and match
/// screens need, with the host/guest asymmetry hidden behind it.
abstract class MatchSession extends ChangeNotifier {
  String get myName;
  String? get oppName;
  bool get isHost;

  /// Transport is up (guest connected / socket alive).
  bool connected = false;

  /// A game has been started (and possibly finished — see [result]).
  bool started = false;

  GameState game = GameState();
  bool myWhite = true;
  TimeControl timeControl = const TimeControl(10, 0);
  String? result; // '1–0 mate', '0–1 resignation', '½–½ agreed', '1–0 time'…
  String? drawOfferFrom; // 'me' | 'opp'
  String? rematchFrom; // 'me' | 'opp'

  // clocks: remaining ms as of [_refMs] (epoch); the side to move decays
  int wMs = 0;
  int bMs = 0;
  bool clockRunning = false;
  int _refMs = 0;

  bool get turnWhiteNow {
    final parts = game.fen.split(' ');
    return parts.length < 2 || parts[1] == 'w';
  }

  bool get myTurn =>
      started && result == null && connected && myWhite == turnWhiteNow;

  /// Live-ticking remaining time for one side, for rendering.
  int displayMs(bool white) {
    var ms = white ? wMs : bMs;
    if (clockRunning && result == null && started && white == turnWhiteNow) {
      ms -= DateTime.now().millisecondsSinceEpoch - _refMs;
    }
    return max(0, ms);
  }

  void sendMove(String from, String to, {String promotion = 'q'});
  void resign();
  void offerDraw();
  void respondDraw(bool accept);

  /// Request a rematch — or accept the opponent's pending request.
  void rematch();

  Future<void> shutdown();
}

// ---------------------------------------------------------------- host

class HostSession extends MatchSession {
  HostSession({
    required String name,
    required TimeControl tc,
    this.hostWhite,
    this.startFen,
  }) : _myName = name {
    timeControl = tc;
  }

  final String _myName;

  /// Host's color; null = coin flip at match start.
  bool? hostWhite;

  /// Optional non-standard start position (a photographed one, later).
  final String? startFen;

  HttpServer? _server;
  WebSocket? _sock;
  String? _guestName;
  Timer? _flagTimer;
  int _seq = 0;

  // raw sides ('host'/'guest') for the wire; the base-class fields hold the
  // 'me'/'opp' view for this device's UI
  String? _drawBy;
  String? _rematchBy;

  @override
  String get myName => _myName;
  @override
  String? get oppName => _guestName;
  @override
  bool get isHost => true;

  /// "ip:port" for the QR / manual entry, once listening.
  String? address;

  Future<void> start() async {
    final server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    _server = server;
    address = '${await _localIp()}:${server.port}';
    server.listen((req) async {
      if (!WebSocketTransformer.isUpgradeRequest(req)) {
        req.response
          ..statusCode = HttpStatus.badRequest
          ..close();
        return;
      }
      final sock = await WebSocketTransformer.upgrade(req);
      await _sock?.close(); // a reconnect replaces the old socket
      _sock = sock;
      sock.listen(
        (data) => _onGuestMessage(data as String),
        onDone: () {
          if (_sock != sock) return;
          _sock = null;
          connected = false;
          _pauseClock(); // fairness: a Wi-Fi blip must not flag anyone
          notifyListeners();
        },
        onError: (_) {},
        cancelOnError: true,
      );
    });
    // flag checks are the host's job (authoritative clock)
    _flagTimer = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (!started || result != null || !clockRunning) return;
      if (displayMs(turnWhiteNow) <= 0) {
        _settleClock();
        result = turnWhiteNow ? '0–1 time' : '1–0 time';
        clockRunning = false;
        _broadcast();
      }
    });
    notifyListeners();
  }

  /// The hotspot/LAN address guests can reach. iOS Personal Hotspot puts
  /// the host on 172.20.10.1; otherwise prefer private-range interfaces.
  Future<String> _localIp() async {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
    );
    final all = [for (final i in interfaces) ...i.addresses];
    for (final prefix in ['172.20.10.', '192.168.', '10.', '172.']) {
      for (final a in all) {
        if (a.address.startsWith(prefix)) return a.address;
      }
    }
    return all.isEmpty ? '127.0.0.1' : all.first.address;
  }

  /// Host taps Start once the guest is in the lobby.
  void beginMatch() {
    if (started || _guestName == null) return;
    myWhite = hostWhite ?? Random().nextBool();
    _freshGame();
    started = true;
    _broadcast();
  }

  void _freshGame() {
    game.dispose();
    game = GameState(fen: startFen);
    wMs = timeControl.baseMs;
    bMs = timeControl.baseMs;
    _refMs = DateTime.now().millisecondsSinceEpoch;
    clockRunning = true;
    result = null;
    _drawBy = null;
    _rematchBy = null;
  }

  void _onGuestMessage(String data) {
    final msg = jsonDecode(data) as Map<String, dynamic>;
    switch (msg['t']) {
      case 'hello':
        _guestName = msg['name'] as String? ?? 'Guest';
        connected = true;
        if (started) _resumeClock(); // back from a blip mid-game
        _broadcast(); // reconnecting guest gets the full game back
      case 'move':
        _applyMove(byWhite: !myWhite, uci: msg['uci'] as String);
      case 'resign':
        _applyResign(byWhite: !myWhite);
      case 'draw':
        _applyDraw(from: 'guest', action: msg['a'] as String);
      case 'rematch':
        _applyRematch(from: 'guest');
    }
  }

  // -- the one authoritative rulebook, used by both sides' intents

  void _applyMove({required bool byWhite, required String uci}) {
    if (!started || result != null || byWhite != turnWhiteNow) return;
    if (uci.length < 4) return;
    final san = game.tryMove(
      uci.substring(0, 2),
      uci.substring(2, 4),
      promotion: uci.length > 4 ? uci.substring(4, 5) : 'q',
    );
    if (san == null) return; // illegal — ignore
    _settleClock();
    if (byWhite) {
      wMs += timeControl.incMs;
    } else {
      bMs += timeControl.incMs;
    }
    _drawBy = null; // making a move declines a pending offer
    final r = game.resultText();
    if (r != null) {
      result = r;
      clockRunning = false;
    }
    _broadcast();
  }

  void _applyResign({required bool byWhite}) {
    if (!started || result != null) return;
    _settleClock();
    result = byWhite ? '0–1 resignation' : '1–0 resignation';
    clockRunning = false;
    _broadcast();
  }

  void _applyDraw({required String from, required String action}) {
    if (!started || result != null) return;
    switch (action) {
      case 'offer':
        _drawBy = from;
      case 'accept':
        if (_drawBy != null && _drawBy != from) {
          _settleClock();
          result = '½–½ agreed';
          clockRunning = false;
        }
      case 'decline':
        if (_drawBy != from) _drawBy = null;
    }
    _broadcast();
  }

  void _applyRematch({required String from}) {
    if (result == null) return; // only after a finished game
    if (_rematchBy == null) {
      _rematchBy = from;
      _broadcast();
      return;
    }
    if (_rematchBy == from) return;
    myWhite = !myWhite; // both agreed: colors swap
    _freshGame();
    _broadcast();
  }

  // -- clock bookkeeping: [wMs]/[bMs] are "as of _refMs"

  void _settleClock() {
    if (!clockRunning) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final spent = now - _refMs;
    if (turnWhiteNow) {
      wMs = max(0, wMs - spent);
    } else {
      bMs = max(0, bMs - spent);
    }
    _refMs = now;
  }

  void _pauseClock() {
    if (!started || result != null) return;
    _settleClock();
    clockRunning = false;
  }

  void _resumeClock() {
    if (!started || result != null || clockRunning) return;
    _refMs = DateTime.now().millisecondsSinceEpoch;
    clockRunning = true;
  }

  void _broadcast() {
    _settleClock();
    drawOfferFrom = _drawBy == null ? null : (_drawBy == 'host' ? 'me' : 'opp');
    rematchFrom = _rematchBy == null
        ? null
        : (_rematchBy == 'host' ? 'me' : 'opp');
    final state = jsonEncode({
      't': 'state',
      'seq': ++_seq,
      'started': started,
      'fen0': startFen,
      'fen': game.fen,
      'uci': [for (final m in game.moves) m.uci],
      'wMs': wMs,
      'bMs': bMs,
      'running': clockRunning,
      'result': result,
      'draw': _drawBy,
      'rematch': _rematchBy,
      'youWhite': !myWhite,
      'hostName': _myName,
      'tc': [timeControl.minutes, timeControl.incrementSec],
    });
    _sock?.add(state);
    notifyListeners();
  }

  // -- MatchSession intents, host side

  @override
  void sendMove(String from, String to, {String promotion = 'q'}) =>
      _applyMove(byWhite: myWhite, uci: '$from$to$promotion');

  @override
  void resign() => _applyResign(byWhite: myWhite);

  @override
  void offerDraw() => _applyDraw(from: 'host', action: 'offer');

  @override
  void respondDraw(bool accept) =>
      _applyDraw(from: 'host', action: accept ? 'accept' : 'decline');

  @override
  void rematch() => _applyRematch(from: 'host');

  @override
  Future<void> shutdown() async {
    _flagTimer?.cancel();
    await _sock?.close();
    await _server?.close(force: true);
    game.dispose();
    dispose();
  }
}

// ---------------------------------------------------------------- guest

class GuestSession extends MatchSession {
  GuestSession({required String name, required this.hostAddress})
    : _myName = name;

  final String _myName;

  /// "ip:port" from the QR code or manual entry.
  final String hostAddress;

  WebSocket? _sock;
  String? _hostName;
  bool _closed = false;
  int _lastSeq = 0;

  @override
  String get myName => _myName;
  @override
  String? get oppName => _hostName;
  @override
  bool get isHost => false;

  Future<void> connect() async {
    while (!_closed) {
      try {
        final sock = await WebSocket.connect(
          'ws://$hostAddress',
        ).timeout(const Duration(seconds: 6));
        if (_closed) {
          await sock.close();
          return;
        }
        _sock = sock;
        connected = true;
        sock.add(jsonEncode({'t': 'hello', 'name': _myName}));
        notifyListeners();
        await for (final data in sock) {
          _onHostMessage(data as String);
        }
      } catch (_) {
        // fall through to the retry below
      }
      _sock = null;
      if (_closed) return;
      connected = false;
      notifyListeners();
      // Wi-Fi blips happen (PRD): keep retrying until told to stop
      await Future<void>.delayed(const Duration(seconds: 2));
    }
  }

  void _onHostMessage(String data) {
    final msg = jsonDecode(data) as Map<String, dynamic>;
    if (msg['t'] != 'state') return;
    final seq = msg['seq'] as int;
    if (seq <= _lastSeq) return; // host seq is monotonic across rematches
    _lastSeq = seq;

    _hostName = msg['hostName'] as String?;
    myWhite = msg['youWhite'] as bool;
    final tc = msg['tc'] as List;
    timeControl = TimeControl(tc[0] as int, tc[1] as int);
    started = msg['started'] as bool;
    result = msg['result'] as String?;
    final draw = msg['draw'] as String?;
    drawOfferFrom = draw == null ? null : (draw == 'guest' ? 'me' : 'opp');
    final rem = msg['rematch'] as String?;
    rematchFrom = rem == null ? null : (rem == 'guest' ? 'me' : 'opp');
    wMs = msg['wMs'] as int;
    bMs = msg['bMs'] as int;
    clockRunning = msg['running'] as bool;
    _refMs = DateTime.now().millisecondsSinceEpoch;

    // rebuild the mirror from scratch when it diverges — a few dozen moves
    // is nothing, and it makes reconnect AND rematch correct for free. The
    // host's current fen is the divergence test (a fresh rematch game has
    // the same empty move list as a stale finished one).
    final uci = (msg['uci'] as List).cast<String>();
    final mine = [for (final m in game.moves) m.uci];
    if (!listEquals(mine, uci) || game.fen != msg['fen'] as String?) {
      game.dispose();
      game = GameState(fen: msg['fen0'] as String?);
      for (final u in uci) {
        game.tryMove(
          u.substring(0, 2),
          u.substring(2, 4),
          promotion: u.length > 4 ? u.substring(4, 5) : 'q',
        );
      }
    }
    notifyListeners();
  }

  void _send(Map<String, dynamic> msg) => _sock?.add(jsonEncode(msg));

  @override
  void sendMove(String from, String to, {String promotion = 'q'}) {
    if (!myTurn) return;
    // optimistic local apply for instant feel; the next state confirms it
    final san = game.tryMove(from, to, promotion: promotion);
    if (san == null) return;
    notifyListeners();
    _send({'t': 'move', 'uci': '$from$to$promotion'});
  }

  @override
  void resign() => _send({'t': 'resign'});

  @override
  void offerDraw() {
    _send({'t': 'draw', 'a': 'offer'});
  }

  @override
  void respondDraw(bool accept) =>
      _send({'t': 'draw', 'a': accept ? 'accept' : 'decline'});

  @override
  void rematch() => _send({'t': 'rematch'});

  @override
  Future<void> shutdown() async {
    _closed = true;
    await _sock?.close();
    game.dispose();
    dispose();
  }
}
