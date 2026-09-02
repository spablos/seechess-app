import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Online game archives — chess.com and lichess. Both expose public,
/// auth-free read APIs keyed by username, which fits the app's no-accounts
/// principle: the user types a name, we fetch their public games.
///
/// Caching: monthly archives of past months never change — cached forever
/// on disk. The current month (and lichess's recent list) refresh from the
/// network but fall back to cache offline.

const _ua = 'Seechess (github.com/spablos/seechess-app)';

/// One importable game, normalized across sources.
class SourceGame {
  SourceGame({
    required this.pgn,
    required this.white,
    required this.black,
    required this.result,
    required this.end,
    required this.timeClass,
    required this.url,
    required this.standardRules,
    this.whiteRating,
    this.blackRating,
  });

  final String pgn;
  final String white;
  final String black;
  final int? whiteRating;
  final int? blackRating;

  /// "1-0" / "0-1" / "1/2-1/2" / "*".
  final String result;
  final DateTime end;

  /// bullet / blitz / rapid / daily / classical…
  final String timeClass;
  final String url;
  final bool standardRules;
}

/// Remembered "site:username" pairs, most recently used first.
class ImportAccounts {
  static const _key = 'import_accounts';

  Future<List<String>> list() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList(_key) ?? const [];
  }

  Future<void> touch(String site, String username) async {
    final prefs = await SharedPreferences.getInstance();
    final entry = '$site:$username';
    final all = prefs.getStringList(_key) ?? [];
    all.remove(entry);
    all.insert(0, entry);
    await prefs.setStringList(_key, all.take(8).toList());
  }

  Future<void> remove(String entry) async {
    final prefs = await SharedPreferences.getInstance();
    final all = prefs.getStringList(_key) ?? [];
    all.remove(entry);
    await prefs.setStringList(_key, all);
  }
}

Future<Directory> _cacheDir(String site, String user) async {
  final base = await getApplicationSupportDirectory();
  final dir = Directory('${base.path}/imports/$site/${user.toLowerCase()}');
  await dir.create(recursive: true);
  return dir;
}

Future<String?> _getCached(File f, {Duration? maxAge}) async {
  if (!await f.exists()) return null;
  if (maxAge != null &&
      DateTime.now().difference(await f.lastModified()) > maxAge) {
    return null;
  }
  return f.readAsString();
}

Future<String> _fetch(Uri url) async {
  final res = await http
      .get(url, headers: {'User-Agent': _ua})
      .timeout(const Duration(seconds: 20));
  if (res.statusCode == 404) {
    throw const SourceException('No such user');
  }
  if (res.statusCode != 200) {
    throw SourceException('Server answered ${res.statusCode}');
  }
  return res.body;
}

class SourceException implements Exception {
  const SourceException(this.message);
  final String message;
  @override
  String toString() => message;
}

// ------------------------------------------------------------- chess.com

class ChessComClient {
  /// Month URLs, oldest→newest (published-data API).
  Future<List<String>> archives(String user) async {
    final dir = await _cacheDir('chesscom', user);
    final f = File('${dir.path}/archives.json');
    String body;
    try {
      body = await _fetch(
        Uri.parse(
          'https://api.chess.com/pub/player/${Uri.encodeComponent(user.toLowerCase())}/games/archives',
        ),
      );
      await f.writeAsString(body);
    } on SourceException {
      rethrow;
    } catch (_) {
      body = await _getCached(f) ?? (throw const SourceException('Offline'));
    }
    return ((jsonDecode(body) as Map)['archives'] as List).cast<String>();
  }

  /// Games of one monthly archive, newest first.
  Future<List<SourceGame>> month(String archiveUrl, String user) async {
    final dir = await _cacheDir('chesscom', user);
    final key = archiveUrl.split('/games/').last.replaceAll('/', '-');
    final f = File('${dir.path}/$key.json');
    final now = DateTime.now();
    final isCurrentMonth =
        key == '${now.year}-${now.month.toString().padLeft(2, '0')}';
    String body;
    final cached = await _getCached(
      f,
      maxAge: isCurrentMonth ? const Duration(minutes: 10) : null,
    );
    if (cached != null) {
      body = cached;
    } else {
      try {
        body = await _fetch(Uri.parse(archiveUrl));
        await f.writeAsString(body);
      } catch (_) {
        body = await _getCached(f) ?? (throw const SourceException('Offline'));
      }
    }
    final games = ((jsonDecode(body) as Map)['games'] as List? ?? const [])
        .cast<Map<String, dynamic>>();
    final out = <SourceGame>[];
    for (final g in games) {
      final pgn = g['pgn'] as String?;
      if (pgn == null) continue;
      final white = (g['white'] as Map?)?['username'] as String? ?? '?';
      final black = (g['black'] as Map?)?['username'] as String? ?? '?';
      final wr = (g['white'] as Map?)?['result'] as String? ?? '';
      out.add(
        SourceGame(
          pgn: pgn,
          white: white,
          black: black,
          result: wr == 'win'
              ? '1-0'
              : ((g['black'] as Map?)?['result'] as String? ?? '') == 'win'
              ? '0-1'
              : '1/2-1/2',
          end: DateTime.fromMillisecondsSinceEpoch(
            ((g['end_time'] as num?) ?? 0).toInt() * 1000,
          ),
          timeClass: g['time_class'] as String? ?? '',
          url: g['url'] as String? ?? '',
          standardRules: (g['rules'] as String? ?? 'chess') == 'chess',
          whiteRating: ((g['white'] as Map?)?['rating'] as num?)?.toInt(),
          blackRating: ((g['black'] as Map?)?['rating'] as num?)?.toInt(),
        ),
      );
    }
    return out.reversed.toList();
  }
}

// -------------------------------------------------------------- lichess

class LichessClient {
  /// Most recent [max] standard-rated-or-casual games, newest first.
  Future<List<SourceGame>> recent(String user, {int max = 60}) async {
    final dir = await _cacheDir('lichess', user);
    final f = File('${dir.path}/recent.ndjson');
    String body;
    final cached = await _getCached(f, maxAge: const Duration(minutes: 10));
    if (cached != null) {
      body = cached;
    } else {
      try {
        final res = await http
            .get(
              Uri.parse(
                'https://lichess.org/api/games/user/${Uri.encodeComponent(user)}'
                '?max=$max&pgnInJson=true&perfType=ultraBullet,bullet,blitz,rapid,classical,correspondence',
              ),
              headers: {'User-Agent': _ua, 'Accept': 'application/x-ndjson'},
            )
            .timeout(const Duration(seconds: 30));
        if (res.statusCode == 404) throw const SourceException('No such user');
        if (res.statusCode != 200) {
          throw SourceException('Server answered ${res.statusCode}');
        }
        body = utf8.decode(res.bodyBytes);
        await f.writeAsString(body);
      } on SourceException {
        rethrow;
      } catch (_) {
        body = await _getCached(f) ?? (throw const SourceException('Offline'));
      }
    }
    final out = <SourceGame>[];
    for (final line in const LineSplitter().convert(body)) {
      if (line.trim().isEmpty) continue;
      final g = jsonDecode(line) as Map<String, dynamic>;
      final pgn = g['pgn'] as String?;
      if (pgn == null) continue;
      final players = g['players'] as Map? ?? const {};
      String name(String side) =>
          ((players[side] as Map?)?['user'] as Map?)?['name'] as String? ??
          'Anonymous';
      final winner = g['winner'] as String?;
      out.add(
        SourceGame(
          pgn: pgn,
          white: name('white'),
          black: name('black'),
          result: winner == 'white'
              ? '1-0'
              : winner == 'black'
              ? '0-1'
              : ((g['status'] as String?) == 'draw' ||
                    (g['status'] as String?) == 'stalemate')
              ? '1/2-1/2'
              : '*',
          end: DateTime.fromMillisecondsSinceEpoch(
            ((g['lastMoveAt'] as num?) ?? 0).toInt(),
          ),
          timeClass: g['speed'] as String? ?? '',
          url: 'https://lichess.org/${g['id']}',
          standardRules: (g['variant'] as String? ?? 'standard') == 'standard',
          whiteRating: ((players['white'] as Map?)?['rating'] as num?)?.toInt(),
          blackRating: ((players['black'] as Map?)?['rating'] as num?)?.toInt(),
        ),
      );
    }
    return out;
  }
}
