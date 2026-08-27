import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Rolling cache of the last photos sent to recognition. iOS's photo picker
/// runs out-of-process and can't show per-app recents, so the app keeps its
/// own: the files themselves are the store — order is mtime, newest first,
/// identity is content (re-picking the same image bumps it, not duplicates).
class RecentPhotos {
  static const _max = 12;

  static Future<Directory> _dir() async {
    final dir = Directory(
      '${(await getApplicationDocumentsDirectory()).path}/recent_photos',
    );
    await dir.create(recursive: true);
    return dir;
  }

  static Future<List<File>> list() async {
    final files = (await _dir()).listSync().whereType<File>().toList()
      ..sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
    return files;
  }

  /// Copy [sourcePath] into the cache and prune to the newest [_max].
  /// Returns the durable cached path (picker files live in tmp, which iOS
  /// may purge — the confirm screen and feedback upload need this copy).
  static Future<String> add(String sourcePath) async {
    final bytes = await File(sourcePath).readAsBytes();
    for (final f in await list()) {
      if (f.lengthSync() == bytes.length &&
          _sameBytes(f.readAsBytesSync(), bytes)) {
        f.setLastModifiedSync(DateTime.now());
        return f.path;
      }
    }
    final dot = sourcePath.lastIndexOf('.');
    final ext = dot > 0 ? sourcePath.substring(dot) : '.jpg';
    final dest = File(
      '${(await _dir()).path}/${DateTime.now().millisecondsSinceEpoch}$ext',
    );
    await dest.writeAsBytes(bytes);
    for (final f in (await list()).skip(_max)) {
      try {
        f.deleteSync();
      } catch (_) {}
    }
    return dest.path;
  }

  static Future<void> remove(File f) async {
    try {
      await f.delete();
    } catch (_) {}
  }

  static Future<void> clear() async {
    for (final f in await list()) {
      await remove(f);
    }
  }

  static bool _sameBytes(List<int> a, List<int> b) {
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
