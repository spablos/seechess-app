import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/game_sources.dart';
import '../services/pgn.dart';
import '../services/stats.dart';
import '../services/saved_games.dart';
import 'analysis.dart';

/// Game import (PRD-game-import): PGN by paste/file/share, and online
/// archives from chess.com / lichess by username — no accounts, their
/// public APIs are keyed on the name alone.

/// Open a parsed game on the analysis board, at move 0, save-ready.
void openPgnGame(BuildContext context, PgnReplay replay, {String? sourceUrl}) {
  unawaited(AppStats.count('game_import'));
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
          // site + both players: filter later by "all games of user X"
          labels: [
            if (g.site?.toLowerCase().contains('chess.com') ?? false)
              'chess.com'
            else if (g.site?.toLowerCase().contains('lichess') ?? false)
              'lichess'
            else
              'imported',
            for (final player in [g.white, g.black])
              if (player != null && player.isNotEmpty && player != '?') player,
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

  /// Multi-user fetch (Pablo): one or more usernames, each with its own
  /// chess.com archive paging state. Games merge, deduped by URL.
  final List<String> _activeUsers = [];
  final Map<String, List<String>> _archives = {};
  final Map<String, int> _monthsLoaded = {};
  final Set<String> _seenUrls = {};

  /// With ≥2 users: false = all their games; true = only games they
  /// played against each other (head-to-head).
  bool _headToHead = false;

  bool _loading = false;
  String? _error;

  /// Username help while typing (last comma-separated token): lichess has
  /// a real autocomplete API; chess.com only exact lookups, so there we
  /// show an exists/not-found verdict instead.
  Timer? _typeDebounce;
  List<String> _suggestions = const [];
  String _checkedToken = '';
  bool? _tokenExists;

  /// 'all' | 'won' | 'lost' | 'draw' — from the first selected user's
  /// perspective (head-to-head keeps that viewpoint too).
  String _resultFilter = 'all';

  /// Only games where the opponent was rated at least this. 0 = any.
  int _minOppRating = 0;

  /// '' = any; else bullet/blitz/rapid/daily/classical/correspondence.
  String _timeClass = '';

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
    if (_saved.isNotEmpty && _activeUsers.isEmpty) {
      _user.text = _saved.first;
      unawaited(_load([_saved.first]));
    }
  }

  void _addGames(Iterable<SourceGame> games) {
    for (final g in games) {
      final key = g.url.isNotEmpty ? g.url : '${g.white}|${g.black}|${g.end}';
      if (_seenUrls.add(key)) _games.add(g);
    }
    _games.sort((a, b) => b.end.compareTo(a.end));
  }

  Future<void> _load(List<String> users) async {
    setState(() {
      _loading = true;
      _error = null;
      _activeUsers
        ..clear()
        ..addAll(users);
      _games = [];
      _seenUrls.clear();
      _archives.clear();
      _monthsLoaded.clear();
    });
    try {
      for (final user in users) {
        if (widget.site == 'chesscom') {
          _archives[user] = (await ChessComClient().archives(
            user,
          )).reversed.toList();
          _monthsLoaded[user] = 0;
          await _loadMoreMonths(user, initial: true);
        } else {
          final games = await LichessClient().recent(user);
          _addGames(games.where((g) => g.standardRules));
        }
        await _accounts.touch(widget.site, user);
      }
      unawaited(_loadAccounts());
    } on SourceException catch (e) {
      _error = e.message;
    } catch (e) {
      _error = 'Something went wrong: $e';
    }
    if (mounted) setState(() => _loading = false);
  }

  bool get _hasOlder =>
      widget.site == 'chesscom' &&
      _activeUsers.any(
        (u) => (_monthsLoaded[u] ?? 0) < (_archives[u]?.length ?? 0),
      );

  /// chess.com pages by month — pull months until we have a screenful.
  Future<void> _loadMoreMonths(String user, {bool initial = false}) async {
    final client = ChessComClient();
    final archives = _archives[user] ?? const [];
    var added = 0;
    while ((_monthsLoaded[user] ?? 0) < archives.length &&
        (added < 30 || initial)) {
      final games = await client.month(
        archives[_monthsLoaded[user] ?? 0],
        user,
      );
      _monthsLoaded[user] = (_monthsLoaded[user] ?? 0) + 1;
      final std = games.where((g) => g.standardRules).toList();
      _addGames(std);
      added += std.length;
      if (initial && added > 0) break; // show something fast
      if (!initial && added >= 30) break;
    }
  }

  void _fetchFromField() {
    final users = _user.text
        .split(RegExp(r'[,\s]+'))
        .map((u) => u.trim())
        .where((u) => u.isNotEmpty)
        .toList();
    if (users.isNotEmpty) _load(users);
  }

  Future<void> _loadOlderAll() async {
    for (final u in List.of(_activeUsers)) {
      if (widget.site == 'chesscom') await _loadMoreMonths(u);
    }
  }

  @override
  void dispose() {
    _typeDebounce?.cancel();
    _user.dispose();
    super.dispose();
  }

  String get _lastToken => _user.text.split(',').last.trim();

  void _onTyped(String _) {
    _typeDebounce?.cancel();
    _typeDebounce = Timer(const Duration(milliseconds: 400), () async {
      final token = _lastToken;
      if (token.length < 3) {
        if (mounted) {
          setState(() {
            _suggestions = const [];
            _checkedToken = '';
            _tokenExists = null;
          });
        }
        return;
      }
      if (widget.site == 'lichess') {
        final hits = await lichessAutocomplete(token);
        if (!mounted || _lastToken != token) return;
        setState(() => _suggestions = hits.take(8).toList());
      } else {
        final exists = await chessComUserExists(token);
        if (!mounted || _lastToken != token) return;
        setState(() {
          _checkedToken = token;
          _tokenExists = exists;
        });
      }
    });
  }

  void _pickSuggestion(String name) {
    final parts = _user.text.split(',');
    parts[parts.length - 1] = ' $name';
    _user.text = parts.join(',').replaceFirst(RegExp(r'^ '), '');
    _user.selection = TextSelection.collapsed(offset: _user.text.length);
    setState(() => _suggestions = const []);
  }

  bool _mine(SourceGame g) {
    // "my" side = the first active user appearing in the game
    for (final u in _activeUsers) {
      if (g.white.toLowerCase() == u.toLowerCase()) return true;
      if (g.black.toLowerCase() == u.toLowerCase()) return false;
    }
    return true;
  }

  int? _oppRating(SourceGame g) => _mine(g) ? g.blackRating : g.whiteRating;

  bool _isHeadToHead(SourceGame g) {
    final names = _activeUsers.map((u) => u.toLowerCase()).toSet();
    return names.contains(g.white.toLowerCase()) &&
        names.contains(g.black.toLowerCase());
  }

  bool _passesFilters(SourceGame g) {
    if (_headToHead && _activeUsers.length >= 2 && !_isHeadToHead(g)) {
      return false;
    }
    if (_timeClass.isNotEmpty && g.timeClass != _timeClass) return false;
    if (_minOppRating > 0 && (_oppRating(g) ?? 0) < _minOppRating) {
      return false;
    }
    switch (_resultFilter) {
      case 'won':
        return _mine(g) ? g.result == '1-0' : g.result == '0-1';
      case 'lost':
        return _mine(g) ? g.result == '0-1' : g.result == '1-0';
      case 'draw':
        return g.result == '1/2-1/2';
    }
    return true;
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
                    // the controller doubles as a ValueListenable, so the
                    // clear button appears/disappears with the text without
                    // waiting for the debounced _onTyped setState
                    child: ValueListenableBuilder<TextEditingValue>(
                      valueListenable: _user,
                      builder: (context, value, _) => TextField(
                        controller: _user,
                        autocorrect: false,
                        textInputAction: TextInputAction.search,
                        onChanged: _onTyped,
                        onSubmitted: (v) => _fetchFromField(),
                        decoration: InputDecoration(
                          labelText:
                              'Username(s) on $_siteLabel — comma for several',
                          border: const OutlineInputBorder(),
                          isDense: true,
                          suffixIcon: value.text.isEmpty
                              ? null
                              : IconButton(
                                  icon: const Icon(Icons.clear, size: 18),
                                  tooltip: 'Clear',
                                  onPressed: () {
                                    _user.clear();
                                    _onTyped('');
                                  },
                                ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: _loading ? null : _fetchFromField,
                    child: const Text('Fetch'),
                  ),
                ],
              ),
            ),
            if (_suggestions.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final name in _suggestions)
                        ActionChip(
                          label: Text(name),
                          visualDensity: VisualDensity.compact,
                          onPressed: () => _pickSuggestion(name),
                        ),
                    ],
                  ),
                ),
              ),
            if (widget.site == 'chesscom' &&
                _checkedToken.isNotEmpty &&
                _checkedToken == _lastToken &&
                _tokenExists != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
                child: Row(
                  children: [
                    Icon(
                      _tokenExists! ? Icons.check_circle : Icons.cancel,
                      size: 16,
                      color: _tokenExists!
                          ? Colors.green
                          : theme.colorScheme.error,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      _tokenExists!
                          ? '"$_checkedToken" exists'
                          : 'no user "$_checkedToken" on chess.com',
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            if (widget.site == 'chesscom')
              Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: TextButton.icon(
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                    ),
                    icon: const Icon(Icons.travel_explore, size: 16),
                    // chess.com's member search cannot be pre-filled or
                    // queried from outside (verified: the URL keyword is
                    // ignored and the internal endpoints reject callers).
                    // Best real flow: copy the name, open their search,
                    // the user pastes into chess.com's own box.
                    label: Text(
                      _lastToken.isEmpty
                          ? 'Find a member on chess.com'
                          : 'Copy "$_lastToken" & open chess.com search',
                      overflow: TextOverflow.ellipsis,
                    ),
                    onPressed: () async {
                      if (_lastToken.isNotEmpty) {
                        await Clipboard.setData(
                          ClipboardData(text: _lastToken),
                        );
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(
                                '"$_lastToken" copied — paste it into '
                                "chess.com's search box",
                              ),
                            ),
                          );
                        }
                      }
                      await launchUrl(
                        Uri.parse('https://www.chess.com/members'),
                        mode: LaunchMode.externalApplication,
                      );
                    },
                  ),
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
                          selected: _activeUsers
                              .map((x) => x.toLowerCase())
                              .contains(u.toLowerCase()),
                          onPressed: _loading
                              ? null
                              : () {
                                  final set = List.of(_activeUsers);
                                  final hit = set.indexWhere(
                                    (x) => x.toLowerCase() == u.toLowerCase(),
                                  );
                                  if (hit >= 0) {
                                    set.removeAt(hit);
                                  } else {
                                    set.add(u);
                                  }
                                  _user.text = set.join(', ');
                                  if (set.isNotEmpty) _load(set);
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
            if (_games.isNotEmpty ||
                _resultFilter != 'all' ||
                _minOppRating > 0)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Row(
                  children: [
                    SegmentedButton<String>(
                      segments: const [
                        ButtonSegment(value: 'all', label: Text('All')),
                        ButtonSegment(value: 'won', label: Text('Won')),
                        ButtonSegment(value: 'lost', label: Text('Lost')),
                        ButtonSegment(value: 'draw', label: Text('½')),
                      ],
                      selected: {_resultFilter},
                      showSelectedIcon: false,
                      style: const ButtonStyle(
                        visualDensity: VisualDensity.compact,
                      ),
                      onSelectionChanged: (sel) =>
                          setState(() => _resultFilter = sel.first),
                    ),
                    const Spacer(),
                    if (_activeUsers.length >= 2)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: FilterChip(
                          label: const Text('Head-to-head'),
                          selected: _headToHead,
                          onSelected: (v) => setState(() => _headToHead = v),
                        ),
                      ),
                    PopupMenuButton<String>(
                      tooltip: 'Time control',
                      initialValue: _timeClass,
                      onSelected: (v) => setState(() => _timeClass = v),
                      itemBuilder: (context) => [
                        const PopupMenuItem(value: '', child: Text('Any pace')),
                        for (final tc in [
                          'bullet',
                          'blitz',
                          'rapid',
                          'daily',
                          'classical',
                          'correspondence',
                        ])
                          PopupMenuItem(value: tc, child: Text(tc)),
                      ],
                      child: Container(
                        margin: const EdgeInsets.only(right: 8),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: _timeClass.isNotEmpty
                              ? theme.colorScheme.primaryContainer
                              : theme.colorScheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          _timeClass.isEmpty ? 'Any pace' : _timeClass,
                          style: theme.textTheme.labelMedium,
                        ),
                      ),
                    ),
                    PopupMenuButton<int>(
                      tooltip: 'Minimum opponent rating',
                      initialValue: _minOppRating,
                      onSelected: (v) => setState(() => _minOppRating = v),
                      itemBuilder: (context) => [
                        const PopupMenuItem(
                          value: 0,
                          child: Text('Any rating'),
                        ),
                        for (final r in [
                          1000,
                          1200,
                          1400,
                          1600,
                          1800,
                          2000,
                          2200,
                        ])
                          PopupMenuItem(value: r, child: Text('Opp ≥ $r')),
                      ],
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: _minOppRating > 0
                              ? theme.colorScheme.primaryContainer
                              : theme.colorScheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          _minOppRating > 0
                              ? 'Opp ≥ $_minOppRating'
                              : 'Any rating',
                          style: theme.textTheme.labelMedium,
                        ),
                      ),
                    ),
                  ],
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
              child: Builder(
                builder: (context) {
                  final shown = _games.where(_passesFilters).toList();
                  return ListView.builder(
                    itemCount: shown.length + (_hasOlder ? 1 : 0),
                    itemBuilder: (context, i) {
                      if (i == shown.length) {
                        return TextButton(
                          onPressed: _loading
                              ? null
                              : () async {
                                  setState(() => _loading = true);
                                  try {
                                    await _loadOlderAll();
                                  } catch (_) {}
                                  if (mounted) {
                                    setState(() => _loading = false);
                                  }
                                },
                          child: const Text('Load older games'),
                        );
                      }
                      final g = shown[i];
                      final mine = _mine(g);
                      final won = mine ? g.result == '1-0' : g.result == '0-1';
                      final lost = mine ? g.result == '0-1' : g.result == '1-0';
                      final opp = _oppRating(g);
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
                          '${g.result} · ${g.timeClass}'
                          '${opp != null ? ' · opp $opp' : ''} · '
                          '${g.end.day}/${g.end.month}/${g.end.year}',
                        ),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => _open(g),
                      );
                    },
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
