// callback_test.dart — the §1.6 callback-exception contract.
//
// The scan/update trampolines catch an exception in the user closure (a
// Dart exception must never unwind through the native frames), stash it,
// and stop/abort the engine call at the ABI level; the scan()/update()
// call sites rethrow the ORIGINAL exception (with its original stack
// trace) once the engine call has returned. These tests pin both halves:
// the exception object surfaces at the CALL SITE (not an isolate crash,
// not a CorvidException unless the callback threw one), and the engine
// is left in a consistent, usable state afterwards — the Dart shape of
// the go binding's recover-and-repanic ruling (panic_test.go).

import 'dart:typed_data';

import 'package:corvid_dart/corvid.dart';
import 'package:test/test.dart';

Uint8List kb(String s) => Uint8List.fromList(s.codeUnits);

void main() {
  late Db db;
  late Collection docs;

  setUp(() {
    db = Db.openMemory();
    docs = db.collection('docs');
  });

  tearDown(() {
    docs.close();
    db.close();
  });

  test('a scan closure exception surfaces at the scan call site', () {
    for (final k in ['a', 'b', 'c']) {
      docs.insert(kb(k), {'k': 1});
    }
    var visited = 0;
    try {
      docs.scan((key, doc) {
        visited++;
        throw StateError('scan-closure-boom');
      });
      fail('a throwing scan closure did not surface at scan()');
    } on StateError catch (e) {
      expect(e.message, 'scan-closure-boom');
    }
    expect(visited, 1, reason: 'the engine stopped at the first callback');
    // The engine saw a clean early-stop, not a broken call: it must
    // still answer normally.
    expect(docs.length(), 3);
    expect(docs.get(kb('b')), isNotNull);
  });

  test('an update closure exception surfaces at the update call site', () {
    docs.insert(kb('k'), {'n': 1});
    try {
      docs.update(
        kb('k'),
        (current) => throw StateError('update-closure-boom'),
      );
      fail('a throwing update closure did not surface at update()');
    } on StateError catch (e) {
      expect(e.message, 'update-closure-boom');
    }
    // The engine saw the aborting-callback status (nothing written); the
    // key must still hold its original document and answer reads.
    expect(docs.get(kb('k')), {'n': 1});
  });

  test('a CorvidException(argument) abort maps to the §1.6 abort contract', () {
    docs.insert(kb('k'), {'n': 1});
    try {
      docs.update(
        kb('k'),
        (current) => throw const CorvidException(
          CorvidErrorCode.argument,
          'update_abort: aborting per the fixture',
        ),
      );
      fail('expected the aborting CorvidException to surface');
    } on CorvidException catch (e) {
      expect(e.code, CorvidErrorCode.argument);
      expect(e.message, contains('update_abort'));
    }
    expect(docs.get(kb('k')), {'n': 1});
  });

  test('scan stops early without an exception (return false)', () {
    for (final k in ['a', 'b', 'c']) {
      docs.insert(kb(k), {'k': 1});
    }
    final seen = <String>[];
    docs.scan((key, doc) {
      seen.add(String.fromCharCodes(key));
      return seen.length < 2;
    });
    expect(seen, ['a', 'b']);
  });
}
