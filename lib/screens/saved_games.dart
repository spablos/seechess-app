import 'dart:io';

import 'package:flutter/material.dart';

import '../services/saved_games.dart';
import 'analysis.dart';
import 'game_import.dart';

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
  String _sortField = 'modified'; // 'name' | 'created' | 'modified'
  bool _sortAsc = false;

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
    out.sort((a, b) {
      final c = switch (_sortField) {
        'name' => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
        'created' => a.createdAt.compareTo(b.createdAt),
        _ => a.modifiedAt.compareTo(b.modifiedAt),
      };
      return _sortAsc ? c : -c;
    });
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
            tooltip: 'Import a game (PGN, chess.com, lichess)',
            icon: const Icon(Icons.download_outlined),
            onPressed: () => showImportSheet(context),
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
                    height: 40,
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 7,
                      ),
                      children: [
                        for (final label in _allLabels)
                          Padding(
                            padding: const EdgeInsets.only(right: 6),
                            // same visual language as the labels on the
                            // rows below — a filter is just one of those,
                            // lit up
                            child: _LabelChip(
                              label,
                              selected: _labelFilter == label,
                              onTap: () => setState(
                                () => _labelFilter = _labelFilter == label
                                    ? null
                                    : label,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                if (games!.isNotEmpty) _tableHeader(theme),
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

  /// Column headers: tap to sort by that column, tap again to reverse.
  Widget _tableHeader(ThemeData theme) {
    Widget cell(String label, String field, {double? width}) {
      final active = _sortField == field;
      final child = InkWell(
        onTap: () => setState(() {
          if (_sortField == field) {
            _sortAsc = !_sortAsc;
          } else {
            _sortField = field;
            _sortAsc = field == 'name'; // names A→Z, dates newest first
          }
        }),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: theme.textTheme.labelMedium?.copyWith(
                  fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                  color: active
                      ? theme.colorScheme.primary
                      : theme.colorScheme.onSurfaceVariant,
                ),
              ),
              if (active)
                Icon(
                  _sortAsc ? Icons.arrow_drop_up : Icons.arrow_drop_down,
                  size: 18,
                  color: theme.colorScheme.primary,
                ),
            ],
          ),
        ),
      );
      return width == null
          ? Expanded(child: child)
          : SizedBox(width: width, child: child);
    }

    return Container(
      padding: const EdgeInsets.only(left: 64, right: 12),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
      ),
      child: Row(
        children: [cell('Name', 'name'), cell('Edited', 'modified', width: 74)],
      ),
    );
  }

  static String _shortDate(DateTime d) {
    final now = DateTime.now();
    if (d.year == now.year && d.month == now.month && d.day == now.day) {
      return '${d.hour.toString().padLeft(2, '0')}:'
          '${d.minute.toString().padLeft(2, '0')}';
    }
    final md =
        '${d.day.toString().padLeft(2, '0')}/'
        '${d.month.toString().padLeft(2, '0')}';
    return d.year == now.year ? md : '$md/${d.year % 100}';
  }

  Widget _entry(ThemeData theme, SavedGame game) {
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
      child: InkWell(
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
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: theme.colorScheme.outlineVariant.withValues(alpha: .4),
              ),
            ),
          ),
          child: Row(
            children: [
              game.photoPath != null && File(game.photoPath!).existsSync()
                  ? ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: Image.file(
                        File(game.photoPath!),
                        width: 44,
                        height: 44,
                        fit: BoxFit.cover,
                      ),
                    )
                  : SizedBox(
                      width: 44,
                      height: 44,
                      child: Icon(
                        game.movesUci.isEmpty ? Icons.grid_on : Icons.timeline,
                        size: 28,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      game.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium,
                    ),
                    if (game.labels.isNotEmpty)
                      Wrap(
                        spacing: 4,
                        children: [
                          for (final label in game.labels)
                            _LabelChip(label, selected: _labelFilter == label),
                        ],
                      ),
                  ],
                ),
              ),
              SizedBox(
                width: 74,
                child: Text(
                  _shortDate(game.modifiedAt),
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The one label look, everywhere: on rows as a tag, on the filter bar as
/// a tappable filter. Selected = the filter currently applied.
class _LabelChip extends StatelessWidget {
  const _LabelChip(this.label, {this.selected = false, this.onTap});
  final String label;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final chip = Container(
      padding: EdgeInsets.symmetric(
        horizontal: onTap == null ? 6 : 10,
        vertical: onTap == null ? 1 : 4,
      ),
      decoration: BoxDecoration(
        color: selected
            ? theme.colorScheme.primaryContainer
            : theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
        border: selected ? Border.all(color: theme.colorScheme.primary) : null,
      ),
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(
          height: 1.0,
          color: selected ? theme.colorScheme.onPrimaryContainer : null,
        ),
      ),
    );
    if (onTap == null) return chip;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      child: chip,
    );
  }
}
