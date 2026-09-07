import 'lessons.dart';
import 'pgn.dart';

/// The learning library as the tree it really is (Pablo's framing): every
/// lesson is a path of moves, lessons of the same perspective share their
/// opening moves, and the ecosystem is two tries — one rooted in the White
/// perspective, one in the Black. Runs of moves with no divergence collapse
/// into a single segment node ("the seven steps in common"), so what the
/// user sees is: shared trunk, then a fork, then each gambit's own line.
///
/// The tree is derived on the fly from lesson PGNs — nothing new is stored,
/// so community lessons slot in automatically. Lines are merged by SAN
/// sequence (transpositions arriving at the same position through different
/// move orders stay separate branches — a known, acceptable limitation).
class LessonTreeNode {
  LessonTreeNode({
    required this.startPly,
    required this.sans,
    required this.children,
    required this.lessonsEndingHere,
    required this.lessonCount,
  });

  /// 0-based ply where this segment starts (0 = White's first move).
  final int startPly;

  /// The collapsed run of SAN moves this node represents.
  final List<String> sans;

  final List<LessonTreeNode> children;

  /// Lessons whose full line ends exactly at the end of this segment.
  final List<Lesson> lessonsEndingHere;

  /// Lessons whose line passes through (or ends in) this segment.
  final int lessonCount;

  bool get isLeaf => children.isEmpty;

  /// "1.e4 e5 2.Nf3"-style label for the segment.
  String get label {
    final b = StringBuffer();
    for (var i = 0; i < sans.length; i++) {
      final ply = startPly + i;
      if (ply.isEven) {
        b.write('${ply ~/ 2 + 1}.');
      } else if (i == 0) {
        b.write('${ply ~/ 2 + 1}…');
      }
      b.write(sans[i]);
      if (i != sans.length - 1) b.write(' ');
    }
    return b.toString();
  }
}

/// One perspective's tree plus the lookups the board UI needs.
class LessonTree {
  LessonTree({required this.side, required this.roots, required this.byId});

  /// 'w' | 'b'.
  final String side;

  /// Top-level segments (usually one per first move: 1.e4, 1.d4…).
  final List<LessonTreeNode> roots;

  final Map<String, List<String>> byId; // lesson id -> its SAN line

  /// Sibling lessons that share [lessonId]'s line up to and including
  /// [ply] moves, then continue differently — the "other paths from here"
  /// the analysis board offers at a fork. Only meaningful when [ply] is
  /// the last shared move; cheap enough to call per position.
  List<Lesson> branchesAt(String lessonId, int ply, List<Lesson> all) {
    final line = byId[lessonId];
    if (line == null || ply < 0) return const [];
    final prefix = line.take(ply).toList();
    final out = <Lesson>[];
    for (final other in all) {
      if (other.id == lessonId || other.side != side) continue;
      final oline = byId[other.id];
      if (oline == null || oline.length <= ply) continue;
      if (!_startsWith(oline, prefix)) continue;
      // a real fork: the next move differs (same next move = same path
      // still — offering it would be noise)
      if (line.length > ply && oline[ply] == line[ply]) continue;
      out.add(other);
    }
    return out;
  }

  static bool _startsWith(List<String> line, List<String> prefix) {
    if (line.length < prefix.length) return false;
    for (var i = 0; i < prefix.length; i++) {
      if (line[i] != prefix[i]) return false;
    }
    return true;
  }
}

class _Trie {
  final Map<String, _Trie> children = {};
  final List<Lesson> endingHere = [];
  int passing = 0;
}

/// Build both perspective trees from the full lesson list. Lessons whose
/// PGN fails to parse (community input) are skipped, never fatal.
Map<String, LessonTree> buildLessonForest(List<Lesson> lessons) {
  final out = <String, LessonTree>{};
  for (final side in ['w', 'b']) {
    final root = _Trie();
    final byId = <String, List<String>>{};
    for (final lesson in lessons.where((l) => l.side == side)) {
      List<String> sans;
      try {
        final game = parsePgn(lesson.pgn);
        if (game.startFen != null) continue; // custom-start: not in the tree
        replayPgn(game); // proves every SAN is a legal move, not junk
        sans = game.sanMoves;
      } catch (_) {
        continue; // community input can be anything — never fatal
      }
      if (sans.isEmpty) continue;
      byId[lesson.id] = sans;
      var node = root;
      node.passing++;
      for (final san in sans) {
        node = node.children.putIfAbsent(san, _Trie.new);
        node.passing++;
      }
      node.endingHere.add(lesson);
    }
    out[side] = LessonTree(side: side, roots: _collapse(root, 0), byId: byId);
  }
  return out;
}

/// Turn the raw one-move-per-node trie into collapsed segment nodes: a
/// chain with a single continuation and no lesson ending mid-chain becomes
/// one node holding the whole run of moves.
List<LessonTreeNode> _collapse(_Trie node, int ply) {
  final out = <LessonTreeNode>[];
  for (final entry in node.children.entries) {
    final sans = <String>[entry.key];
    var cur = entry.value;
    final start = ply;
    while (cur.children.length == 1 && cur.endingHere.isEmpty) {
      final next = cur.children.entries.first;
      sans.add(next.key);
      cur = next.value;
    }
    out.add(
      LessonTreeNode(
        startPly: start,
        sans: sans,
        children: _collapse(cur, start + sans.length),
        lessonsEndingHere: List.of(cur.endingHere),
        lessonCount: cur.passing,
      ),
    );
  }
  // busiest branches first — the mainstream trunk tops the list
  out.sort((a, b) => b.lessonCount.compareTo(a.lessonCount));
  return out;
}
