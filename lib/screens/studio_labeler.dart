import 'package:flutter/material.dart';

import '../services/dataset.dart';
import '../widgets/board.dart' show pieceImage;

/// The phone-first labeler: pick a batch (one board style per reel),
/// correct the model's reading square by square with a paint palette,
/// save, next. Corner fixes are four taps on the image (a8 h8 h1 a1).
class StudioLabelerScreen extends StatefulWidget {
  const StudioLabelerScreen({super.key});

  @override
  State<StudioLabelerScreen> createState() => _StudioLabelerScreenState();
}

const _palette = [
  'wP',
  'wN',
  'wB',
  'wR',
  'wQ',
  'wK',
  'bP',
  'bN',
  'bB',
  'bR',
  'bQ',
  'bK',
  '',
];

class _StudioLabelerScreenState extends State<StudioLabelerScreen> {
  List<DatasetEntry> _all = const [];
  String? _base;
  String _batch = '';
  bool _unlabeledOnly = true;
  int _index = 0;
  Map<String, String> _pieces = {};
  String _brush = 'wP';
  bool _cornersMode = false;
  final List<List<double>> _cornerTaps = [];
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
    _cornerTaps.clear();
    _cornersMode = false;
    _status = null;
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
    final ok = await saveCorrection(e.id, _mapToFen(_pieces));
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (ok) {
        e.correctedFen = _mapToFen(_pieces);
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

  Future<void> _onImageTap(TapDownDetails d, Size size) async {
    if (!_cornersMode) return;
    final x = (d.localPosition.dx / size.width).clamp(0.0, 1.0);
    final y = (d.localPosition.dy / size.height).clamp(0.0, 1.0);
    setState(() => _cornerTaps.add([x, y]));
    if (_cornerTaps.length == 4) {
      final e = _current!;
      setState(() => _busy = true);
      final ok = await saveCorners(e.id, List.of(_cornerTaps));
      DatasetEntry? fresh;
      if (ok) fresh = await fetchEntry(e.id);
      if (!mounted) return;
      setState(() {
        _busy = false;
        _cornersMode = false;
        _cornerTaps.clear();
        if (fresh != null) {
          final i = _all.indexWhere((x) => x.id == e.id);
          if (i >= 0) _all[i] = fresh;
          _status = 'Corners saved — prediction refreshed';
          _syncBoard();
        } else {
          _status = ok ? 'Corners saved' : 'Corner save failed';
        }
      });
    }
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
                    flex: 5,
                    child: InteractiveViewer(
                      maxScale: 6,
                      // taps normalize against the exact image rect, so
                      // the picture is constrained to its own aspect
                      // ratio instead of letterboxing inside the slot
                      child: Center(
                        child: _imgSize == null
                            ? Image.network(
                                '$_base/v1/dataset/${e.id}/display',
                                fit: BoxFit.contain,
                                gaplessPlayback: true,
                              )
                            : AspectRatio(
                                aspectRatio: _imgSize!.width / _imgSize!.height,
                                child: LayoutBuilder(
                                  builder: (context, box) => GestureDetector(
                                    onTapDown: (d) =>
                                        _onImageTap(d, box.biggest),
                                    child: Stack(
                                      fit: StackFit.expand,
                                      children: [
                                        Image.network(
                                          '$_base/v1/dataset/${e.id}/display',
                                          fit: BoxFit.fill,
                                          gaplessPlayback: true,
                                        ),
                                        for (final c in _cornerTaps)
                                          Positioned(
                                            left: c[0] * box.biggest.width - 8,
                                            top: c[1] * box.biggest.height - 8,
                                            child: Container(
                                              width: 16,
                                              height: 16,
                                              decoration: BoxDecoration(
                                                shape: BoxShape.circle,
                                                border: Border.all(
                                                  color: Colors.redAccent,
                                                  width: 3,
                                                ),
                                              ),
                                            ),
                                          ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                      ),
                    ),
                  ),
                  if (_cornersMode)
                    Padding(
                      padding: const EdgeInsets.all(4),
                      child: Text(
                        'tap corner ${['a8', 'h8', 'h1', 'a1'][_cornerTaps.length.clamp(0, 3)]}'
                        ' (${_cornerTaps.length}/4)',
                        style: TextStyle(color: theme.colorScheme.error),
                      ),
                    ),
                  Expanded(
                    flex: 6,
                    child: Center(
                      child: AspectRatio(aspectRatio: 1, child: _grid(theme)),
                    ),
                  ),
                  SizedBox(
                    height: 52,
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      children: [
                        for (final p in _palette)
                          Padding(
                            padding: const EdgeInsets.all(3),
                            child: InkWell(
                              onTap: () => setState(() => _brush = p),
                              child: Container(
                                width: 44,
                                alignment: Alignment.center,
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(
                                    width: 2,
                                    color: _brush == p
                                        ? theme.colorScheme.primary
                                        : theme.colorScheme.outlineVariant,
                                  ),
                                ),
                                child: p.isEmpty
                                    ? const Icon(Icons.close, size: 20)
                                    : pieceImage(p, 32),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
                    child: Row(
                      children: [
                        IconButton(
                          tooltip: 'Fix board corners (4 taps: a8 h8 h1 a1)',
                          isSelected: _cornersMode,
                          icon: const Icon(Icons.crop_free),
                          onPressed: () => setState(() {
                            _cornersMode = !_cornersMode;
                            _cornerTaps.clear();
                          }),
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
                        return InkWell(
                          onTap: () => setState(() {
                            if (_brush.isEmpty) {
                              _pieces.remove(sq);
                            } else if (_pieces[sq] == _brush) {
                              // tapping with the same brush erases — quick
                              // toggle without switching to the eraser
                              _pieces.remove(sq);
                            } else {
                              _pieces[sq] = _brush;
                            }
                          }),
                          child: Container(
                            color: light
                                ? const Color(0xFFF0D9B5)
                                : const Color(0xFFB58863),
                            alignment: Alignment.center,
                            child: p == null
                                ? null
                                : FittedBox(child: pieceImage(p, 40)),
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
