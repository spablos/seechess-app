import 'dart:convert';

import 'package:http/http.dart' as http;

import 'recognizer.dart';

/// One labeler item: a stored image with the model's reading and the
/// human correction (when done). Mirrors /v1/dataset's entry meta.
class DatasetEntry {
  DatasetEntry({
    required this.id,
    required this.batch,
    required this.inputType,
    required this.predictedFen,
    required this.correctedFen,
  });

  final String id;
  final String batch;
  final String inputType;
  final String predictedFen;
  String? correctedFen;

  bool get labeled => correctedFen != null && correctedFen!.isNotEmpty;

  factory DatasetEntry.fromJson(Map<String, dynamic> j) => DatasetEntry(
    id: j['id'] as String,
    batch: (j['batch'] ?? '') as String,
    inputType: (j['input_type'] ?? 'photo') as String,
    predictedFen: (j['predicted_fen'] ?? '') as String,
    correctedFen: j['corrected_fen'] as String?,
  );
}

Future<String> datasetBase() => RecognizerClient.savedUrl();

Future<List<DatasetEntry>> fetchDataset() async {
  final base = await datasetBase();
  final res = await http
      .get(Uri.parse('$base/v1/dataset'))
      .timeout(const Duration(seconds: 20));
  if (res.statusCode != 200) return const [];
  return [
    for (final j in jsonDecode(res.body) as List)
      DatasetEntry.fromJson(j as Map<String, dynamic>),
  ];
}

Future<bool> saveCorrection(String id, String placement) async {
  final base = await datasetBase();
  final res = await http
      .put(
        Uri.parse('$base/v1/dataset/$id'),
        body: {'corrected_fen': placement},
      )
      .timeout(const Duration(seconds: 15));
  return res.statusCode == 200;
}

/// Corners normalized 0..1 in order a8, h8, h1, a1.
Future<bool> saveCorners(String id, List<List<double>> corners) async {
  final base = await datasetBase();
  final res = await http
      .put(
        Uri.parse('$base/v1/dataset/$id/corners'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'corners': corners}),
      )
      .timeout(const Duration(seconds: 15));
  return res.statusCode == 200;
}

Future<DatasetEntry?> fetchEntry(String id) async {
  // the list endpoint is the only reader; refetch and pick
  for (final e in await fetchDataset()) {
    if (e.id == id) return e;
  }
  return null;
}

Future<bool> deleteEntry(String id) async {
  final base = await datasetBase();
  final res = await http
      .delete(Uri.parse('$base/v1/dataset/$id'))
      .timeout(const Duration(seconds: 15));
  return res.statusCode == 200;
}
