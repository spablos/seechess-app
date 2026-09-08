import 'dart:convert';
import 'package:universal_io/io.dart';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
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
  /// cache fallback so Learn works offline. The cache is a file on
  /// mobile and SharedPreferences on web (no filesystem there — the
  /// direct port threw and killed Learn's community list, Sep 2026).
  Future<List<Lesson>> community() async {
    String? cached;
    try {
      final base = await RecognizerClient.savedUrl();
      final res = await http
          .get(Uri.parse('$base/v1/lessons'))
          .timeout(const Duration(seconds: 10));
      if (res.statusCode == 200) {
        cached = res.body;
        if (kIsWeb) {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString('learn_community', res.body);
        } else {
          await (await _cacheFile()).writeAsString(res.body);
        }
      }
    } catch (_) {
      // offline — fall through to the cache
    }
    if (cached == null) {
      try {
        if (kIsWeb) {
          final prefs = await SharedPreferences.getInstance();
          cached = prefs.getString('learn_community');
        } else {
          final f = await _cacheFile();
          if (await f.exists()) cached = await f.readAsString();
        }
      } catch (_) {}
    }
    if (cached == null) return [];
    try {
      final list = jsonDecode(cached) as List;
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

/// Web-app admin mode: present when the page URL carries ?token= — the
/// reviewer's Learn tab then also shows pending lessons with approve/
/// reject, replacing the back-office HTML walker.
String? adminToken() {
  if (!kIsWeb) return null;
  final t = Uri.base.queryParameters['token'];
  return (t == null || t.isEmpty) ? null : t;
}

Future<List<Lesson>> fetchPendingLessons(String token) async {
  final base = await RecognizerClient.savedUrl();
  final res = await http
      .get(Uri.parse('$base/v1/lessons/pending?token=$token'))
      .timeout(const Duration(seconds: 10));
  if (res.statusCode != 200) return const [];
  return [
    for (final j in jsonDecode(res.body) as List)
      Lesson.fromJson(j as Map<String, dynamic>, community: true),
  ];
}

Future<bool> moderateLesson(String token, String id, bool approve) async {
  final base = await RecognizerClient.savedUrl();
  final res = await http
      .post(
        Uri.parse('$base/v1/lessons/moderate?token=$token'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'id': id, 'approve': approve}),
      )
      .timeout(const Duration(seconds: 10));
  return res.statusCode == 200;
}
