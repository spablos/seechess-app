import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:seechess/services/offline/ble_transport.dart';
import 'package:seechess/services/offline/match_session.dart';
import 'package:seechess/services/offline/transport.dart';

/// An in-memory transport pair: what the BLE (or any future) link must
/// behave like. Proves the sessions are genuinely transport-blind.
class FakePipe {
  final host = _FakeHost();
  final guest = _FakeGuest();

  FakePipe() {
    host._peer = guest;
    guest._peer = host;
  }
}

class _FakeHost extends HostTransport {
  _FakeGuest? _peer;
  @override
  Future<void> start() async {}
  @override
  void send(String json) {
    if (_peer!._up) _peer!.onMessage?.call(json);
  }

  @override
  Future<void> close() async {}
}

class _FakeGuest extends GuestTransport {
  _FakeHost? _peer;
  bool _up = false;
  @override
  String get label => 'fake';
  @override
  Future<void> connect() async {
    _up = true;
    onLink?.call(true);
  }

  void drop() {
    _up = false;
    onLink?.call(false);
    _peer!.onPeerLost?.call();
  }

  @override
  void send(String json) {
    if (_up) _peer!.onMessage?.call(json);
  }

  @override
  Future<void> close() async {
    _up = false;
  }
}

void main() {
  group('FrameBuffer', () {
    test('roundtrips a message split into tiny chunks', () {
      final msg = jsonEncode({'t': 'state', 'uci': List.filled(60, 'e2e4')});
      final frame = FrameBuffer.encode(msg);
      final buf = FrameBuffer();
      final got = <String>[];
      for (var i = 0; i < frame.length; i += 7) {
        final end = i + 7 > frame.length ? frame.length : i + 7;
        got.addAll(buf.add(Uint8List.sublistView(frame, i, end)));
      }
      expect(got, [msg]);
    });

    test('two frames arriving glued together both decode', () {
      final buf = FrameBuffer();
      final joined = BytesBuilder()
        ..add(FrameBuffer.encode('{"a":1}'))
        ..add(FrameBuffer.encode('{"b":2}'));
      expect(buf.add(joined.toBytes()), ['{"a":1}', '{"b":2}']);
    });

    test('empty and non-ascii payloads survive', () {
      final buf = FrameBuffer();
      expect(buf.add(FrameBuffer.encode('')), ['']);
      expect(buf.add(FrameBuffer.encode('{"n":"פבלו ♞"}')), ['{"n":"פבלו ♞"}']);
    });
  });

  test('a full match runs over an arbitrary transport', () async {
    final pipe = FakePipe();
    final host = HostSession(
      name: 'Pablo',
      tc: const TimeControl(3, 2),
      hostWhite: true,
      transports: [pipe.host],
    );
    await host.start();
    final guest = GuestSession(name: 'Rotem', transport: pipe.guest);
    await guest.connect();

    expect(host.oppName, 'Rotem');
    expect(guest.connected, isTrue);

    host.beginMatch();
    expect(guest.started, isTrue);
    expect(guest.myWhite, isFalse);

    host.sendMove('e2', 'e4');
    expect(guest.game.moves.length, 1);
    guest.sendMove('e7', 'e5');
    expect(host.game.moves.length, 2);

    // a link blip pauses the clock and reconnect restores full state
    final ticking = host.clockRunning;
    expect(ticking, isTrue);
    pipe.guest.drop();
    expect(host.connected, isFalse);
    expect(host.clockRunning, isFalse);
    await guest.connect(); // fake reconnect; hello re-syncs
    expect(host.connected, isTrue);
    expect(host.clockRunning, isTrue);
    expect(guest.game.moves.length, 2);

    guest.resign(); // the guest is Black — White wins
    expect(host.result, '1–0 resignation');
    expect(guest.result, '1–0 resignation');

    await guest.shutdown();
    await host.shutdown();
  });
}
