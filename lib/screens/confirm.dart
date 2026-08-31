import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';

import '../models/setup_state.dart';
import '../services/recognizer.dart';
import '../services/saved_games.dart';
import '../utils/fen_clipboard.dart';
import '../utils/position_link.dart';
import '../widgets/board.dart';
import '../widgets/setup_palette.dart';
import 'analysis.dart';

/// ≥ this many fixed squares counts as "detection was way off" and earns
/// the sincere apology rather than a casual thanks.
const badDetectionThreshold = 6;

/// Squares where the confirmed position differs from the predicted one —
/// the honest measure of how much fixing the user just did.
int fixedSquares(String predictedFen, String confirmedFen) {
  List<String> expand(String fen) {
    final out = <String>[];
    for (final row in fen.split(' ').first.split('/')) {
      for (final ch in row.split('')) {
        final digit = int.tryParse(ch);
        if (digit != null) {
          out.addAll(List.filled(digit, ' '));
        } else {
          out.add(ch);
        }
      }
    }
    return out;
  }

  final predicted = expand(predictedFen);
  final confirmed = expand(confirmedFen);
  if (predicted.length != 64 || confirmed.length != 64) return 64;
  var wrong = 0;
  for (var i = 0; i < 64; i++) {
    if (predicted[i] != confirmed[i]) wrong++;
  }
  return wrong;
}

/// Step 2: confirm/fix the recognized position, set whose turn, then analyze.
class ConfirmScreen extends StatefulWidget {
  const ConfirmScreen({
    super.key,
    required this.photoPath,
    required this.recognition,
  });

  final String photoPath;
  final RecognitionResult recognition;

  @override
  State<ConfirmScreen> createState() => _ConfirmScreenState();
}

class _ConfirmScreenState extends State<ConfirmScreen> {
  late final SetupState setup;
  bool _confirmed = false;

  /// Start in the photo's own orientation: a Black's-perspective source
  /// shows flipped so board and photo match at a glance.
  late bool _flipped = widget.recognition.flippedDisplay;
  bool _photoVisible = false;

  /// The library entry this screen created/updated (auto-capture).
  SavedGame? _libraryEntry;
  Offset? _photoOffset; // null until first shown: placed top-right in build
  String? _lastFeedbackFen;

  @override
  void initState() {
    super.initState();
    setup = SetupState.fromFen(widget.recognition.fen);
    if (widget.recognition.turn != null) {
      setup.setTurn(widget.recognition.turn == 'w');
    } else {
      // a king in check fixes whose move it is — better default than
      // always-White; the user can still override
      final implied = setup.impliedTurn();
      if (implied != null) setup.setTurn(implied == 'w');
    }
    if (widget.recognition.fromMemory) {
      // this exact photo was confirmed before (server answered from feedback
      // memory) — open already confirmed, and don't re-send that correction
      _confirmed = true;
      _lastFeedbackFen = setup.toFen();
    }
    // any further edit invalidates a given confirmation
    setup.addListener(() {
      if (_confirmed) setState(() => _confirmed = false);
    });
  }

  @override
  void dispose() {
    setup.dispose();
    super.dispose();
  }

  void _analyze() {
    final problem = setup.validationError();
    if (problem != null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(problem)));
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) =>
            AnalysisScreen(fen: setup.toFen(), initialFlipped: _flipped),
      ),
    );
  }

  Future<void> _confirm() async {
    // a confirmed position becomes training ground truth AND may be
    // analyzed — never let an illegal position through
    final problem = setup.validationError();
    if (problem != null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(problem)));
      return;
    }
    // impossible-but-playable material on a photo of a real game usually
    // means a misread piece — nudge, don't block (composed teaching
    // positions are legitimate photos too)
    final material = setup.materialWarning();
    if (material != null) {
      final proceed =
          await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              title: const Text('Double-check the pieces'),
              content: Text(material),
              actions: [
                FilledButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('Fix position'),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('Confirm anyway'),
                ),
              ],
            ),
          ) ??
          false;
      if (!proceed || !mounted) return;
    }
    setState(() {
      _confirmed = true;
      _photoVisible = false; // confirming closes the reference photo
    });
    // fire-and-forget: the library write must never delay the check toast
    unawaited(_captureToLibrary());
    await _accuracyPopup();
    if (!mounted) return;
    final fen = setup.toFen();
    if (fen == _lastFeedbackFen) return;

    var consent = await RecognizerClient.feedbackConsent();
    if (consent == null && mounted) {
      consent =
          await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              title: const Text('Help improve recognition?'),
              content: const Text(
                'When you confirm a position, seechess can send the photo '
                'together with the correction back to your recognition '
                'server. Confirmed corrections are what teach the model '
                'to read boards like yours. You can change this anytime '
                'by reinstalling.',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('No thanks'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('Share confirmations'),
                ),
              ],
            ),
          ) ??
          false;
      await RecognizerClient.setFeedbackConsent(consent);
    }
    if (consent != true) return;

    _lastFeedbackFen = fen;
    try {
      final url = await RecognizerClient.savedUrl();
      await RecognizerClient(url).sendFeedback(
        imageBytes: await File(widget.photoPath).readAsBytes(),
        predictedFen: widget.recognition.fen,
        correctedFen: fen,
        // how the user was viewing the board when confirming = how this
        // photo displays the position; memory serves it back on re-open
        flippedDisplay: _flipped,
      );
    } catch (_) {
      _lastFeedbackFen = null; // silent: feedback must never block the user
    }
  }

  /// Every confirmed position lands in the library automatically —
  /// confirmation is the quality gate that separates an attempt from a
  /// position worth keeping. Re-confirming updates the same entry.
  Future<void> _captureToLibrary() async {
    try {
      final now = DateTime.now();
      final existing = _libraryEntry;
      if (existing != null) {
        final updated = existing.copyWith(fen: setup.toFen(), modifiedAt: now);
        await SavedGamesStore().update(updated);
        _libraryEntry = updated;
        return;
      }
      final photo = await SavedGamesStore.keepPhoto(widget.photoPath);
      final entry = SavedGame(
        name:
            'Detected ${now.year}-${now.month.toString().padLeft(2, '0')}-'
            '${now.day.toString().padLeft(2, '0')} '
            '${now.hour.toString().padLeft(2, '0')}:'
            '${now.minute.toString().padLeft(2, '0')}',
        fen: setup.toFen(),
        createdAt: now,
        photoPath: photo,
      );
      await SavedGamesStore().add(entry);
      _libraryEntry = entry;
    } catch (_) {
      // the library must never block confirming
    }
  }

  /// Brief, action-free feedback the moment the user confirms: a green
  /// check plus one line, fading out on its own. (Was a dialog — Pablo:
  /// don't make the user tap anything.)
  Future<void> _accuracyPopup() async {
    final fixes = fixedSquares(widget.recognition.fen, setup.toFen());
    final String text;
    if (fixes == 0) {
      text = 'Detection was accurate';
    } else if (fixes < badDetectionThreshold) {
      text = 'Thanks for fixing $fixes square${fixes == 1 ? '' : 's'}';
    } else {
      text = 'Sorry — that was rough. Thanks for fixing $fixes squares';
    }
    final overlay = Overlay.of(context);
    final entry = OverlayEntry(builder: (context) => _FadingCheck(text: text));
    overlay.insert(entry);
    Future<void>.delayed(const Duration(milliseconds: 2200), entry.remove);
  }

  Future<void> _save() async {
    final nameController = TextEditingController();
    var keepPhoto = false;
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Save position'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameController,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'Name',
                  hintText: 'e.g. Park bench endgame',
                ),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Keep the photo'),
                subtitle: const Text('The position itself is always kept'),
                value: keepPhoto,
                onChanged: (v) => setDialogState(() => keepPhoto = v),
              ),
            ],
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
      ),
    );
    if (saved != true || !mounted) return;
    final name = nameController.text.trim().isEmpty
        ? 'Position ${DateTime.now().toString().substring(0, 16)}'
        : nameController.text.trim();
    String? photoPath;
    if (keepPhoto) {
      photoPath = await SavedGamesStore.keepPhoto(widget.photoPath);
    }
    await SavedGamesStore().add(
      SavedGame(
        name: name,
        fen: setup.toFen(),
        createdAt: DateTime.now(),
        photoPath: photoPath,
      ),
    );
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Saved "$name"')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Confirm'),
        actions: [
          CopyFenButton(fen: () => setup.toFen()),
          SharePositionButton(fen: () => setup.toFen()),
          IconButton(
            tooltip: 'Flip board (view only)',
            icon: const Icon(Icons.swap_vert),
            onPressed: () => setState(() => _flipped = !_flipped),
          ),
          IconButton(
            tooltip: 'Rotate position 90° (edits the position)',
            icon: const Icon(Icons.rotate_90_degrees_cw_outlined),
            onPressed: setup.rotate90,
          ),
          IconButton(
            tooltip: _photoVisible ? 'Hide photo' : 'Show photo',
            isSelected: _photoVisible,
            icon: const Icon(Icons.image_outlined),
            selectedIcon: const Icon(Icons.image),
            onPressed: () => setState(() => _photoVisible = !_photoVisible),
          ),
        ],
      ),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, bounds) => Stack(
            children: [
              _editor(theme),
              if (_photoVisible) _photoPanel(theme, bounds.biggest),
            ],
          ),
        ),
      ),
    );
  }

  Widget _editor(ThemeData theme) {
    return AnimatedBuilder(
      animation: setup,
      builder: (context, _) => Column(
        children: [
          // recognition warnings are developer telemetry, not user copy
          if (kDebugMode && widget.recognition.warnings.isNotEmpty)
            Container(
              width: double.infinity,
              color: theme.colorScheme.surfaceContainerHighest,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Text(
                'DEBUG · ${widget.recognition.warnings.join(' · ')}',
                style: theme.textTheme.bodySmall,
              ),
            ),
          Expanded(
            // everything around the board accepts drags: dropping a
            // piece outside the board deletes it
            child: DragTarget<String>(
              onAcceptWithDetails: (details) => setup.remove(details.data),
              builder: (context, candidates, rejected) => Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: ChessBoard(
                    pieces: setup.pieces,
                    flipped: _flipped,
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
                const Spacer(),
                const SizedBox(width: 12),
                // guide the eye: the one live next step breathes — Confirm
                // before confirmation, then Save and Analyze after it
                _Pulse(
                  active: !_confirmed,
                  child: _confirmed
                      ? FilledButton.icon(
                          style: FilledButton.styleFrom(
                            backgroundColor: const Color(0xFF2E7D32),
                            foregroundColor: Colors.white,
                          ),
                          icon: const Icon(Icons.check_circle),
                          label: const Text('Confirmed'),
                          onPressed: () => setState(() => _confirmed = false),
                        )
                      : FilledButton.icon(
                          style: FilledButton.styleFrom(
                            padding: const EdgeInsets.symmetric(horizontal: 14),
                          ),
                          icon: const Icon(Icons.check),
                          label: const Text('Confirm'),
                          onPressed: _confirm,
                        ),
                ),
                const SizedBox(width: 6),
                _Pulse(
                  active: _confirmed,
                  child: IconButton.filledTonal(
                    tooltip: 'Save',
                    icon: const Icon(Icons.bookmark_add),
                    onPressed: _confirmed ? _save : null,
                  ),
                ),
                const SizedBox(width: 4),
                _Pulse(
                  active: _confirmed,
                  child: IconButton.filledTonal(
                    tooltip: 'Analyze',
                    icon: const Icon(Icons.query_stats),
                    onPressed: _confirmed ? _analyze : null,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Floating photo panel: drag the handle bar to move the whole rectangle
  /// (to uncover the board behind it); pan/pinch inside to move the photo
  /// within it. Two independent gestures on purpose.
  Widget _photoPanel(ThemeData theme, Size bounds) {
    final width = (bounds.width * 0.72).clamp(220.0, 360.0);
    final height = width * 1.0;
    _photoOffset ??= Offset(bounds.width - width - 8, 8);
    final pos = Offset(
      _photoOffset!.dx.clamp(40.0 - width, bounds.width - 40.0),
      _photoOffset!.dy.clamp(0.0, bounds.height - 48.0),
    );
    return Positioned(
      left: pos.dx,
      top: pos.dy,
      child: Material(
        elevation: 10,
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        color: theme.colorScheme.surfaceContainerHighest,
        child: SizedBox(
          width: width,
          height: height,
          child: Column(
            children: [
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onPanUpdate: (d) =>
                    setState(() => _photoOffset = pos + d.delta),
                child: SizedBox(
                  height: 36,
                  child: Stack(
                    children: [
                      Center(
                        child: CustomPaint(
                          size: const Size(96, 14),
                          painter: _GripPainter(theme.colorScheme.outline),
                        ),
                      ),
                      Positioned(
                        right: 0,
                        top: 0,
                        bottom: 0,
                        child: InkWell(
                          onTap: () => setState(() => _photoVisible = false),
                          child: const Padding(
                            padding: EdgeInsets.all(8),
                            child: Icon(Icons.close, size: 20),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Expanded(
                child: InteractiveViewer(
                  maxScale: 8,
                  child: SizedBox.expand(
                    child: Image.file(
                      File(widget.photoPath),
                      fit: BoxFit.contain,
                    ),
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

/// Gentle repeating grow-shrink drawing a beginner's eye to the one live
/// next step. Inactive children render still at natural size.
class _Pulse extends StatefulWidget {
  const _Pulse({required this.active, required this.child});
  final bool active;
  final Widget child;

  @override
  State<_Pulse> createState() => _PulseState();
}

class _PulseState extends State<_Pulse> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 650),
  );
  late final Animation<double> _scale = Tween(
    begin: 1.0,
    end: 1.07,
  ).chain(CurveTween(curve: Curves.easeInOut)).animate(_controller);

  @override
  void initState() {
    super.initState();
    if (widget.active) _controller.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(covariant _Pulse old) {
    super.didUpdateWidget(old);
    if (widget.active && !_controller.isAnimating) {
      _controller.repeat(reverse: true);
    } else if (!widget.active && _controller.isAnimating) {
      _controller.stop();
      _controller.value = 0;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      ScaleTransition(scale: _scale, child: widget.child);
}

/// Continuous 2-row dot grid with uniform pitch — one grip texture, not a
/// row of icon glyphs with gaps between them.
class _GripPainter extends CustomPainter {
  const _GripPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    const pitch = 7.0;
    final cols = (size.width / pitch).floor();
    final x0 = (size.width - (cols - 1) * pitch) / 2;
    for (var row = 0; row < 2; row++) {
      final y = size.height / 2 + (row - 0.5) * pitch;
      for (var col = 0; col < cols; col++) {
        canvas.drawCircle(Offset(x0 + col * pitch, y), 1.6, paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _GripPainter old) => old.color != color;
}

/// Green check + one line that appears centered and fades away on its own.
class _FadingCheck extends StatefulWidget {
  const _FadingCheck({required this.text});
  final String text;

  @override
  State<_FadingCheck> createState() => _FadingCheckState();
}

class _FadingCheckState extends State<_FadingCheck>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2100),
  )..forward();

  // pop in quickly, hold, fade out
  late final Animation<double> _opacity = TweenSequence<double>([
    TweenSequenceItem(tween: Tween(begin: 0, end: 1), weight: 12),
    TweenSequenceItem(tween: ConstantTween(1), weight: 48),
    TweenSequenceItem(tween: Tween(begin: 1, end: 0), weight: 40),
  ]).animate(_c);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: IgnorePointer(
        child: FadeTransition(
          opacity: _opacity,
          child: Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
              decoration: BoxDecoration(
                color: const Color(0xE6222420),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.check_circle,
                    color: Color(0xFF7FC96B),
                    size: 44,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    widget.text,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
