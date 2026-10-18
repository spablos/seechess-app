import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'dataset.dart';

/// Offline pack for the Studio labeler (flight mode).
///
/// Everything lives under `<documents>/offline_labeler/` and in ONE place
/// so the feature can be reverted by deleting this file and its few
/// call sites:
///   manifest.json     the dataset entries as served at download time
///   `images/<id>.jpg`  the display images
///   journal.jsonl     append-only actions, replayed on sync in order
///
/// Journal action types -> server calls on sync:
///   save     {fen, transit, highlight} -> saveCorrection + saveSquareMarks
///   corners  {corners}                 -> saveCorners
///   itype    {input_type}              -> saveInputType
///   discard  {}                        -> deleteEntry
class OfflineLabeler {
  static Future<Directory> _root() async {
    final docs = await getApplicationDocumentsDirectory();
    final d = Directory('${docs.path}/offline_labeler');
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  static Future<File> _manifest() async =>
      File('${(await _root()).path}/manifest.json');

  static Future<File> _journal() async =>
      File('${(await _root()).path}/journal.jsonl');

  static Future<bool> hasPack() async => (await _manifest()).exists();

  static Future<int> journalLength() async {
    final f = await _journal();
    if (!await f.exists()) return 0;
    return _unique(
      (await f.readAsLines()).where((l) => l.trim().isNotEmpty).toList(),
    ).length;
  }

  /// Keep only the LAST action per (type, id): re-saving an image
  /// replaces its queued action instead of piling up duplicates.
  static List<String> _unique(List<String> lines) {
    final seen = <String>{};
    final out = <String>[];
    for (final l in lines.reversed) {
      try {
        final a = jsonDecode(l) as Map<String, dynamic>;
        if (seen.add('${a['type']}:${a['id']}')) out.add(l);
      } catch (_) {}
    }
    return out.reversed.toList();
  }

  /// Download every given entry's metadata + display image.
  ///
  /// The manifest is written FIRST so an interrupted download still
  /// leaves a usable (partial) pack, and images fetch 6 at a time.
  static Future<int> downloadPack(
    List<DatasetEntry> entries,
    void Function(int done, int total) onProgress,
  ) async {
    final root = await _root();
    final imgDir = Directory('${root.path}/images');
    if (!await imgDir.exists()) await imgDir.create();
    await (await _manifest()).writeAsString(
      jsonEncode([for (final e in entries) _entryJson(e)]),
    );
    final base = await datasetBase();
    var done = 0;
    Future<void> fetchOne(DatasetEntry e) async {
      final img = File('${imgDir.path}/${e.id}.jpg');
      if (!await img.exists()) {
        try {
          final res = await http
              .get(Uri.parse('$base/v1/dataset/${e.id}/display'))
              .timeout(const Duration(seconds: 30));
          if (res.statusCode == 200) {
            await img.writeAsBytes(res.bodyBytes);
          }
        } catch (_) {
          // skipped image: the pack stays usable, a retap retries it
        }
      }
      done++;
      onProgress(done, entries.length);
    }

    const lanes = 6;
    for (var i = 0; i < entries.length; i += lanes) {
      await Future.wait([
        for (final e in entries.skip(i).take(lanes)) fetchOne(e),
      ]);
    }
    return done;
  }

  static Map<String, dynamic> _entryJson(DatasetEntry e) => {
    'id': e.id,
    'batch': e.batch,
    'input_type': e.inputType,
    'input_type_labeled_at': e.typeConfirmed ? 'offline' : null,
    'predicted_fen': e.predictedFen,
    'corrected_fen': e.correctedFen,
    'draft_fen': e.draftFen,
    'corners': e.corners,
    'square_marks': {
      'transit': e.transit.toList(),
      'highlight': e.highlight.toList(),
    },
  };

  static Future<List<DatasetEntry>> loadPack() async {
    final raw = jsonDecode(await (await _manifest()).readAsString());
    return [
      for (final j in raw as List)
        DatasetEntry.fromJson(j as Map<String, dynamic>),
    ];
  }

  /// Persist the pack's current in-memory state (so reopening the app
  /// offline shows your own edits).
  static Future<void> saveLocalState(List<DatasetEntry> entries) async {
    await (await _manifest()).writeAsString(
      jsonEncode([for (final e in entries) _entryJson(e)]),
    );
  }

  static Future<File> imageFile(String id) async =>
      File('${(await _root()).path}/images/$id.jpg');

  /// Append an action, replacing any queued action of the same type
  /// for the same entry. Returns the queued-action count.
  static Future<int> journal(
    String type,
    String id,
    Map<String, dynamic> payload,
  ) async {
    final f = await _journal();
    final lines = await f.exists()
        ? (await f.readAsLines()).where((l) => l.trim().isNotEmpty).toList()
        : <String>[];
    lines.add(jsonEncode({'type': type, 'id': id, ...payload}));
    final unique = _unique(lines);
    await f.writeAsString('${unique.join('\n')}\n');
    return unique.length;
  }

  /// Replay the journal in order. Successfully applied lines are
  /// dropped; the remainder (after a network failure) stays queued.
  static Future<(int ok, int left)> sync(
    void Function(int done, int total) onProgress,
  ) async {
    final f = await _journal();
    if (!await f.exists()) return (0, 0);
    final lines = _unique(
      (await f.readAsLines()).where((l) => l.trim().isNotEmpty).toList(),
    );
    var ok = 0;
    final remaining = <String>[];
    for (var i = 0; i < lines.length; i++) {
      if (remaining.isNotEmpty) {
        remaining.add(lines[i]); // keep order after first failure
        continue;
      }
      final a = jsonDecode(lines[i]) as Map<String, dynamic>;
      var applied = false;
      try {
        switch (a['type']) {
          case 'save':
            applied = await saveCorrection(
              a['id'] as String,
              a['fen'] as String,
              seedBatchDraft: a['seed_batch'] == true,
            );
            if (applied) {
              await saveSquareMarks(
                a['id'] as String,
                {...(a['transit'] as List).cast<String>()},
                {...(a['highlight'] as List).cast<String>()},
              );
            }
          case 'corners':
            applied = await saveCorners(a['id'] as String, [
              for (final c in a['corners'] as List)
                c == null
                    ? null
                    : [(c[0] as num).toDouble(), (c[1] as num).toDouble()],
            ], applyToBatch: a['apply_to_batch'] == true);
          case 'itype':
            applied = await saveInputType(
              a['id'] as String,
              a['input_type'] as String,
            );
          case 'discard':
            applied = await deleteEntry(a['id'] as String);
          default:
            applied = true; // unknown action: drop it
        }
      } catch (_) {
        applied = false;
      }
      if (applied) {
        ok++;
      } else {
        remaining.add(lines[i]);
      }
      onProgress(ok, lines.length);
    }
    if (remaining.isEmpty) {
      await f.delete();
    } else {
      await f.writeAsString('${remaining.join('\n')}\n');
    }
    return (ok, remaining.length);
  }

  static Future<void> clearPack() async {
    final root = await _root();
    if (await root.exists()) await root.delete(recursive: true);
  }
}
