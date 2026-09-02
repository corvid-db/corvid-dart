// geo — radius / bbox / nearest over a `[lat, lon]` array field.
//
// Points are `[lat, lon]` arrays (the map `{lat, lon}` form works too);
// the geo index accelerates the radius/bbox windows. Radius and nearest
// return hits nearest-first with haversine kilometres; bbox in key
// order.
//
// Run: dart run examples/geo.dart   (after ./fetch.sh)

import 'dart:typed_data';

import 'package:corvid_dart/corvid.dart';

Uint8List kb(String s) => Uint8List.fromList(s.codeUnits);

const cities = <(String, double, double)>[
  ('berlin', 52.52, 13.40),
  ('potsdam', 52.40, 13.06),
  ('hamburg', 53.55, 9.99),
  ('munchen', 48.14, 11.58),
];

void show(String label, List<GeoHit> hits) {
  final parts = [
    for (final h in hits)
      '${String.fromCharCodes(h.key)} ${h.distanceKm.toStringAsFixed(6)}km',
  ];
  print('${label.padRight(34)} [${parts.join(' ')}]');
}

void main() {
  final db = Db.openMemory();
  final places = db.collection('places');

  for (final (name, lat, lon) in cities) {
    places.insert(kb(name), {
      'name': name,
      'loc': [lat, lon], // the [lat, lon] array encoding
    });
  }
  places.createGeoIndex('loc');

  show('within 600km of Berlin:', places.geoWithinRadius('loc', 52.52, 13.40, 600.0));
  show('bbox 47..55N, 5..15E:', places.geoWithinBBox('loc', 47, 5, 55, 15));
  show('nearest 2 to Berlin:', places.geoNearest('loc', 52.52, 13.40, 2));

  places.close();
  db.close();
}
