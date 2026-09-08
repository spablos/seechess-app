import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

/// On desktop web the window is far wider than the content column; a raw
/// AppBar throws its leading arrow and action icons to the window's far
/// corners. This centers the bar over the content (mobile-like placement)
/// without constraining the body — floating panels keep the full window.
PreferredSizeWidget cappedAppBar(AppBar bar, {double width = 900}) {
  if (!kIsWeb) return bar;
  return PreferredSize(
    preferredSize: bar.preferredSize,
    child: Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: width),
        child: bar,
      ),
    ),
  );
}
