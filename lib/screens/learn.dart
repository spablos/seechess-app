import 'dart:async';

import 'package:flutter/material.dart';

import '../services/lessons.dart';
import '../services/stats.dart';
import '../services/pgn.dart';
import 'analysis.dart';

/// The learning library: curated openings and traps with coaching remarks,
/// plus community lessons approved on the server. Tapping a lesson opens
/// the analysis board at move 0 — step through and read the balloons; the
/// engine runs so "why not this?" always has an answer.
class LearnScreen extends StatefulWidget {
  const LearnScreen({super.key});

  @override
  State<LearnScreen> createState() => _LearnScreenState();
}

class _LearnScreenState extends State<LearnScreen> {
  List<Lesson>? _lessons;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final store = LessonStore();
    final bundled = await store.bundled();
    if (mounted) setState(() => _lessons = bundled);
    final community = await store.community();
    if (mounted && community.isNotEmpty) {
      setState(() => _lessons = [...bundled, ...community]);
    }
  }

  void _open(Lesson lesson) {
    final PgnReplay replay;
    try {
      replay = lesson.replay();
    } on FormatException catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("This lesson won't open: ${e.message}")),
      );
      return;
    }
    unawaited(AppStats.count('lesson_open'));
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => AnalysisScreen(
          fen: replay.game.startFen,
          movesUci: replay.uci,
          editable: true,
          initialPly: 0,
          initialFlipped: lesson.side == 'b',
          title: lesson.title,
          comments: replay.game.comments,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final lessons = _lessons;
    // stable order: curated categories first, community last
    final categories = <String>[];
    for (final l in lessons ?? <Lesson>[]) {
      if (!categories.contains(l.category)) categories.add(l.category);
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Learn')),
      body: lessons == null
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                children: [
                  for (final cat in categories) ...[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                      child: Text(
                        cat,
                        style: theme.textTheme.titleSmall?.copyWith(
                          color: theme.colorScheme.primary,
                        ),
                      ),
                    ),
                    for (final l in lessons.where((l) => l.category == cat))
                      ListTile(
                        leading: Container(
                          width: 34,
                          height: 34,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: l.side == 'w'
                                ? Colors.white
                                : const Color(0xFF1E1E1E),
                            border: Border.all(
                              color: theme.colorScheme.outlineVariant,
                            ),
                          ),
                          child: Icon(
                            Icons.school,
                            size: 18,
                            color: l.side == 'w'
                                ? Colors.black54
                                : Colors.white70,
                          ),
                        ),
                        title: Text(l.title),
                        subtitle: l.author != null
                            ? Text('by ${l.author}')
                            : null,
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => _open(l),
                      ),
                  ],
                  const SizedBox(height: 24),
                ],
              ),
            ),
    );
  }
}
