import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:universal_io/io.dart';

/// Photo storage that works on every platform. On mobile, photos are real
/// files (recent_photos, library). The web has no filesystem, so picked
/// or cropped photos live in this in-memory registry under pseudo-paths —
/// plenty for the pick→crop→recognize→confirm→feedback session flow.
final Map<String, Uint8List> _webPhotos = {};
int _webSeq = 0;

bool isWebPhoto(String path) => path.startsWith('web-photo:');

String storeWebPhotoBytes(Uint8List bytes) {
  final key = 'web-photo:${++_webSeq}';
  _webPhotos[key] = bytes;
  // bounded: the session only ever needs the last few
  if (_webPhotos.length > 12) {
    _webPhotos.remove(_webPhotos.keys.first);
  }
  return key;
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
