// db.dart — the Db handle: open/close, collections, admin.
//
// Lifetime mapping (docs/PLAN.md): each corvid_db handle becomes a Dart
// Db with an explicit `close()` (idempotent) and a NativeFinalizer
// attached as a BACKSTOP only — close deliberately; the finalizer exists
// so a leaked Db cannot pin engine memory forever. Db is safe for
// concurrent use from multiple isolates' threads via the engine's own
// Arc<Mutex> story (FFI.md §6: reads concurrent, writes serialized by
// the engine); the API is synchronous on purpose — the engine has no
// async surface, so Future-returning wrappers would be a lie.
//
// Close caveat (FFI.md §6, the quiescence contract): close only after
// every concurrent operation on this Db has completed — freeing the
// engine handle while another thread is inside a call on it is undefined
// behavior. The closed-handle gate below is TOCTOU by design (a loud
// use-after-close rejection, not a lock); sequencing close against
// in-flight calls is the caller's contract.

import 'dart:ffi' as ffi;

import 'package:ffi/ffi.dart' as ffi2;

import 'bindings.dart';
import 'collection.dart';
import 'errors.dart';
import 'native.dart';
import 'values.dart';

/// An open corvid database: file-backed via [Db.open], in-memory via
/// [Db.openMemory].
///
/// ```dart
/// final db = Db.open('app.corvid');   // or Db.openMemory()
/// final docs = db.collection('docs');
/// // ...
/// docs.close();
/// db.close();
/// ```
/// The raw-handle side table: the public Db class carries NO FFI-typed
/// members (FFI.md ruling 3 — no FFI symbol leaks into the public API);
/// this package's other internal layers resolve a Db's pointer through
/// the Expando instead.
final Expando<ffi.Pointer<corvid_db>> _dbHandles = Expando('corvidDb');

/// The raw corvid_db handle behind [db] (internal layers only).
ffi.Pointer<corvid_db> dbHandleOf(Db db) {
  final p = _dbHandles[db];
  if (p == null) {
    throw const CorvidException(CorvidErrorCode.database, 'database is closed');
  }
  return p;
}

class Db implements ffi.Finalizable {
  static ffi.NativeFinalizer? _finalizer;

  ffi.Pointer<corvid_db>? _p;

  Db._(this._p) {
    _dbHandles[this] = _p!;
    _finalizer ??= ffi.NativeFinalizer(native.addresses.corvid_close.cast());
    _finalizer!.attach(this, _p!.cast(), detach: this);
  }

  static const int _ffiVersionWanted = 1; // FFI.md §4.1

  /// Opens (or creates) a file-backed database at [path].
  ///
  /// Throws [CorvidException] (code `database` / `incompatibleFormat` /
  /// `io`) when the engine refuses the open. An ABI-version mismatch
  /// between the loaded cdylib and this binding throws immediately with
  /// code `incompatibleFormat` — bindings verify the version before
  /// anything else (FFI.md §4.1).
  static Db open(String path) {
    _verifyAbi();
    return ffi2.using((arena) {
      final p = nativeUtf8(path, arena);
      final handle = native.corvid_open(p.ptr, p.len);
      if (handle == ffi.nullptr) throw CorvidException.lastError();
      return Db._(handle);
    });
  }

  /// Opens a private in-memory database (no file).
  static Db openMemory() {
    _verifyAbi();
    final handle = native.corvid_open_memory();
    if (handle == ffi.nullptr) throw CorvidException.lastError();
    return Db._(handle);
  }

  static void _verifyAbi() {
    final v = native.corvid_ffi_version();
    if (v != _ffiVersionWanted) {
      throw CorvidException(
        CorvidErrorCode.incompatibleFormat,
        'corvid: FFI version $v, this binding speaks $_ffiVersionWanted',
      );
    }
  }

  void _checkOpen() {
    if (_p == null) {
      throw const CorvidException(
        CorvidErrorCode.database,
        'database is closed',
      );
    }
  }

  /// Closes the database (idempotent). Derived [Collection] handles keep
  /// the engine alive through their own reference (FFI.md §2); close them
  /// too. A NativeFinalizer performs the close as a backstop for a
  /// leaked Db — treat an explicit close as the only supported path, and
  /// honour the §6 quiescence contract: close only after every
  /// concurrent operation on this Db has completed.
  void close() {
    final p = _p;
    if (p == null) return;
    _p = null;
    _finalizer?.detach(this);
    checkStatus(native.corvid_close(p));
  }

  /// Acquires a handle to the named collection (created on first write).
  /// Reserved and invalid names surface at write time, not here —
  /// exactly like the ABI (FFI.md §4.2). Close the returned handle when
  /// finished; note that live collection handles keep `compact` busy
  /// (FFI.md §4.13).
  Collection collection(String name) {
    _checkOpen();
    return Collection.forDbAndName(this, name);
  }

  /// Lists the database's user collection names, in engine (name) order.
  /// Listing never creates anything.
  List<String> collections() {
    _checkOpen();
    final cur = native.corvid_collections(_p!);
    if (cur == ffi.nullptr) throw CorvidException.lastError();
    return walkStrs(cur);
  }

  /// Writes a portable, version-stamped dump of the whole database to
  /// [path] (one read snapshot).
  void dump(String path) {
    _checkOpen();
    ffi2.using((arena) {
      final p = nativeUtf8(path, arena);
      checkStatus(native.corvid_dump_to_path(_p!, p.ptr, p.len));
    });
  }

  /// Replays a dump file (as [dump] writes) into this database; existing
  /// collections merge per the engine contract.
  void load(String path) {
    _checkOpen();
    ffi2.using((arena) {
      final p = nativeUtf8(path, arena);
      checkStatus(native.corvid_load_from_path(_p!, p.ptr, p.len));
    });
  }

  /// Replays a dump file into this database, renaming source collections
  /// on the fly (the migration path for legacy `__`-containing names).
  /// An invalid target fails with `invalidName`, a colliding rename map
  /// with `argument` — both BEFORE the stream is read (FFI.md §4.13).
  void loadWithRenames(String path, Map<String, String> renames) {
    _checkOpen();
    ffi2.using((arena) {
      final p = nativeUtf8(path, arena);
      final olds = renames.keys.toList(growable: false);
      final news = renames.values.toList(growable: false);
      final (oldPtrs, oldLens) = nativeStrArray(olds, arena);
      final (newPtrs, newLens) = nativeStrArray(news, arena);
      checkStatus(
        native.corvid_load_from_path_with_renames(
          _p!,
          p.ptr,
          p.len,
          oldPtrs,
          newPtrs,
          oldLens,
          newLens,
          olds.length,
        ),
      );
    });
  }

  /// Copies the database file to a fresh [path] (an existing target
  /// fails with `backupTargetExists`). Consistent point-in-time, safe
  /// while writers are active.
  void backup(String path) {
    _checkOpen();
    ffi2.using((arena) {
      final p = nativeUtf8(path, arena);
      checkStatus(native.corvid_backup(_p!, p.ptr, p.len));
    });
  }

  /// Reclaims file space after heavy deletes; returns whether any data
  /// moved. The engine requires EXCLUSIVE access: every [Collection]
  /// derived from this Db must be closed first, or the call fails with
  /// `busy` (FFI.md §4.13). In-memory databases succeed with no
  /// movement.
  bool compact() {
    _checkOpen();
    final moved = ffi2.malloc<ffi.Int>();
    try {
      checkStatus(native.corvid_compact(_p!, moved));
      return moved.value != 0;
    } finally {
      ffi2.malloc.free(moved);
    }
  }
}
