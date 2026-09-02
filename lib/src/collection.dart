// collection.dart — the Collection handle: mutations, reads, TTL,
// indexes, schema, graph, geo, and the §1.6 callbacks.
//
// Collection is safe for concurrent use under the same §6 close caveat
// as Db. Documents cross as Dart values (values.dart mapping); keys are
// Uint8List. Failures throw CorvidException. close() releases the engine
// handle (idempotent; a NativeFinalizer backstops a leaked handle).
//
// The scan/update callbacks cross through NativeCallable.isolateLocal:
// the engine invokes them synchronously on the calling isolate's thread
// (FFI.md §1.6 — "the callback runs on the caller's thread between
// engine operations"), which is exactly the isolateLocal contract. A
// Dart exception thrown inside the callback MUST NOT unwind through the
// native frames — the trampoline catches it, stashes it, and stops/aborts
// the engine call at the ABI level; the exception then surfaces VERBATIM
// at the scan()/update() call site once the engine call has returned
// (the Dart shape of the go binding's recover-and-repanic ruling — see
// callback_test.dart, which pins both halves).

import 'dart:ffi' as ffi;
import 'dart:typed_data';

import 'package:ffi/ffi.dart' as ffi2;

import 'bindings.dart';
import 'db.dart';
import 'errors.dart';
import 'native.dart';
import 'query.dart';
import 'values.dart';

/// The raw-handle side table for Collection (the public class carries no
/// FFI-typed members — FFI.md ruling 3; internal layers resolve the
/// pointer through this Expando).
final Expando<ffi.Pointer<corvid_coll>> _collHandles = Expando('corvidColl');

/// The raw corvid_coll handle behind [coll] (internal layers only).
ffi.Pointer<corvid_coll> collHandleOf(Collection coll) {
  final p = _collHandles[coll];
  if (p == null) {
    throw const CorvidException(
      CorvidErrorCode.database,
      'collection is closed',
    );
  }
  return p;
}

/// A handle to one collection of a [Db]: mutations, reads, TTL, indexes,
/// schema, graph edges, and geo queries.
class Collection implements ffi.Finalizable {
  static ffi.NativeFinalizer? _finalizer;

  ffi.Pointer<corvid_coll>? _p;
  final String _name;

  Collection.forDbAndName(Db db, String name)
    : _name = name,
      _p = ffi2.using((arena) {
        final n = nativeUtf8(name, arena);
        final handle = native.corvid_collection(dbHandleOf(db), n.ptr, n.len);
        if (handle == ffi.nullptr) throw CorvidException.lastError();
        return handle;
      }) {
    _collHandles[this] = _p!;
    _finalizer ??= ffi.NativeFinalizer(
      native.addresses.corvid_collection_free.cast(),
    );
    _finalizer!.attach(this, _p!.cast(), detach: this);
  }

  /// Releases the collection handle (idempotent; a NativeFinalizer
  /// backstops a leaked handle). Live collection handles keep the db's
  /// [Db.compact] busy — close them first (FFI.md §4.13). The §6
  /// quiescence contract applies: close only after in-flight operations
  /// on this handle have completed.
  void close() {
    final p = _p;
    if (p == null) return;
    _p = null;
    _finalizer?.detach(this);
    native.corvid_collection_free(p);
  }

  /// The collection's name (the handle's own record).
  String get name => _name;

  /// Inserts or overwrites the document at [key].
  void insert(Uint8List key, Object? doc) {
    final v = encodeValue(doc);
    try {
      ffi2.using((arena) {
        final k = nativeBytes(key, arena);
        checkStatus(native.corvid_insert(collHandleOf(this), k, key.length, v));
      });
    } finally {
      freeValue(v);
    }
  }

  /// Stores key/document pairs in ONE transaction: either all pairs land
  /// or the batch rolls back (a schema violation anywhere fails the whole
  /// call with nothing stored).
  void putMany(List<Uint8List> keys, List<Object?> docs) {
    if (keys.length != docs.length) {
      throw CorvidException(
        CorvidErrorCode.argument,
        'putMany: ${keys.length} keys but ${docs.length} documents',
      );
    }
    ffi2.using((arena) {
      final vals = <ffi.Pointer<corvid_value>>[];
      for (final d in docs) {
        vals.add(encodeValue(d));
      }
      try {
        final items = arena.allocate<corvid_kv>(
          keys.isEmpty ? 1 : keys.length * ffi.sizeOf<corvid_kv>(),
        );
        for (var i = 0; i < keys.length; i++) {
          final k = nativeBytes(keys[i], arena);
          items[i].key = k;
          items[i].key_len = keys[i].length;
          items[i].val = vals[i];
        }
        checkStatus(
          native.corvid_put_many(collHandleOf(this), items, keys.length),
        );
      } finally {
        for (final v in vals) {
          freeValue(v);
        }
      }
    });
  }

  /// Inserts [doc] under a fresh engine-generated key (20-digit,
  /// zero-padded, strictly monotonic per collection) and returns it.
  Uint8List insertAuto(Object? doc) {
    final v = encodeValue(doc);
    ffi.Pointer<ffi.Uint8> key = ffi.nullptr;
    try {
      final len = ffi2.malloc<ffi.Size>(1);
      try {
        key = native.corvid_insert_auto(collHandleOf(this), v, len);
        if (key == ffi.nullptr) throw CorvidException.lastError();
        return copyBytes(key, len.value);
      } finally {
        ffi2.malloc.free(len);
      }
    } finally {
      freeValue(v);
      if (key != ffi.nullptr) native.corvid_free(key.cast()); // ABI buffer
    }
  }

  /// Inserts [doc] at [key] with an expiry instant ([expiresAt], Unix
  /// seconds in the caller's epoch). A plain insert over the key later
  /// clears the expiry.
  void insertTTL(Uint8List key, Object? doc, int expiresAt) {
    final v = encodeValue(doc);
    try {
      ffi2.using((arena) {
        final k = nativeBytes(key, arena);
        checkStatus(
          native.corvid_insert_with_ttl(
            collHandleOf(this),
            k,
            key.length,
            v,
            expiresAt,
          ),
        );
      });
    } finally {
      freeValue(v);
    }
  }

  /// Sets (or moves) [key]'s expiry without rewriting the document.
  /// Setting an expiry on an absent key records it anyway (the engine's
  /// TTL index is key-addressed; harmless by design).
  void setTTL(Uint8List key, int expiresAt) {
    ffi2.using((arena) {
      final k = nativeBytes(key, arena);
      checkStatus(
        native.corvid_set_ttl(collHandleOf(this), k, key.length, expiresAt),
      );
    });
  }

  /// [key]'s expiry instant, or null when none is set.
  int? getTTL(Uint8List key) {
    return ffi2.using((arena) {
      final at = arena.allocate<ffi.Int64>(1 * ffi.sizeOf<ffi.Int64>());
      final has = arena.allocate<ffi.Int32>(1 * ffi.sizeOf<ffi.Int32>());
      final k = nativeBytes(key, arena);
      checkStatus(
        native.corvid_get_ttl(collHandleOf(this), k, key.length, at, has),
      );
      return has.value != 0 ? at.value : null;
    });
  }

  /// Removes every key whose expiry is <= [now] (inclusive) and returns
  /// how many went. Each candidate is re-verified inside the delete
  /// transaction.
  int purgeExpired(int now) {
    final purged = ffi2.malloc<ffi.Size>(1);
    try {
      checkStatus(native.corvid_purge_expired(collHandleOf(this), now, purged));
      return purged.value;
    } finally {
      ffi2.malloc.free(purged);
    }
  }

  /// Merges [patch]'s top-level fields into the map at [key] (creating it
  /// when absent); a non-map on either side replaces the document.
  void patch(Uint8List key, Object? patch) {
    final v = encodeValue(patch);
    try {
      ffi2.using((arena) {
        final k = nativeBytes(key, arena);
        checkStatus(native.corvid_patch(collHandleOf(this), k, key.length, v));
      });
    } finally {
      freeValue(v);
    }
  }

  /// Read-modify-write [key] under the engine's consistency. [fn]
  /// receives the current document (null when absent) and returns the
  /// replacement, or null to delete the key.
  ///
  /// Throwing inside [fn] aborts — nothing is written — and the thrown
  /// object surfaces verbatim at this call site (never through the
  /// native frames). Throwing a `CorvidException(argument, …)` is the
  /// canonical abort, matching the ABI's §1.6 aborting-callback contract.
  /// The callback must not call back into the engine (FFI.md §1.6).
  void update(Uint8List key, Object? Function(Object? current) fn) {
    Object? pending;
    StackTrace? pendingStack;
    final callable = ffi.NativeCallable<corvid_update_fnFunction>.isolateLocal((
      ffi.Pointer<ffi.Void> ctx,
      ffi.Pointer<corvid_value> current,
      ffi.Pointer<ffi.Pointer<corvid_value>> out,
    ) {
      out.value = ffi.nullptr; // the abort path's required shape (§1.6)
      try {
        final cur = current == ffi.nullptr ? null : decodeValue(current);
        final v = fn(cur);
        if (v == null) {
          return 0; // delete the key
        }
        out.value = encodeValue(v); // owned; consumed by the call
        return 0; // CORVID_OK
      } catch (e, st) {
        pending = e;
        pendingStack = st;
        return 1; // CORVID_ERR: abort, *out stays NULL
      }
    }, exceptionalReturn: 1); // unreachable (catch-all); CORVID_ERR-shaped
    int status;
    try {
      status = ffi2.using((arena) {
        final k = nativeBytes(key, arena);
        return native.corvid_update(
          collHandleOf(this),
          k,
          key.length,
          callable.nativeFunction.cast(),
          ffi.nullptr.cast(),
        );
      });
    } finally {
      callable.close();
    }
    final thrown = pending;
    if (thrown != null) {
      Error.throwWithStackTrace(thrown, pendingStack!); // surfaces HERE
    }
    checkStatus(status);
  }

  /// Atomic conditional write: the return value reports whether [expected]
  /// matched. A null [expected] means "key must be absent"; a null
  /// [replacement] means "delete on match". A failed compare is NOT an
  /// error. Equality is the engine's semantic equality (NaN == NaN,
  /// -0.0 == 0.0, containers element-wise).
  bool compareAndSet(Uint8List key, Object? expected, Object? replacement) {
    return ffi2.using((arena) {
      final ex = expected == null ? ffi.nullptr : encodeValue(expected);
      final re = replacement == null ? ffi.nullptr : encodeValue(replacement);
      try {
        final applied = arena.allocate<ffi.Int32>(1 * ffi.sizeOf<ffi.Int32>());
        final k = nativeBytes(key, arena);
        checkStatus(
          native.corvid_compare_and_set(
            collHandleOf(this),
            k,
            key.length,
            ex,
            re,
            applied,
          ),
        );
        return applied.value != 0;
      } finally {
        if (ex != ffi.nullptr) freeValue(ex);
        if (re != ffi.nullptr) freeValue(re);
      }
    });
  }

  /// Removes [key] (cascading its graph edges in the same transaction),
  /// returning whether a document was removed.
  bool delete(Uint8List key) {
    return ffi2.using((arena) {
      final existed = arena.allocate<ffi.Int32>(1 * ffi.sizeOf<ffi.Int32>());
      final k = nativeBytes(key, arena);
      checkStatus(
        native.corvid_delete(collHandleOf(this), k, key.length, existed),
      );
      return existed.value != 0;
    });
  }

  /// Removes every document matching [pred] (consumed by the call, even
  /// on failure — FFI.md §8) and returns how many went.
  int deleteWhere(Predicate pred) {
    final p = predConsume(pred);
    final removed = ffi2.malloc<ffi.Size>(1);
    try {
      checkStatus(native.corvid_delete_where(collHandleOf(this), p, removed));
      return removed.value;
    } finally {
      ffi2.malloc.free(removed);
    }
  }

  /// Removes each of [keys] in one call, returning how many existed.
  int deleteBatch(List<Uint8List> keys) {
    return ffi2.using((arena) {
      final removed = arena.allocate<ffi.Size>(1 * ffi.sizeOf<ffi.Size>());
      final (ptrs, lens) = nativeKeyArray(keys, arena);
      checkStatus(
        native.corvid_delete_batch(
          collHandleOf(this),
          ptrs,
          lens,
          keys.length,
          removed,
        ),
      );
      return removed.value;
    });
  }

  /// The document at [key] (null when absent), decoded per the values
  /// mapping. Map keys enumerate through the engine's
  /// `corvid_value_map_keys` (v0.3.0): every document this engine can
  /// read decodes COMPLETE — on any database, whatever wrote it.
  Object? get(Uint8List key) {
    return ffi2.using((arena) {
      final out = arena.allocate<ffi.Pointer<corvid_value>>(
        ffi.sizeOf<ffi.Pointer<corvid_value>>(),
      );
      final k = nativeBytes(key, arena);
      checkStatus(native.corvid_get(collHandleOf(this), k, key.length, out));
      final v = out.value;
      if (v == ffi.nullptr) return null; // absence is a success
      try {
        return decodeValue(v);
      } finally {
        freeValue(v);
      }
    });
  }

  /// The named fields (dot paths; all-digit segments index arrays) of the
  /// document at [key], as a map holding exactly the fields present.
  Map<String, Object?> getFields(Uint8List key, List<String> fields) {
    return ffi2.using((arena) {
      final out = arena.allocate<ffi.Pointer<corvid_value>>(
        ffi.sizeOf<ffi.Pointer<corvid_value>>(),
      );
      final k = nativeBytes(key, arena);
      checkStatus(native.corvid_get(collHandleOf(this), k, key.length, out));
      final v = out.value;
      if (v == ffi.nullptr) return <String, Object?>{};
      try {
        final result = <String, Object?>{};
        for (final f in fields) {
          final child = walkValuePath(v, f);
          if (child != ffi.nullptr) result[f] = decodeValue(child);
        }
        return result;
      } finally {
        freeValue(v);
      }
    });
  }

  /// The number of live documents (O(1) maintained counter).
  int length() {
    return ffi2.using((arena) {
      final out = arena.allocate<ffi.Size>(1 * ffi.sizeOf<ffi.Size>());
      checkStatus(native.corvid_len(collHandleOf(this), out));
      return out.value;
    });
  }

  /// Streams every (key, document) pair in key order to [fn]; [fn]
  /// returning false stops the scan early (not an error). An exception
  /// thrown by [fn] stops the scan at the ABI level and surfaces verbatim
  /// at this call site. The callback must not call back into the engine
  /// (FFI.md §1.6).
  void scan(bool Function(Uint8List key, Object? doc) fn) {
    Object? pending;
    StackTrace? pendingStack;
    CorvidException? decodeErr;
    final callable = ffi.NativeCallable<corvid_scan_fnFunction>.isolateLocal((
      ffi.Pointer<ffi.Void> ctx,
      ffi.Pointer<ffi.Uint8> key,
      int keyLen,
      ffi.Pointer<corvid_value> doc,
    ) {
      try {
        final d = decodeValue(doc); // decode failure stops the scan
        return fn(copyBytes(key.cast(), keyLen), d) ? 1 : 0;
      } on CorvidException catch (e, st) {
        decodeErr = e;
        pendingStack = st;
        return 0; // stop; not an error at the C level
      } catch (e, st) {
        pending = e;
        pendingStack = st;
        return 0; // stop the scan — rethrow at the call site
      }
    }, exceptionalReturn: 0); // unreachable (catch-all); stop-shaped
    int status;
    try {
      status = native.corvid_scan(
        collHandleOf(this),
        callable.nativeFunction.cast(),
        ffi.nullptr.cast(),
      );
    } finally {
      callable.close();
    }
    final thrown = pending;
    if (thrown != null) {
      Error.throwWithStackTrace(thrown, pendingStack!); // surfaces HERE
    }
    final derr = decodeErr;
    if (derr != null) throw derr;
    checkStatus(status);
  }

  /// Keyset pagination: up to [limit] rows in key order strictly after
  /// [after] (null to start at the beginning), plus the resume cursor —
  /// null means the end was reached. Documents always materialize in page
  /// rows.
  Page page(Uint8List? after, int limit) {
    return ffi2.using((arena) {
      final rowsOut = arena.allocate<ffi.Pointer<corvid_rows>>(
        ffi.sizeOf<ffi.Pointer<corvid_rows>>(),
      );
      final nextOut = arena.allocate<ffi.Pointer<ffi.Uint8>>(
        ffi.sizeOf<ffi.Pointer<ffi.Uint8>>(),
      );
      final nextLen = arena.allocate<ffi.Size>(1 * ffi.sizeOf<ffi.Size>());
      final ffi.Pointer<ffi.Uint8> a = (after == null || after.isEmpty)
          ? ffi.nullptr
          : nativeBytes(after, arena);
      checkStatus(
        native.corvid_page(
          collHandleOf(this),
          a,
          after?.length ?? 0,
          limit,
          rowsOut,
          nextOut,
          nextLen,
        ),
      );
      try {
        final rows = <Row>[];
        while (true) {
          final step = rowsNext(rowsOut.value);
          if (step == null) break;
          rows.add(Row(step.key, decodeValue(step.doc), step.score));
        }
        final next = nextOut.value == ffi.nullptr
            ? null
            : copyBytes(nextOut.value, nextLen.value);
        return Page(rows, next);
      } finally {
        native.corvid_rows_free(rowsOut.value);
        if (nextOut.value != ffi.nullptr) {
          native.corvid_free(nextOut.value.cast());
        }
      }
    });
  }

  /// The DIRECT positional text search (engine v0.3.0; no query handle):
  /// documents whose [field] TEXT contains [phrase] as a consecutive,
  /// IN-ORDER run of analyzed tokens, most relevant first, ties by key,
  /// up to [k] rows. The engine's analysis applies to the phrase too,
  /// and stop words collapse out of adjacency ("embedded the database"
  /// matches "embedded database"). k == 0 answers empty — inert, never
  /// an error. Rows carry the document and the BM25 phrase score (the
  /// phrase scale, NOT the builder's fused RRF scale).
  List<Row> phraseSearch(String field, String phrase, int k) {
    return ffi2.using((arena) {
      final f = nativeUtf8(field, arena);
      final ph = nativeUtf8(phrase, arena);
      final rows = native.corvid_phrase_search(
        collHandleOf(this),
        f.ptr,
        f.len,
        ph.ptr,
        ph.len,
        k,
      );
      if (rows == ffi.nullptr) throw CorvidException.lastError();
      try {
        final out = <Row>[];
        while (true) {
          final step = rowsNext(rows);
          if (step == null) break;
          out.add(Row(step.key, decodeValue(step.doc), step.score));
        }
        return out;
      } finally {
        native.corvid_rows_free(rows);
      }
    });
  }

  /// Starts a fluent query over this collection — see [Query].
  Query query() => Query.forCollection(this);

  // ---------------------------------------------------------------------
  // Indexes (FFI.md §4.10). Existing documents train a new index
  // immediately; PQ variants fail with `emptyIndexTraining` when the
  // field has no vectors or dim % subspaces != 0.
  // ---------------------------------------------------------------------

  void createScalarIndex(String field) {
    ffi2.using((arena) {
      final f = nativeUtf8(field, arena);
      checkStatus(
        native.corvid_create_scalar_index(collHandleOf(this), f.ptr, f.len),
      );
    });
  }

  void createCompoundIndex(List<String> fields) {
    ffi2.using((arena) {
      final (ptrs, lens) = nativeStrArray(fields, arena);
      checkStatus(
        native.corvid_create_compound_index(
          collHandleOf(this),
          ptrs,
          lens,
          fields.length,
        ),
      );
    });
  }

  void createTextIndex(String field) {
    ffi2.using((arena) {
      final f = nativeUtf8(field, arena);
      checkStatus(
        native.corvid_create_text_index(collHandleOf(this), f.ptr, f.len),
      );
    });
  }

  void createTextIndexOnDisk(String field) {
    ffi2.using((arena) {
      final f = nativeUtf8(field, arena);
      checkStatus(
        native.corvid_create_text_index_ondisk(
          collHandleOf(this),
          f.ptr,
          f.len,
        ),
      );
    });
  }

  void createGeoIndex(String field) {
    ffi2.using((arena) {
      final f = nativeUtf8(field, arena);
      checkStatus(
        native.corvid_create_geo_index(collHandleOf(this), f.ptr, f.len),
      );
    });
  }

  void createVectorIndex(String field, Metric metric) {
    ffi2.using((arena) {
      final f = nativeUtf8(field, arena);
      checkStatus(
        native.corvid_create_vector_index(
          collHandleOf(this),
          f.ptr,
          f.len,
          metric.value,
        ),
      );
    });
  }

  void createVectorIndexQuantized(String field, Metric metric, Quant quant) {
    ffi2.using((arena) {
      final f = nativeUtf8(field, arena);
      checkStatus(
        native.corvid_create_vector_index_quantized(
          collHandleOf(this),
          f.ptr,
          f.len,
          metric.value,
          quant.value,
        ),
      );
    });
  }

  void createVectorIndexOnDisk(String field, Metric metric) {
    ffi2.using((arena) {
      final f = nativeUtf8(field, arena);
      checkStatus(
        native.corvid_create_vector_index_ondisk(
          collHandleOf(this),
          f.ptr,
          f.len,
          metric.value,
        ),
      );
    });
  }

  void createVectorIndexOnDiskQuantized(
    String field,
    Metric metric,
    Quant quant,
  ) {
    ffi2.using((arena) {
      final f = nativeUtf8(field, arena);
      checkStatus(
        native.corvid_create_vector_index_ondisk_quantized(
          collHandleOf(this),
          f.ptr,
          f.len,
          metric.value,
          quant.value,
        ),
      );
    });
  }

  void createVectorIndexPQ(
    String field,
    Metric metric,
    int subspaces,
    int centroids,
  ) {
    ffi2.using((arena) {
      final f = nativeUtf8(field, arena);
      checkStatus(
        native.corvid_create_vector_index_pq(
          collHandleOf(this),
          f.ptr,
          f.len,
          metric.value,
          subspaces,
          centroids,
        ),
      );
    });
  }

  void createVectorIndexOnDiskPQ(
    String field,
    Metric metric,
    int subspaces,
    int centroids,
  ) {
    ffi2.using((arena) {
      final f = nativeUtf8(field, arena);
      checkStatus(
        native.corvid_create_vector_index_ondisk_pq(
          collHandleOf(this),
          f.ptr,
          f.len,
          metric.value,
          subspaces,
          centroids,
        ),
      );
    });
  }

  // ---------------------------------------------------------------------
  // Schema (FFI.md §4.10)
  // ---------------------------------------------------------------------

  /// Declares (or replaces) the collection's schema. Enforced on
  /// subsequent writes only — existing documents are not retroactively
  /// validated.
  void setSchema(List<FieldDef> defs) {
    ffi2.using((arena) {
      final arr = arena.allocate<corvid_field_def>(
        defs.isEmpty ? 1 : defs.length * ffi.sizeOf<corvid_field_def>(),
      );
      for (var i = 0; i < defs.length; i++) {
        final d = defs[i];
        final n = nativeUtf8(d.name, arena);
        arr[i].name = n.ptr;
        arr[i].name_len = n.len;
        arr[i].type = d.type.value;
        arr[i].required = d.required ? 1 : 0;
        arr[i].unique = d.unique ? 1 : 0;
      }
      checkStatus(
        native.corvid_set_schema(collHandleOf(this), arr, defs.length),
      );
    });
  }

  /// The declared schema (null when none is declared), in declaration
  /// order.
  List<FieldDef>? schema() {
    final it = ffi2.using((arena) {
      final out = arena.allocate<ffi.Pointer<corvid_schemaiter>>(
        ffi.sizeOf<ffi.Pointer<corvid_schemaiter>>(),
      );
      checkStatus(native.corvid_schema(collHandleOf(this), out));
      return out.value;
    });
    if (it == ffi.nullptr) return null; // absence is a success
    try {
      final defs = <FieldDef>[];
      while (true) {
        final step = schemaNext(it);
        if (step == null) break;
        defs.add(
          FieldDef(
            step.name,
            FieldType.fromValue(step.type),
            required: step.required,
            unique: step.unique,
          ),
        );
      }
      return defs;
    } finally {
      native.corvid_schemaiter_free(it);
    }
  }

  // ---------------------------------------------------------------------
  // Graph (FFI.md §4.11)
  // ---------------------------------------------------------------------

  /// Adds a directed edge from→to under [relation] (idempotent; weight
  /// 1.0, overwriting a prior weighted edge's weight).
  void link(Uint8List from, String relation, Uint8List to) {
    ffi2.using((arena) {
      final f = nativeBytes(from, arena);
      final r = nativeUtf8(relation, arena);
      final t = nativeBytes(to, arena);
      checkStatus(
        native.corvid_link(
          collHandleOf(this),
          f,
          from.length,
          r.ptr,
          r.len,
          t,
          to.length,
        ),
      );
    });
  }

  /// Adds a directed weighted edge (readable back via
  /// [neighborsWeighted]).
  void linkWeighted(
    Uint8List from,
    String relation,
    Uint8List to,
    double weight,
  ) {
    ffi2.using((arena) {
      final f = nativeBytes(from, arena);
      final r = nativeUtf8(relation, arena);
      final t = nativeBytes(to, arena);
      checkStatus(
        native.corvid_link_weighted(
          collHandleOf(this),
          f,
          from.length,
          r.ptr,
          r.len,
          t,
          to.length,
          weight,
        ),
      );
    });
  }

  /// Removes the edge (and its reverse), returning whether the FORWARD
  /// edge existed. Deleting a key always cascades its edges.
  bool unlink(Uint8List from, String relation, Uint8List to) {
    return ffi2.using((arena) {
      final removed = arena.allocate<ffi.Int>(1 * ffi.sizeOf<ffi.Int>());
      final f = nativeBytes(from, arena);
      final r = nativeUtf8(relation, arena);
      final t = nativeBytes(to, arena);
      checkStatus(
        native.corvid_unlink(
          collHandleOf(this),
          f,
          from.length,
          r.ptr,
          r.len,
          t,
          to.length,
          removed,
        ),
      );
      return removed.value != 0;
    });
  }

  /// The outgoing targets of [from] under [relation], in key order.
  List<Uint8List> neighbors(Uint8List from, String relation) {
    return ffi2.using((arena) {
      final f = nativeBytes(from, arena);
      final r = nativeUtf8(relation, arena);
      final cur = native.corvid_neighbors(
        collHandleOf(this),
        f,
        from.length,
        r.ptr,
        r.len,
      );
      if (cur == ffi.nullptr) throw CorvidException.lastError();
      return _walkByteStrs(cur);
    });
  }

  /// The incoming sources of [to] under [relation], in key order.
  List<Uint8List> inNeighbors(Uint8List to, String relation) {
    return ffi2.using((arena) {
      final t = nativeBytes(to, arena);
      final r = nativeUtf8(relation, arena);
      final cur = native.corvid_in_neighbors(
        collHandleOf(this),
        t,
        to.length,
        r.ptr,
        r.len,
      );
      if (cur == ffi.nullptr) throw CorvidException.lastError();
      return _walkByteStrs(cur);
    });
  }

  /// (target, weight) for [from]'s outgoing edges under [relation], in
  /// key order.
  List<Weighted> neighborsWeighted(Uint8List from, String relation) {
    return ffi2.using((arena) {
      final f = nativeBytes(from, arena);
      final r = nativeUtf8(relation, arena);
      final cur = native.corvid_neighbors_weighted(
        collHandleOf(this),
        f,
        from.length,
        r.ptr,
        r.len,
      );
      if (cur == ffi.nullptr) throw CorvidException.lastError();
      try {
        final out = <Weighted>[];
        while (true) {
          final step = geoNext(cur);
          if (step == null) break;
          out.add(Weighted(step.key, step.dist)); // no doc for these (§4.12)
        }
        return out;
      } finally {
        native.corvid_geohits_free(cur);
      }
    });
  }

  /// Breadth-first walk of [relation] up to [hops] levels from [start]:
  /// the reachable nodes EXCLUDING [start], each once, in BFS order;
  /// cycles terminate; hops == 0 yields nothing.
  List<Uint8List> traverse(Uint8List start, String relation, int hops) {
    return ffi2.using((arena) {
      final s = nativeBytes(start, arena);
      final r = nativeUtf8(relation, arena);
      final cur = native.corvid_traverse(
        collHandleOf(this),
        s,
        start.length,
        r.ptr,
        r.len,
        hops,
      );
      if (cur == ffi.nullptr) throw CorvidException.lastError();
      return _walkByteStrs(cur);
    });
  }

  // ---------------------------------------------------------------------
  // Geo (FFI.md §4.12). Hits come back nearest-first (radius/nearest) or
  // in key order (bbox), with haversine kilometres; documents lacking a
  // valid point are skipped.
  // ---------------------------------------------------------------------

  /// Documents whose [field] point lies within [radiusKm] of
  /// ([lat], [lon]) — inclusive, nearest first, ties by key.
  List<GeoHit> geoWithinRadius(
    String field,
    double lat,
    double lon,
    double radiusKm,
  ) {
    return ffi2.using((arena) {
      final f = nativeUtf8(field, arena);
      final h = native.corvid_geo_within_radius(
        collHandleOf(this),
        f.ptr,
        f.len,
        lat,
        lon,
        radiusKm,
      );
      if (h == ffi.nullptr) throw CorvidException.lastError();
      return _walkGeoHits(h);
    });
  }

  /// Documents whose [field] point lies inside the box
  /// [minLat, maxLat] × [minLon, maxLon], in key order. Bounds are
  /// validated at entry — inverted latitude rejected with `argument`;
  /// minLon > maxLon wraps the antimeridian.
  List<GeoHit> geoWithinBBox(
    String field,
    double minLat,
    double minLon,
    double maxLat,
    double maxLon,
  ) {
    return ffi2.using((arena) {
      final f = nativeUtf8(field, arena);
      final h = native.corvid_geo_within_bbox(
        collHandleOf(this),
        f.ptr,
        f.len,
        minLat,
        minLon,
        maxLat,
        maxLon,
      );
      if (h == ffi.nullptr) throw CorvidException.lastError();
      return _walkGeoHits(h);
    });
  }

  /// The [k] documents nearest to ([lat], [lon]) by [field] point —
  /// exact, expanding radius.
  List<GeoHit> geoNearest(String field, double lat, double lon, int k) {
    return ffi2.using((arena) {
      final f = nativeUtf8(field, arena);
      final h = native.corvid_geo_nearest(
        collHandleOf(this),
        f.ptr,
        f.len,
        lat,
        lon,
        k,
      );
      if (h == ffi.nullptr) throw CorvidException.lastError();
      return _walkGeoHits(h);
    });
  }

  List<GeoHit> _walkGeoHits(ffi.Pointer<corvid_geohits> h) {
    try {
      final out = <GeoHit>[];
      while (true) {
        final step = geoNext(h);
        if (step == null) break;
        final doc = step.doc == null ? null : decodeValue(step.doc!);
        out.add(GeoHit(step.key, step.dist, doc));
      }
      return out;
    } finally {
      native.corvid_geohits_free(h);
    }
  }

  List<Uint8List> _walkByteStrs(ffi.Pointer<corvid_strs> cur) {
    try {
      final out = <Uint8List>[];
      final str = ffi2.malloc<ffi.Pointer<ffi.Char>>();
      final len = ffi2.malloc<ffi.Size>(1);
      try {
        while (native.corvid_strs_next(cur, str, len) != 0) {
          out.add(copyBytes(str.value.cast(), len.value));
        }
      } finally {
        ffi2.malloc.free(str);
        ffi2.malloc.free(len);
      }
      return out;
    } finally {
      native.corvid_strs_free(cur);
    }
  }
}
