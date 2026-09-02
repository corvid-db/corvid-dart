// text-search — BM25 incl. CJK bigram segmentation, plus the v0.3.0
// direct phraseSearch.
//
// A bilingual corpus (English + Chinese/Japanese-style CJK): BM25
// ranking (the inverted index's own scale) for multi-term queries and
// CJK bigrams, then the positional phrase search — consecutive,
// in-order tokens (stop words collapse out of adjacency), reversed
// phrases matching nothing.
//
// Run: dart run examples/text_search.dart   (after ./fetch.sh)

import 'dart:typed_data';

import 'package:corvid_dart/corvid.dart';

Uint8List kb(String s) => Uint8List.fromList(s.codeUnits);

const corpus = <(String, String)>[
  ('n1', 'the quick brown fox jumps over the lazy dog'),
  ('n2', 'a quick red fox leaps over a sleeping dog'),
  ('n3', 'slow green turtle crosses the road'),
  ('n4', '东京是一座巨大的城市'), // Tokyo is a huge city
  ('n5', '大阪是关西最大的城市'), // Osaka is Kansai's biggest city
  ('n6', '机器学习正在改变数据库'), // ML is changing databases
];

void search(Collection notes, String query, String label) {
  final rows = notes.query().text('body', query, 3).run();
  final parts = [
    for (final r in rows)
      '${String.fromCharCodes(r.key)}(${r.score.toStringAsFixed(6)})',
  ];
  print('${label.padRight(30)} -> ${parts.join(' ')}');
}

void phrase(Collection notes, String query, String label) {
  final rows = notes.phraseSearch('body', query, 3);
  final parts = [
    for (final r in rows)
      '${String.fromCharCodes(r.key)}(${r.score.toStringAsFixed(6)})',
  ];
  print('${label.padRight(30)} -> ${parts.join(' ')}');
}

void main() {
  final db = Db.openMemory();
  final notes = db.collection('notes');

  for (final (key, body) in corpus) {
    notes.insert(kb(key), {'body': body});
  }
  notes.createTextIndex('body');

  search(notes, 'quick fox', 'bm25 "quick fox":');
  search(notes, 'quick dog', 'bm25 "quick dog":');
  search(notes, '城市', 'bm25 CJK 城市 (city):');
  search(notes, '数据库', 'bm25 CJK 数据库 (database):');

  phrase(notes, 'fox jumps over', 'phrase "fox jumps over":');
  phrase(notes, 'over jumps fox', 'phrase "over jumps fox" (reversed — no match):');
  phrase(notes, 'leaps over a sleeping', 'phrase with stop words collapsed:');

  notes.close();
  db.close();
}
