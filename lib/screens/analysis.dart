import 'package:chess/chess.dart' as ch;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../engine/engine.dart';
import '../engine/stockfish_engine.dart';
import '../models/game_state.dart';
import '../models/setup_state.dart';
import '../services/saved_games.dart';
import '../utils/fen_clipboard.dart';
import '../utils/position_link.dart';
import '../widgets/board.dart';
import '../widgets/setup_palette.dart';

/// chess.com-style analysis board: eval bar + board + engine lines + move
/// list + step controls. Reused later (in a different mode) for offline play.
class AnalysisScreen extends StatefulWidget {
  const AnalysisScreen({
    super.key,
    this.fen,
    this.initialFlipped = false,
    this.editable = false,
    this.source,
    this.engineFactory,
  });

  final String? fen;

  /// Board orientation carried over from the confirm screen.
  final bool initialFlipped;

  /// Offer free position editing. On when the board is opened from scratch;
  /// positions arriving from a photo are edited on the confirm screen.
  final bool editable;

  /// The saved game this board was opened from, if any — enables
  /// "update" alongside "save as new".
  final SavedGame? source;

  /// Injectable for tests; defaults to real Stockfish.
  final AnalysisEngine Function()? engineFactory;

  @override
  State<AnalysisScreen> createState() => _AnalysisScreenState();
}

class _AnalysisScreenState extends State<AnalysisScreen> {
  late GameState game;
  late final AnalysisEngine engine;

  /// Non-null while the position editor is open.
  SetupState? _setup;

  /// The saved entry this board currently represents (follows an update or
  /// save-as-new, so repeated saves keep targeting the right record).
  late SavedGame? _source = widget.source;

  /// Only engines this screen created get disposed; the shared Stockfish
  /// outlives every screen (its teardown races crash on quick re-entry).
  late final bool _ownsEngine;
  late bool flipped = widget.initialFlipped;

  /// Set when the incoming FEN is not a legal position (legacy saves predate
  /// confirm-time validation). The in-process engine would crash on it.
  String? _fenError;

  @override
  void initState() {
    super.initState();
    if (widget.fen != null) {
      final v = ch.Chess.validate_fen(widget.fen!);
      if (!(v['valid'] as bool)) {
        _fenError = v['error'] as String;
        return;
      }
    }
    game = GameState(fen: widget.fen);
    _ownsEngine = widget.engineFactory != null;
    engine = _ownsEngine ? widget.engineFactory!() : StockfishEngine.shared;
    engine.start();
    engine.analyze(game.fen);
    game.addListener(_onPosition);
  }

  void _onPosition() => engine.analyze(game.fen);

  /// Play the first [plies] moves of an engine line onto the game — tapping
  /// any move in a line jumps the board to that point (chess.com behavior).
  /// The PV was computed from the currently shown position, so the moves
  /// apply directly; if we're mid-move-list they replace the tail.
  void _playLine(EngineLine line, int plies) {
    for (final uci in line.pvUci.take(plies)) {
      final san = game.tryMove(
        uci.substring(0, 2),
        uci.substring(2, 4),
        promotion: uci.length > 4 ? uci.substring(4, 5) : 'q',
      );
      if (san == null) break; // stale line for a superseded position
    }
  }

  @override
  void dispose() {
    if (_fenError == null) {
      game.removeListener(_onPosition);
      engine.stop();
      if (_ownsEngine) engine.dispose();
      game.dispose();
      _setup?.dispose();
    }
    super.dispose();
  }

  /// Open the free-placement editor seeded with the position on screen;
  /// tapping the toolbar button again cancels back to the unchanged game.
  void _toggleEdit() {
    if (_setup != null) {
      engine.analyze(game.fen); // resume where we left off
      _closeEditor();
      return;
    }
    engine.stop(); // no point analyzing a position being torn apart
    final setup = SetupState(pieces: game.pieceMap());
    final parts = game.fen.split(' ');
    if (parts.length > 1 && parts[1] == 'b') setup.setTurn(false);
    setState(() => _setup = setup);
  }

  void _applyEdit() {
    final setup = _setup!;
    final problem = setup.validationError();
    if (problem != null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(problem)));
      return;
    }
    game.removeListener(_onPosition);
    game.dispose();
    game = GameState(fen: setup.toFen());
    game.addListener(_onPosition);
    engine.analyze(game.fen);
    _closeEditor();
  }

  /// Load a FEN from the clipboard as the new position (accepts a bare
  /// placement too — turn defaults to White).
  Future<void> _pasteFen() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    var text = (data?.text ?? '').trim();
    if (!mounted) return;
    if (text.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Clipboard is empty')));
      return;
    }
    if (!text.contains(' ')) text = '$text w - - 0 1';
    final v = ch.Chess.validate_fen(text);
    if (!(v['valid'] as bool)) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Not a valid FEN: ${v['error']}')));
      return;
    }
    if (_setup != null) _closeEditor();
    game.removeListener(_onPosition);
    game.dispose();
    game = GameState(fen: text);
    game.addListener(_onPosition);
    engine.analyze(game.fen);
    setState(() {});
  }

  void _closeEditor() {
    final old = _setup!;
    setState(() => _setup = null);
    // the editor's AnimatedBuilder detaches during this frame's rebuild —
    // disposing the notifier before that would assert
    WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
  }

  /// Save: overwrite the saved entry this board came from (no questions
  /// asked — same name, same photo). Only offered once such an entry exists.
  Future<void> _save() async {
    final source = _source!;
    final saved = SavedGame(
      name: source.name,
      fen: game.fen,
      createdAt: DateTime.now(),
      photoPath: source.photoPath,
    );
    await SavedGamesStore().update(source, saved);
    _source = saved;
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Saved "${source.name}"')));
    }
  }

  /// Save as: a new entry under a new name, leaving the original untouched.
  Future<void> _saveAs() async {
    final nameController = TextEditingController(
      text: _source == null ? '' : '${_source!.name} (copy)',
    );
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Save position as'),
        content: TextField(
          controller: nameController,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Name',
            hintText: 'e.g. Rook endgame study',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final name = nameController.text.trim().isEmpty
        ? 'Position ${DateTime.now().toString().substring(0, 16)}'
        : nameController.text.trim();
    final saved = SavedGame(
      name: name,
      fen: game.fen,
      createdAt: DateTime.now(),
    );
    await SavedGamesStore().add(saved);
    _source = saved; // further plain Saves target the new entry
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Saved "$name"')));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_fenError != null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Analysis')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              'This position isn\'t legal, so it can\'t be analyzed.\n'
              '$_fenError',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: Text(_setup == null ? 'Analysis' : 'Set up position'),
        actions: [
          if (widget.editable)
            IconButton(
              icon: const Icon(Icons.edit_outlined),
              selectedIcon: const Icon(Icons.edit),
              isSelected: _setup != null,
              tooltip: _setup == null ? 'Set up position' : 'Cancel editing',
              onPressed: _toggleEdit,
            ),
          SharePositionButton(fen: () => _setup?.toFen() ?? game.fen),
          // secondary actions live in an overflow so the title survives
          PopupMenuButton<String>(
            tooltip: 'More',
            onSelected: (v) {
              switch (v) {
                case 'copy':
                  copyFen(context, _setup?.toFen() ?? game.fen);
                case 'paste':
                  _pasteFen();
                case 'save':
                  _save();
                case 'saveAs':
                  _saveAs();
              }
            },
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'copy', child: Text('Copy FEN')),
              const PopupMenuItem(value: 'paste', child: Text('Paste FEN')),
              if (_setup == null) ...[
                const PopupMenuDivider(),
                if (_source != null)
                  PopupMenuItem(
                    value: 'save',
                    child: Text('Save · ${_source!.name}'),
                  ),
                const PopupMenuItem(value: 'saveAs', child: Text('Save as…')),
              ],
            ],
          ),
          IconButton(
            icon: const Icon(Icons.swap_vert),
            tooltip: 'Flip board',
            onPressed: () => setState(() => flipped = !flipped),
          ),
        ],
      ),
      body: SafeArea(
        child: _setup != null
            ? _editor()
            : AnimatedBuilder(
                animation: Listenable.merge([game, engine]),
                builder: (context, _) {
                  // defense in depth: a line whose moves don't apply to the shown
                  // position renders as a bare score — never display those
                  final lines = engine.lines
                      .where((l) => l.pvSan.isNotEmpty)
                      .toList();
                  final best = lines.isEmpty ? null : lines.first;
                  final lastMove = game.ply > 0
                      ? game.moves[game.ply - 1].uci
                      : null;
                  // at a finished game the engine has no lines — the result, not
                  // a 50/50 fallback, is the truth
                  final result = game.resultText();
                  final share = result == null
                      ? (best?.whiteShare ?? 0.5)
                      : result.startsWith('1')
                      ? 1.0
                      : result.startsWith('0')
                      ? 0.0
                      : 0.5;
                  return Column(
                    children: [
                      _EngineHeader(
                        best: best,
                        ready: engine.ready,
                        result: result,
                      ),
                      _EvalBar(share: share),
                      _MaterialDiff(fen: game.fen),
                      Expanded(
                        child: Center(
                          child: ChessBoard(
                            pieces: game.pieceMap(),
                            flipped: flipped,
                            lastMoveFrom: lastMove?.substring(0, 2),
                            lastMoveTo: lastMove?.substring(2, 4),
                            legalTargetsFor: game.legalTargets,
                            onMove: (from, to) => game.tryMove(from, to),
                          ),
                        ),
                      ),
                      _EngineLines(
                        lines: lines,
                        baseFen: game.fen,
                        onPlay: _playLine,
                      ),
                      _MoveList(game: game),
                      _Controls(
                        game: game,
                        onBestMove: lines.isEmpty
                            ? null
                            : () => _playLine(lines.first, 1),
                      ),
                    ],
                  );
                },
              ),
      ),
    );
  }

  /// Free-placement editor (same mechanics as the confirm screen): drag
  /// pieces anywhere, drop off-board to delete, palette to add, dots for
  /// whose turn. Done swaps the game to the new position.
  Widget _editor() {
    final setup = _setup!;
    return AnimatedBuilder(
      animation: setup,
      builder: (context, _) => Column(
        children: [
          Expanded(
            // everything around the board accepts drags: dropping a piece
            // outside the board deletes it
            child: DragTarget<String>(
              onAcceptWithDetails: (details) => setup.remove(details.data),
              builder: (context, candidates, rejected) => Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: ChessBoard(
                    pieces: setup.pieces,
                    flipped: flipped,
                    legalTargetsFor: (_) => const {},
                    onMove: setup.move,
                    freeMove: true,
                    onTap: setup.tapSquare,
                    onDoubleTap: setup.flipPiece,
                    onPlace: setup.place,
                  ),
                ),
              ),
            ),
          ),
          SetupPalette(setup: setup),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                TurnDot(
                  white: true,
                  selected: setup.whiteToMove,
                  onTap: () => setup.setTurn(true),
                ),
                const SizedBox(width: 6),
                TurnDot(
                  white: false,
                  selected: !setup.whiteToMove,
                  onTap: () => setup.setTurn(false),
                ),
                const SizedBox(width: 6),
                IconButton.filledTonal(
                  tooltip: 'Clear board',
                  icon: const Icon(Icons.layers_clear_outlined),
                  onPressed: setup.pieces.isEmpty ? null : setup.clear,
                ),
                const Spacer(),
                FilledButton.icon(
                  icon: const Icon(Icons.check),
                  label: const Text('Done'),
                  onPressed: _applyEdit,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _EngineHeader extends StatelessWidget {
  const _EngineHeader({required this.best, required this.ready, this.result});
  final EngineLine? best;
  final bool ready;

  /// Game-over result ("1–0 checkmate") — replaces the live score.
  final String? result;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          Text(
            result ?? best?.displayScore ?? (ready ? '…' : 'engine starting…'),
            style:
                (result != null
                        ? Theme.of(context).textTheme.titleMedium
                        : Theme.of(context).textTheme.headlineSmall)
                    ?.copyWith(fontWeight: FontWeight.bold),
          ),
          const SizedBox(width: 12),
          if (result == null && best != null)
            Text(
              'depth ${best!.depth}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          const Spacer(),
          const Text('Stockfish', style: TextStyle(color: Colors.grey)),
        ],
      ),
    );
  }
}

/// Horizontal evaluation bar (chess.com style): white's share grows from
/// the left, animated so eval swings read as motion.
class _EvalBar extends StatelessWidget {
  const _EvalBar({required this.share});
  final double share;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: SizedBox(
          height: 14,
          width: double.infinity,
          child: Stack(
            children: [
              const SizedBox.expand(
                child: ColoredBox(color: Color(0xFF403D39)),
              ),
              AnimatedFractionallySizedBox(
                duration: const Duration(milliseconds: 400),
                curve: Curves.easeOutCubic,
                alignment: Alignment.centerLeft,
                // a live eval keeps a sliver of both sides visible; a
                // DECIDED game (share exactly 0 or 1) fills the bar
                widthFactor: share == 0 || share == 1
                    ? share
                    : share.clamp(0.03, 0.97),
                // both factors must be set: with only widthFactor the
                // childless ColoredBox collapses to zero height (invisible)
                heightFactor: 1,
                child: const SizedBox.expand(
                  child: ColoredBox(color: Colors.white),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Material imbalance, standard values (P1 N3 B3 R5 Q9): each side's
/// surplus pieces as glyphs, with the point lead on the side that has it.
/// Hidden entirely when material is identical.
class _MaterialDiff extends StatelessWidget {
  const _MaterialDiff({required this.fen});
  final String fen;

  static const _values = {'q': 9, 'r': 5, 'b': 3, 'n': 3, 'p': 1};
  static const _glyphs = {'q': '♛', 'r': '♜', 'b': '♝', 'n': '♞', 'p': '♟'};

  @override
  Widget build(BuildContext context) {
    final counts = <String, int>{};
    for (final ch in fen.split(' ').first.split('')) {
      if ('pnbrqPNBRQ'.contains(ch)) counts[ch] = (counts[ch] ?? 0) + 1;
    }
    var points = 0;
    final white = StringBuffer();
    final black = StringBuffer();
    for (final t in ['q', 'r', 'b', 'n', 'p']) {
      final d = (counts[t.toUpperCase()] ?? 0) - (counts[t] ?? 0);
      points += _values[t]! * d;
      (d > 0 ? white : black).write(_glyphs[t]! * d.abs());
    }
    if (white.isEmpty && black.isEmpty) return const SizedBox.shrink();

    final style = TextStyle(fontSize: 13, color: Colors.grey.shade600);
    final lead = TextStyle(
      fontSize: 13,
      fontWeight: FontWeight.w700,
      color: Colors.grey.shade700,
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
      child: Row(
        children: [
          if (white.isNotEmpty) Text('$white', style: style),
          if (points > 0) Text(' +$points', style: lead),
          const Spacer(),
          if (points < 0) Text('+${-points} ', style: lead),
          if (black.isNotEmpty) Text('$black', style: style),
        ],
      ),
    );
  }
}

class _EngineLines extends StatelessWidget {
  const _EngineLines({
    required this.lines,
    required this.baseFen,
    required this.onPlay,
  });
  final List<EngineLine> lines;
  final String baseFen;
  final void Function(EngineLine line, int plies) onPlay;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final parts = baseFen.split(' ');
    final blackFirst = parts.length > 1 && parts[1] == 'b';
    final baseNumber = parts.length > 5 ? int.tryParse(parts[5]) ?? 1 : 1;

    String label(EngineLine line, int i) {
      final san = i < line.pvSan.length ? line.pvSan[i] : line.pvUci[i];
      final whiteMove = blackFirst ? i.isOdd : i.isEven;
      final number = baseNumber + ((blackFirst ? i + 1 : i) ~/ 2);
      if (whiteMove) return '$number. $san';
      if (i == 0) return '$number… $san';
      return san;
    }

    return Container(
      constraints: const BoxConstraints(minHeight: 66, maxHeight: 116),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      alignment: Alignment.topLeft,
      child: ListView(
        children: [
          for (final line in lines)
            SizedBox(
              height: 36,
              child: Row(
                children: [
                  SizedBox(
                    width: 46,
                    child: Text(
                      line.displayScore,
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                  Expanded(
                    child: ListView.builder(
                      scrollDirection: Axis.horizontal,
                      // show only moves with SAN — the raw-UCI tail past the
                      // conversion cap adds noise, not information
                      itemCount: line.pvSan.length,
                      itemBuilder: (context, i) => InkWell(
                        borderRadius: BorderRadius.circular(4),
                        onTap: () => onPlay(line, i + 1),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 5,
                            vertical: 6,
                          ),
                          child: Text(
                            label(line, i),
                            style: theme.textTheme.bodyMedium,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _MoveList extends StatelessWidget {
  const _MoveList({required this.game});
  final GameState game;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 36,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        itemCount: game.moves.length,
        itemBuilder: (context, i) {
          final numberPrefix = i.isEven ? '${i ~/ 2 + 1}. ' : '';
          final active = i == game.ply - 1;
          return InkWell(
            onTap: () => game.stepTo(i + 1),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
              decoration: active
                  ? BoxDecoration(
                      color: Theme.of(context).colorScheme.primaryContainer,
                      borderRadius: BorderRadius.circular(4),
                    )
                  : null,
              child: Text(
                '$numberPrefix${game.moves[i].san}',
                style: TextStyle(
                  fontWeight: active ? FontWeight.bold : FontWeight.normal,
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _Controls extends StatelessWidget {
  const _Controls({required this.game, this.onBestMove});
  final GameState game;

  /// At the tip of the game the forward arrow plays the engine's best move.
  final VoidCallback? onBestMove;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          IconButton(
            iconSize: 32,
            icon: const Icon(Icons.first_page),
            onPressed: game.ply > 0 ? () => game.stepTo(0) : null,
          ),
          IconButton(
            iconSize: 32,
            icon: const Icon(Icons.chevron_left),
            onPressed: game.ply > 0 ? game.stepBack : null,
          ),
          IconButton(
            iconSize: 32,
            icon: const Icon(Icons.chevron_right),
            onPressed: !game.atLatest ? game.stepForward : onBestMove,
          ),
          IconButton(
            iconSize: 32,
            icon: const Icon(Icons.last_page),
            onPressed: !game.atLatest
                ? () => game.stepTo(game.moves.length)
                : null,
          ),
        ],
      ),
    );
  }
}
