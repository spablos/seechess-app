import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'recognizer.dart';

/// Anonymous usage statistics — first-party only, no accounts.
///
/// A random install id (no relation to any hardware or user identity) plus
/// a daily heartbeat with feature counters. That's the entire footprint:
/// no third-party SDK, nothing identifying, and the server discards raw
/// IPs at ingestion (see service/stats.py).
class AppStats {
  static const _idKey = 'stats_install_id';
  static const _lastKey = 'stats_last_heartbeat';
  static const _countersKey = 'stats_counters';

  /// Count one use of a feature; flushed with the next heartbeat.
  static Future<void> count(String key) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final counters =
          jsonDecode(prefs.getString(_countersKey) ?? '{}')
              as Map<String, dynamic>;
      counters[key] = (counters[key] as int? ?? 0) + 1;
      await prefs.setString(_countersKey, jsonEncode(counters));
    } catch (_) {
      // stats must never break the app
    }
  }

  /// The anonymous install id (created on first use) — also attached to
  /// feedback submissions so a poisoning source can be capped/purged.
  static Future<String> installId() async {
    final prefs = await SharedPreferences.getInstance();
    var id = prefs.getString(_idKey);
    if (id == null) {
      final rng = Random.secure();
      id = List.generate(32, (_) => '0123456789abcdef'[rng.nextInt(16)]).join();
      await prefs.setString(_idKey, id);
    }
    return id;
  }

  /// Send the daily ping if one hasn't gone out in ~20h. Fire-and-forget.
  static Future<void> heartbeat() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final last = prefs.getInt(_lastKey) ?? 0;
      final now = DateTime.now().millisecondsSinceEpoch;
      if (now - last < 20 * 3600 * 1000) return;

      final id = await installId();
      final info = await PackageInfo.fromPlatform();
      final counters =
          jsonDecode(prefs.getString(_countersKey) ?? '{}')
              as Map<String, dynamic>;
      final base = await RecognizerClient.savedUrl();
      final res = await http
          .post(
            Uri.parse('$base/v1/heartbeat'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'install_id': id,
              'platform': Platform.isIOS ? 'ios' : 'android',
              'version': '${info.version}+${info.buildNumber}',
              if (counters.isNotEmpty) 'counters': counters,
            }),
          )
          .timeout(const Duration(seconds: 10));
      if (res.statusCode == 200) {
        await prefs.setInt(_lastKey, now);
        await prefs.setString(_countersKey, '{}');
      }
    } catch (_) {
      // offline — counters keep accumulating, next launch retries
    }
  }
}
