import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../services/recent_photos.dart';
import '../services/recognizer.dart';
import 'confirm.dart';

/// Step 1 of "Analyze a photo": take or choose a picture, send it to the
/// recognition service, then hand off to the confirm screen.
class PhotoFlowScreen extends StatefulWidget {
  const PhotoFlowScreen({super.key});

  @override
  State<PhotoFlowScreen> createState() => _PhotoFlowScreenState();
}

class _PhotoFlowScreenState extends State<PhotoFlowScreen> {
  final _picker = ImagePicker();
  final _urlController = TextEditingController();
  bool _busy = false;
  String? _error;
  String _phase = '';
  List<File> _recents = const [];

  @override
  void initState() {
    super.initState();
    RecognizerClient.savedUrl().then((url) {
      if (mounted) _urlController.text = url;
    });
    _loadRecents();
  }

  Future<void> _loadRecents() async {
    final recents = await RecentPhotos.list();
    if (mounted) setState(() => _recents = recents);
  }

  @override
  void dispose() {
    _urlController.dispose();
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
      // even if recognition fails (picker files live in purgeable tmp)
      final path = await RecentPhotos.add(file.path);
      await _loadRecents();
      await _recognize(path);
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
      photo.setLastModifiedSync(DateTime.now()); // bump to front
      await _recognize(photo.path);
      await _loadRecents();
    } catch (e) {
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _recognize(String path) async {
    final url = _urlController.text.trim();
    await RecognizerClient.saveUrl(url);
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
    final bytes = await File(path).readAsBytes();
    final result = await client.recognize(bytes);
    debugPrint('recognize round-trip: ${sw.elapsedMilliseconds}ms');
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ConfirmScreen(photoPath: path, recognition: result),
      ),
    );
  }

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
                if (_recents.isNotEmpty) ...[
                  const SizedBox(height: 20),
                  Text(
                    'Recently used',
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 6),
                  SizedBox(
                    height: 64,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      itemCount: _recents.length,
                      separatorBuilder: (_, _) => const SizedBox(width: 8),
                      itemBuilder: (context, i) {
                        final photo = _recents[i];
                        return GestureDetector(
                          onTap: () => _rerun(photo),
                          onLongPress: () async {
                            await RecentPhotos.remove(photo);
                            _loadRecents();
                          },
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: Image.file(
                              photo,
                              width: 64,
                              height: 64,
                              fit: BoxFit.cover,
                            ),
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
              ExpansionTile(
                title: Text(
                  'Recognition server',
                  style: theme.textTheme.bodySmall,
                ),
                tilePadding: EdgeInsets.zero,
                children: [
                  TextField(
                    controller: _urlController,
                    decoration: const InputDecoration(
                      hintText: 'https://seechess.nopatos.com',
                      isDense: true,
                    ),
                    keyboardType: TextInputType.url,
                    autocorrect: false,
                  ),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton.icon(
                      icon: const Icon(Icons.network_ping, size: 18),
                      label: const Text('Test connection'),
                      onPressed: () async {
                        final url = _urlController.text.trim();
                        final messenger = ScaffoldMessenger.of(context);
                        try {
                          final rtt = await RecognizerClient(url).ping();
                          messenger.showSnackBar(
                            SnackBar(
                              content: Text(
                                'Server OK — ${rtt.inMilliseconds} ms',
                              ),
                            ),
                          );
                        } catch (e) {
                          messenger.showSnackBar(
                            SnackBar(content: Text('Failed: $e')),
                          );
                        }
                      },
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
