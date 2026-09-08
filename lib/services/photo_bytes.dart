import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:universal_io/io.dart';

import 'web_photo_store.dart';

/// Photo storage that works on every platform. On mobile, photos are real
/// files (recent_photos, library). The web has no filesystem, so picked
/// or cropped photos live in this in-memory registry under pseudo-paths —
/// plenty for the pick→crop→recognize→confirm→feedback session flow.
final Map<String, Uint8List> _webPhotos = {};
int _webSeq = 0;

bool isWebPhoto(String path) => path.startsWith('web-photo:');

String storeWebPhotoBytes(Uint8List bytes) {
  final key = 'web-photo:${DateTime.now().millisecondsSinceEpoch}-${++_webSeq}';
  _webPhotos[key] = bytes;
  // bounded: the session only ever needs the last few
  if (_webPhotos.length > 12) {
    _webPhotos.remove(_webPhotos.keys.first);
  }
  persistWebPhoto(key, bytes); // recents strip survives reloads (web)
  return key;
}

/// Rehydrate persisted web recents into the registry; newest-first keys.
List<String> restoreWebPhotoKeys() {
  final out = <String>[];
  for (final (key, bytes) in loadPersistedWebPhotos()) {
    _webPhotos[key] = bytes;
    out.add(key);
  }
  return out;
}

void removeWebPhoto(String key) {
  _webPhotos.remove(key);
  removePersistedWebPhoto(key);
}

void clearWebPhotos() {
  _webPhotos.clear();
  clearPersistedWebPhotos();
}

Future<Uint8List> readPhotoBytes(String path) async {
  if (isWebPhoto(path)) {
    final bytes = _webPhotos[path];
    if (bytes == null) throw StateError('web photo expired: $path');
    return bytes;
  }
  return File(path).readAsBytes();
}

/// The right Image widget for a photo path on this platform.
Widget photoImage(String path, {BoxFit? fit}) {
  if (isWebPhoto(path)) {
    final bytes = _webPhotos[path];
    if (bytes == null) return const SizedBox.shrink();
    return Image.memory(bytes, fit: fit);
  }
  return Image.file(File(path), fit: fit);
}

/// Web-safe "does this photo still exist" — File.existsSync throws
/// "_Namespace" on web (the gray-screen crash, Sep 2026).
bool photoExists(String path) {
  if (isWebPhoto(path)) return _webPhotos.containsKey(path);
  if (kIsWeb) return false;
  try {
    return File(path).existsSync();
  } catch (_) {
    return false;
  }
}
