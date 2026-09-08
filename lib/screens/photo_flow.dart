import 'dart:async';
import 'package:universal_io/io.dart';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:crop_your_image/crop_your_image.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';

import '../services/clipboard_image.dart';
import '../services/photo_bytes.dart';
import '../services/recent_photos.dart';
import '../services/recognizer.dart';
import 'confirm.dart';

/// Step 1 of "Analyze a photo": take or choose a picture, send it to the
/// recognition service, then hand off to the confirm screen.
class PhotoFlowScreen extends StatefulWidget {
  const PhotoFlowScreen({super.key, this.sharedImagePath});

  /// An image handed to the app by the OS share sheet / "open with": run
  /// recognition on it right away instead of waiting for a pick.
  final String? sharedImagePath;

  @override
  State<PhotoFlowScreen> createState() => _PhotoFlowScreenState();
}

class _PhotoFlowScreenState extends State<PhotoFlowScreen> {
  final _picker = ImagePicker();
  bool _busy = false;
  String? _error;
  String _phase = '';
  List<File> _recents = const [];

  /// Edit mode for the recents strip: thumbnails grow an × badge.
  bool _editingRecents = false;

  @override
  void initState() {
    super.initState();
    if (widget.sharedImagePath != null) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _ingestShared(widget.sharedImagePath!),
      );
    }
    _loadRecents();
    if (kIsWeb) {
      // Ctrl/Cmd+V anywhere on this screen recognizes the pasted image
      listenForImagePaste((bytes) {
        if (mounted) _fromBytes(bytes);
      });
    }
  }

  /// Shared entry for clipboard images (button and paste event).
  Future<void> _fromBytes(Uint8List bytes) async {
    setState(() {
      _busy = true;
      _error = null;
      _phase = '';
    });
    try {
      final path = storeWebPhotoBytes(bytes);
      if (!mounted) return;
      final edited = await editPhoto(context, path);
      if (edited == null) return;
      await _recognize(edited);
    } catch (e) {
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pasteImage() async {
    final bytes = await readClipboardImage();
    if (bytes == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'No image in the clipboard — copy one, or press Ctrl/Cmd+V',
            ),
          ),
        );
      }
      return;
    }
    await _fromBytes(bytes);
  }

  Future<void> _loadRecents() async {
    final recents = await RecentPhotos.list();
    if (mounted) setState(() => _recents = recents);
  }

  @override
  void dispose() {
    stopImagePasteListener();
    super.dispose();
  }

  Future<void> _pick(ImageSource source) async {
    setState(() {
      _busy = true;
      _error = null;
      _phase = '';
    });
    try {
      final file = await _picker.pickImage(
        source: source,
        maxWidth: 1600,
        imageQuality: 88,
      );
      if (file == null) return;
      // cache first: the copy is durable and lands in the recents strip
      // even if recognition fails (picker files live in purgeable tmp).
      // Web: no filesystem — bytes go to the in-memory registry.
      final String path;
      if (kIsWeb) {
        path = storeWebPhotoBytes(await file.readAsBytes());
      } else {
        path = await RecentPhotos.add(file.path);
      }
      await _loadRecents();
      if (!mounted) return;
      final edited = await editPhoto(context, path);
      if (edited == null) return;
      await _loadRecents();
      await _recognize(edited);
    } catch (e) {
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// A shared-in image: cache it like a picked one, then recognize.
  Future<void> _ingestShared(String path) async {
    setState(() {
      _busy = true;
      _error = null;
      _phase = '';
    });
    try {
      final cached = await RecentPhotos.add(path);
      await _loadRecents();
      if (!mounted) return;
      final edited = await editPhoto(context, cached);
      if (edited == null) return;
      await _loadRecents();
      await _recognize(edited);
    } catch (e) {
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _rerun(File photo) async {
    setState(() {
      _busy = true;
      _error = null;
      _phase = '';
    });
    try {
      if (!kIsWeb) photo.setLastModifiedSync(DateTime.now()); // bump front
      final edited = await editPhoto(context, photo.path);
      if (edited == null) return;
      await _recognize(edited);
      await _loadRecents();
    } catch (e) {
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _recognize(String path) async {
    final url = await RecognizerClient.savedUrl();
    final client = RecognizerClient(url);

    // 1. fast reachability check with one retry — the first request after
    // the cellular radio idles can miss a single window spuriously
    setState(() => _phase = 'Contacting server…');
    try {
      await client.ping();
    } catch (_) {
      try {
        await client.ping();
      } catch (e) {
        final lan =
            url.contains('.local') ||
            url.contains('192.168.') ||
            url.contains('localhost');
        final hint = lan
            ? 'Check that the phone and the server are on the same Wi-Fi '
                  'and that iOS has Local Network permission for seechess '
                  '(Settings → Privacy & Security → Local Network).'
            : 'Check your internet connection and that seechess is '
                  'allowed to use cellular data (Settings → Cellular).';
        throw 'Can\'t reach the recognition server at $url.\n$hint\n($e)';
      }
    }

    // 2. upload + recognize (server inference itself is ~0.1-1s)
    setState(() => _phase = 'Uploading & recognizing…');
    final sw = Stopwatch()..start();
    final bytes = await readPhotoBytes(path);
    final RecognitionResult result;
    try {
      result = await client.recognize(bytes);
    } on RecognizerException catch (e) {
      // the photo the model can't read is the training data we most lack —
      // rescue it (consent-gated inside) before surfacing the error
      if (e.statusCode == 422) {
        unawaited(
          client
              .sendRescue(imageBytes: bytes, error: e.message)
              .catchError((_) {}),
        );
      }
      rethrow;
    }
    debugPrint('recognize round-trip: ${sw.elapsedMilliseconds}ms');
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ConfirmScreen(photoPath: path, recognition: result),
      ),
    );
  }

  Future<void> _deleteRecent(File photo) async {
    await RecentPhotos.remove(photo);
    await _loadRecents();
    if (mounted && _recents.isEmpty) setState(() => _editingRecents = false);
  }

  Future<void> _clearRecents() async {
    final sure = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          _recents.length == 1
              ? 'Delete the only recent photo?'
              : 'Delete all ${_recents.length} recent photos?',
        ),
        content: const Text(
          'Only this list is cleared — saved games keep their photos.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete all'),
          ),
        ],
      ),
    );
    if (sure != true) return;
    await RecentPhotos.clear();
    await _loadRecents();
    if (mounted) setState(() => _editingRecents = false);
  }

  /// Long-press on a thumbnail: quick actions without entering edit mode.
  Future<void> _recentActions(File photo) async {
    await showModalBottomSheet<void>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: SizedBox(
                  height: 160,
                  child: photoImage(photo.path, fit: BoxFit.cover),
                ),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.replay),
              title: const Text('Analyze again'),
              onTap: () {
                Navigator.pop(context);
                _rerun(photo);
              },
            ),
            ListTile(
              leading: Icon(Icons.delete_outline, color: theme(context).error),
              title: const Text('Delete this photo'),
              onTap: () {
                Navigator.pop(context);
                _deleteRecent(photo);
              },
            ),
          ],
        ),
      ),
    );
  }

  static ColorScheme theme(BuildContext context) =>
      Theme.of(context).colorScheme;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Analyze a photo')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Spacer(),
              Icon(
                Icons.photo_camera_outlined,
                size: 96,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(height: 12),
              Text(
                'Photograph a chessboard\nand get instant analysis',
                textAlign: TextAlign.center,
                style: theme.textTheme.titleLarge,
              ),
              const SizedBox(height: 32),
              if (_busy)
                Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      children: [
                        const CircularProgressIndicator(),
                        const SizedBox(height: 12),
                        Text(_phase),
                      ],
                    ),
                  ),
                )
              else ...[
                FilledButton.icon(
                  icon: const Icon(Icons.photo_camera),
                  label: const Text('Take a photo'),
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                  onPressed: () => _pick(ImageSource.camera),
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  icon: const Icon(Icons.photo_library),
                  label: const Text('Choose from library'),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                  onPressed: () => _pick(ImageSource.gallery),
                ),
                if (kIsWeb) ...[
                  const SizedBox(height: 10),
                  OutlinedButton.icon(
                    icon: const Icon(Icons.content_paste),
                    label: const Text('Paste image  (or Ctrl/Cmd+V)'),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                    ),
                    onPressed: _busy ? null : _pasteImage,
                  ),
                ],
                if (_recents.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Text(
                        'Recently used',
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const Spacer(),
                      IconButton(
                        tooltip: _editingRecents ? 'Done' : 'Edit recents',
                        visualDensity: VisualDensity.compact,
                        icon: Icon(
                          _editingRecents ? Icons.check : Icons.edit_outlined,
                          size: 20,
                        ),
                        onPressed: () =>
                            setState(() => _editingRecents = !_editingRecents),
                      ),
                      IconButton(
                        tooltip: 'Delete all recents',
                        visualDensity: VisualDensity.compact,
                        icon: const Icon(Icons.delete_sweep_outlined, size: 20),
                        onPressed: _clearRecents,
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  SizedBox(
                    height: 72,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      itemCount: _recents.length,
                      separatorBuilder: (_, _) => const SizedBox(width: 8),
                      itemBuilder: (context, i) {
                        final photo = _recents[i];
                        return GestureDetector(
                          onTap: _editingRecents
                              ? () => _deleteRecent(photo)
                              : () => _rerun(photo),
                          onLongPress: () => _recentActions(photo),
                          child: Stack(
                            clipBehavior: Clip.none,
                            children: [
                              Padding(
                                padding: const EdgeInsets.only(
                                  top: 6,
                                  right: 6,
                                ),
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(8),
                                  child: SizedBox(
                                    width: 64,
                                    height: 64,
                                    child: photoImage(
                                      photo.path,
                                      fit: BoxFit.cover,
                                    ),
                                  ),
                                ),
                              ),
                              if (_editingRecents)
                                Positioned(
                                  top: 0,
                                  right: 0,
                                  child: Container(
                                    width: 22,
                                    height: 22,
                                    decoration: BoxDecoration(
                                      color: theme.colorScheme.error,
                                      shape: BoxShape.circle,
                                    ),
                                    child: Icon(
                                      Icons.close,
                                      size: 16,
                                      color: theme.colorScheme.onError,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ],
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 16),
                  child: Text(
                    _error!,
                    textAlign: TextAlign.center,
                    style: TextStyle(color: theme.colorScheme.error),
                  ),
                ),
              const Spacer(),
            ],
          ),
        ),
      ),
    );
  }
}

/// Crop/zoom the photo before detection (Pablo: "allow to crop, zoom and
/// edit after it's been taken, before it's sent"). Returns the path to
/// recognize — a new cached crop, the untouched original, or null on
/// cancel. Cropping tight around the board is also the best manual assist
/// the corner model can get.
Future<String?> editPhoto(BuildContext context, String path) async {
  final bytes = await readPhotoBytes(path);
  if (!context.mounted) return null;
  final cropped = await Navigator.of(context).push<Uint8List?>(
    MaterialPageRoute(builder: (_) => _PhotoEditorScreen(bytes: bytes)),
  );
  if (cropped == null) return null; // cancelled
  if (cropped.isEmpty) return path; // "use as is"
  if (kIsWeb) return storeWebPhotoBytes(cropped);
  final dir = await getTemporaryDirectory();
  final f = File(
    '${dir.path}/crop_${DateTime.now().millisecondsSinceEpoch}.jpg',
  );
  await f.writeAsBytes(cropped);
  return RecentPhotos.add(f.path);
}

class _PhotoEditorScreen extends StatefulWidget {
  const _PhotoEditorScreen({required this.bytes});
  final Uint8List bytes;

  @override
  State<_PhotoEditorScreen> createState() => _PhotoEditorScreenState();
}

class _PhotoEditorScreenState extends State<_PhotoEditorScreen> {
  final _controller = CropController();
  bool _cropping = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('Frame the board'),
        actions: [
          TextButton(
            onPressed: _cropping
                ? null
                : () => Navigator.pop(context, Uint8List(0)),
            child: const Text('Use as is'),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: Crop(
                image: widget.bytes,
                controller: _controller,
                interactive: true,
                baseColor: Colors.black,
                maskColor: Colors.black54,
                onCropped: (result) {
                  if (!mounted) return;
                  switch (result) {
                    case CropSuccess(:final croppedImage):
                      Navigator.pop(context, croppedImage);
                    case CropFailure():
                      setState(() => _cropping = false);
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text(
                            'Could not crop — using the '
                            'full photo',
                          ),
                        ),
                      );
                      Navigator.pop(context, Uint8List(0));
                  }
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Drag the corners tight around the board — '
                      'pinch to zoom',
                      style: TextStyle(color: Colors.white70, fontSize: 13),
                    ),
                  ),
                  FilledButton.icon(
                    icon: _cropping
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.check),
                    label: const Text('Detect'),
                    onPressed: _cropping
                        ? null
                        : () {
                            setState(() => _cropping = true);
                            _controller.crop();
                          },
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
