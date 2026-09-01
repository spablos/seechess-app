import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/game_sources.dart';
import '../services/pgn.dart';
import '../services/saved_games.dart';
import 'analysis.dart';

/// Game import (PRD-game-import): PGN by paste/file/share, and online
/// archives from chess.com / lichess by username — no accounts, their
/// public APIs are keyed on the name alone.

/// Open a parsed game on the analysis board, at move 0, save-ready.
void openPgnGame(BuildContext context, PgnReplay replay, {String? sourceUrl}) {
  final g = replay.game;
  final date = g.date?.replaceAll('.', '-');
  final players = g.playersLabel;
  Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => AnalysisScreen(
        fen: g.startFen,
        movesUci: replay.uci,
        editable: true,
        initialPly: 0,
        title: players == null
            ? null
            : '$players${g.result == null ? '' : ' · ${g.result}'}',
        comments: g.comments,
        importDraft: SavedGame(
          name: [players ?? 'Imported game', ?date].join(' '),
          fen: replay.finalFen,
          createdAt: DateTime.now(),
          labels: [
            if (g.site?.toLowerCase().contains('chess.com') ?? false)
              'chess.com'
            else if (g.site?.toLowerCase().contains('lichess') ?? false)
              'lichess'
            else
              'imported',
          ],
          white: g.white,
          black: g.black,
          result: g.result,
          sourceUrl: sourceUrl,
        ),
      ),
    ),
  );
}

/// Parse text and open it, or explain what's wrong. Returns success.
bool importPgnText(BuildContext context, String text, {String? sourceUrl}) {
  try {
    final games = splitPgn(text);
    final replay = replayPgn(parsePgn(games.first));
    openPgnGame(context, replay, sourceUrl: sourceUrl);
    if (games.length > 1 && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'The text held ${games.length} games — opened the first',
          ),
        ),
      );
    }
    return true;
  } on FormatException catch (e) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text("Couldn't read the game: ${e.message}")),
    );
    return false;
  }
}

/// The Library's import entry: paste / file / online archives.
Future<void> showImportSheet(BuildContext context) async {
  await showModalBottomSheet<void>(
    context: context,
    builder: (sheet) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.paste),
            title: const Text('Paste a game (PGN)'),
            onTap: () async {
              Navigator.pop(sheet);
              final data = await Clipboard.getData(Clipboard.kTextPlain);
              final text = (data?.text ?? '').trim();
              if (!context.mounted) return;
              if (text.isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Clipboard is empty')),
                );
                return;
              }
              importPgnText(context, text);
            },
          ),
          ListTile(
            leading: const Icon(Icons.file_open_outlined),
            title: const Text('Open a .pgn file'),
            onTap: () async {
              Navigator.pop(sheet);
              final picked = await FilePicker.pickFile();
              final path = picked?.path;
              if (path == null || !context.mounted) return;
              try {
                final text = await File(path).readAsString();
                if (context.mounted) importPgnText(context, text);
              } catch (_) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text("Couldn't read that file as text"),
                    ),
                  );
                }
              }
            },
          ),
          ListTile(
            leading: const Icon(Icons.public),
            title: const Text('From chess.com'),
            onTap: () {
              Navigator.pop(sheet);
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => const ImportGamesScreen(site: 'chesscom'),
                ),
              );
            },
          ),
          ListTile(
            leading: const Icon(Icons.public),
            title: const Text('From lichess'),
            onTap: () {
              Navigator.pop(sheet);
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => const ImportGamesScreen(site: 'lichess'),
                ),
              );
            },
          ),
        ],
      ),
    ),
  );
}

/// Username → recent games list → tap to analyze.
class ImportGamesScreen extends StatefulWidget {
  const ImportGamesScreen({super.key, required this.site});

  /// 'chesscom' | 'lichess'
  final String site;

  @override
  State<ImportGamesScreen> createState() => _ImportGamesScreenState();
}

class _ImportGamesScreenState extends State<ImportGamesScreen> {
  final _user = TextEditingController();
  final _accounts = ImportAccounts();
  List<String> _saved = [];
  List<SourceGame> _games = [];
  List<String> _archives = []; // chess.com month URLs, newest first
  int _monthsLoaded = 0;
  bool _loading = false;
  String? _error;
  String? _activeUser;

  String get _siteLabel => widget.site == 'chesscom' ? 'chess.com' : 'lichess';

  @override
  void initState() {
    super.initState();
    _loadAccounts();
  }

  Future<void> _loadAccounts() async {
    final all = await _accounts.list();
    if (!mounted) return;
    setState(() {
      _saved = [
        for (final e in all)
          if (e.startsWith('${widget.site}:'))
            e.substring(widget.site.length + 1),
      ];
    });
    // one remembered account: go straight to their games
    if (_saved.isNotEmpty && _activeUser == null) {
      _user.text = _saved.first;
      unawaited(_load(_saved.first));
    }
  }

  Future<void> _load(String user) async {
    setState(() {
      _loading = true;
      _error = null;
      _activeUser = user;
      _games = [];
      _archives = [];
      _monthsLoaded = 0;
    });
    try {
      if (widget.site == 'chesscom') {
        final archives = (await ChessComClient().archives(
          user,
        )).reversed.toList();
        _archives = archives;
        await _loadMoreMonths(user, initial: true);
      } else {
        final games = await LichessClient().recent(user);
        _games = games.where((g) => g.standardRules).toList();
      }
      await _accounts.touch(widget.site, user);
      unawaited(_loadAccounts());
    } on SourceException catch (e) {
      _error = e.message;
    } catch (e) {
      _error = 'Something went wrong: $e';
    }
    if (mounted) setState(() => _loading = false);
  }

  /// chess.com pages by month — pull months until we have a screenful.
  Future<void> _loadMoreMonths(String user, {bool initial = false}) async {
    final client = ChessComClient();
    var added = 0;
    while (_monthsLoaded < _archives.length && (added < 30 || initial)) {
      final games = await client.month(_archives[_monthsLoaded], user);
      _monthsLoaded++;
      final std = games.where((g) => g.standardRules).toList();
      _games = [..._games, ...std];
      added += std.length;
      if (initial && added > 0) break; // show something fast
      if (!initial && added >= 30) break;
    }
  }

  @override
  void dispose() {
    _user.dispose();
    super.dispose();
  }

  void _open(SourceGame g) {
    try {
      final replay = replayPgn(parsePgn(g.pgn));
      openPgnGame(context, replay, sourceUrl: g.url);
    } on FormatException catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Couldn't read that game: ${e.message}")),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text('Games on $_siteLabel')),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _user,
                      autocorrect: false,
                      textInputAction: TextInputAction.search,
                      onSubmitted: (v) {
                        if (v.trim().isNotEmpty) _load(v.trim());
                      },
                      decoration: InputDecoration(
                        labelText: 'Username on $_siteLabel',
                        border: const OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: _loading
                        ? null
                        : () {
                            final v = _user.text.trim();
                            if (v.isNotEmpty) _load(v);
                          },
                    child: const Text('Fetch'),
                  ),
                ],
              ),
            ),
            if (_saved.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Wrap(
                    spacing: 6,
                    children: [
                      for (final u in _saved)
                        InputChip(
                          label: Text(u),
                          selected: u == _activeUser,
                          onPressed: () {
                            _user.text = u;
                            _load(u);
                          },
                          onDeleted: () async {
                            await _accounts.remove('${widget.site}:$u');
                            unawaited(_loadAccounts());
                          },
                        ),
                    ],
                  ),
                ),
              ),
            if (_loading) const LinearProgressIndicator(minHeight: 2),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  _error!,
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ),
            Expanded(
              child: ListView.builder(
                itemCount:
                    _games.length +
                    (widget.site == 'chesscom' &&
                            _monthsLoaded < _archives.length
                        ? 1
                        : 0),
                itemBuilder: (context, i) {
                  if (i == _games.length) {
                    return TextButton(
                      onPressed: _loading || _activeUser == null
                          ? null
                          : () async {
                              setState(() => _loading = true);
                              try {
                                await _loadMoreMonths(_activeUser!);
                              } catch (_) {}
                              if (mounted) {
                                setState(() => _loading = false);
                              }
                            },
                      child: const Text('Load older games'),
                    );
                  }
                  final g = _games[i];
                  final mine =
                      g.white.toLowerCase() == _activeUser?.toLowerCase();
                  final won = mine ? g.result == '1-0' : g.result == '0-1';
                  final lost = mine ? g.result == '0-1' : g.result == '1-0';
                  return ListTile(
                    dense: true,
                    leading: Icon(
                      Icons.circle,
                      size: 14,
                      color: won
                          ? Colors.green
                          : lost
                          ? theme.colorScheme.error
                          : theme.colorScheme.outline,
                    ),
                    title: Text('${g.white} – ${g.black}'),
                    subtitle: Text(
                      '${g.result} · ${g.timeClass} · '
                      '${g.end.day}/${g.end.month}/${g.end.year}',
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => _open(g),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
