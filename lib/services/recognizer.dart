import 'dart:convert';

import 'package:http/http.dart' as http;

import 'stats.dart';
import 'package:shared_preferences/shared_preferences.dart';

class RecognitionResult {
  RecognitionResult({
    required this.fen,
    required this.confidence,
    required this.warnings,
    required this.inputType,
    this.fromMemory = false,
    this.flippedDisplay = false,
    this.turn,
  });

  /// Placement-only FEN as recognized (turn is unknown to the service).
  final String fen;
  final List<double> confidence; // 64 values in FEN order, a8..h1
  final List<String> warnings;
  final String inputType;

  /// True when the server answered from feedback memory: this exact photo
  /// was human-corrected before, so the position is already confirmed.
  final bool fromMemory;

  /// True when the source showed the board from Black's perspective (the
  /// position was rotated to true orientation): present the board flipped
  /// so it visually matches the photo.
  final bool flippedDisplay;

  /// 'w' or 'b' when known (only human confirmations know the turn —
  /// served back on feedback-memory hits); null otherwise.
  final String? turn;
}

/// Client for the seechess recognition service (POST /v1/recognize).
class RecognizerClient {
  RecognizerClient(this.baseUrl);

  final String baseUrl;
  static const _prefsKey = 'server_url';

  static Future<String> savedUrl() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString(_prefsKey);
    // production default: the public server — works from any network, no
    // dependency on the dev Mac being awake. The dev laptop is still
    // reachable by typing its URL in the server field.
    // Migrate stale localhost/raw-LAN-IP/dev-Mac values from earlier builds.
    const fallback = 'https://seechess.nopatos.com';
    if (stored == null ||
        stored.contains('localhost') ||
        stored.contains('192.168.50.245') ||
        stored.contains('pablos-macbook-pro.local')) {
      return fallback;
    }
    return stored;
  }

  static Future<void> saveUrl(String url) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, url);
  }

  /// Reachability probe so an unreachable server fails fast with a clear
  /// message instead of a 30s spinner on a dead upload. 8s, not less: a
  /// cold cellular radio needs DNS + TCP + TLS before the first byte.
  Future<Duration> ping() async {
    final sw = Stopwatch()..start();
    final resp = await http
        .get(Uri.parse('$baseUrl/healthz'))
        .timeout(const Duration(seconds: 8));
    if (resp.statusCode != 200) {
      throw RecognizerException(
        'server responded ${resp.statusCode}',
        resp.statusCode,
      );
    }
    return sw.elapsed;
  }

  Future<RecognitionResult> recognize(
    List<int> imageBytes, {
    String filename = 'photo.jpg',
  }) async {
    final uri = Uri.parse('$baseUrl/v1/recognize');
    final request = http.MultipartRequest('POST', uri)
      ..files.add(
        http.MultipartFile.fromBytes('image', imageBytes, filename: filename),
      );
    // 30s: a weak cellular uplink can legitimately need this for a photo
    final streamed = await request.send().timeout(const Duration(seconds: 30));
    final body = await streamed.stream.bytesToString();
    if (streamed.statusCode != 200) {
      String detail = body;
      try {
        detail = (jsonDecode(body) as Map)['detail'].toString();
      } catch (_) {}
      throw RecognizerException(detail, streamed.statusCode);
    }
    final json = jsonDecode(body) as Map<String, dynamic>;
    return RecognitionResult(
      fen: (json['fen'] as String).split(' ').first,
      confidence: [
        for (final c in (json['per_square_confidence'] as List? ?? []))
          (c as num).toDouble(),
      ],
      warnings: [for (final w in (json['warnings'] as List? ?? [])) '$w'],
      inputType: json['input_type_used'] as String? ?? 'unknown',
      fromMemory: json['from_memory'] == true,
      flippedDisplay: json['flipped_display'] == true,
      turn: json['turn'] as String?,
    );
  }

  /// Fire-and-forget confirmed-position feedback (the data flywheel).
  Future<void> sendFeedback({
    required List<int> imageBytes,
    required String predictedFen,
    required String correctedFen,
    bool flippedDisplay = false,
  }) async {
    final request =
        http.MultipartRequest('POST', Uri.parse('$baseUrl/v1/feedback'))
          ..fields['predicted_fen'] = predictedFen
          ..fields['corrected_fen'] = correctedFen
          ..fields['flipped_display'] = '$flippedDisplay'
          // provenance: lets the server cap/purge a poisoning source
          ..fields['install_id'] = await AppStats.installId()
          ..files.add(
            http.MultipartFile.fromBytes(
              'image',
              imageBytes,
              filename: 'photo.jpg',
            ),
          );
    await request.send().timeout(const Duration(seconds: 15));
  }

  static const _consentKey = 'feedback_consent';

  /// null = never asked; true/false = user's stored choice.
  static Future<bool?> feedbackConsent() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_consentKey);
  }

  static Future<void> setFeedbackConsent(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_consentKey, value);
  }
}

class RecognizerException implements Exception {
  RecognizerException(this.message, this.statusCode);
  final String message;
  final int statusCode;
  @override
  String toString() => message;
}
