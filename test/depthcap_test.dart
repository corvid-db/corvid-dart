// depthcap_test.dart — the encode-side nesting cap (the python-F1
// class, accepted-review fix): encode caps at the engine's decode
// bound, `corvid::value::MAX_NESTING` (128) — exported here as
// `maxNesting` (lib/src/values.dart). Converter-accepted == decodable:
// a deeper graph could be BUILT through the value-constructor ABI but
// the engine could never decode it back (dump/load), so encode rejects
// it up front with a typed CorvidException(argument) — the old posture
// (an unguarded recursion whose StackOverflowError was catchable by
// accident, not by contract) is retired.
//
// The boundary follows the engine decoder's own convention (top-level
// value is depth 0, every container's children one more, boundary
// inclusive): a chain of 128 containers round-trips; 129 throws.

import 'dart:typed_data';

import 'package:corvid_dart/corvid.dart';
import 'package:test/test.dart';

Uint8List kb(String s) => Uint8List.fromList(s.codeUnits);

/// A chain of [wrappers] nested lists around a scalar.
Object? nestedLists(int wrappers) {
  Object? v = 1;
  for (var i = 0; i < wrappers; i++) {
    v = <Object?>[v];
  }
  return v;
}

void main() {
  test('the exported cap IS the engine decode bound (128)', () {
    expect(maxNesting, 128);
  });

  test('a 129-deep list insert is a clean CorvidException(argument)', () {
    final db = Db.openMemory();
    final docs = db.collection('depthcap');
    expect(
      () => docs.insert(kb('over'), nestedLists(129)),
      throwsA(
        isA<CorvidException>()
            .having((e) => e.code, 'code', CorvidErrorCode.argument),
      ),
    );
    expect(docs.length(), 0, reason: 'nothing stored');
    docs.close();
    db.close();
  });

  test('a 128-deep list round-trips — the boundary is inclusive', () {
    final db = Db.openMemory();
    final docs = db.collection('depthcap-edge');
    docs.insert(kb('edge'), nestedLists(128));
    expect(docs.length(), 1, reason: '128-deep stored + readable');
    // Walk back down to the scalar.
    Object? cur = docs.get(kb('edge'));
    for (var i = 0; i < 128; i++) {
      cur = (cur as List<Object?>)[0];
    }
    expect(cur, 1, reason: 'innermost scalar survives the round trip');
    docs.close();
    db.close();
  });
}
