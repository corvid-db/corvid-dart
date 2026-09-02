// vector-index — the three vector-index families vs the exact scan.
//
// One corpus, three index lanes over three fields: the in-memory HNSW,
// the on-disk HNSW, and the binary-quantized in-memory index. A fourth
// field stays unindexed (the exact brute-force scan every query falls
// back to). Reopening the file shows the on-disk graph reload without a
// rebuild and answer again.
//
// Scores are RRF ranks (1/(60 + rank)) — the lone vector source's row
// score — so they reflect each lane's own ranking.
//
// Run: dart run examples/vector_index.dart   (after ./fetch.sh)

import 'dart:io';
import 'dart:typed_data';

import 'package:corvid_dart/corvid.dart';

Uint8List kb(String s) => Uint8List.fromList(s.codeUnits);

const corpus = <(String, List<double>)>[
  ('k0', [1.0, 0.0, 0.0, 0.0]), // nearest
  ('k1', [0.95, 0.05, 0.0, 0.0]),
  ('k2', [0.0, 1.0, 0.0, 0.0]),
  ('k3', [0.0, 0.9, 0.1, 0.0]),
  ('k4', [0.0, 0.0, 1.0, 0.0]),
  ('k5', [0.7, 0.7, 0.0, 0.0]),
  ('k6', [0.0, 0.0, 0.0, 1.0]),
  ('k7', [0.98, 0.02, 0.0, 0.0]),
];

final probe = Float32List.fromList([1.0, 0.0, 0.0, 0.0]);

void runQuery(Collection items, String field, bool approx, String label) {
  var q = items.query().vector(field, probe, 4, Metric.cosine);
  if (approx) q = q.approx();
  final rows = q.run();
  final parts = [
    for (final r in rows)
      '${String.fromCharCodes(r.key)}(${r.score.toStringAsFixed(6)})',
  ];
  print('${label.padRight(38)} ${parts.join(' ')}');
}

void main() {
  final path = '${Directory.systemTemp.path}/corvid-dart-vector-index.redb';
  final f = File(path);
  if (f.existsSync()) f.deleteSync(); // reruns start clean (single-file db)

  final db = Db.open(path);
  final items = db.collection('items');
  for (final (key, v) in corpus) {
    items.insert(kb(key), {
      'v_mem': Float32List.fromList(v),
      'v_disk': Float32List.fromList(v),
      'v_q': Float32List.fromList(v),
    });
  }
  items.createVectorIndex('v_mem', Metric.cosine);
  items.createVectorIndexOnDisk('v_disk', Metric.cosine);
  items.createVectorIndexQuantized('v_q', Metric.cosine, Quant.binary);

  print('top-4 nearest to (1,0,0,0) under cosine:');
  runQuery(items, 'v_mem', false, 'exact (scan):');
  runQuery(items, 'v_mem', true, 'ann in-memory HNSW:');
  runQuery(items, 'v_disk', true, 'ann on-disk HNSW:');
  runQuery(items, 'v_q', true, 'ann binary-quantized:');
  print('(the quantized lane trades recall for a ~32x smaller index)');

  items.close();
  db.close();

  // Reopen: the on-disk graph reloads (no rebuild) and answers again.
  final db2 = Db.open(path);
  final items2 = db2.collection('items');
  runQuery(items2, 'v_disk', true, 'ann on-disk after reopen:');
  items2.close();
  db2.close();

  f.deleteSync();
}
