import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SavedGame {
  SavedGame({
    required this.name,
    required this.fen,
    required this.createdAt,
    this.photoPath,
  });

  final String name;
  final String fen; // full FEN including turn
  final DateTime createdAt;
  final String? photoPath; // copy inside app documents, if kept

  Map<String, dynamic> toJson() => {
    'name': name,
    'fen': fen,
    'createdAt': createdAt.toIso8601String(),
    if (photoPath != null) 'photoPath': photoPath,
  };

  static SavedGame fromJson(Map<String, dynamic> json) => SavedGame(
    name: json['name'] as String,
    fen: json['fen'] as String,
    createdAt: DateTime.parse(json['createdAt'] as String),
    photoPath: json['photoPath'] as String?,
  );
}

/// Local-first storage for saved positions/games (PRD §3). FEN is the
/// record of truth; the photo is an optional keepsake copied into the app's
/// documents directory so library cleanups can't break it.
class SavedGamesStore {
  static const _key = 'saved_games';

  Future<List<SavedGame>> list() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null) return [];
    final games = [
      for (final item in jsonDecode(raw) as List)
        SavedGame.fromJson(item as Map<String, dynamic>),
    ];
    games.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return games;
  }

  Future<void> add(SavedGame game) async {
    final games = await list();
    games.insert(0, game);
    await _write(games);
  }

  Future<void> remove(SavedGame game) async {
    final games = await list();
    games.removeWhere(
      (g) => g.createdAt == game.createdAt && g.name == game.name,
    );
    if (game.photoPath != null) {
      try {
        await File(game.photoPath!).delete();
      } catch (_) {}
    }
    await _write(games);
  }

  /// Replace [old] with [updated] in place (edit-and-resave from the
  /// analysis board); the kept photo, if any, carries over untouched.
  Future<void> update(SavedGame old, SavedGame updated) async {
    final games = await list();
    final i = games.indexWhere(
      (g) => g.createdAt == old.createdAt && g.name == old.name,
    );
    if (i < 0) {
      games.insert(0, updated);
    } else {
      games[i] = updated;
    }
    await _write(games);
  }

  Future<void> _write(List<SavedGame> games) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _key,
      jsonEncode([for (final g in games) g.toJson()]),
    );
  }

  /// Copy a photo into the app documents dir; returns the durable path.
  static Future<String> keepPhoto(String sourcePath) async {
    final dir = await getApplicationDocumentsDirectory();
    final name =
        'photo_${DateTime.now().millisecondsSinceEpoch}${sourcePath.substring(sourcePath.lastIndexOf('.'))}';
    final dest = '${dir.path}/$name';
    await File(sourcePath).copy(dest);
    return dest;
  }
}
