import 'dart:async';

import 'package:chess/chess.dart' as ch;
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../widgets/capped_app_bar.dart';

import '../widgets/board.dart';
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
  // the tree IS the library (Pablo): Learn opens in tree view
  bool _treeView = true;

  /// Preview board under the tree: the position at the tapped node's end
  /// (or a leaf's starting point). Empty = initial position.
  List<String> _previewSans = const [];
  String _previewSide = 'w';
  String? _selectedLeafId;

  /// Caption under the preview board: the node's name (or the lesson's
  /// title for a selected leaf); doubles as bottom padding.
  String _previewTitle = 'Start position';

  /// Drill-down mode: the tree shows only the current subtree, one level
  /// at a time, like a file explorer. The crumbs stack holds the paths we
  /// drilled through so "back" retraces them exactly.
  bool _drillMode = false;
  String? _drillSide;
  List<String> _drillPath = const [];
  final List<List<String>> _drillCrumbs = [];

  void _drillInto(String side, List<String> path) {
    setState(() {
      if (_drillSide != null) _drillCrumbs.add(_drillPath);
      _drillSide = side;
      _drillPath = path;
      _selectedLeafId = null;
      _previewTitle = path.isEmpty
          ? (side == 'w' ? 'White' : 'Black')
          : (openingNameFor(path) ?? _movesLabel(path));
    });
    _saveUiState();
    _preview(path, side);
  }

  void _drillUp() {
    setState(() {
      if (_drillCrumbs.isNotEmpty) {
        _drillPath = _drillCrumbs.removeLast();
        _previewTitle = _drillPath.isEmpty
            ? (_drillSide == 'w' ? 'White' : 'Black')
            : (openingNameFor(_drillPath) ?? _movesLabel(_drillPath));
      } else {
        _drillSide = null;
        _drillPath = const [];
        _previewTitle = 'Start position';
      }
      _selectedLeafId = null;
    });
    _saveUiState();
    if (_drillSide != null) _preview(_drillPath, _drillSide!);
  }

  /// Tree expansion, persisted across launches: node keys are the SAN
  /// path joined by spaces, sections are 'w'/'b'. The appbar buttons
  /// rewrite the whole set at once (epoch forces tiles to rebuild).
  Set<String> _openNodes = {};
  Set<String> _openSections = {'w', 'b'};
  int _treeEpoch = 0;
  SharedPreferences? _prefs;

  /// Restore the Learn UI the way it was left: tree expansion, the
  /// full-tree vs drill-down choice, and the drill location.
  Future<void> _loadUiState() async {
    final p = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _prefs = p;
      _openNodes = {...?p.getStringList('learn_open_nodes')};
      _openSections = {
        ...(p.getStringList('learn_open_sections') ?? const ['w', 'b']),
      };
      _drillMode = p.getBool('learn_drill_mode') ?? false;
      final side = p.getString('learn_drill_side');
      _drillSide = (side == null || side.isEmpty) ? null : side;
      _drillPath = p.getStringList('learn_drill_path') ?? const [];
      _drillCrumbs
        ..clear()
        ..addAll([
          for (final c in p.getStringList('learn_drill_crumbs') ?? const [])
            c.isEmpty ? <String>[] : c.split(' '),
        ]);
      _treeEpoch++;
    });
    final ds = _drillSide;
    if (_drillMode && ds != null) {
      setState(() {
        _previewTitle = _drillPath.isEmpty
            ? (ds == 'w' ? 'White' : 'Black')
            : (openingNameFor(_drillPath) ?? _movesLabel(_drillPath));
      });
      _preview(_drillPath, ds);
    }
  }

  void _saveUiState() {
    final p = _prefs;
    if (p == null) return;
    p.setStringList('learn_open_nodes', _openNodes.toList());
    p.setStringList('learn_open_sections', _openSections.toList());
    p.setBool('learn_drill_mode', _drillMode);
    p.setString('learn_drill_side', _drillSide ?? '');
    p.setStringList('learn_drill_path', _drillPath);
    p.setStringList('learn_drill_crumbs', [
      for (final c in _drillCrumbs) c.join(' '),
    ]);
  }

  /// Every node key in the forest — "expand all" materialized.
  Set<String> _allNodeKeys() {
    final out = <String>{};
    final forest = buildLessonForest(_lessons ?? const []);
    void walk(List<LessonTreeNode> nodes, List<String> path) {
      for (final n in nodes) {
        final p = [...path, ...n.sans];
        out.add(p.join(' '));
        walk(n.children, p);
      }
    }

    for (final side in const ['w', 'b']) {
      walk(forest[side]!.roots, const []);
    }
    return out;
  }

  /// Live search over everything a lesson is made of: title, author,
  /// category, remarks and moves (a query like "e4" matches the PGN).
  final _search = TextEditingController();
  bool _searching = false;

  /// Category filter: null = everything, 'o' = openings only,
  /// 't' = traps & gambits only. Classified by lesson.category.
  String? _catFilter;

  bool _isTrap(Lesson l) {
    final c = l.category.toLowerCase();
    return c.contains('trap') || c.contains('gambit');
  }

  List<Lesson> _byCat(List<Lesson> all) => switch (_catFilter) {
    'o' => [
      for (final l in all)
        if (!_isTrap(l)) l,
    ],
    't' => [
      for (final l in all)
        if (_isTrap(l)) l,
    ],
    _ => all,
  };

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
    _loadUiState();
  }

  Future<void> _load() async {
    unawaited(
      fetchOpeningNames().then((names) {
        if (mounted) setState(() => setCustomOpeningNames(names));
      }),
    );
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

  /// Admin: rename a tree node inline; the override is stored server-side
  /// and every client shows it on its next Learn load.
  Future<void> _renameNode(List<String> pathSans, String name) async {
    final token = adminToken();
    if (token == null) return;
    final ok = await setOpeningName(token, pathSans.join(' '), name);
    final names = await fetchOpeningNames();
    if (!mounted) return;
    setState(() => setCustomOpeningNames(names));
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Rename failed — check the token')),
      );
    }
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
          title: name ?? host?.title ?? 'Openings',
          comments: comments,
          lessonId: host?.id,
          treeLessons: all,
          // only forks inside the subtree entered through — lessons from
          // other opening families are reachable via the tree, not here
          branchesFromPly: pathSans.length,
          offerHostLesson: true,
        ),
      ),
    );
  }

  void _preview(List<String> sans, String side) {
    setState(() {
      _previewSans = sans;
      _previewSide = side;
      // tapping a trunk clears any leaf selection
    });
  }

  /// Tapping the preview board opens what it shows: the selected lesson,
  /// or the shared line of the previewed node.
  void _openPreviewed() {
    final leafId = _selectedLeafId;
    if (leafId != null) {
      final all = [...?_lessons, ..._pending];
      for (final l in all) {
        if (l.id == leafId) {
          _open(l);
          return;
        }
      }
    }
    if (_previewSans.isNotEmpty) {
      _openTrunk(_previewSans, _previewSide);
    }
  }

  /// A leaf previews its parent's position PLUS its own first move:
  /// siblings share the starting point, so the board must show the one
  /// move that tells them apart (Pablo).
  List<String> _leafPreviewSans(Lesson lesson, List<String> sans) {
    try {
      final game = parsePgn(lesson.pgn);
      if (game.startFen != null) return sans;
      final line = game.sanMoves;
      if (line.length > sans.length) return line.sublist(0, sans.length + 1);
    } catch (_) {}
    return sans;
  }

  String _movesLabel(List<String> sans) {
    if (sans.isEmpty) return 'Start position';
    final b = StringBuffer('After ');
    for (var i = 0; i < sans.length; i++) {
      if (i.isEven) b.write('${i ~/ 2 + 1}.');
      b.write(sans[i]);
      if (i != sans.length - 1) b.write(' ');
    }
    return b.toString();
  }

  Map<String, String> _previewPieces() {
    final g = ch.Chess();
    for (final san in _previewSans) {
      try {
        if (g.move(san) != true) break;
      } catch (_) {
        break;
      }
    }
    final out = <String, String>{};
    for (final sq in ch.Chess.SQUARES.keys) {
      final piece = g.get(sq);
      if (piece != null) {
        out[sq] =
            '${piece.color == ch.Color.WHITE ? 'w' : 'b'}'
            '${piece.type.toUpperCase()}';
      }
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final lessons = _lessons == null ? null : _filter(_lessons!);
    final listLessons = lessons == null ? null : _byCat(_bySide(lessons));
    final searchingActive = _search.text.trim().isNotEmpty;
    // stable order: curated categories first, community last
    final categories = <String>[];
    for (final l in listLessons ?? <Lesson>[]) {
      if (!categories.contains(l.category)) categories.add(l.category);
    }
    return Scaffold(
      appBar: cappedAppBar(
        AppBar(
          title: const Text('Learn'),
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
            IconButton(
              tooltip: switch (_catFilter) {
                'o' => 'Showing openings — tap for traps & gambits',
                't' => 'Showing traps & gambits — tap for everything',
                _ => 'Showing everything — tap for openings only',
              },
              icon: switch (_catFilter) {
                'o' => const Icon(Icons.menu_book),
                't' => const Icon(Icons.flash_on),
                _ => const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.menu_book, size: 15),
                    Icon(Icons.flash_on, size: 15),
                  ],
                ),
              },
              onPressed: () => setState(() {
                _catFilter = switch (_catFilter) {
                  null => 'o',
                  'o' => 't',
                  _ => null,
                };
              }),
            ),
            if (_treeView)
              IconButton(
                tooltip: _drillMode
                    ? 'Back to the full tree'
                    : 'Drill-down mode — browse one branch at a time',
                isSelected: _drillMode,
                icon: const Icon(Icons.folder_outlined),
                selectedIcon: const Icon(Icons.folder),
                onPressed: () {
                  setState(() {
                    _drillMode = !_drillMode;
                    _drillSide = null;
                    _drillPath = const [];
                    _drillCrumbs.clear();
                  });
                  _saveUiState();
                },
              ),
            if (_treeView && !_drillMode) ...[
              IconButton(
                tooltip: 'Collapse all',
                icon: const Icon(Icons.compress),
                onPressed: () {
                  setState(() {
                    _openNodes = {};
                    _openSections = {};
                    _treeEpoch++;
                  });
                  _saveUiState();
                },
              ),
              IconButton(
                tooltip: 'Expand all',
                icon: const Icon(Icons.expand),
                onPressed: () {
                  setState(() {
                    _openNodes = _allNodeKeys();
                    _openSections = {'w', 'b'};
                    _treeEpoch++;
                  });
                  _saveUiState();
                },
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
        Column(
          children: [
            if (_searching)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
                child: TextField(
                  controller: _search,
                  autofocus: true,
                  textInputAction: TextInputAction.search,
                  decoration: InputDecoration(
                    hintText: 'Search lessons, text, moves (e.g. e4)…',
                    prefixIcon: const Icon(Icons.search),
                    suffixIcon: _search.text.isEmpty
                        ? null
                        : IconButton(
                            tooltip: 'Clear',
                            icon: const Icon(Icons.clear),
                            onPressed: () => setState(_search.clear),
                          ),
                    filled: true,
                    isDense: true,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(28),
                      borderSide: BorderSide.none,
                    ),
                  ),
                  onChanged: (_) => setState(() {}),
                ),
              ),
            Expanded(
              child: lessons == null
                  ? const Center(child: CircularProgressIndicator())
                  : _treeView
                  ? Column(
                      children: [
                        Expanded(
                          flex: 3,
                          child: LessonTreeView(
                            key: ValueKey(
                              '$_treeEpoch|${_search.text}|$_sideFilter|$_catFilter'
                              '|$_drillMode|$_drillSide|${_drillPath.join(" ")}',
                            ),
                            lessons: listLessons!,
                            expanded: searchingActive,
                            sectionsExpanded: searchingActive,
                            openNodes: _openNodes,
                            onToggleNode: (key, open) {
                              open
                                  ? _openNodes.add(key)
                                  : _openNodes.remove(key);
                              _saveUiState();
                            },
                            openSections: _openSections,
                            onToggleSection: (side, open) {
                              open
                                  ? _openSections.add(side)
                                  : _openSections.remove(side);
                              _saveUiState();
                            },
                            onOpenLesson: _open,
                            onOpenTrunk: _openTrunk,
                            onRenameNode: adminToken() != null
                                ? _renameNode
                                : null,
                            onPreview: (sans, side) {
                              setState(() {
                                _selectedLeafId = null;
                                _previewTitle =
                                    openingNameFor(sans) ?? _movesLabel(sans);
                              });
                              _preview(sans, side);
                            },
                            selectedLessonId: _selectedLeafId,
                            onSelectLeaf: (lesson, sans, side) {
                              setState(() {
                                _selectedLeafId = lesson.id;
                                _previewTitle = lesson.title;
                              });
                              _preview(_leafPreviewSans(lesson, sans), side);
                            },
                            drillMode: _drillMode,
                            drillSide: _drillSide,
                            drillPath: _drillPath,
                            onDrill: _drillInto,
                            onDrillUp: _drillUp,
                          ),
                        ),
                        // lower third: the position at the tapped node (or a
                        // leaf's starting point) — the tree becomes browsable
                        Expanded(
                          flex: 2,
                          child: Column(
                            children: [
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 7,
                                ),
                                child: Container(
                                  height: 4,
                                  width: 56,
                                  decoration: BoxDecoration(
                                    color: theme.colorScheme.outlineVariant,
                                    borderRadius: BorderRadius.circular(2),
                                  ),
                                ),
                              ),
                              Expanded(
                                child: Center(
                                  child: AspectRatio(
                                    aspectRatio: 1,
                                    child: GestureDetector(
                                      // the board is a door: tapping it opens
                                      // the previewed lesson or shared line
                                      onTap: _openPreviewed,
                                      child: ChessBoard(
                                        pieces: _previewPieces(),
                                        flipped: _previewSide == 'b',
                                        interactive: false,
                                        onMove: (_, _) {},
                                        legalTargetsFor: (_) => const {},
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                              // the caption IS the bottom padding
                              Padding(
                                padding: const EdgeInsets.fromLTRB(
                                  16,
                                  8,
                                  16,
                                  12,
                                ),
                                child: Text(
                                  _previewTitle,
                                  textAlign: TextAlign.center,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.labelLarge?.copyWith(
                                    color: theme.colorScheme.onSurfaceVariant,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
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
                            for (final l in _byCat(_bySide(_filter(_pending))))
                              ListTile(
                                leading: const Icon(Icons.pending_actions),
                                title: LessonTitle(l.title),
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
                                title: LessonTitle(l.title),
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
            ),
          ],
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
