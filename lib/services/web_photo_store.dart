library;

/// Platform selector for persisted web recents (no-ops off-web).
export 'web_photo_store_stub.dart'
    if (dart.library.js_interop) 'web_photo_store_web.dart';
