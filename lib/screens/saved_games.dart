import 'dart:io';

import 'package:flutter/material.dart';

import '../services/saved_games.dart';
import 'analysis.dart';

class SavedGamesScreen extends StatefulWidget {
  const SavedGamesScreen({super.key});

  @override
  State<SavedGamesScreen> createState() => _SavedGamesScreenState();
}

class _SavedGamesScreenState extends State<SavedGamesScreen> {
  final store = SavedGamesStore();
  List<SavedGame>? games;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final loaded = await store.list();
    if (mounted) setState(() => games = loaded);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Saved games')),
      body: games == null
          ? const Center(child: CircularProgressIndicator())
          : games!.isEmpty
          ? Center(
              child: Text(
                'Nothing saved yet.\nAnalyze a photo and tap '
                'Save on the confirm screen.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium,
              ),
            )
          : ListView.builder(
              itemCount: games!.length,
              itemBuilder: (context, i) {
                final game = games![i];
                final date = game.createdAt;
                final dateText =
                    '${date.year}-${date.month.toString().padLeft(2, '0')}-'
                    '${date.day.toString().padLeft(2, '0')} '
                    '${date.hour.toString().padLeft(2, '0')}:'
                    '${date.minute.toString().padLeft(2, '0')}';
                return Dismissible(
                  key: ValueKey('${game.createdAt}${game.name}'),
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
                    leading:
                        game.photoPath != null &&
                            File(game.photoPath!).existsSync()
                        ? ClipRRect(
                            borderRadius: BorderRadius.circular(6),
                            child: Image.file(
                              File(game.photoPath!),
                              width: 48,
                              height: 48,
                              fit: BoxFit.cover,
                            ),
                          )
                        : const Icon(Icons.grid_on, size: 36),
                    title: Text(game.name),
                    subtitle: Text(
                      '$dateText · ${game.fen.split(' ')[1] == 'w' ? 'White' : 'Black'} to move',
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => AnalysisScreen(fen: game.fen),
                      ),
                    ),
                  ),
                );
              },
            ),
    );
  }
}
