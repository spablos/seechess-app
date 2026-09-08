library;

/// Platform selector: real clipboard-image support on web, no-ops
/// elsewhere. See clipboard_image_web.dart for the two entry points.
export 'clipboard_image_stub.dart'
    if (dart.library.js_interop) 'clipboard_image_web.dart';
