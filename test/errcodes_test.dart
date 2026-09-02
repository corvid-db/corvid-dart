// errcodes_test.dart — the frozen error-code table.
//
// Pins the frozen table (FFI.md §1.3: values are never renumbered) — the
// docs/SURFACE.tsv mapping for the engine's corvid::Error rows. The
// fixtures prove the codes the suite can trigger (10/11/12/14/15/17);
// the redb-internal fault variants have no public trigger (the engine's
// own radar exempts them), so the table itself is the proof that every
// variant maps to its documented code. Code 19 (busy) is FFI-only:
// compact exclusivity, with no engine Error variant.

import 'package:corvid_dart/corvid.dart';
import 'package:test/test.dart';

void main() {
  test('the frozen error-code table never drifts', () {
    final frozen = <CorvidErrorCode, int>{
      CorvidErrorCode.none: 0,
      CorvidErrorCode.database: 1,
      CorvidErrorCode.transaction: 2,
      CorvidErrorCode.table: 3,
      CorvidErrorCode.storage: 4,
      CorvidErrorCode.commit: 5,
      CorvidErrorCode.setDurability: 6,
      CorvidErrorCode.compaction: 7,
      CorvidErrorCode.decode: 8,
      CorvidErrorCode.corruptIndex: 9,
      CorvidErrorCode.reservedCollection: 10,
      CorvidErrorCode.invalidName: 11,
      CorvidErrorCode.argument: 12,
      CorvidErrorCode.incompatibleFormat: 13,
      CorvidErrorCode.emptyIndexTraining: 14,
      CorvidErrorCode.schemaViolation: 15,
      CorvidErrorCode.invalidDump: 16,
      CorvidErrorCode.backupTargetExists: 17,
      CorvidErrorCode.io: 18,
      CorvidErrorCode.busy: 19,
    };
    for (final e in CorvidErrorCode.values) {
      expect(
        e.value,
        frozen[e],
        reason:
            '${e.name} = ${e.value}, want ${frozen[e]} (frozen table drifted)',
      );
    }
    expect(
      CorvidErrorCode.values,
      hasLength(20),
      reason: 'table must cover exactly 0..19',
    );
    // The enum round-trips every documented code.
    for (var code = 0; code <= 19; code++) {
      expect(CorvidErrorCode.fromValue(code).value, code);
    }
  });
}
