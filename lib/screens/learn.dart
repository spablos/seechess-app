import 'dart:async';

import 'package:flutter/material.dart';

import '../widgets/capped_app_bar.dart';

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

  /// Tree expansion: everything starts collapsed; the appbar buttons flip
  /// every node at once (epoch forces the subtree to rebuild its state).
  bool _treeExpanded = false;
  int _treeEpoch = 0;

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
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => AnalysisScreen(
          movesUci: replay.uci,
          editable: true,
          initialPly: 0,
          initialFlipped: side == 'b',
          title: 'Shared line — ${host?.title ?? 'openings'}',
          comments: comments,
          lessonId: host?.id,
          treeLessons: all,
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
      appBar: cappedAppBar(
        AppBar(
          title: const Text('Learn'),
          actions: [
            if (_treeView) ...[
              IconButton(
                tooltip: 'Collapse all',
                icon: const Icon(Icons.unfold_less),
                onPressed: () => setState(() {
                  _treeExpanded = false;
                  _treeEpoch++;
                }),
              ),
              IconButton(
                tooltip: 'Expand all',
                icon: const Icon(Icons.unfold_more),
                onPressed: () => setState(() {
                  _treeExpanded = true;
                  _treeEpoch++;
                }),
              ),
            ],
            IconButton(
              tooltip: _treeView ? 'List view' : 'Tree view',
              isSelected: _treeView,
              icon: const Icon(Icons.account_tree_outlined),
              selectedIcon: const Icon(Icons.account_tree),
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
            ? _TreeView(
                key: ValueKey(_treeEpoch),
                lessons: lessons,
                expanded: _treeExpanded,
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
                      for (final l in _pending)
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
        width: 760,
      ),
    );
  }
}

/// The library as two tries — the ecosystem view. Shared move runs are one
/// row; forks indent below it. Tapping a shared segment replays exactly the
/// common moves; tapping a lesson leaf opens the full lesson.
class _TreeView extends StatelessWidget {
  const _TreeView({
    super.key,
    required this.lessons,
    required this.expanded,
    required this.onOpenLesson,
    required this.onOpenTrunk,
  });

  final List<Lesson> lessons;
  final bool expanded;
  final void Function(Lesson, {int initialPly}) onOpenLesson;
  final void Function(List<String> pathSans, String side) onOpenTrunk;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final forest = buildLessonForest(lessons);
    return ListView(
      children: [
        for (final side in const ['w', 'b'])
          ExpansionTile(
            initiallyExpanded: expanded,
            shape: const Border(),
            title: Text(
              side == 'w' ? 'Playing as White' : 'Playing as Black',
              style: theme.textTheme.titleSmall?.copyWith(
                color: theme.colorScheme.primary,
              ),
            ),
            children: [
              for (final node in forest[side]!.roots)
                _TreeNodeTile(
                  node: node,
                  side: side,
                  depth: 0,
                  path: const [],
                  expanded: expanded,
                  onOpenLesson: onOpenLesson,
                  onOpenTrunk: onOpenTrunk,
                ),
            ],
          ),
        const SizedBox(height: 24),
      ],
    );
  }
}

class _TreeNodeTile extends StatefulWidget {
  const _TreeNodeTile({
    required this.node,
    required this.side,
    required this.depth,
    required this.path,
    required this.expanded,
    required this.onOpenLesson,
    required this.onOpenTrunk,
  });

  final LessonTreeNode node;
  final String side;
  final int depth;

  /// Whole-tree default from the appbar buttons.
  final bool expanded;

  /// SAN moves leading up to (excluding) this node.
  final List<String> path;
  final void Function(Lesson, {int initialPly}) onOpenLesson;
  final void Function(List<String> pathSans, String side) onOpenTrunk;

  @override
  State<_TreeNodeTile> createState() => _TreeNodeTileState();
}

class _TreeNodeTileState extends State<_TreeNodeTile> {
  late bool _expanded = widget.expanded;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final node = widget.node;
    final fullPath = [...widget.path, ...node.sans];
    final shared = node.lessonCount > 1;
    final indent = 16.0 + widget.depth * 18.0;
    final name = openingNameFor(fullPath, afterPly: node.startPly);
    final left = node.deepestPly - node.endPly;
    // terse, affordance-first: 🎓 lessons · ⛓ common steps · ⋯ steps left
    Widget count(IconData icon, int n, String tip) => Tooltip(
      message: tip,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: theme.colorScheme.outline),
          const SizedBox(width: 2),
          Text('$n', style: theme.textTheme.labelSmall),
        ],
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListTile(
          contentPadding: EdgeInsets.only(left: indent, right: 8),
          dense: true,
          leading: Icon(
            shared ? Icons.alt_route : Icons.trending_flat,
            size: 18,
            color: shared
                ? theme.colorScheme.primary
                : theme.colorScheme.outline,
          ),
          title: name != null
              ? Text(name)
              : Text(
                  node.label,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 13.5,
                  ),
                ),
          subtitle: Row(
            children: [
              if (shared) ...[
                count(Icons.school, node.lessonCount, 'lessons'),
                const SizedBox(width: 10),
              ],
              count(Icons.link, node.endPly, 'common steps'),
              if (left > 0) ...[
                const SizedBox(width: 10),
                count(Icons.more_horiz, left, 'steps below'),
              ],
              if (name != null) ...[
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    node.label,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(
                      fontFamily: 'monospace',
                      color: theme.colorScheme.outline,
                    ),
                  ),
                ),
              ],
            ],
          ),
          trailing: node.isLeaf && node.lessonsEndingHere.length <= 1
              ? null
              : IconButton(
                  icon: Icon(_expanded ? Icons.expand_less : Icons.expand_more),
                  onPressed: () => setState(() => _expanded = !_expanded),
                ),
          onTap: () => widget.onOpenTrunk(fullPath, widget.side),
        ),
        if (_expanded) ...[
          for (final lesson in node.lessonsEndingHere)
            ListTile(
              contentPadding: EdgeInsets.only(left: indent + 18, right: 8),
              dense: true,
              leading: Icon(
                Icons.school,
                size: 18,
                color: theme.colorScheme.secondary,
              ),
              title: Text(lesson.title),
              subtitle: lesson.author != null
                  ? Text('by ${lesson.author}')
                  : null,
              onTap: () => widget.onOpenLesson(lesson),
            ),
          for (final child in node.children)
            _TreeNodeTile(
              node: child,
              side: widget.side,
              depth: widget.depth + 1,
              path: fullPath,
              expanded: widget.expanded,
              onOpenLesson: widget.onOpenLesson,
              onOpenTrunk: widget.onOpenTrunk,
            ),
        ],
      ],
    );
  }
}

/// Keep list content readable inside the full-window web canvas.
Widget _webCap(Widget child, {double width = 760}) => Align(
  alignment: Alignment.topCenter,
  child: ConstrainedBox(
    constraints: BoxConstraints(maxWidth: width),
    child: child,
  ),
);
