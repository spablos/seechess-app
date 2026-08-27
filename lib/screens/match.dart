import 'dart:async';

import 'package:flutter/material.dart';

import '../services/offline/match_session.dart';
import '../services/saved_games.dart';
import '../utils/fen_clipboard.dart';
import '../widgets/board.dart';

/// Live offline match (PRD §4): board + chess.com-style clocks. The session
/// (host or guest) is the single source of truth; this screen only renders
/// it and forwards intents.
class MatchScreen extends StatefulWidget {
  const MatchScreen({super.key, required this.session});
  final MatchSession session;

  @override
  State<MatchScreen> createState() => _MatchScreenState();
}

class _MatchScreenState extends State<MatchScreen> {
  late final Timer _ticker;

  MatchSession get session => widget.session;

  @override
  void initState() {
    super.initState();
    // clocks tick locally between authoritative syncs
    _ticker = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (mounted && session.started) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker.cancel();
    session.shutdown();
    super.dispose();
  }

  Future<void> _confirmExit() async {
    final live = session.started && session.result == null;
    if (!live) {
      if (mounted) Navigator.of(context).pop();
      return;
    }
    final leave = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Leave the match?'),
        content: const Text('Leaving ends the game for both players.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep playing'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Leave'),
          ),
        ],
      ),
    );
    if (leave == true && mounted) Navigator.of(context).pop();
  }

  Future<void> _resign() async {
    final sure = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Resign?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep playing'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Resign'),
          ),
        ],
      ),
    );
    if (sure == true) session.resign();
  }

  Future<void> _save() async {
    final opp = session.oppName ?? 'opponent';
    await SavedGamesStore().add(
      SavedGame(
        name: 'vs $opp — ${session.result}',
        fen: session.game.fen,
        createdAt: DateTime.now(),
      ),
    );
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Game saved')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _confirmExit();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text('${session.timeControl.display} · offline'),
          leading: IconButton(
            icon: const Icon(Icons.close),
            onPressed: _confirmExit,
          ),
          actions: [CopyFenButton(fen: () => session.game.fen)],
        ),
        body: SafeArea(
          child: AnimatedBuilder(
            animation: session,
            builder: (context, _) {
              final game = session.game;
              final lastMove = game.moves.isEmpty ? null : game.moves.last.uci;
              return Column(
                children: [
                  _PlayerBar(
                    name: session.oppName ?? '…',
                    white: !session.myWhite,
                    ms: session.displayMs(!session.myWhite),
                    active:
                        session.result == null &&
                        session.started &&
                        session.turnWhiteNow != session.myWhite,
                  ),
                  _banner(theme),
                  Expanded(
                    child: Center(
                      child: ChessBoard(
                        pieces: game.pieceMap(),
                        flipped: !session.myWhite,
                        lastMoveFrom: lastMove?.substring(0, 2),
                        lastMoveTo: lastMove?.substring(2, 4),
                        legalTargetsFor: session.myTurn
                            ? game.legalTargets
                            : (_) => const {},
                        // v1 promotes to queen (same default as analysis)
                        onMove: session.myTurn ? session.sendMove : (_, _) {},
                      ),
                    ),
                  ),
                  _moveList(theme),
                  _PlayerBar(
                    name: session.myName,
                    white: session.myWhite,
                    ms: session.displayMs(session.myWhite),
                    active:
                        session.result == null &&
                        session.started &&
                        session.turnWhiteNow == session.myWhite,
                  ),
                  _controls(theme),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  /// One line of match status: result, disconnect, or a pending offer.
  Widget _banner(ThemeData theme) {
    final String? text;
    List<Widget> actions = const [];
    if (session.result != null) {
      text = session.result;
    } else if (!session.connected) {
      text = 'Connection lost — clocks paused, waiting to reconnect…';
    } else if (session.drawOfferFrom == 'opp') {
      text = '${session.oppName} offers a draw';
      actions = [
        TextButton(
          onPressed: () => session.respondDraw(true),
          child: const Text('Accept'),
        ),
        TextButton(
          onPressed: () => session.respondDraw(false),
          child: const Text('Decline'),
        ),
      ];
    } else if (session.drawOfferFrom == 'me') {
      text = 'Draw offered…';
    } else {
      text = null;
    }
    if (text == null) return const SizedBox(height: 4);
    return Container(
      width: double.infinity,
      color: theme.colorScheme.surfaceContainerHighest,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: session.result != null
                    ? FontWeight.w700
                    : FontWeight.w400,
              ),
            ),
          ),
          ...actions,
          if (session.result != null) ...[
            TextButton(onPressed: _save, child: const Text('Save')),
            TextButton(
              onPressed: session.rematchFrom == 'me' ? null : session.rematch,
              child: Text(
                session.rematchFrom == 'opp'
                    ? 'Accept rematch'
                    : session.rematchFrom == 'me'
                    ? 'Rematch…'
                    : 'Rematch',
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _moveList(ThemeData theme) {
    final moves = session.game.moves;
    return SizedBox(
      height: 32,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        reverse: true, // newest move always visible
        padding: const EdgeInsets.symmetric(horizontal: 8),
        itemCount: moves.length,
        itemBuilder: (context, i) {
          final idx = moves.length - 1 - i;
          final prefix = idx.isEven ? '${idx ~/ 2 + 1}. ' : '';
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 7),
            child: Text(
              '$prefix${moves[idx].san}',
              style: TextStyle(
                fontWeight: idx == moves.length - 1
                    ? FontWeight.bold
                    : FontWeight.normal,
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _controls(ThemeData theme) {
    final live = session.started && session.result == null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 2, 12, 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          TextButton.icon(
            icon: const Icon(Icons.flag_outlined, size: 20),
            label: const Text('Resign'),
            onPressed: live ? _resign : null,
          ),
          const SizedBox(width: 16),
          TextButton.icon(
            icon: const Icon(Icons.handshake_outlined, size: 20),
            label: const Text('Draw'),
            onPressed: live && session.drawOfferFrom == null
                ? session.offerDraw
                : null,
          ),
        ],
      ),
    );
  }
}

/// chess.com-style player strip: name on one side, boxed clock on the
/// other; the side to move is highlighted, low time turns red.
class _PlayerBar extends StatelessWidget {
  const _PlayerBar({
    required this.name,
    required this.white,
    required this.ms,
    required this.active,
  });

  final String name;
  final bool white;
  final int ms;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final seconds = (ms / 1000).ceil();
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    final s = seconds % 60;
    final time = h > 0
        ? '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}'
        : '$m:${s.toString().padLeft(2, '0')}';
    final lowTime = active && ms < 30000;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Row(
        children: [
          Container(
            width: 14,
            height: 14,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: white ? Colors.white : const Color(0xFF1E1E1E),
              border: Border.all(color: theme.colorScheme.outlineVariant),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              name,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: active ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
          ),
          AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
            decoration: BoxDecoration(
              color: active
                  ? (white ? Colors.white : const Color(0xFF262421))
                  : theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(6),
              border: active
                  ? Border.all(color: theme.colorScheme.primary, width: 2)
                  : null,
            ),
            child: Text(
              time,
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                fontFeatures: const [FontFeature.tabularFigures()],
                color: lowTime
                    ? Colors.red
                    : active
                    ? (white ? Colors.black87 : Colors.white)
                    : theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
