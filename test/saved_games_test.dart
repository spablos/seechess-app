import 'package:flutter_test/flutter_test.dart';
import 'package:seechess/services/saved_games.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('model round-trips labels, dates and moves', () {
    final g = SavedGame(
      name: 'Study',
      fen: '4k3/8/8/8/8/8/8/4K3 w - - 0 1',
      createdAt: DateTime(2026, 8, 31, 12),
      modifiedAt: DateTime(2026, 8, 31, 13),
      labels: ['endgame', 'study'],
      startFen: '4k3/8/8/8/8/8/8/4K3 w - - 0 1',
      movesUci: ['e1e2', 'e8e7'],
    );
    final back = SavedGame.fromJson(g.toJson());
    expect(back.id, g.id);
    expect(back.labels, ['endgame', 'study']);
    expect(back.modifiedAt, DateTime(2026, 8, 31, 13));
    expect(back.movesUci, ['e1e2', 'e8e7']);
  });

  test('legacy entries without id/labels still load', () {
    final back = SavedGame.fromJson({
      'name': 'Old',
      'fen': '4k3/8/8/8/8/8/8/4K3 w - - 0 1',
      'createdAt': '2026-07-01T10:00:00.000',
    });
    expect(back.labels, isEmpty);
    expect(back.modifiedAt, back.createdAt);
    expect(back.id, isNotEmpty);
  });

  test('update upserts by id and survives a rename', () async {
    final store = SavedGamesStore();
    final g = SavedGame(
      name: 'Before',
      fen: '4k3/8/8/8/8/8/8/4K3 w - - 0 1',
      createdAt: DateTime.now(),
    );
    await store.add(g);
    await store.update(g.copyWith(name: 'After', modifiedAt: DateTime.now()));
    final all = await store.list();
    expect(all.length, 1);
    expect(all.single.name, 'After');
    expect(all.single.id, g.id);
  });
}
