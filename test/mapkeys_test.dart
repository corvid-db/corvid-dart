// mapkeys_test.dart — the map-key completeness boundary.
//
// Engine v0.3.0's corvid_value_map_keys collapsed the v0.2.x-era
// candidate-key oracle the earlier bindings needed: decoding enumerates
// the map's keys through the real iterator, so every read path decodes
// COMPLETE documents on any database, whatever wrote the data. This test
// pins the shape the oracle existed for — a document written through ONE
// handle read back, COMPLETE, through a FRESH OPEN of the same file,
// keys the reader never saw declared (unknown + UTF-8 + nested).

import 'dart:io';
import 'dart:typed_data';

import 'package:corvid_dart/corvid.dart';
import 'package:test/test.dart';

Uint8List kb(String s) => Uint8List.fromList(s.codeUnits);

void main() {
  late Directory dir;
  late String path;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('corvid-mapkeys-');
    path = '${dir.path}/mapkeys.redb';
  });

  tearDown(() {
    dir.deleteSync(recursive: true);
  });

  test('a complete decode survives a close/reopen of the file', () {
    {
      final db = Db.open(path);
      final docs = db.collection('docs');
      docs.insert(kb('k'), {
        'known': 1,
        'ünknown': 'ütf8 key', // the reader never declares this key
        'nested': {
          'deep': [
            1,
            2,
            {'x': true},
          ],
        },
      });
      docs.close();
      db.close();
    }
    {
      final db = Db.open(path);
      final docs = db.collection('docs');
      final doc = docs.get(kb('k')) as Map<String, Object?>;
      expect(doc.keys, unorderedEquals(<String>['known', 'ünknown', 'nested']));
      expect(doc['known'], 1);
      expect(doc['ünknown'], 'ütf8 key');
      expect(doc['nested'], {
        'deep': [
          1,
          2,
          {'x': true},
        ],
      });
      // The same completeness holds through the scan and page paths.
      var scanned = 0;
      docs.scan((key, d) {
        scanned++;
        expect((d as Map<String, Object?>).length, 3);
        return true;
      });
      expect(scanned, 1);
      final page = docs.page(null, 10);
      expect(page.rows, hasLength(1));
      expect((page.rows.first.doc as Map<String, Object?>).length, 3);
      expect(page.next, isNull);
      docs.close();
      db.close();
    }
  });
}
