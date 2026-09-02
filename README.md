# Seechess (app)

The Flutter client of [Seechess](https://seechess.nopatos.com): photograph
any chessboard — a real board at an angle, a screenshot, a diagram — and
land on a live Stockfish analysis board. Import full games (PGN,
chess.com, lichess), learn classic openings with move-by-move coaching,
keep a searchable library, and play a friend offline over Bluetooth or a
hotspot — no accounts, no ads, no tracking.

Free software under GPL-3 (see LICENSE), powered by the Stockfish chess
engine. iOS: TestFlight (https://testflight.apple.com/join/Y6HeCtNe) ·
Android: Play testing
(https://play.google.com/apps/testing/com.seechess.seechess).

## Fair play

Seechess is built for learning and analysis — reviewing games, studying
openings, understanding positions. After the game, not during it.

Using engine assistance while playing rated chess, online or over the
board, is cheating: it violates the fair-play rules of every major
platform (chess.com, lichess) and of FIDE, and typically ends in account
closure or disqualification. Seechess is not designed for, and must not
be used for, real-time assistance in competitive play. How you use the
app is your responsibility alone.

## Building

Standard Flutter: `flutter pub get && flutter run`. The recognition
server it talks to lives in the main seechess repository.
