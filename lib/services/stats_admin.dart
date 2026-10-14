import 'dart:convert';

import 'package:http/http.dart' as http;

import 'lessons.dart';
import 'recognizer.dart';

/// One day of anonymous usage (mirrors /v1/stats/summary "daily" rows).
class DailyStat {
  DailyStat({
    required this.date,
    required this.active,
    required this.fresh,
    required this.scans,
    required this.feedback,
    required this.counters,
  });

  final String date;
  final int active;
  final int fresh;
  final int scans;
  final int feedback;
  final Map<String, int> counters;

  factory DailyStat.fromJson(Map<String, dynamic> j) => DailyStat(
    date: j['date'] as String,
    active: (j['active'] ?? 0) as int,
    fresh: (j['new'] ?? 0) as int,
    scans: ((j['requests'] ?? const {})['recognize'] ?? 0) as int,
    feedback: ((j['requests'] ?? const {})['feedback'] ?? 0) as int,
    counters: {
      for (final e in ((j['counters'] ?? const {}) as Map).entries)
        e.key as String: e.value as int,
    },
  );
}

class StatsSummary {
  StatsSummary({
    required this.dau,
    required this.wau,
    required this.mau,
    required this.installs,
    required this.retentionD1,
    required this.retentionD7,
    required this.platforms,
    required this.versions,
    required this.countries,
    required this.features,
    required this.daily,
  });

  final int dau;
  final int wau;
  final int mau;
  final int installs;
  final String retentionD1;
  final String retentionD7;
  final Map<String, int> platforms;
  final Map<String, int> versions;
  final Map<String, int> countries;
  final Map<String, int> features;
  final List<DailyStat> daily;

  static Map<String, int> _counts(dynamic m) => {
    for (final e in ((m ?? const {}) as Map).entries)
      e.key as String: e.value as int,
  };

  factory StatsSummary.fromJson(Map<String, dynamic> j) => StatsSummary(
    dau: (j['dau'] ?? 0) as int,
    wau: (j['wau'] ?? 0) as int,
    mau: (j['mau'] ?? 0) as int,
    installs: (j['installs_total'] ?? 0) as int,
    retentionD1: (j['retention_d1'] ?? 'n/a') as String,
    retentionD7: (j['retention_d7'] ?? 'n/a') as String,
    platforms: _counts(j['platforms']),
    versions: _counts(j['versions']),
    countries: _counts(j['countries']),
    features: _counts(j['feature_counters_30d']),
    daily: [
      for (final d in (j['daily'] ?? const []) as List)
        DailyStat.fromJson(d as Map<String, dynamic>),
    ],
  );
}

Future<StatsSummary?> fetchStatsSummary({int days = 30}) async {
  final base = await RecognizerClient.savedUrl();
  final token = adminToken() ?? '';
  final res = await http
      .get(Uri.parse('$base/v1/stats/summary?token=$token&days=$days'))
      .timeout(const Duration(seconds: 20));
  if (res.statusCode != 200) return null;
  return StatsSummary.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
}
