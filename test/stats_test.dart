import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:seechess/services/stats.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('counters accumulate across calls and survive in prefs', () async {
    SharedPreferences.setMockInitialValues({});
    await AppStats.count('lesson_open');
    await AppStats.count('lesson_open');
    await AppStats.count('match_host');
    final prefs = await SharedPreferences.getInstance();
    final counters =
        jsonDecode(prefs.getString('stats_counters')!) as Map<String, dynamic>;
    expect(counters, {'lesson_open': 2, 'match_host': 1});
  });

  test('heartbeat throttles to ~daily', () async {
    SharedPreferences.setMockInitialValues({
      'stats_last_heartbeat': DateTime.now().millisecondsSinceEpoch,
      'stats_counters': '{"lesson_open":1}',
    });
    // recent heartbeat: returns without network and keeps counters
    await AppStats.heartbeat();
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('stats_counters'), '{"lesson_open":1}');
  });
}
