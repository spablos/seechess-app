import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// One library entry. FEN is the record of truth; [startFen]+[movesUci]
/// additionally carry a played game so it can be reopened mid-line; the
/// photo is an optional keepsake copied into the app's documents dir.
class SavedGame {
  SavedGame({
    String? id,
    required this.name,
    required this.fen,
    required this.createdAt,
    DateTime? modifiedAt,
    this.labels = const [],
    this.photoPath,
    this.startFen,
    this.movesUci = const [],
    this.white,
    this.black,
    this.result,
    this.sourceUrl,
    this.comments = const {},
  }) : id = id ?? createdAt.microsecondsSinceEpoch.toString(),
       modifiedAt = modifiedAt ?? createdAt;

  /// Stable identity — survives renames and edits.
  final String id;
  final String name;

  /// Current position, full FEN including turn.
  final String fen;
  final DateTime createdAt;
  final DateTime modifiedAt;
  final List<String> labels;
  final String? photoPath;

  /// When a played game was saved: the position it started from and the
  /// moves from there (UCI). [fen] stays the latest position.
  final String? startFen;
  final List<String> movesUci;

  /// Imported-game metadata (PGN headers), null for home-grown entries.
  final String? white;
  final String? black;
  final String? result;

  /// Round-trip link to where the game came from (chess.com / lichess).
  final String? sourceUrl;

  /// PGN comments by 1-based ply, shown during replay.
  final Map<int, String> comments;

  SavedGame copyWith({
    String? name,
    String? fen,
    DateTime? modifiedAt,
    List<String>? labels,
    String? photoPath,
    String? startFen,
    List<String>? movesUci,
  }) => SavedGame(
    id: id,
    name: name ?? this.name,
    fen: fen ?? this.fen,
    createdAt: createdAt,
    modifiedAt: modifiedAt ?? this.modifiedAt,
    labels: labels ?? this.labels,
    photoPath: photoPath ?? this.photoPath,
    startFen: startFen ?? this.startFen,
    movesUci: movesUci ?? this.movesUci,
    white: white,
    black: black,
    result: result,
    sourceUrl: sourceUrl,
    comments: comments,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'fen': fen,
    'createdAt': createdAt.toIso8601String(),
    'modifiedAt': modifiedAt.toIso8601String(),
    if (labels.isNotEmpty) 'labels': labels,
    if (photoPath != null) 'photoPath': photoPath,
    if (startFen != null) 'startFen': startFen,
    if (movesUci.isNotEmpty) 'movesUci': movesUci,
    if (white != null) 'white': white,
    if (black != null) 'black': black,
    if (result != null) 'result': result,
    if (sourceUrl != null) 'sourceUrl': sourceUrl,
    if (comments.isNotEmpty)
      'comments': {for (final e in comments.entries) '${e.key}': e.value},
  };

  static SavedGame fromJson(Map<String, dynamic> json) {
    final created = DateTime.parse(json['createdAt'] as String);
    return SavedGame(
      // pre-library entries had no id — derive a stable one
      id: json['id'] as String? ?? created.microsecondsSinceEpoch.toString(),
      name: json['name'] as String,
      fen: json['fen'] as String,
      createdAt: created,
      modifiedAt: json['modifiedAt'] != null
          ? DateTime.parse(json['modifiedAt'] as String)
          : created,
      labels: (json['labels'] as List?)?.cast<String>() ?? const [],
      photoPath: json['photoPath'] as String?,
      startFen: json['startFen'] as String?,
      movesUci: (json['movesUci'] as List?)?.cast<String>() ?? const [],
      white: json['white'] as String?,
      black: json['black'] as String?,
      result: json['result'] as String?,
      sourceUrl: json['sourceUrl'] as String?,
      comments: {
        for (final e in ((json['comments'] as Map?) ?? const {}).entries)
          int.parse(e.key as String): e.value as String,
      },
    );
  }
}

/// Local-first library storage (PRD §3): every confirmed detection lands
/// here automatically; analysis-board saves are explicit entries.
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
    games.sort((a, b) => b.modifiedAt.compareTo(a.modifiedAt));
    return games;
  }

  Future<void> add(SavedGame game) async {
    final games = await list();
    games.insert(0, game);
    await _write(games);
  }

  Future<void> remove(SavedGame game) async {
    final games = await list();
    games.removeWhere((g) => g.id == game.id);
    if (game.photoPath != null) {
      try {
        await File(game.photoPath!).delete();
      } catch (_) {}
    }
    await _write(games);
  }

  /// Upsert by stable id.
  Future<void> update(SavedGame updated) async {
    final games = await list();
    final i = games.indexWhere((g) => g.id == updated.id);
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
