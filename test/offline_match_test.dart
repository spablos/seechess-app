import 'package:flutter_test/flutter_test.dart';
import 'package:seechess/services/offline/match_session.dart';

/// Real host + guest over a loopback socket — the whole protocol end to end.
Future<void> until(bool Function() cond, String why) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!cond()) {
    if (DateTime.now().isAfter(deadline)) fail('timed out waiting: $why');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  test('lobby, moves, clocks, resign and rematch over a real socket', () async {
    final host = HostSession(
      name: 'Pablo',
      tc: const TimeControl(3, 2),
      hostWhite: true,
    );
    await host.start();
    expect(host.address, isNotNull);

    final guest = GuestSession(
      name: 'Rotem',
      hostAddress: '127.0.0.1:${host.address!.split(':').last}',
    );
    // ignore: unawaited_futures
    guest.connect();

    await until(() => host.oppName == 'Rotem', 'host sees guest hello');
    await until(() => guest.connected, 'guest connected');

    host.beginMatch();
    await until(() => guest.started, 'guest received match start');
    expect(guest.myWhite, isFalse);
    expect(guest.timeControl.minutes, 3);
    expect(guest.oppName, 'Pablo');

    // white (host) moves; black (guest) answers
    host.sendMove('e2', 'e4');
    await until(() => guest.game.moves.length == 1, 'guest mirrors e4');
    expect(guest.game.moves.first.san, 'e4');

    guest.sendMove('e7', 'e5');
    await until(() => host.game.moves.length == 2, 'host applies ...e5');
    expect(host.game.moves.last.san, 'e5');

    // out-of-turn and illegal moves are ignored by the authority
    guest.sendMove('d7', 'd5'); // not guest's turn
    host.sendMove('e4', 'e6'); // illegal pawn jump
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(host.game.moves.length, 2);

    // clocks: white spent time and got the +2s increment back
    expect(host.displayMs(true), greaterThan(3 * 60000 - 3000));
    expect(host.displayMs(true), lessThanOrEqualTo(3 * 60000 + 2000));

    // draw offer flows across and can be declined
    guest.offerDraw();
    await until(() => host.drawOfferFrom == 'opp', 'host sees draw offer');
    host.respondDraw(false);
    await until(() => guest.drawOfferFrom == null, 'offer cleared');

    // resignation ends the game on both devices
    host.resign();
    await until(() => guest.result != null, 'guest sees result');
    expect(guest.result, '0–1 resignation');
    expect(host.result, '0–1 resignation');

    // rematch: both agree, colors swap, board resets
    host.rematch();
    await until(() => guest.rematchFrom == 'opp', 'guest sees request');
    guest.rematch();
    await until(() => guest.result == null && guest.started, 'rematch started');
    expect(guest.myWhite, isTrue);
    expect(host.myWhite, isFalse);
    expect(guest.game.moves, isEmpty);
    expect(host.game.moves, isEmpty);

    // now the guest is white and moves first
    guest.sendMove('d2', 'd4');
    await until(() => host.game.moves.length == 1, 'host mirrors d4');

    await guest.shutdown();
    await host.shutdown();
  });

  test('a flag on the authoritative clock ends the game', () async {
    final host = HostSession(
      name: 'A',
      tc: const TimeControl(0, 0), // zero base time: white flags instantly
      hostWhite: true,
    );
    await host.start();
    final guest = GuestSession(
      name: 'B',
      hostAddress: '127.0.0.1:${host.address!.split(':').last}',
    );
    // ignore: unawaited_futures
    guest.connect();
    await until(() => host.oppName == 'B', 'hello');
    host.beginMatch();
    await until(() => guest.result != null, 'flag propagates');
    expect(guest.result, '0–1 time');
    await guest.shutdown();
    await host.shutdown();
  });
}
