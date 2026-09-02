// quickstart — the README tour as a runnable file.
//
// Open an in-memory database, create a collection, insert three small
// documents carrying 2-d embeddings, run a kNN vector query under
// cosine, and print the ranked rows. Close what you opened.
//
// Run: dart run examples/quickstart.dart   (after ./fetch.sh)

import 'dart:typed_data';

import 'package:corvid/corvid.dart';

Uint8List kb(String s) => Uint8List.fromList(s.codeUnits);

// docs:begin:quickstart
void main() {
  final db = Db.openMemory();
  final docs = db.collection('docs');

  docs.insert(kb('p1'), {
    'title': 'rust embedded database',
    'kind': 'doc',
    'v': Float32List.fromList([1.0, 0.0]),
  });
  docs.insert(kb('p2'), {
    'title': 'python web frameworks',
    'kind': 'doc',
    'v': Float32List.fromList([0.0, 1.0]),
  });
  docs.insert(kb('p3'), {
    'title': 'rust again database',
    'kind': 'doc',
    'v': Float32List.fromList([0.9, 0.1]),
  });

  // kNN: the 3 nearest documents to (1, 0) under cosine. Row.doc is
  // materialized only under select — retrieval rows carry keys and
  // scores, so select the field the printout needs.
  final rows = docs
      .query()
      .vector('v', Float32List.fromList([1.0, 0.0]), 3, Metric.cosine)
      .select(['title'])
      .run();
  var rank = 0;
  for (final r in rows) {
    print('${++rank}. ${String.fromCharCodes(r.key)} '
        'score=${r.score.toStringAsFixed(6)} ${r.doc}');
  }

  docs.close();
  db.close();
}
// docs:end:quickstart
