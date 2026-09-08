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

  /// Total plies from the root through the END of this segment.
  int get endPly => startPly + sans.length;

  /// Longest lesson line under (and including) this node, in plies —
  /// "steps left" below a node is deepestPly - endPly.
  int get deepestPly => children.isEmpty
      ? endPly
      : children.map((c) => c.deepestPly).reduce((a, b) => a > b ? a : b);

  /// First two moves plus an ellipsis — the tree is for drilling down,
  /// not reading whole lines (Pablo).
  String get shortLabel {
    final b = StringBuffer();
    final show = sans.length > 2 ? 2 : sans.length;
    for (var i = 0; i < show; i++) {
      final ply = startPly + i;
      if (ply.isEven) {
        b.write('${ply ~/ 2 + 1}.');
      } else if (i == 0) {
        b.write('${ply ~/ 2 + 1}…');
      }
      b.write(sans[i]);
      if (i != show - 1) b.write(' ');
    }
    if (sans.length > 2) b.write(' …');
    return b.toString();
  }

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

/// Compact opening book: SAN prefix -> conventional name. Longest match
/// wins; a node shows the name only when the name is *reached* inside its
/// own segment (an ancestor's name repeating down the tree is noise).
const Map<String, String> _openingNames = {
  'e4': "King's Pawn",
  'e4 e5': 'Open Game',
  'e4 e5 Nf3 Nc6 Bb5': 'Ruy Lopez',
  'e4 e5 Nf3 Nc6 Bb5 a6': 'Ruy Lopez, Morphy Defense',
  'e4 e5 Nf3 Nc6 Bc4': 'Italian Game',
  'e4 e5 Nf3 Nc6 Bc4 Bc5': 'Giuoco Piano',
  'e4 e5 Nf3 Nc6 Bc4 Nf6': 'Two Knights Defense',
  'e4 e5 Nf3 Nc6 Bc4 Nf6 Ng5': 'Fried Liver territory',
  'e4 e5 Nf3 Nc6 d4': 'Scotch Game',
  'e4 e5 Nf3 Nf6': "Petrov's Defense",
  'e4 e5 Nf3 Nf6 Nxe5 Nc6': 'Stafford Gambit',
  'e4 e5 Nf3 d6': 'Philidor Defense',
  'e4 e5 f4': "King's Gambit",
  'e4 e5 Nc3': 'Vienna Game',
  'e4 e5 Bc4': "Bishop's Opening",
  'e4 e5 Qh5': 'Wayward Queen (Scholar\'s mate try)',
  'e4 c5': 'Sicilian Defense',
  'e4 c5 Nf3 d6 d4 cxd4 Nxd4 Nf6 Nc3 a6': 'Sicilian Najdorf',
  'e4 c5 Nf3 d6 d4 cxd4 Nxd4 Nf6 Nc3 g6': 'Sicilian Dragon',
  'e4 e6': 'French Defense',
  'e4 c6': 'Caro-Kann Defense',
  'e4 d6': 'Pirc Defense',
  'e4 d5': 'Scandinavian Defense',
  'e4 Nf6': "Alekhine's Defense",
  'd4': "Queen's Pawn",
  'd4 d5 c4': "Queen's Gambit",
  'd4 d5 c4 e6': "Queen's Gambit Declined",
  'd4 d5 c4 dxc4': "Queen's Gambit Accepted",
  'd4 d5 c4 c6': 'Slav Defense',
  'd4 d5 Bf4': 'London System',
  'd4 d5 Nf3 Nf6 Bf4': 'London System',
  'd4 d5 e4': 'Blackmar-Diemer Gambit',
  'd4 Nf6 c4 g6': "King's Indian / Grünfeld complex",
  'd4 Nf6 c4 e6 Nc3 Bb4': 'Nimzo-Indian Defense',
  'd4 e5': 'Englund Gambit',
  'c4': 'English Opening',
  'Nf3': 'Réti Opening',
  'Nc3': 'Van Geet Opening',
  'f4': "Bird's Opening",
  'b4': 'Polish (Orangutan)',
};

/// Name for the line ending at [endPly] along [fullPath], but only when
/// the naming move falls after [afterPly] (inside the current segment).
String? openingNameFor(List<String> fullPath, {int afterPly = -1}) {
  String? best;
  var bestLen = -1;
  for (final e in _openingNames.entries) {
    final seq = e.key.split(' ');
    if (seq.length <= afterPly || seq.length > fullPath.length) continue;
    if (seq.length <= bestLen) continue;
    var match = true;
    for (var i = 0; i < seq.length; i++) {
      if (fullPath[i] != seq[i]) {
        match = false;
        break;
      }
    }
    if (match) {
      best = e.value;
      bestLen = seq.length;
    }
  }
  return best;
}
