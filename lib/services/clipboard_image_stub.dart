import 'dart:typed_data';

/// Mobile/desktop: image-paste is a web affordance (the OS share sheet and
/// picker cover it natively) — no-ops here.
Future<Uint8List?> readClipboardImage() async => null;

void listenForImagePaste(void Function(Uint8List bytes) onImage) {}

void stopImagePasteListener() {}
