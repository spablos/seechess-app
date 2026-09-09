import 'dart:async';

import 'package:flutter/material.dart';

import '../widgets/capped_app_bar.dart';

import '../widgets/lesson_tree_view.dart';
import '../services/lesson_tree.dart';
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
  List<Lesson> _pending = const [];
  bool _treeView = false;

  /// Tree expansion: sections (White/Black) start open, everything under
  /// them collapsed; the appbar buttons flip the whole tree at once
  /// (epoch forces the subtree to rebuild its state).
  bool _treeExpanded = false;
  bool _sectionsExpanded = true;
  int _treeEpoch = 0;

  /// Live search over everything a lesson is made of: title, author,
  /// category, remarks and moves (a query like "e4" matches the PGN).
  final _search = TextEditingController();
  bool _searching = false;

  /// List-view perspective filter: null = both sides, 'w', 'b'.
  String? _sideFilter;

  List<Lesson> _filter(List<Lesson> all) {
    final q = _search.text.trim().toLowerCase();
    if (q.isEmpty) return all;
    return [
      for (final l in all)
        if (l.title.toLowerCase().contains(q) ||
            (l.author ?? '').toLowerCase().contains(q) ||
            l.category.toLowerCase().contains(q) ||
            l.pgn.toLowerCase().contains(q))
          l,
    ];
  }

  List<Lesson> _bySide(List<Lesson> all) => _sideFilter == null
      ? all
      : [
          for (final l in all)
            if (l.side == _sideFilter) l,
        ];

  /// The filter button's face: the same white/black circle the lesson rows
  /// wear — split in half when both sides are shown.
  Widget _sideFilterIcon(ThemeData theme) {
    const white = Colors.white;
    const black = Color(0xFF1E1E1E);
    return Container(
      width: 24,
      height: 24,
      foregroundDecoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(
          color: theme.colorScheme.onSurfaceVariant,
          width: 1.5,
        ),
      ),
      child: ClipOval(
        child: _sideFilter == null
            ? const Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(child: ColoredBox(color: white)),
                  Expanded(child: ColoredBox(color: black)),
                ],
              )
            : SizedBox.expand(
                child: ColoredBox(color: _sideFilter == 'w' ? white : black),
              ),
      ),
    );
  }

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
    final token = adminToken();
    if (token != null) {
      try {
        final pending = await fetchPendingLessons(token);
        if (mounted) setState(() => _pending = pending);
      } catch (_) {}
    }
  }

  Future<void> _moderate(Lesson lesson, bool approve) async {
    final token = adminToken();
    if (token == null) return;
    final ok = await moderateLesson(token, lesson.id, approve);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          ok
              ? '"${lesson.title}" ${approve ? 'approved' : 'rejected'}'
              : 'Moderation failed — check the token',
        ),
      ),
    );
    if (ok) unawaited(_load());
  }

  void _open(Lesson lesson, {int initialPly = 0}) {
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
          initialPly: initialPly,
          initialFlipped: lesson.side == 'b',
          title: lesson.title,
          comments: replay.game.comments,
          lessonId: lesson.id,
          treeLessons: _lessons,
        ),
      ),
    );
  }

  /// Open a shared-trunk segment: the moves every lesson below the node
  /// has in common, annotated with the remarks of one lesson that passes
  /// through (the busiest one available).
  void _openTrunk(List<String> pathSans, String side) {
    final all = _lessons ?? const <Lesson>[];
    Lesson? host;
    Map<int, String> comments = const {};
    for (final l in all.where((l) => l.side == side)) {
      try {
        final game = parsePgn(l.pgn);
        if (game.sanMoves.length >= pathSans.length &&
            List.generate(pathSans.length, (i) => game.sanMoves[i]).join(' ') ==
                pathSans.join(' ')) {
          host = l;
          comments = {
            for (final e in game.comments.entries)
              if (e.key <= pathSans.length) e.key: e.value,
          };
          break;
        }
      } on FormatException {
        continue;
      }
    }
    final PgnReplay replay;
    try {
      replay = replayPgn(
        PgnGame(headers: const {}, sanMoves: pathSans, comments: comments),
      );
    } catch (_) {
      return;
    }
    unawaited(AppStats.count('lesson_open'));
    final name = openingNameFor(pathSans, afterPly: 0);
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => AnalysisScreen(
          movesUci: replay.uci,
          editable: true,
          initialPly: 0,
          initialFlipped: side == 'b',
          title: 'Shared line — ${name ?? host?.title ?? 'openings'}',
          comments: comments,
          lessonId: host?.id,
          treeLessons: all,
          // only forks inside the subtree entered through — lessons from
          // other opening families are reachable via the tree, not here
          branchesFromPly: pathSans.length,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final lessons = _lessons == null ? null : _filter(_lessons!);
    final listLessons = lessons == null ? null : _bySide(lessons);
    final searchingActive = _search.text.trim().isNotEmpty;
    // stable order: curated categories first, community last
    final categories = <String>[];
    for (final l in listLessons ?? <Lesson>[]) {
      if (!categories.contains(l.category)) categories.add(l.category);
    }
    return Scaffold(
      appBar: cappedAppBar(
        AppBar(
          title: _searching
              ? TextField(
                  controller: _search,
                  autofocus: true,
                  decoration: const InputDecoration(
                    hintText: 'Search lessons, text, moves (e.g. e4)…',
                    border: InputBorder.none,
                  ),
                  onChanged: (_) => setState(() {}),
                )
              : const Text('Learn'),
          actions: [
            IconButton(
              tooltip: _searching ? 'Close search' : 'Search',
              icon: Icon(_searching ? Icons.close : Icons.search),
              onPressed: () => setState(() {
                if (_searching) _search.clear();
                _searching = !_searching;
              }),
            ),
            IconButton(
              tooltip: switch (_sideFilter) {
                'w' => 'Showing White lessons — tap for Black',
                'b' => 'Showing Black lessons — tap for both',
                _ => 'Showing both sides — tap for White',
              },
              icon: _sideFilterIcon(theme),
              onPressed: () => setState(() {
                _sideFilter = switch (_sideFilter) {
                  null => 'w',
                  'w' => 'b',
                  _ => null,
                };
              }),
            ),
            if (_treeView) ...[
              IconButton(
                tooltip: 'Collapse all',
                icon: const Icon(Icons.compress),
                onPressed: () => setState(() {
                  _treeExpanded = false;
                  _sectionsExpanded = false;
                  _treeEpoch++;
                }),
              ),
              IconButton(
                tooltip: 'Expand all',
                icon: const Icon(Icons.expand),
                onPressed: () => setState(() {
                  _treeExpanded = true;
                  _sectionsExpanded = true;
                  _treeEpoch++;
                }),
              ),
            ],
            IconButton(
              tooltip: _treeView ? 'List view' : 'Tree view',
              isSelected: _treeView,
              icon: const Icon(Icons.park_outlined),
              selectedIcon: const Icon(Icons.park),
              onPressed: () => setState(() => _treeView = !_treeView),
            ),
          ],
        ),
        width: 760,
      ),
      body: _webCap(
        lessons == null
            ? const Center(child: CircularProgressIndicator())
            : _treeView
            ? LessonTreeView(
                key: ValueKey('$_treeEpoch|${_search.text}|$_sideFilter'),
                lessons: listLessons!,
                expanded: _treeExpanded || searchingActive,
                sectionsExpanded: _sectionsExpanded || searchingActive,
                onOpenLesson: _open,
                onOpenTrunk: _openTrunk,
              )
            : RefreshIndicator(
                onRefresh: _load,
                child: ListView(
                  children: [
                    if (_pending.isNotEmpty) ...[
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                        child: Text(
                          'Pending review (admin)',
                          style: theme.textTheme.titleSmall?.copyWith(
                            color: theme.colorScheme.error,
                          ),
                        ),
                      ),
                      for (final l in _bySide(_filter(_pending)))
                        ListTile(
                          leading: const Icon(Icons.pending_actions),
                          title: Text(l.title),
                          subtitle: Text('by ${l.author ?? 'anonymous'}'),
                          onTap: () => _open(l),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                tooltip: 'Approve',
                                icon: const Icon(
                                  Icons.check_circle,
                                  color: Color(0xFF2E7D32),
                                ),
                                onPressed: () => _moderate(l, true),
                              ),
                              IconButton(
                                tooltip: 'Reject',
                                icon: const Icon(
                                  Icons.cancel,
                                  color: Color(0xFFC62828),
                                ),
                                onPressed: () => _moderate(l, false),
                              ),
                            ],
                          ),
                        ),
                      const Divider(),
                    ],
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
                      for (final l in listLessons!.where(
                        (l) => l.category == cat,
                      ))
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
        width: 760,
      ),
    );
  }
}

/// The library as two tries — the ecosystem view. Shared move runs are one
/// row; forks indent below it. Tapping a shared segment replays exactly the
/// common moves; tapping a lesson leaf opens the full lesson.

/// Keep list content readable inside the full-window web canvas.
Widget _webCap(Widget child, {double width = 760}) => Align(
  alignment: Alignment.topCenter,
  child: ConstrainedBox(
    constraints: BoxConstraints(maxWidth: width),
    child: child,
  ),
);
