import 'dart:convert';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

/// Web recents live in localStorage (base64, newest-first key index,
/// capped) — enough for the thumbnail strip to survive reloads. Quota
/// errors just shrink the strip; storage must never break the flow.
const _indexKey = 'recent_photo_keys';
const _cap = 5;

List<String> _keys() {
  try {
    final raw = web.window.localStorage.getItem(_indexKey);
    if (raw == null) return [];
    return (jsonDecode(raw) as List).cast<String>();
  } catch (_) {
    return [];
  }
}

void _saveKeys(List<String> keys) {
  try {
    web.window.localStorage.setItem(_indexKey, jsonEncode(keys));
  } catch (_) {}
}

void persistWebPhoto(String key, Uint8List bytes) {
  try {
    final keys = _keys()..remove(key);
    keys.insert(0, key);
    while (keys.length > _cap) {
      final evict = keys.removeLast();
      web.window.localStorage.removeItem('photo:$evict');
    }
    web.window.localStorage.setItem('photo:$key', base64Encode(bytes));
    _saveKeys(keys);
  } catch (_) {
    // quota — drop the oldest and give up quietly if it still fails
    try {
      final keys = _keys();
      if (keys.isNotEmpty) {
        web.window.localStorage.removeItem('photo:${keys.removeLast()}');
        _saveKeys(keys);
      }
    } catch (_) {}
  }
}

List<(String, Uint8List)> loadPersistedWebPhotos() {
  final out = <(String, Uint8List)>[];
  for (final key in _keys()) {
    try {
      final b64 = web.window.localStorage.getItem('photo:$key');
      if (b64 != null) out.add((key, base64Decode(b64)));
    } catch (_) {}
  }
  return out;
}

void removePersistedWebPhoto(String key) {
  try {
    web.window.localStorage.removeItem('photo:$key');
    _saveKeys(_keys()..remove(key));
  } catch (_) {}
}

void clearPersistedWebPhotos() {
  for (final key in _keys()) {
    try {
      web.window.localStorage.removeItem('photo:$key');
    } catch (_) {}
  }
  _saveKeys([]);
}
