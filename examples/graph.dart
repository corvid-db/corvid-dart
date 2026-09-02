// graph — directed edges over document keys, weighted routes, BFS
// traversal, and the delete cascade.
//
// Edges live in the collection (atomic with writes) and may dangle on
// keys that never existed as documents; deleting a key — document or
// not — cascades its edges in the same transaction.
//
// Run: dart run examples/graph.dart   (after ./fetch.sh)

import 'dart:typed_data';

import 'package:corvid_dart/corvid.dart';

Uint8List kb(String s) => Uint8List.fromList(s.codeUnits);

void show(String label, List<Uint8List> keys) {
  final names = [for (final k in keys) String.fromCharCodes(k)];
  print('${label.padRight(36)} [${names.join(' ')}]');
}

void main() {
  final db = Db.openMemory();
  final nodes = db.collection('nodes');

  for (final key in ['ga', 'gb', 'gc']) {
    nodes.insert(kb(key), {'n': key});
  }

  nodes.link(kb('ga'), 'parent_of', kb('gb'));
  nodes.link(kb('ga'), 'parent_of', kb('gc'));
  nodes.link(kb('gb'), 'parent_of', kb('gd')); // gd never exists as a document
  nodes.linkWeighted(kb('ga'), 'route', kb('gb'), 2.5);
  nodes.linkWeighted(kb('ga'), 'route', kb('gd'), 0.75);

  final ga = kb('ga'), gb = kb('gb');

  show('neighbors(ga)', nodes.neighbors(ga, 'parent_of'));
  show('in_neighbors(gb)', nodes.inNeighbors(gb, 'parent_of'));

  final routes = nodes.neighborsWeighted(ga, 'route');
  final parts = [
    for (final r in routes)
      '${String.fromCharCodes(r.key)}=${r.weight.toStringAsFixed(2)}',
  ];
  print('${'routes from ga (weighted):'.padRight(36)} [${parts.join(' ')}]');

  show('traverse(ga, 1 hop)', nodes.traverse(ga, 'parent_of', 1));
  show('traverse(ga, 2 hops)', nodes.traverse(ga, 'parent_of', 2));

  // Delete cascade: remove gc (a document) and gd (never a document).
  print('delete gc: existed = ${nodes.delete(kb('gc'))}');
  print('delete gd: existed = ${nodes.delete(kb('gd'))} '
      '(never a document; its edges still cascade)');

  show('neighbors(ga) after deletes', nodes.neighbors(ga, 'parent_of'));
  show('neighbors(gb) after deletes', nodes.neighbors(gb, 'parent_of'));
  show('traverse(ga, 2 hops) after', nodes.traverse(ga, 'parent_of', 2));

  nodes.close();
  db.close();
}
