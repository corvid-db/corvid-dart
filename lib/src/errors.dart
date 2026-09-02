// errors.dart — the binding's error type.
//
// Every failing corvid call throws a CorvidException (never returns an
// error, never lets an ABI status leak): the detailed code (FFI.md §1.3,
// read from the thread-local slot immediately after the failing call)
// plus the engine-recorded message. This is the Dart shape of the ABI
// ruling "CORVID_ERR becomes native exceptions" (FFI.md ruling 3).

import 'native.dart';
import 'values.dart';

/// The detailed corvid error codes (FFI.md §1.3, frozen per §8). Values
/// 1–18 map 1:1 onto the engine's `corvid::Error` variants; 19
/// (`busy`) is FFI-only.
enum CorvidErrorCode {
  /// No error recorded on this thread.
  none(0),

  /// Opening/creating the database file failed.
  database(1),

  /// Beginning a read/write transaction failed.
  transaction(2),

  /// Opening a storage table failed.
  table(3),

  /// A storage read/write failed.
  storage(4),

  /// Committing a write transaction failed.
  commit(5),

  /// Changing transaction durability failed.
  setDurability(6),

  /// Compacting the file failed.
  compaction(7),

  /// Stored bytes are not a decodable value.
  decode(8),

  /// Persisted index state is corrupt.
  corruptIndex(9),

  /// Collection name uses the `__` prefix.
  reservedCollection(10),

  /// Name has a NUL byte or interior `__`.
  invalidName(11),

  /// Argument outside its domain (also the FFI's NULL/UTF-8 discipline).
  argument(12),

  /// Foreign database format version.
  incompatibleFormat(13),

  /// PQ index creation with no training vectors.
  emptyIndexTraining(14),

  /// Write violates the declared schema.
  schemaViolation(15),

  /// Malformed / unknown-version dump.
  invalidDump(16),

  /// Backup path already exists.
  backupTargetExists(17),

  /// I/O error (dump/load paths, files).
  io(18),

  /// FFI-only: `compact` while derived handles are still open (§4.13).
  busy(19);

  const CorvidErrorCode(this.value);

  /// The ABI's integer code.
  final int value;

  static CorvidErrorCode fromValue(int value) => switch (value) {
    0 => CorvidErrorCode.none,
    1 => CorvidErrorCode.database,
    2 => CorvidErrorCode.transaction,
    3 => CorvidErrorCode.table,
    4 => CorvidErrorCode.storage,
    5 => CorvidErrorCode.commit,
    6 => CorvidErrorCode.setDurability,
    7 => CorvidErrorCode.compaction,
    8 => CorvidErrorCode.decode,
    9 => CorvidErrorCode.corruptIndex,
    10 => CorvidErrorCode.reservedCollection,
    11 => CorvidErrorCode.invalidName,
    12 => CorvidErrorCode.argument,
    13 => CorvidErrorCode.incompatibleFormat,
    14 => CorvidErrorCode.emptyIndexTraining,
    15 => CorvidErrorCode.schemaViolation,
    16 => CorvidErrorCode.invalidDump,
    17 => CorvidErrorCode.backupTargetExists,
    18 => CorvidErrorCode.io,
    19 => CorvidErrorCode.busy,
    _ => throw ArgumentError('unknown corvid error code $value'),
  };
}

/// The exception every failing corvid call throws. Carries the ABI's
/// detailed [code] and the engine-recorded [message]; branch on the code:
///
/// ```dart
/// try {
///   docs.insert(key, doc);
/// } on CorvidException catch (e) {
///   if (e.code == CorvidErrorCode.schemaViolation) { /* ... */ }
/// }
/// ```
class CorvidException implements Exception {
  /// The detailed corvid error code (FFI.md §1.3).
  final CorvidErrorCode code;

  /// The failure detail the engine recorded.
  final String message;

  const CorvidException(this.code, this.message);

  /// Reads the thread-local last-error slot (called immediately after a
  /// failing ABI call, on the thread the call ran on). A failure whose
  /// slot reads empty surfaces as a zero-code exception — loud, never
  /// silently misattributed (the same discipline as the go binding).
  factory CorvidException.lastError() {
    final code = CorvidErrorCode.fromValue(native.corvid_last_error_code());
    final message = lastErrorMessage();
    if (message == null) {
      return CorvidException(
        code,
        'failure recorded (code ${code.value}) without a message',
      );
    }
    return CorvidException(code, message);
  }

  @override
  String toString() => 'corvid: $message (code ${code.value})';
}

/// Turns a non-OK ABI status into the recorded CorvidException.
void checkStatus(int status) {
  if (status != 0) throw CorvidException.lastError();
}
