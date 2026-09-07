import 'package:flutter_test/flutter_test.dart';
import 'package:seechess/services/lesson_tree.dart';
import 'package:seechess/services/lessons.dart';

Lesson _l(String id, String side, String pgn) =>
    Lesson(id: id, title: id, category: 'Test', side: side, pgn: pgn);

void main() {
  group('lesson forest', () {
    // three black-perspective lines sharing 4 plies, forking at ply 5
    final lessons = [
      _l('a', 'b', '1. e4 e5 2. Nf3 Nc6 3. Bc4 Bc5'),
      _l('b', 'b', '1. e4 e5 2. Nf3 Nc6 3. Bc4 Nf6'),
      _l('c', 'b', '1. e4 e5 2. Nf3 Nc6 3. Bb5 a6'),
      _l('w1', 'w', '1. d4 d5 2. c4'),
    ];
    final forest = buildLessonForest(lessons);

    test('perspectives split into two trees', () {
      expect(forest['b']!.roots, hasLength(1));
      expect(forest['w']!.roots, hasLength(1));
      expect(forest['w']!.roots.first.label, '1.d4 d5 2.c4');
    });

    test('shared trunk collapses into one segment, forks where lines part',
        () {
      final trunk = forest['b']!.roots.first;
      // all three share 1.e4 e5 2.Nf3 Nc6
      expect(trunk.sans, ['e4', 'e5', 'Nf3', 'Nc6']);
      expect(trunk.lessonCount, 3);
      expect(trunk.label, '1.e4 e5 2.Nf3 Nc6');
      // then Bc4 (two lessons) vs Bb5 (one)
      expect(trunk.children, hasLength(2));
      final bc4 = trunk.children.first; // busiest first
      expect(bc4.sans.first, 'Bc4');
      expect(bc4.lessonCount, 2);
      // Bc4's fork: Bc5 and Nf6 leaves
      expect(bc4.children, hasLength(2));
      expect(bc4.children.every((n) => n.isLeaf), isTrue);
    });

    test('mid-chain label numbering from a black move', () {
      final bc5 = forest['b']!
          .roots
          .first
          .children
          .first
          .children
          .map((n) => n.label)
          .toList();
      expect(bc5, containsAll(['3…Bc5', '3…Nf6']));
    });

    test('branchesAt offers only true forks', () {
      final tree = forest['b']!;
      // after 5 plies (…3.Bc4) lesson a and b diverge on Black's reply
      final atFork = tree.branchesAt('a', 5, lessons);
      expect(atFork.map((l) => l.id), ['b']);
      // at ply 4 the next move (Bc4 vs Bb5) forks lesson c away
      final earlier = tree.branchesAt('a', 4, lessons);
      expect(earlier.map((l) => l.id), ['c']);
      // no forks at ply 2 (everyone plays Nf3)
      expect(tree.branchesAt('a', 2, lessons), isEmpty);
      // other-perspective lessons never appear
      expect(tree.branchesAt('a', 0, lessons), isEmpty);
    });

    test('unparseable community pgn is skipped, not fatal', () {
      final f = buildLessonForest([
        _l('bad', 'w', 'not a pgn at all }{'),
        _l('ok', 'w', '1. e4'),
      ]);
      expect(f['w']!.roots, hasLength(1));
    });
  });
}
