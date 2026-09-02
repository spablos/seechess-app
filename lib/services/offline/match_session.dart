import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../../models/game_state.dart';
import 'ble_transport.dart';
import 'hotspot.dart';
import 'transport.dart';

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
    List<HostTransport>? transports,
  }) : _myName = name,
       transports =
           transports ??
           [
             WsHostTransport(),
             // phones also advertise over Bluetooth — a guest can join with
             // no shared network at all (tests and desktop stay ws-only)
             if (Platform.isAndroid || Platform.isIOS)
               BleHostTransport(advertiseName: name),
           ] {
    timeControl = tc;
  }

  final String _myName;

  /// Host's color; null = coin flip at match start.
  bool? hostWhite;

  /// Optional non-standard start position (a photographed one, later).
  final String? startFen;

  /// Every way a guest can reach this host, all live at once; whichever
  /// one the guest dials delivers, the rest idle.
  final List<HostTransport> transports;

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

  WsHostTransport? get _ws =>
      transports.whereType<WsHostTransport>().firstOrNull;

  /// Which paths this host offers (the lobby renders only what exists).
  bool get hasWifi => _ws != null;
  bool get hasBle => _ble != null;
  BleHostTransport? get _ble =>
      transports.whereType<BleHostTransport>().firstOrNull;

  /// "ip:port" for the QR / manual entry, once listening.
  String? get address => _ws?.address;

  /// True when no usable network interface exists — a QR would encode a
  /// meaningless address. The lobby explains and offers a recheck.
  bool get noNetwork => _ws?.noNetwork ?? false;

  /// What the Bluetooth broadcast actually says (name or open invite).
  String? get bleAdvertiseName => _ble?.advertiseName;

  /// Bluetooth advertising state for the lobby: 'advertising' | 'off' |
  /// 'unsupported' | null (no BLE transport).
  String? get bleStatus => _ble?.status;

  Future<void> start() async {
    for (final t in transports) {
      t.onMessage = _onGuestMessage;
      t.onChanged = notifyListeners;
      t.onPeerLost = () {
        connected = false;
        _pauseClock(); // fairness: a link blip must not flag anyone
        notifyListeners();
      };
      await t.start();
    }
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

  /// The user joined a network after hosting without one — look again.
  Future<void> recheckNetwork() async => _ws?.recheckNetwork();

  /// Hotspot credentials once [startHotspot] succeeded — carried in the QR
  /// so a guest's phone joins the network automatically.
  String? hotspotSsid;
  String? hotspotPass;

  /// Android can spin up an app-owned hotspot; iOS cannot (no public API).
  bool get canHotspot => !kIsWeb && Platform.isAndroid;

  /// Returns null on success, else the blocker code (see Hotspot.hostStart).
  Future<String?> startHotspot() async {
    final cfg = await Hotspot.hostStart();
    if (cfg.error != null || cfg.ssid == null) {
      return cfg.error ?? 'failed';
    }
    hotspotSsid = cfg.ssid;
    hotspotPass = cfg.pass;
    _ws?.preferApInterface = true;
    // the hotspot interface takes a moment to get its address
    for (var i = 0; i < 10 && address == null; i++) {
      await _ws?.recheckNetwork();
      if (address != null) break;
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    notifyListeners();
    return null;
  }

  /// What the QR encodes: the socket address, plus hotspot credentials
  /// when we opened one (the guest joins the network, then dials).
  String? get qrPayload {
    final a = address;
    if (a == null) return null;
    if (hotspotSsid == null) return 'seechess://$a';
    return 'seechess://$a'
        '?ssid=${Uri.encodeQueryComponent(hotspotSsid!)}'
        '&pass=${Uri.encodeQueryComponent(hotspotPass!)}';
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
    for (final t in transports) {
      t.send(state);
    }
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
    for (final t in transports) {
      await t.close();
    }
    if (hotspotSsid != null) await Hotspot.hostStop();
    game.dispose();
    dispose();
  }
}

// ---------------------------------------------------------------- guest

class GuestSession extends MatchSession {
  /// Dial by ip:port (QR / typed address) or over any [GuestTransport]
  /// (the Bluetooth nearby list passes one in).
  GuestSession({
    required String name,
    String? hostAddress,
    GuestTransport? transport,
  }) : assert(hostAddress != null || transport != null),
       _myName = name,
       transport = transport ?? WsGuestTransport(hostAddress!);

  final String _myName;

  final GuestTransport transport;

  /// What the UI shows for "connecting to …" — an address or a host name.
  String get hostAddress => transport.label;

  String? _hostName;
  int _lastSeq = 0;

  @override
  String get myName => _myName;
  @override
  String? get oppName => _hostName;
  @override
  bool get isHost => false;

  /// Set once connecting has failed for a while: the UI tells the user the
  /// host is unreachable (retries continue underneath regardless).
  bool struggling = false;

  Future<void> connect() {
    transport.onMessage = _onHostMessage;
    transport.onStruggling = () => struggling = true;
    transport.onLink = (up) {
      connected = up;
      if (up) {
        struggling = false;
        transport.send(jsonEncode({'t': 'hello', 'name': _myName}));
      }
      notifyListeners();
    };
    return transport.connect();
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

  void _send(Map<String, dynamic> msg) => transport.send(jsonEncode(msg));

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
    await transport.close();
    await Hotspot.guestLeave(); // no-op unless the QR join used one
    game.dispose();
    dispose();
  }
}
