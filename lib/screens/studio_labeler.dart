import 'package:flutter/material.dart';

import '../services/dataset.dart';
import '../widgets/board.dart' show pieceImage;
import '../widgets/setup_palette.dart' show YinYangPainter;

/// The phone-first labeler: pick a batch (one board style per reel),
/// correct the model's reading square by square with a paint palette,
/// save, next. Corner fixes are four taps on the image (a8 h8 h1 a1).
class StudioLabelerScreen extends StatefulWidget {
  const StudioLabelerScreen({super.key});

  @override
  State<StudioLabelerScreen> createState() => _StudioLabelerScreenState();
}

class _StudioLabelerScreenState extends State<StudioLabelerScreen> {
  List<DatasetEntry> _all = const [];
  String? _base;
  String _batch = '';
  bool _unlabeledOnly = true;
  int _index = 0;
  Map<String, String> _pieces = {};
  // per-square training marks: piece caught mid-move (video frame) and
  // exceptional background color (usually the GUI's last-move highlight)
  Set<String> _transit = {};
  Set<String> _hl = {};
  // unsaved board edits: a corners save must not wipe them by resyncing
  // to the server's (re-predicted) FEN
  bool _boardDirty = false;
  // same palette model as the app's position editor: one color at a
  // time, a piece-type tool or the eraser; double-tap flips colors
  bool _paletteWhite = true;
  String _tool = 'P';
  bool _cornersMode = false;

  /// Draggable corner handles, normalized 0..1, order a8 h8 h1 a1.
  List<List<double>> _handles = const [];
  int? _dragIdx;
  Offset _dragOff = Offset.zero;
  double _lastScale = 1.0;
  int _lastPtrCount = 1;
  final TransformationController _viewCtrl = TransformationController();
  static const _cornerNames = ['a8', 'h8', 'h1', 'a1'];
  bool _busy = false;
  String? _status;
  Size? _imgSize;
  ImageStreamListener? _imgListener;

  void _resolveImageSize(String url) {
    _imgSize = null;
    final stream = NetworkImage(url).resolve(ImageConfiguration.empty);
    _imgListener = ImageStreamListener((info, _) {
      if (mounted) {
        setState(
          () => _imgSize = Size(
            info.image.width.toDouble(),
            info.image.height.toDouble(),
          ),
        );
      }
    }, onError: (_, _) {});
    stream.addListener(_imgListener!);
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    _base = await datasetBase();
    final all = await fetchDataset();
    if (!mounted) return;
    setState(() {
      _all = all;
      final batches = _batches(all);
      if (_batch.isEmpty && batches.isNotEmpty) {
        // reel batches are the working set; newest style first
        _batch = batches.firstWhere(
          (b) => b.startsWith('reel-'),
          orElse: () => batches.first,
        );
      }
      _index = 0;
      _syncBoard();
    });
  }

  List<String> _batches(List<DatasetEntry> all) {
    final set = <String>{
      for (final e in all)
        if (e.batch.isNotEmpty) e.batch,
    };
    final out = set.toList()..sort();
    return out;
  }

  List<DatasetEntry> get _items => [
    for (final e in _all)
      if ((e.batch == _batch) && (!_unlabeledOnly || !e.labeled)) e,
  ];

  DatasetEntry? get _current {
    final items = _items;
    if (items.isEmpty) return null;
    return items[_index.clamp(0, items.length - 1)];
  }

  void _syncBoard() {
    final e = _current;
    if (e != null && _base != null) {
      _resolveImageSize('$_base/v1/dataset/${e.id}/display');
    }
    _pieces = e == null
        ? {}
        : _fenToMap(
            e.correctedFen?.isNotEmpty == true
                ? e.correctedFen!
                : e.predictedFen,
          );
    _transit = {...?e?.transit};
    _hl = {...?e?.highlight};
    _boardDirty = false;
    _cornersMode = false;
    _viewCtrl.value = Matrix4.identity();
    _status = null;
    WidgetsBinding.instance.addPostFrameCallback((_) => _prefetch());
  }

  /// Warm the image cache around the current index so Next/Previous
  /// show instantly instead of waiting on the network.
  void _prefetch() {
    if (!mounted || _base == null) return;
    final items = _items;
    for (final j in [for (var d = 1; d <= 8; d++) _index + d, _index - 1]) {
      if (j < 0 || j >= items.length) continue;
      precacheImage(
        NetworkImage('$_base/v1/dataset/${items[j].id}/display'),
        context,
      );
    }
  }

  static Map<String, String> _fenToMap(String placement) {
    final out = <String, String>{};
    final ranks = placement.split('/');
    if (ranks.length != 8) return out;
    for (var r = 0; r < 8; r++) {
      var file = 0;
      for (final ch in ranks[r].split('')) {
        final d = int.tryParse(ch);
        if (d != null) {
          file += d;
        } else {
          final sq = '${'abcdefgh'[file]}${8 - r}';
          final white = ch.toUpperCase() == ch;
          out[sq] = '${white ? 'w' : 'b'}${ch.toUpperCase()}';
          file++;
        }
      }
    }
    return out;
  }

  static String _mapToFen(Map<String, String> pieces) {
    final rows = <String>[];
    for (var r = 8; r >= 1; r--) {
      var row = '';
      var empty = 0;
      for (var f = 0; f < 8; f++) {
        final p = pieces['${'abcdefgh'[f]}$r'];
        if (p == null) {
          empty++;
        } else {
          if (empty > 0) {
            row += '$empty';
            empty = 0;
          }
          final letter = p[1];
          row += p[0] == 'w' ? letter : letter.toLowerCase();
        }
      }
      if (empty > 0) row += '$empty';
      rows.add(row);
    }
    return rows.join('/');
  }

  Future<void> _save() async {
    final e = _current;
    if (e == null || _busy) return;
    setState(() => _busy = true);
    final ok =
        await saveCorrection(e.id, _mapToFen(_pieces)) &&
        await saveSquareMarks(e.id, _transit, _hl);
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (ok) {
        e.correctedFen = _mapToFen(_pieces);
        e.transit = {..._transit};
        e.highlight = {..._hl};
        _status = 'Saved ✓';
        if (_unlabeledOnly) {
          // the list shrank under us; stay at the same index
          if (_index >= _items.length) _index = 0;
        } else if (_index < _items.length - 1) {
          _index++;
        }
        _syncBoard();
      } else {
        _status = 'Save failed — check connection';
      }
    });
  }

  Future<void> _discard() async {
    final e = _current;
    if (e == null || _busy) return;
    final sure = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Discard this image?'),
        content: const Text(
          'Removes it from the training set for good — for boards '
          'we decided not to support.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('Discard'),
          ),
        ],
      ),
    );
    if (sure != true || !mounted) return;
    setState(() => _busy = true);
    final ok = await deleteEntry(e.id);
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (ok) {
        _all.removeWhere((x) => x.id == e.id);
        if (_index >= _items.length) _index = 0;
        _status = 'Image discarded';
        _syncBoard();
      } else {
        _status = 'Discard failed — check connection';
      }
    });
  }

  void _enterCorners() {
    final e = _current;
    final stored = e?.corners;
    _handles = stored != null
        ? [
            for (final c in stored) [c[0], c[1]],
          ]
        : [
            [0.1, 0.1],
            [0.9, 0.1],
            [0.9, 0.9],
            [0.1, 0.9],
          ];
    _cornersMode = true;
    _status = 'drag a8 h8 h1 a1 onto the board corners, then Save corners';
  }

  Future<void> _saveCorners() async {
    final e = _current;
    if (e == null || _busy) return;
    setState(() => _busy = true);
    final ok = await saveCorners(e.id, List.of(_handles));
    DatasetEntry? fresh;
    if (ok) fresh = await fetchEntry(e.id);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _cornersMode = false;
      _viewCtrl.value = Matrix4.identity();
      if (fresh != null) {
        final i = _all.indexWhere((x) => x.id == e.id);
        if (i >= 0) _all[i] = fresh;
        if (_boardDirty) {
          // keep the operator's unsaved piece/mark edits
          _status = 'Corners saved';
        } else {
          _status = 'Corners saved — prediction refreshed';
          _syncBoard();
        }
      } else {
        _status = ok ? 'Corners saved' : 'Corner save failed';
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final items = _items;
    final e = _current;
    final batches = _batches(_all);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Labeler'),
        actions: [
          IconButton(
            tooltip: _unlabeledOnly
                ? 'Showing unlabeled — tap for all'
                : 'Showing all — tap for unlabeled only',
            isSelected: _unlabeledOnly,
            icon: const Icon(Icons.filter_alt_outlined),
            selectedIcon: const Icon(Icons.filter_alt),
            onPressed: () => setState(() {
              _unlabeledOnly = !_unlabeledOnly;
              _index = 0;
              _syncBoard();
            }),
          ),
          IconButton(
            tooltip: 'Reload',
            icon: const Icon(Icons.refresh),
            onPressed: _load,
          ),
        ],
      ),
      body: _all.isEmpty
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Row(
                    children: [
                      Expanded(
                        child: DropdownButton<String>(
                          value: batches.contains(_batch) ? _batch : null,
                          isExpanded: true,
                          hint: const Text('batch'),
                          items: [
                            for (final b in batches)
                              DropdownMenuItem(value: b, child: Text(b)),
                          ],
                          onChanged: (v) => setState(() {
                            _batch = v ?? '';
                            _index = 0;
                            _syncBoard();
                          }),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Text(
                        items.isEmpty ? '0/0' : '${_index + 1}/${items.length}',
                        style: theme.textTheme.labelLarge,
                      ),
                    ],
                  ),
                ),
                if (e == null)
                  const Expanded(child: Center(child: Text('Batch is done 🎉')))
                else ...[
                  Expanded(
                    flex: 7,
                    child: Container(
                      decoration: _cornersMode
                          ? BoxDecoration(
                              border: Border.all(
                                color: theme.colorScheme.error,
                                width: 3,
                              ),
                            )
                          : null,
                      child: InteractiveViewer(
                        maxScale: 12,
                        transformationController: _viewCtrl,
                        // all gestures live in the GestureDetector below so
                        // zoom/pan behave the same in and out of corners mode
                        panEnabled: false,
                        scaleEnabled: false,
                        child: Center(
                          child: _imgSize == null
                              ? Image.network(
                                  '$_base/v1/dataset/${e.id}/display',
                                  fit: BoxFit.contain,
                                  gaplessPlayback: true,
                                )
                              : AspectRatio(
                                  aspectRatio:
                                      _imgSize!.width / _imgSize!.height,
                                  child: LayoutBuilder(
                                    builder: (context, box) {
                                      return GestureDetector(
                                        onScaleStart: (d) {
                                          _lastScale = 1.0;
                                          _lastPtrCount = d.pointerCount;
                                          _dragIdx = null;
                                          if (!_cornersMode ||
                                              d.pointerCount != 1) {
                                            return;
                                          }
                                          var best = -1;
                                          // grab radius constant on
                                          // screen, not on the image
                                          var bestDist =
                                              56.0 /
                                              _viewCtrl.value
                                                  .getMaxScaleOnAxis();
                                          for (var i = 0; i < 4; i++) {
                                            final h = Offset(
                                              _handles[i][0] *
                                                  box.biggest.width,
                                              _handles[i][1] *
                                                  box.biggest.height,
                                            );
                                            final dist = (d.localFocalPoint - h)
                                                .distance;
                                            if (dist < bestDist) {
                                              bestDist = dist;
                                              best = i;
                                              _dragOff = h - d.localFocalPoint;
                                            }
                                          }
                                          _dragIdx = best >= 0 ? best : null;
                                        },
                                        onScaleUpdate: (d) {
                                          final i = _dragIdx;
                                          if (_cornersMode &&
                                              i != null &&
                                              d.pointerCount == 1) {
                                            // relative drag: the handle
                                            // keeps its grab offset so
                                            // it never jumps under the
                                            // finger and stays visible
                                            final pos =
                                                d.localFocalPoint + _dragOff;
                                            setState(() {
                                              _handles[i][0] =
                                                  (pos.dx / box.biggest.width)
                                                      .clamp(0.0, 1.0);
                                              _handles[i][1] =
                                                  (pos.dy / box.biggest.height)
                                                      .clamp(0.0, 1.0);
                                            });
                                            return;
                                          }
                                          // corners mode: one finger
                                          // only ever moves a handle;
                                          // the image needs two fingers.
                                          // outside corners mode one
                                          // finger pans freely
                                          if (_cornersMode &&
                                              d.pointerCount < 2) {
                                            _lastPtrCount = d.pointerCount;
                                            return;
                                          }
                                          if (d.pointerCount != _lastPtrCount) {
                                            // scale baseline resets
                                            // when a finger lands/lifts
                                            _lastPtrCount = d.pointerCount;
                                            _lastScale = d.scale;
                                          }
                                          final m = Matrix4.copy(
                                            _viewCtrl.value,
                                          );
                                          final cur = m.getMaxScaleOnAxis();
                                          var s = d.scale / _lastScale;
                                          _lastScale = d.scale;
                                          final target = (cur * s).clamp(
                                            1.0,
                                            12.0,
                                          );
                                          s = target / cur;
                                          // deadband: finger-spacing
                                          // noise while panning must
                                          // not jitter the zoom
                                          if ((s - 1).abs() < 0.004) {
                                            s = 1;
                                          }
                                          final p = d.localFocalPoint;
                                          m
                                            ..translateByDouble(
                                              p.dx,
                                              p.dy,
                                              0,
                                              1,
                                            )
                                            ..scaleByDouble(s, s, 1, 1)
                                            ..translateByDouble(
                                              -p.dx,
                                              -p.dy,
                                              0,
                                              1,
                                            )
                                            // focalPointDelta arrives
                                            // already in image-local
                                            // coords (the detector sits
                                            // inside the transform), so
                                            // it applies as-is: dividing
                                            // by the zoom again made the
                                            // pan crawl when zoomed in
                                            ..translateByDouble(
                                              d.focalPointDelta.dx,
                                              d.focalPointDelta.dy,
                                              0,
                                              1,
                                            );
                                          _viewCtrl.value = m;
                                        },
                                        onScaleEnd: (_) => _dragIdx = null,
                                        child: Stack(
                                          fit: StackFit.expand,
                                          children: [
                                            Image.network(
                                              '$_base/v1/dataset/${e.id}/display',
                                              fit: BoxFit.fill,
                                              gaplessPlayback: true,
                                            ),
                                            // saved corners stay visible
                                            if (!_cornersMode &&
                                                e.corners != null)
                                              for (var i = 0; i < 4; i++)
                                                Positioned(
                                                  left:
                                                      e.corners![i][0] *
                                                          box.biggest.width -
                                                      9,
                                                  top:
                                                      e.corners![i][1] *
                                                          box.biggest.height -
                                                      9,
                                                  child: IgnorePointer(
                                                    child: _cornerDot(
                                                      _cornerNames[i],
                                                      18,
                                                      Colors.lightGreen,
                                                    ),
                                                  ),
                                                ),
                                            if (_cornersMode)
                                              for (var i = 0; i < 4; i++)
                                                Positioned(
                                                  left:
                                                      _handles[i][0] *
                                                          box.biggest.width -
                                                      16,
                                                  top:
                                                      _handles[i][1] *
                                                          box.biggest.height -
                                                      16,
                                                  child: IgnorePointer(
                                                    child: _cornerDot(
                                                      _cornerNames[i],
                                                      32,
                                                      Colors.redAccent,
                                                    ),
                                                  ),
                                                ),
                                          ],
                                        ),
                                      );
                                    },
                                  ),
                                ),
                        ),
                      ),
                    ),
                  ),
                  Expanded(
                    flex: 5,
                    child: Center(
                      child: AspectRatio(
                        aspectRatio: 1,
                        child: Opacity(
                          opacity: _cornersMode ? 0.35 : 1,
                          child: _grid(theme),
                        ),
                      ),
                    ),
                  ),
                  GestureDetector(
                    onDoubleTap: () =>
                        setState(() => _paletteWhite = !_paletteWhite),
                    behavior: HitTestBehavior.opaque,
                    child: SizedBox(
                      height: 52,
                      child: ListView(
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        children: [
                          for (final kind in const [
                            'K',
                            'Q',
                            'R',
                            'B',
                            'N',
                            'P',
                            'erase',
                            'transit',
                            'hl',
                          ])
                            Padding(
                              padding: const EdgeInsets.all(3),
                              child: Builder(
                                builder: (context) {
                                  final chip = InkWell(
                                    onTap: () => setState(() => _tool = kind),
                                    child: Container(
                                      width: 44,
                                      alignment: Alignment.center,
                                      decoration: BoxDecoration(
                                        borderRadius: BorderRadius.circular(8),
                                        border: Border.all(
                                          width: 2,
                                          color: _tool == kind
                                              ? theme.colorScheme.primary
                                              : theme
                                                    .colorScheme
                                                    .outlineVariant,
                                        ),
                                      ),
                                      child: kind == 'erase'
                                          ? Icon(
                                              Icons.cleaning_services_outlined,
                                              size: 22,
                                              color: theme.colorScheme.error,
                                            )
                                          : kind == 'transit'
                                          // piece caught mid-move
                                          ? const Icon(
                                              Icons.motion_photos_on,
                                              size: 22,
                                              color: Color(0xFF7B1FA2),
                                            )
                                          : kind == 'hl'
                                          // last-move highlight square
                                          ? const Icon(
                                              Icons.format_color_fill,
                                              size: 22,
                                              color: Color(0xFFFFA000),
                                            )
                                          : pieceImage(
                                              '${_paletteWhite ? 'w' : 'b'}$kind',
                                              32,
                                            ),
                                    ),
                                  );
                                  if (kind == 'erase' ||
                                      kind == 'transit' ||
                                      kind == 'hl') {
                                    return chip;
                                  }
                                  final code =
                                      '${_paletteWhite ? 'w' : 'b'}$kind';
                                  // drag straight onto a square, like the
                                  // position editor's palette
                                  return Draggable<String>(
                                    data: code,
                                    feedback: pieceImage(code, 52),
                                    childWhenDragging: Opacity(
                                      opacity: 0.4,
                                      child: chip,
                                    ),
                                    child: chip,
                                  );
                                },
                              ),
                            ),
                          Padding(
                            padding: const EdgeInsets.all(3),
                            child: InkWell(
                              onTap: () => setState(
                                () => _paletteWhite = !_paletteWhite,
                              ),
                              child: Container(
                                width: 44,
                                alignment: Alignment.center,
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(
                                    width: 2,
                                    color: theme.colorScheme.outlineVariant,
                                  ),
                                ),
                                child: const CustomPaint(
                                  size: Size(28, 28),
                                  painter: YinYangPainter(),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
                    child: Row(
                      children: [
                        IconButton(
                          tooltip: 'Previous',
                          icon: const Icon(Icons.skip_previous),
                          onPressed: items.length < 2
                              ? null
                              : () => setState(() {
                                  _index =
                                      (_index - 1 + items.length) %
                                      items.length;
                                  _syncBoard();
                                }),
                        ),
                        OutlinedButton.icon(
                          icon: Icon(
                            Icons.crop_free,
                            size: 18,
                            color: _cornersMode
                                ? theme.colorScheme.error
                                : null,
                          ),
                          label: Text(
                            _cornersMode ? 'Save corners' : 'Corners',
                          ),
                          onPressed: _busy
                              ? null
                              : () {
                                  if (_cornersMode) {
                                    _saveCorners();
                                  } else {
                                    setState(_enterCorners);
                                  }
                                },
                        ),
                        if (_cornersMode)
                          TextButton(
                            onPressed: () => setState(() {
                              _cornersMode = false;
                              _viewCtrl.value = Matrix4.identity();
                            }),
                            child: const Text('Cancel'),
                          ),
                        const SizedBox(width: 4),
                        IconButton(
                          tooltip: 'Discard image',
                          icon: Icon(
                            Icons.delete_outline,
                            color: theme.colorScheme.error,
                          ),
                          onPressed: _busy ? null : _discard,
                        ),
                        IconButton(
                          tooltip: 'Skip',
                          icon: const Icon(Icons.skip_next),
                          onPressed: items.length < 2
                              ? null
                              : () => setState(() {
                                  _index = (_index + 1) % items.length;
                                  _syncBoard();
                                }),
                        ),
                        if (_status != null)
                          Expanded(
                            child: Text(
                              _status!,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.labelMedium,
                            ),
                          )
                        else
                          const Spacer(),
                        FilledButton.icon(
                          onPressed: _busy ? null : _save,
                          icon: _busy
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.check),
                          label: const Text('Save & next'),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
    );
  }

  Widget _cornerDot(String name, double size, Color color) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: Colors.black38,
        border: Border.all(color: color, width: 3),
      ),
      child: Stack(
        alignment: Alignment.center,
        children: [
          // 45°-rotated cross: its intersection pinpoints the exact
          // corner without hiding it behind axis-aligned lines
          CustomPaint(
            size: Size.square(size * 0.72),
            painter: _DiagCrossPainter(color),
          ),
          Align(
            alignment: const Alignment(0, -0.62),
            child: Text(
              name,
              style: TextStyle(
                fontSize: size * 0.26,
                fontWeight: FontWeight.w700,
                color: Colors.white,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _grid(ThemeData theme) {
    return Column(
      children: [
        for (var r = 8; r >= 1; r--)
          Expanded(
            child: Row(
              children: [
                for (var f = 0; f < 8; f++)
                  Expanded(
                    child: Builder(
                      builder: (context) {
                        final sq = '${'abcdefgh'[f]}$r';
                        final light = (f + r) % 2 == 1;
                        final p = _pieces[sq];
                        return DragTarget<String>(
                          onAcceptWithDetails: (d) => setState(() {
                            _pieces[sq] = d.data;
                            _boardDirty = true;
                          }),
                          builder: (context, cand, rej) => InkWell(
                            onTap: () => setState(() {
                              if (_cornersMode) {
                                _status =
                                    'Corners are marked on the PHOTO '
                                    'above — tap the board corners in '
                                    'the image';
                                return;
                              }
                              _boardDirty = true;
                              if (_tool == 'transit') {
                                _transit.contains(sq)
                                    ? _transit.remove(sq)
                                    : _transit.add(sq);
                              } else if (_tool == 'hl') {
                                _hl.contains(sq) ? _hl.remove(sq) : _hl.add(sq);
                              } else if (_tool == 'erase') {
                                _pieces.remove(sq);
                                _transit.remove(sq);
                                _hl.remove(sq);
                              } else {
                                final brush =
                                    '${_paletteWhite ? 'w' : 'b'}$_tool';
                                if (_pieces[sq] == brush) {
                                  _pieces.remove(sq);
                                } else {
                                  _pieces[sq] = brush;
                                }
                              }
                            }),
                            // like the board editor: double-tap flips the
                            // piece's color in place
                            onDoubleTap: () => setState(() {
                              if (_cornersMode) return;
                              final p = _pieces[sq];
                              if (p != null) {
                                _pieces[sq] =
                                    '${p[0] == 'w' ? 'b' : 'w'}${p[1]}';
                                _boardDirty = true;
                              }
                            }),
                            child: Container(
                              color: light
                                  ? const Color(0xFFF0D9B5)
                                  : const Color(0xFFB58863),
                              child: Stack(
                                fit: StackFit.expand,
                                children: [
                                  // amber wash = exceptional background
                                  // (last-move highlight) in the photo
                                  if (_hl.contains(sq))
                                    Container(color: const Color(0x66FFA000)),
                                  if (p != null)
                                    FittedBox(child: pieceImage(p, 40)),
                                  // mid-move piece badge
                                  if (_transit.contains(sq))
                                    const Positioned(
                                      top: 1,
                                      right: 1,
                                      child: Icon(
                                        Icons.motion_photos_on,
                                        size: 12,
                                        color: Color(0xFF7B1FA2),
                                      ),
                                    ),
                                  // coordinates, like the real board
                                  if (f == 0)
                                    Positioned(
                                      top: 1,
                                      left: 2,
                                      child: Text(
                                        '$r',
                                        style: TextStyle(
                                          fontSize: 9,
                                          fontWeight: FontWeight.w700,
                                          color: light
                                              ? const Color(0xFFB58863)
                                              : const Color(0xFFF0D9B5),
                                        ),
                                      ),
                                    ),
                                  if (r == 1)
                                    Positioned(
                                      bottom: 0,
                                      right: 2,
                                      child: Text(
                                        'abcdefgh'[f],
                                        style: TextStyle(
                                          fontSize: 9,
                                          fontWeight: FontWeight.w700,
                                          color: light
                                              ? const Color(0xFFB58863)
                                              : const Color(0xFFF0D9B5),
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

class _DiagCrossPainter extends CustomPainter {
  const _DiagCrossPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = color
      ..strokeWidth = 2;
    canvas.drawLine(Offset.zero, Offset(size.width, size.height), p);
    canvas.drawLine(Offset(size.width, 0), Offset(0, size.height), p);
  }

  @override
  bool shouldRepaint(covariant _DiagCrossPainter old) => old.color != color;
}
