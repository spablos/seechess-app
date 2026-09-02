import 'dart:async';
import 'dart:io';

/// One end of the offline-match wire. Messages are JSON strings; a transport
/// only moves them and reports link health — the sessions stay
/// transport-blind, so the same game logic runs over Wi-Fi or Bluetooth.

abstract class HostTransport {
  void Function(String data)? onMessage;

  /// The connected guest went away (socket closed / central unsubscribed).
  void Function()? onPeerLost;

  /// Anything worth a lobby repaint (advertising state, address change).
  void Function()? onChanged;

  /// Begin accepting a guest. Must return promptly — transports that wait
  /// on external state (Bluetooth power) finish setup in the background.
  Future<void> start();

  /// Deliver to the connected guest, if any (silently dropped otherwise —
  /// the session broadcasts to every transport and only the live one has
  /// a peer).
  void send(String json);

  Future<void> close();
}

abstract class GuestTransport {
  void Function(String data)? onMessage;

  /// Link came up / went down. The session sends its hello on `true`.
  void Function(bool up)? onLink;

  /// Connecting has failed for a while — worth telling the user, though
  /// retries continue underneath.
  void Function()? onStruggling;

  /// What the UI can show for "connecting to …".
  String get label;

  /// Connect and keep reconnecting until [close].
  Future<void> connect();

  void send(String json);

  Future<void> close();
}

// -------------------------------------------------------------- WebSocket

/// Host side of the original transport: a WebSocket server on the LAN /
/// hotspot, dialed via the QR's ip:port.
class WsHostTransport extends HostTransport {
  HttpServer? _server;
  WebSocket? _sock;

  /// "ip:port" for the QR / manual entry, once listening on a real network.
  String? address;

  /// True when no usable network interface exists — a QR would encode a
  /// meaningless address. The lobby explains and offers a recheck.
  bool noNetwork = false;

  @override
  Future<void> start() async {
    final server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    _server = server;
    await _refreshAddress();
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
        (data) => onMessage?.call(data as String),
        onDone: () {
          if (_sock != sock) return;
          _sock = null;
          onPeerLost?.call();
        },
        onError: (_) {},
        cancelOnError: true,
      );
    });
  }

  Future<void> _refreshAddress() async {
    final ip = await _localIp();
    noNetwork = ip == null;
    address = ip == null ? null : '$ip:${_server!.port}';
  }

  /// The user joined a network after hosting without one — look again.
  Future<void> recheckNetwork() async {
    await _refreshAddress();
    onChanged?.call();
  }

  /// Set when the app started its own hotspot: the QR must carry THAT
  /// interface's address, not whatever Wi-Fi the phone also joined —
  /// the credentials in the QR put the guest on the hotspot's subnet.
  bool preferApInterface = false;

  /// The hotspot/LAN address guests can reach, or null when the device has
  /// no network at all (e.g. airplane mode). iOS Personal Hotspot puts
  /// the host on 172.20.10.1; otherwise prefer private-range interfaces.
  Future<String?> _localIp() async {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
    );
    if (preferApInterface) {
      // Android AP-mode interfaces: swlan0 / ap0 / softap / wlan1
      final apName = RegExp(r'swlan|softap|^ap\d|wlan1');
      for (final i in interfaces) {
        if (apName.hasMatch(i.name.toLowerCase()) && i.addresses.isNotEmpty) {
          return i.addresses.first.address;
        }
      }
      // fallback: the AP host address is the gateway-style .1
      for (final i in interfaces) {
        for (final a in i.addresses) {
          if (a.address.startsWith('192.168.') && a.address.endsWith('.1')) {
            return a.address;
          }
        }
      }
    }
    final all = [for (final i in interfaces) ...i.addresses];
    for (final prefix in ['172.20.10.', '192.168.', '10.', '172.']) {
      for (final a in all) {
        if (a.address.startsWith(prefix)) return a.address;
      }
    }
    return all.isEmpty ? null : all.first.address;
  }

  @override
  void send(String json) => _sock?.add(json);

  @override
  Future<void> close() async {
    await _sock?.close();
    await _server?.close(force: true);
  }
}

/// Guest side: dial the host's ip:port, retry forever through blips.
class WsGuestTransport extends GuestTransport {
  WsGuestTransport(this.hostAddress);

  /// "ip:port" from the QR code or manual entry.
  final String hostAddress;

  WebSocket? _sock;
  bool _closed = false;

  @override
  String get label => hostAddress;

  @override
  Future<void> connect() async {
    final began = DateTime.now();
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
        onLink?.call(true);
        await for (final data in sock) {
          onMessage?.call(data as String);
        }
      } catch (_) {
        // fall through to the retry below
      }
      _sock = null;
      if (_closed) return;
      if (DateTime.now().difference(began) > const Duration(seconds: 12)) {
        onStruggling?.call();
      }
      onLink?.call(false);
      // Wi-Fi blips happen (PRD): keep retrying until told to stop
      await Future<void>.delayed(const Duration(seconds: 2));
    }
  }

  @override
  void send(String json) => _sock?.add(json);

  @override
  Future<void> close() async {
    _closed = true;
    await _sock?.close();
  }
}
