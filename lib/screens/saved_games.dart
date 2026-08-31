import 'dart:io';

import 'package:flutter/material.dart';

import '../services/saved_games.dart';
import 'analysis.dart';

/// The library: every confirmed detection plus explicit analysis-board
/// saves. Search by name/label, filter by label, sort by created or
/// modified date; long-press an entry to rename, label, or delete it.
class SavedGamesScreen extends StatefulWidget {
  const SavedGamesScreen({super.key});

  @override
  State<SavedGamesScreen> createState() => _SavedGamesScreenState();
}

class _SavedGamesScreenState extends State<SavedGamesScreen> {
  final store = SavedGamesStore();
  List<SavedGame>? games;
  final _search = TextEditingController();
  String? _labelFilter;
  bool _byModified = true;

  @override
  void initState() {
    super.initState();
    _search.addListener(() => setState(() {}));
    _load();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final loaded = await store.list();
    if (mounted) setState(() => games = loaded);
  }

  List<SavedGame> get _visible {
    final q = _search.text.trim().toLowerCase();
    var out = games!.where((g) {
      if (_labelFilter != null && !g.labels.contains(_labelFilter)) {
        return false;
      }
      if (q.isEmpty) return true;
      return g.name.toLowerCase().contains(q) ||
          g.labels.any((l) => l.toLowerCase().contains(q));
    }).toList();
    out.sort(
      (a, b) => _byModified
          ? b.modifiedAt.compareTo(a.modifiedAt)
          : b.createdAt.compareTo(a.createdAt),
    );
    return out;
  }

  List<String> get _allLabels {
    final s = <String>{};
    for (final g in games!) {
      s.addAll(g.labels);
    }
    final out = s.toList()..sort();
    return out;
  }

  static String _date(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')} '
      '${d.hour.toString().padLeft(2, '0')}:'
      '${d.minute.toString().padLeft(2, '0')}';

  Future<void> _editEntry(SavedGame game) async {
    final nameController = TextEditingController(text: game.name);
    final labelsController = TextEditingController(
      text: game.labels.join(', '),
    );
    final action = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (context) => Padding(
        padding: EdgeInsets.only(
          left: 20,
          right: 20,
          top: 16,
          bottom: MediaQuery.of(context).viewInsets.bottom + 16,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: nameController,
              decoration: const InputDecoration(labelText: 'Name'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: labelsController,
              decoration: const InputDecoration(
                labelText: 'Labels',
                hintText: 'endgame, study, vs Rotem — comma-separated',
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                TextButton.icon(
                  icon: Icon(
                    Icons.delete_outline,
                    color: Theme.of(context).colorScheme.error,
                  ),
                  label: const Text('Delete'),
                  onPressed: () => Navigator.pop(context, 'delete'),
                ),
                const Spacer(),
                FilledButton(
                  onPressed: () => Navigator.pop(context, 'save'),
                  child: const Text('Save'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
    if (action == 'delete') {
      await store.remove(game);
    } else if (action == 'save') {
      final labels = labelsController.text
          .split(',')
          .map((l) => l.trim())
          .where((l) => l.isNotEmpty)
          .toList();
      await store.update(
        game.copyWith(
          name: nameController.text.trim().isEmpty
              ? game.name
              : nameController.text.trim(),
          labels: labels,
          modifiedAt: DateTime.now(),
        ),
      );
    }
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Library'),
        actions: [
          IconButton(
            tooltip: _byModified ? 'Sorted by modified' : 'Sorted by created',
            icon: Icon(_byModified ? Icons.edit_calendar : Icons.today),
            onPressed: () => setState(() => _byModified = !_byModified),
          ),
        ],
      ),
      body: games == null
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                  child: TextField(
                    controller: _search,
                    decoration: InputDecoration(
                      hintText: 'Search names and labels',
                      prefixIcon: const Icon(Icons.search),
                      suffixIcon: _search.text.isEmpty
                          ? null
                          : IconButton(
                              icon: const Icon(Icons.clear),
                              onPressed: _search.clear,
                            ),
                      isDense: true,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                ),
                if (_allLabels.isNotEmpty)
                  SizedBox(
                    height: 46,
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 6,
                      ),
                      children: [
                        for (final label in _allLabels)
                          Padding(
                            padding: const EdgeInsets.only(right: 6),
                            child: FilterChip(
                              label: Text(label),
                              selected: _labelFilter == label,
                              onSelected: (on) => setState(
                                () => _labelFilter = on ? label : null,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                Expanded(
                  child: games!.isEmpty
                      ? Center(
                          child: Text(
                            'Your library is empty.\nConfirm a detected '
                            'board or save a position — everything you '
                            'confirm lands here automatically.',
                            textAlign: TextAlign.center,
                            style: theme.textTheme.bodyMedium,
                          ),
                        )
                      : _visible.isEmpty
                      ? Center(
                          child: Text(
                            'No matches.',
                            style: theme.textTheme.bodyMedium,
                          ),
                        )
                      : ListView.builder(
                          itemCount: _visible.length,
                          itemBuilder: (context, i) =>
                              _entry(theme, _visible[i]),
                        ),
                ),
              ],
            ),
    );
  }

  Widget _entry(ThemeData theme, SavedGame game) {
    final turn = game.fen.split(' ').length > 1 && game.fen.split(' ')[1] == 'b'
        ? 'Black'
        : 'White';
    final detail = _byModified
        ? 'edited ${_date(game.modifiedAt)}'
        : _date(game.createdAt);
    return Dismissible(
      key: ValueKey(game.id),
      direction: DismissDirection.endToStart,
      background: Container(
        color: theme.colorScheme.error,
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        child: const Icon(Icons.delete, color: Colors.white),
      ),
      onDismissed: (_) async {
        await store.remove(game);
        _load();
      },
      child: ListTile(
        leading: game.photoPath != null && File(game.photoPath!).existsSync()
            ? ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: Image.file(
                  File(game.photoPath!),
                  width: 48,
                  height: 48,
                  fit: BoxFit.cover,
                ),
              )
            : Icon(
                game.movesUci.isEmpty ? Icons.grid_on : Icons.timeline,
                size: 36,
              ),
        title: Text(game.name),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '$detail · $turn to move'
              '${game.movesUci.isEmpty ? '' : ' · ${game.movesUci.length} moves'}',
            ),
            if (game.labels.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Wrap(
                  spacing: 4,
                  children: [
                    for (final label in game.labels)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 1,
                        ),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(label, style: theme.textTheme.labelSmall),
                      ),
                  ],
                ),
              ),
          ],
        ),
        trailing: const Icon(Icons.chevron_right),
        onLongPress: () => _editEntry(game),
        // the board can update or add entries — refresh on return
        onTap: () => Navigator.of(context)
            .push(
              MaterialPageRoute(
                builder: (_) => AnalysisScreen(
                  fen: game.startFen ?? game.fen,
                  movesUci: game.movesUci,
                  editable: true,
                  source: game,
                ),
              ),
            )
            .then((_) => _load()),
      ),
    );
  }
}
