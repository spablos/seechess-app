import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'pgn.dart';
import 'recognizer.dart';

/// The learning library (PRD-learn-and-coach §1–2): curated opening
/// lessons bundled with the app, merged with community lessons approved on
/// the server. A lesson is a PGN whose comments are the coaching balloons.
class Lesson {
  Lesson({
    required this.id,
    required this.title,
    required this.category,
    required this.side,
    required this.pgn,
    this.author,
    this.community = false,
  });

  final String id;
  final String title;

  /// "Openings" | "Traps & gambits" | community-chosen.
  final String category;

  /// Whose ideas the remarks coach: 'w' | 'b'.
  final String side;
  final String pgn;
  final String? author;
  final bool community;

  static Lesson fromJson(Map<String, dynamic> j, {bool community = false}) =>
      Lesson(
        id: j['id'] as String,
        title: j['title'] as String,
        category: j['category'] as String? ?? 'Community',
        side: j['side'] as String? ?? 'w',
        pgn: j['pgn'] as String,
        author: j['author'] as String?,
        community: community,
      );

  /// Parse and validate; throws [FormatException] on a broken lesson.
  PgnReplay replay() => replayPgn(parsePgn(pgn));
}

class LessonStore {
  /// The pack shipped inside the app — always available, even offline.
  Future<List<Lesson>> bundled() async {
    final raw = await rootBundle.loadString('assets/learn/lessons.json');
    return [
      for (final j in jsonDecode(raw) as List)
        Lesson.fromJson(j as Map<String, dynamic>),
    ];
  }

  Future<File> _cacheFile() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/learn_community.json');
  }

  /// Community lessons approved on the server; network refresh with a
  /// disk-cache fallback so Learn works offline.
  Future<List<Lesson>> community() async {
    final f = await _cacheFile();
    try {
      final base = await RecognizerClient.savedUrl();
      final res = await http
          .get(Uri.parse('$base/v1/lessons'))
          .timeout(const Duration(seconds: 10));
      if (res.statusCode == 200) {
        await f.writeAsString(res.body);
      }
    } catch (_) {
      // offline — fall through to the cache
    }
    if (!await f.exists()) return [];
    try {
      final list = jsonDecode(await f.readAsString()) as List;
      final out = <Lesson>[];
      for (final j in list) {
        final lesson = Lesson.fromJson(
          j as Map<String, dynamic>,
          community: true,
        );
        try {
          lesson.replay(); // never surface a lesson that can't play
          out.add(lesson);
        } on FormatException {
          continue;
        }
      }
      return out;
    } catch (_) {
      return [];
    }
  }

  /// Submit a lesson for review. Returns null on success, else the error.
  Future<String?> submit({
    required String title,
    required String pgn,
    String? author,
    String side = 'w',
  }) async {
    try {
      final base = await RecognizerClient.savedUrl();
      final res = await http
          .post(
            Uri.parse('$base/v1/lessons/submit'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'title': title,
              'pgn': pgn,
              'side': side,
              if (author != null && author.isNotEmpty) 'author': author,
            }),
          )
          .timeout(const Duration(seconds: 15));
      if (res.statusCode == 200) return null;
      return 'Server answered ${res.statusCode}';
    } catch (e) {
      return 'Could not reach the server';
    }
  }
}
