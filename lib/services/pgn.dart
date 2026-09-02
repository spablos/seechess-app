import 'package:chess/chess.dart' as ch;

/// PGN (Portable Game Notation) import: headers + mainline SAN + per-ply
/// comments. Variations and NAGs are skipped (v1 keeps a single line);
/// engine tags inside comments ([%clk], [%eval]) are stripped, the human
/// part of a comment is kept and shown during replay.
class PgnGame {
  PgnGame({
    required this.headers,
    required this.sanMoves,
    required this.comments,
  });

  final Map<String, String> headers;
  final List<String> sanMoves;

  /// Comment shown after ply N (1-based: comments[1] follows White's first
  /// move). Index 0 = a comment before any move.
  final Map<int, String> comments;

  String? get white => headers['White'];
  String? get black => headers['Black'];
  String? get result => headers['Result'];
  String? get date => headers['Date'] ?? headers['UTCDate'];
  String? get startFen => headers['FEN'];
  String? get site => headers['Site'];
  String? get variant => headers['Variant'];

  /// "White – Black" when both are known (import naming).
  String? get playersLabel =>
      white != null && black != null ? '$white – $black' : null;
}

/// A parsed-and-replayed game, ready for the analysis board.
class PgnReplay {
  PgnReplay({required this.game, required this.uci, required this.finalFen});
  final PgnGame game;
  final List<String> uci;
  final String finalFen;
}

/// Split a file/paste that may hold several games (chess.com month
/// downloads, tournament files) into individual PGN texts.
List<String> splitPgn(String text) {
  final out = <String>[];
  final lines = text.replaceAll('\r\n', '\n').split('\n');
  var current = StringBuffer();
  var sawMoves = false;
  for (final line in lines) {
    final isHeader =
        line.trimLeft().startsWith('[') &&
        RegExp(r'^\s*\[\w+\s+"').hasMatch(line);
    if (isHeader && sawMoves) {
      out.add(current.toString());
      current = StringBuffer();
      sawMoves = false;
    }
    current.writeln(line);
    if (!isHeader && line.trim().isNotEmpty) sawMoves = true;
  }
  if (current.toString().trim().isNotEmpty) out.add(current.toString());
  return out;
}

/// Parse one PGN game. Throws [FormatException] with a human-readable
/// message on garbage input.
PgnGame parsePgn(String text) {
  final headers = <String, String>{};
  final headerRe = RegExp(r'^\s*\[(\w+)\s+"(.*)"\]\s*$');
  final lines = text.replaceAll('\r\n', '\n').split('\n');
  var moveText = StringBuffer();
  for (final line in lines) {
    final m = headerRe.firstMatch(line);
    if (m != null && moveText.toString().trim().isEmpty) {
      headers[m.group(1)!] = m.group(2)!;
    } else {
      moveText.writeln(line);
    }
  }

  var body = moveText.toString();

  // comments: capture, remember which ply they follow, then remove
  final comments = <int, String>{};
  final sanMoves = <String>[];

  // remove variations first (nested) — they can contain comments we skip.
  // Brace-aware: parentheses INSIDE a {comment} are prose, not variations.
  var depth = 0;
  var inComment = false;
  final noVars = StringBuffer();
  for (var i = 0; i < body.length; i++) {
    final c = body[i];
    if (c == '{' && depth == 0) inComment = true;
    if (c == '}') inComment = false;
    if (!inComment && c == '(') {
      depth++;
    } else if (!inComment && c == ')') {
      if (depth > 0) depth--;
    } else if (depth == 0) {
      noVars.write(c);
    }
  }
  body = noVars.toString();

  // walk tokens: comments attach to the ply count so far
  final tokenRe = RegExp(r'\{[^}]*\}|\S+');
  for (final m in tokenRe.allMatches(body)) {
    final tok = m.group(0)!;
    if (tok.startsWith('{')) {
      final cleaned = tok
          .substring(1, tok.length - 1)
          .replaceAll(RegExp(r'\[%\w+[^\]]*\]'), '')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      if (cleaned.isNotEmpty) {
        final ply = sanMoves.length;
        comments[ply] = comments.containsKey(ply)
            ? '${comments[ply]} $cleaned'
            : cleaned;
      }
      continue;
    }
    if (tok.startsWith(r'$')) continue; // NAG
    if (tok == '1-0' || tok == '0-1' || tok == '1/2-1/2' || tok == '*') {
      continue;
    }
    // move numbers: "12." "12..." possibly glued to the move ("12.e4")
    var t = tok.replaceFirst(RegExp(r'^\d+\.(\.\.)?'), '');
    if (t.isEmpty) continue;
    t = t.replaceAll(RegExp(r'[!?]+$'), ''); // annotations e4!? → e4
    if (t.isEmpty || t == '.' || t == '..') continue;
    sanMoves.add(t);
  }

  if (headers.isEmpty && sanMoves.isEmpty) {
    throw const FormatException('No PGN content found');
  }
  return PgnGame(headers: headers, sanMoves: sanMoves, comments: comments);
}

/// Replay the mainline into UCI, validating every move. Throws
/// [FormatException] naming the first move that doesn't apply.
PgnReplay replayPgn(PgnGame game) {
  if (game.variant != null &&
      game.variant!.toLowerCase() != 'standard' &&
      game.variant!.toLowerCase() != 'chess') {
    throw FormatException('Variant "${game.variant}" isn\'t supported');
  }
  final start = game.startFen;
  final board = start == null ? ch.Chess() : ch.Chess.fromFEN(start);
  if (start != null) {
    final v = ch.Chess.validate_fen(start);
    if (!(v['valid'] as bool)) {
      throw FormatException('Bad starting FEN: ${v['error']}');
    }
  }
  final uci = <String>[];
  for (var i = 0; i < game.sanMoves.length; i++) {
    final san = game.sanMoves[i];
    if (!board.move(san)) {
      final moveNo = i ~/ 2 + 1;
      throw FormatException(
        'Move ${i.isEven ? '$moveNo.' : '$moveNo…'} "$san" doesn\'t apply',
      );
    }
    final last = board.getHistory({'verbose': true}).last;
    final from = last['from'] as String;
    final to = last['to'] as String;
    // verbose history omits the promotion piece — read it off the SAN
    final eq = san.indexOf('=');
    final promo = eq >= 0 && eq + 1 < san.length
        ? san[eq + 1].toLowerCase()
        : '';
    uci.add('$from$to$promo');
  }
  return PgnReplay(game: game, uci: uci, finalFen: board.fen);
}

/// Build a lesson PGN from a played game: movetext with the remarks as
/// standard PGN comments (the exact shape the server validates and other
/// clients replay).
String buildLessonPgn({
  required String startFen,
  required List<String> sanMoves,
  required Map<int, String> comments,
}) {
  const std = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';
  final b = StringBuffer();
  var moveNo = 1;
  var whiteToMove = true;
  if (startFen != std) {
    b.writeln('[FEN "$startFen"]');
    b.writeln('[SetUp "1"]');
    b.writeln();
    final parts = startFen.split(' ');
    whiteToMove = parts.length < 2 || parts[1] == 'w';
    moveNo = parts.length > 5 ? (int.tryParse(parts[5]) ?? 1) : 1;
  }
  for (var i = 0; i < sanMoves.length; i++) {
    if (whiteToMove) {
      b.write('$moveNo. ');
    } else if (i == 0) {
      b.write('$moveNo... ');
    }
    b.write(sanMoves[i]);
    final remark = comments[i + 1];
    if (remark != null && remark.trim().isNotEmpty) {
      b.write(' {${remark.replaceAll('{', '(').replaceAll('}', ')')}}');
    }
    b.write(' ');
    if (!whiteToMove) moveNo++;
    whiteToMove = !whiteToMove;
  }
  return b.toString().trim();
}

/// True when clipboard/shared text looks like PGN rather than a FEN.
bool looksLikePgn(String text) {
  final t = text.trim();
  if (t.startsWith('[')) return true;
  // SAN movetext: move numbers followed by piece/pawn moves
  return RegExp(r'\d+\.\s*[KQRBNOa-h]').hasMatch(t);
}
