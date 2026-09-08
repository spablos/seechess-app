import 'dart:typed_data';

/// Mobile/desktop: recents are real files — nothing to persist here.
void persistWebPhoto(String key, Uint8List bytes) {}

List<(String, Uint8List)> loadPersistedWebPhotos() => const [];

void removePersistedWebPhoto(String key) {}

void clearPersistedWebPhotos() {}
