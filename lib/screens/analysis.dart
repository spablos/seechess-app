import 'dart:io';

import 'package:chess/chess.dart' as ch;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../engine/engine.dart';
import '../engine/stockfish_engine.dart';
import '../models/game_state.dart';
import '../models/setup_state.dart';
import '../services/pgn.dart';
import '../services/saved_games.dart';
import '../utils/fen_clipboard.dart';
import '../utils/position_link.dart';
import '../widgets/board.dart';
import '../widgets/photo_panel.dart';
import '../widgets/setup_palette.dart';

/// How the shown position relates to an imported/saved game's original
/// line: null = no original or still on it; 'sideline' = a shown move
/// differs from the original; 'beyond' = play continued past its end.
String? offLineStatus(List<PlayedMove> moves, int ply, List<String>? original) {
  if (original == null) return null;
  for (var i = 0; i < ply; i++) {
    if (i >= original.length) return 'beyond';
    if (moves[i].uci != original[i]) return 'sideline';
  }
  return null;
}

/// chess.com-style analysis board: eval bar + board + engine lines + move
/// list + step controls. Reused later (in a different mode) for offline play.
class AnalysisScreen extends StatefulWidget {
  const AnalysisScreen({
    super.key,
    this.fen,
    this.movesUci = const [],
    this.initialFlipped = false,
    this.editable = false,
    this.source,
    this.photoPath,
    this.engineFactory,
    this.initialPly,
    this.title,
    this.comments = const {},
    this.importDraft,
  });

  final String? fen;

  /// Moves to replay onto [fen] (a saved game reopens at its tip).
  final List<String> movesUci;

  /// Board orientation carried over from the confirm screen.
  final bool initialFlipped;

  /// Offer free position editing. On when the board is opened from scratch;
  /// positions arriving from a photo are edited on the confirm screen.
  final bool editable;

  /// The saved game this board was opened from, if any — enables
  /// "update" alongside "save as new".
  final SavedGame? source;

  /// The original photo, when arriving straight from a detection (the
  /// library path supplies it via [source] instead).
  final String? photoPath;

  /// Injectable for tests; defaults to real Stockfish.
  final AnalysisEngine Function()? engineFactory;

  /// Open at this ply of [movesUci] (imported games start at 0 — reviewing
  /// begins at the opening; saved games default to the tip).
  final int? initialPly;

  /// AppBar title override, e.g. "White – Black · 1-0" for imports.
  final String? title;

  /// PGN comments by 1-based ply, shown under the move list during replay.
  final Map<int, String> comments;

  /// Prefilled unsaved entry for imports: Save as starts from its name and
  /// metadata (players, result, source link, labels) instead of blanks.
  final SavedGame? importDraft;

  @override
  State<AnalysisScreen> createState() => _AnalysisScreenState();
}

class _AnalysisScreenState extends State<AnalysisScreen> {
  late GameState game;
  late final AnalysisEngine engine;

  /// Non-null while the position editor is open.
  SetupState? _setup;

  bool _photoVisible = false;

  /// Comments/title/draft follow the loaded game — Paste PGN replaces them.
  late Map<int, String> _comments = widget.source?.comments.isNotEmpty == true
      ? widget.source!.comments
      : widget.comments;

  /// The game's original move line (import or saved entry) — kept so the
  /// UI can say when analysis has wandered off it, and lead back.
  late List<String>? _original = widget.movesUci.isEmpty
      ? null
      : List.of(widget.movesUci);
  late String? _title = widget.title;
  late SavedGame? _importDraft = widget.importDraft;

  /// The original photo of the position, when there is one.
  String? get _photoPath {
    final path = widget.photoPath ?? _source?.photoPath;
    return path != null && File(path).existsSync() ? path : null;
  }

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

  /// The position the current game's move list starts from — follows
  /// Paste FEN and editor applies, so a save replays correctly.
  late String _startFen =
      widget.fen ?? 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';

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
    for (final uci in widget.movesUci) {
      if (uci.length < 4) continue;
      final san = game.tryMove(
        uci.substring(0, 2),
        uci.substring(2, 4),
        promotion: uci.length > 4 ? uci.substring(4, 5) : 'q',
      );
      if (san == null) break; // stop at the first non-applying move
    }
    if (widget.initialPly != null) game.stepTo(widget.initialPly!);
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
    _original = null;
    _startFen = setup.toFen();
    game.addListener(_onPosition);
    engine.analyze(game.fen);
    _closeEditor();
  }

  /// Load whatever is on the clipboard: a full PGN game (headers or
  /// movetext) or a FEN (bare placement accepted — turn defaults to White).
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
    if (looksLikePgn(text)) {
      try {
        final replay = replayPgn(parsePgn(splitPgn(text).first));
        _loadReplay(replay);
      } on FormatException catch (e) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Couldn't read the PGN: ${e.message}")),
        );
      }
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
    _original = null;
    _startFen = text;
    game.addListener(_onPosition);
    engine.analyze(game.fen);
    setState(() {});
  }

  /// Swap the board to an imported game, starting at the opening.
  void _loadReplay(PgnReplay replay) {
    if (_setup != null) _closeEditor();
    game.removeListener(_onPosition);
    game.dispose();
    game = GameState(fen: replay.game.startFen);
    for (final u in replay.uci) {
      game.tryMove(
        u.substring(0, 2),
        u.substring(2, 4),
        promotion: u.length > 4 ? u.substring(4, 5) : 'q',
      );
    }
    game.stepTo(0);
    _original = List.of(replay.uci);
    _startFen = game.startFen;
    _comments = replay.game.comments;
    final players = replay.game.playersLabel;
    _title = players == null
        ? null
        : '$players${replay.game.result == null ? '' : ' · ${replay.game.result}'}';
    _importDraft = SavedGame(
      name: players ?? 'Imported game',
      fen: replay.finalFen,
      createdAt: DateTime.now(),
      white: replay.game.white,
      black: replay.game.black,
      result: replay.game.result,
    );
    _source = null;
    game.addListener(_onPosition);
    engine.analyze(game.fen);
    setState(() {});
  }

  /// Rebuild the original line and land where analysis left it.
  void _backToGame() {
    final orig = _original!;
    var keep = 0;
    while (keep < game.ply &&
        keep < orig.length &&
        game.moves[keep].uci == orig[keep]) {
      keep++;
    }
    game.removeListener(_onPosition);
    game.dispose();
    game = GameState(fen: _startFen);
    for (final u in orig) {
      game.tryMove(
        u.substring(0, 2),
        u.substring(2, 4),
        promotion: u.length > 4 ? u.substring(4, 5) : 'q',
      );
    }
    game.stepTo(keep);
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
    final saved = source.copyWith(
      fen: game.fen,
      modifiedAt: DateTime.now(),
      startFen: _startFen,
      movesUci: [for (final m in game.moves) m.uci],
    );
    await SavedGamesStore().update(saved);
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
      text:
          _importDraft?.name ??
          (_source == null ? '' : '${_source!.name} (copy)'),
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
    final draft = _importDraft;
    final saved = SavedGame(
      name: name,
      fen: game.fen,
      createdAt: DateTime.now(),
      startFen: _startFen,
      movesUci: [for (final m in game.moves) m.uci],
      labels: draft?.labels ?? const [],
      white: draft?.white,
      black: draft?.black,
      result: draft?.result,
      sourceUrl: draft?.sourceUrl,
      comments: _comments,
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
        title: Text(
          _setup != null ? 'Set up position' : _title ?? 'Analysis',
          overflow: TextOverflow.fade,
        ),
        actions: [
          if (widget.editable)
            IconButton(
              icon: const Icon(Icons.edit_outlined),
              selectedIcon: const Icon(Icons.edit),
              isSelected: _setup != null,
              tooltip: _setup == null ? 'Set up position' : 'Cancel editing',
              onPressed: _toggleEdit,
            ),
          if (_photoPath != null)
            IconButton(
              tooltip: _photoVisible ? 'Hide photo' : 'Show photo',
              isSelected: _photoVisible,
              icon: const Icon(Icons.image_outlined),
              selectedIcon: const Icon(Icons.image),
              onPressed: () => setState(() => _photoVisible = !_photoVisible),
            ),
          IconButton(
            icon: const Icon(Icons.swap_vert),
            tooltip: 'Flip board',
            onPressed: () => setState(() => flipped = !flipped),
          ),
        ],
      ),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, boxBounds) => Stack(
            children: [
              _setup != null
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
                              whiteToMove: game.fen.split(' ')[1] == 'w',
                              onLine: _original == null
                                  ? null
                                  : offLineStatus(
                                          game.moves,
                                          game.ply,
                                          _original,
                                        ) ==
                                        null,
                              onBackToGame: _backToGame,
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
                            if (offLineStatus(
                                      game.moves,
                                      game.ply,
                                      _original,
                                    ) ==
                                    null &&
                                _comments[game.ply] != null)
                              Padding(
                                padding: const EdgeInsets.fromLTRB(
                                  12,
                                  0,
                                  12,
                                  4,
                                ),
                                child: Text(
                                  _comments[game.ply]!,
                                  style: Theme.of(context).textTheme.bodySmall
                                      ?.copyWith(
                                        fontStyle: FontStyle.italic,
                                        color: Theme.of(
                                          context,
                                        ).colorScheme.onSurfaceVariant,
                                      ),
                                  maxLines: 3,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            _actionStrip(),
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
              if (_photoVisible && _photoPath != null)
                FloatingPhotoPanel(
                  photoPath: _photoPath!,
                  bounds: boxBounds.biggest,
                  onClose: () => setState(() => _photoVisible = false),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// Every position action, visible — no overflow menu. Save targets the
  /// entry this board came from and is disabled until one exists.
  Widget _actionStrip({bool editing = false}) {
    String fen() => _setup?.toFen() ?? game.fen;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          IconButton(
            tooltip: 'Copy FEN',
            icon: const Icon(Icons.content_copy_outlined),
            onPressed: () => copyFen(context, fen()),
          ),
          IconButton(
            tooltip: 'Paste FEN',
            icon: const Icon(Icons.content_paste_go),
            onPressed: _pasteFen,
          ),
          IconButton(
            tooltip: 'Share position',
            icon: const Icon(Icons.ios_share),
            onPressed: () => sharePosition(context, fen()),
          ),
          if (!editing) ...[
            IconButton(
              tooltip: _source == null
                  ? 'Save (nothing to overwrite yet — use Save as)'
                  : 'Save · ${_source!.name}',
              icon: const Icon(Icons.bookmark),
              onPressed: _source == null ? null : _save,
            ),
            IconButton(
              tooltip: 'Save as…',
              icon: const Icon(Icons.bookmark_add_outlined),
              onPressed: _saveAs,
            ),
          ],
        ],
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
          _actionStrip(editing: true),
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
  const _EngineHeader({
    required this.best,
    required this.ready,
    required this.whiteToMove,
    this.result,
    this.onLine,
    this.onBackToGame,
  });
  final EngineLine? best;
  final bool ready;
  final bool whiteToMove;

  /// Game-over result ("1–0 mate") — replaces the live score.
  final String? result;

  /// null = no original game to compare against; true = on its line;
  /// false = wandered off (tapping the icon returns).
  final bool? onLine;
  final VoidCallback? onBackToGame;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          Text(
            result ?? best?.displayScore ?? (ready ? '…' : 'engine starting…'),
            style:
                (result != null
                        ? theme.textTheme.titleMedium
                        : theme.textTheme.headlineSmall)
                    ?.copyWith(fontWeight: FontWeight.bold),
          ),
          const SizedBox(width: 12),
          if (result == null && best != null)
            Text('depth ${best!.depth}', style: theme.textTheme.bodySmall),
          const Spacer(),
          // original-line indicator: a line while on it, "off" over the
          // line when analysis wandered — tap returns to the game
          if (onLine != null) ...[
            Tooltip(
              message: onLine!
                  ? "On the game's original line"
                  : "Off the game's line — tap to return",
              child: InkWell(
                onTap: onLine! ? null : onBackToGame,
                borderRadius: BorderRadius.circular(12),
                child: SizedBox(
                  width: 28,
                  height: 24,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      Icon(
                        Icons.timeline,
                        size: 20,
                        color: onLine!
                            ? theme.colorScheme.primary
                            : theme.colorScheme.outlineVariant,
                      ),
                      if (!onLine!)
                        // rubber-stamped over the line, "REJECTED"-style
                        Transform.rotate(
                          angle: -0.35,
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 2),
                            decoration: BoxDecoration(
                              color: theme.colorScheme.surface.withValues(
                                alpha: 0.55,
                              ),
                              border: Border.all(
                                color: theme.colorScheme.error,
                                width: 1.2,
                              ),
                              borderRadius: BorderRadius.circular(2),
                            ),
                            child: Text(
                              'OFF',
                              style: theme.textTheme.labelSmall?.copyWith(
                                fontSize: 8,
                                height: 1.2,
                                fontWeight: FontWeight.w900,
                                letterSpacing: 0.5,
                                color: theme.colorScheme.error,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(width: 10),
          ],
          // whose turn — a disc alone says it (no words)
          if (result == null)
            Tooltip(
              message: whiteToMove ? 'White to move' : 'Black to move',
              child: Container(
                width: 18,
                height: 18,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: whiteToMove ? Colors.white : const Color(0xFF1E1E1E),
                  border: Border.all(color: theme.colorScheme.outlineVariant),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

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
