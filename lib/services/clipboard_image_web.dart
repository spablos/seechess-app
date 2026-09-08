import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

/// Web clipboard images, two ways in:
/// - [readClipboardImage]: the async Clipboard API behind the "Paste image"
///   button (Chrome/Edge/Safari prompt for permission on first use).
/// - [listenForImagePaste]: the DOM 'paste' event — Ctrl/Cmd+V anywhere on
///   the screen, no permission prompt, fires only on a real user gesture.
Future<Uint8List?> readClipboardImage() async {
  try {
    final items = await web.window.navigator.clipboard.read().toDart;
    for (var i = 0; i < items.length; i++) {
      final item = items.toDart[i];
      final types = item.types.toDart;
      for (final t in types) {
        final type = t.toDart;
        if (type.startsWith('image/')) {
          final blob = await item.getType(type).toDart;
          final buf = await blob.arrayBuffer().toDart;
          return buf.toDart.asUint8List();
        }
      }
    }
  } catch (_) {
    // permission denied / API absent — the paste-event path still works
  }
  return null;
}

JSFunction? _pasteHandler;

void listenForImagePaste(void Function(Uint8List bytes) onImage) {
  stopImagePasteListener();
  void handler(web.Event e) {
    final ce = e as web.ClipboardEvent;
    final data = ce.clipboardData;
    if (data == null) return;
    final items = data.items;
    for (var i = 0; i < items.length; i++) {
      final item = items[i];
      if (item.kind == 'file' && item.type.startsWith('image/')) {
        final file = item.getAsFile();
        if (file == null) continue;
        e.preventDefault();
        file.arrayBuffer().toDart.then(
          (buf) => onImage(buf.toDart.asUint8List()),
        );
        return;
      }
    }
  }

  _pasteHandler = handler.toJS;
  web.window.addEventListener('paste', _pasteHandler);
}

void stopImagePasteListener() {
  final h = _pasteHandler;
  if (h != null) {
    web.window.removeEventListener('paste', h);
    _pasteHandler = null;
  }
}
