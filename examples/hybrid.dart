// hybrid — the flagship: filter + vector + BM25, RRF fusion, MMR
// rerank, limit.
//
// Hybrid retrieval over a 4-document corpus: a pre-ranking `kind`
// filter, a vector (ANN) source and a BM25 text source, both
// contributing top-2 candidate lists, fused with Reciprocal Rank
// Fusion (k = 60) and reranked for diversity with MMR (lambda = 1.0),
// capped at 2 rows. The printed scores are RRF rank sums: s1 is rank 1
// of both sources (1/61 + 1/61 = 2/61), s3 rank 2 of both (2/62).
//
// Run: dart run examples/hybrid.dart   (after ./fetch.sh)

import 'dart:typed_data';

import 'package:corvid_dart/corvid.dart';

Uint8List kb(String s) => Uint8List.fromList(s.codeUnits);

// docs:begin:hybrid
void main() {
  final db = Db.openMemory();
  final docs = db.collection('docs');

  docs.insert(kb('s1'), {
    'kind': 'doc',
    'body': 'rust embedded database',
    'v': Float32List.fromList([1.0, 0.0]),
  });
  docs.insert(kb('s2'), {
    'kind': 'doc',
    'body': 'python web frameworks',
    'v': Float32List.fromList([0.0, 1.0]),
  });
  docs.insert(kb('s3'), {
    'kind': 'doc',
    'body': 'rust again database',
    'v': Float32List.fromList([0.9, 0.1]),
  });
  docs.insert(kb('m1'), {'kind': 'meta'}); // filtered out below

  // The flagship query: filter + vector + text, RRF + MMR + limit.
  final rows = docs
      .query()
      .filter(field('kind').eq('doc'))
      .vector('v', Float32List.fromList([1.0, 0.0]), 2, Metric.cosine)
      .text('body', 'rust database', 2)
      .fuseRRF(60)
      .rerankMMR(1.0)
      .limit(2)
      .select(['body'])
      .run();
  var rank = 0;
  for (final r in rows) {
    print('${++rank}. ${String.fromCharCodes(r.key)} '
        'score=${r.score.toStringAsFixed(6)} ${r.doc}');
  }

  docs.close();
  db.close();
}
// docs:end:hybrid
