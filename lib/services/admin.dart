import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Studio (admin) token. The web app reads it from ?token= in the URL;
/// on a phone it is entered once (long-press the version line on Home)
/// and kept in preferences. Holding the token unlocks the Studio card
/// and the in-app admin features.
final ValueNotifier<String?> studioToken = ValueNotifier(null);

Future<void> loadStudioToken() async {
  try {
    final p = await SharedPreferences.getInstance();
    final t = p.getString('studio_token');
    if (t != null && t.isNotEmpty) studioToken.value = t;
  } catch (_) {}
}

Future<void> saveStudioToken(String? token) async {
  final t = (token ?? '').trim();
  studioToken.value = t.isEmpty ? null : t;
  try {
    final p = await SharedPreferences.getInstance();
    if (studioToken.value == null) {
      await p.remove('studio_token');
    } else {
      await p.setString('studio_token', studioToken.value!);
    }
  } catch (_) {}
}
