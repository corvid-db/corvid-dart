// query.dart — the fluent Query builder, predicates, and result types.
//
// A Query is a single-shot builder chain (FFI.md §6): build, call exactly
// one terminal (run or an aggregation), done. Build-step failures throw
// immediately (Dart's fail-fast idiom over the go binding's held-error
// terminal surfacing — same information, earlier); the native query
// handle is consumed by the terminal (even on failure, spec §8) and an
// abandoned builder is freed by close() with a NativeFinalizer backstop.
// Predicates are consumed by filter/deleteWhere/the combinators exactly
// as the ABI consumes them.
//
// Documents in run() rows materialize through select(): a projected row
// decodes from exactly the selected fields. Without select(), Row.doc is
// null — retrieval queries return keys and scores; pair with get (or
// Collection.phraseSearch, whose rows always carry documents).

import 'dart:ffi' as ffi;
import 'dart:typed_data';

import 'package:ffi/ffi.dart' as ffi2;

import 'bindings.dart';
import 'collection.dart';
import 'errors.dart';
import 'native.dart';
import 'values.dart';

/// The vector distance metric (FFI.md §1.4, frozen per §8).
enum Metric {
  /// Cosine distance `1 - cos_sim` in `[0,2]`; zero-norm = maximally
  /// distant.
  cosine(0),

  /// Negated dot product (larger dot sorts first).
  dot(1),

  /// Squared Euclidean (monotonic with L2).
  l2(2);

  const Metric(this.value);

  /// The ABI's integer discriminant.
  final int value;
}

/// The stored-vector quantization mode (FFI.md §1.4, frozen per §8).
enum Quant {
  /// Full `f32` precision (`dim * 4` bytes/vector).
  none(0),

  /// One bit per dimension (sign), Hamming; ~32x smaller.
  binary(1),

  /// 8-bit per-vector min+scale; ~4x smaller.
  scalar(2);

  const Quant(this.value);

  /// The ABI's integer discriminant.
  final int value;
}

/// The declared type of a schema field (FFI.md §1.4, frozen per §8).
enum FieldType {
  /// Any value accepted.
  any(0),

  /// Booleans.
  boolean(1),

  /// 64-bit integers.
  integer(2),

  /// 64-bit floats.
  float(3),

  /// UTF-8 text.
  text(4),

  /// Opaque bytes.
  bytes(5),

  /// Dense f32 embeddings.
  vector(6),

  /// Ordered lists.
  array(7),

  /// String-keyed maps.
  map(8);

  const FieldType(this.value);

  /// The ABI's integer discriminant.
  final int value;

  /// Resolves an ABI discriminant to the public enum (the internal
  /// mirror of corvid_field_type).
  static FieldType fromValue(int v) => switch (v) {
    0 => FieldType.any,
    1 => FieldType.boolean,
    2 => FieldType.integer,
    3 => FieldType.float,
    4 => FieldType.text,
    5 => FieldType.bytes,
    6 => FieldType.vector,
    7 => FieldType.array,
    8 => FieldType.map,
    _ => throw ArgumentError('unknown corvid field type $v'),
  };
}

/// One declared schema field.
class FieldDef {
  /// The field's name.
  final String name;

  /// The accepted value type.
  final FieldType type;

  /// The field must be present and non-null on every write.
  final bool required;

  /// No two documents may share this field's value.
  final bool unique;

  const FieldDef(
    this.name,
    this.type, {
    this.required = false,
    this.unique = false,
  });
}

/// One query result row: the key, the projected document (null unless
/// [Query.select] was called), and the relevance score (0 for
/// non-scoring queries).
class Row {
  /// The row's key.
  final Uint8List key;

  /// The projected document — null without select() (retrieval rows
  /// carry keys and scores); always present for phraseSearch rows.
  final Object? doc;

  /// The fused RRF score (run rows) or the BM25 phrase score
  /// (phraseSearch rows) — the two producers keep their own scales.
  final double score;

  const Row(this.key, this.doc, this.score);
}

/// One page of [Collection.page].
class Page {
  /// The page's rows, in key order.
  final List<Row> rows;

  /// The resume cursor — null means the collection's end.
  final Uint8List? next;

  const Page(this.rows, this.next);
}

/// One group-aggregate result, in engine (ascending group-key) order.
class Group {
  /// The canonical group key (text bare; `i:`/`f:`/`b:` tagged).
  final String key;

  /// The group's count, sum, or mean.
  final double value;

  const Group(this.key, this.value);
}

/// One weighted graph edge.
class Weighted {
  /// The edge's target key.
  final Uint8List key;

  /// The edge weight (1.0 for unweighted links).
  final double weight;

  const Weighted(this.key, this.weight);
}

/// One geo query hit. [doc] is null for weighted-neighbor cursors, which
/// carry no document (FFI.md §4.12).
class GeoHit {
  /// The hit's key.
  final Uint8List key;

  /// Kilometres from the query point (haversine); the 0.0 sentinel for
  /// bbox hits; the edge weight for weighted neighbors.
  final double distanceKm;

  /// The hit's document, when the cursor carries documents.
  final Object? doc;

  const GeoHit(this.key, this.distanceKm, this.doc);
}

// ---------------------------------------------------------------------------
// Predicates
// ---------------------------------------------------------------------------

/// A filter tree node. Build one from a field expression
/// (`field('n').eq(5)`, `field('body').startsWith('rust')`, …), combine
/// with and/or/not. A Predicate is consumed by [Query.filter],
/// [Collection.deleteWhere], and the combinators — exactly once; close()
/// frees a never-consumed root. Single-isolate use (FFI.md §6).
class Predicate implements ffi.Finalizable {
  static ffi.NativeFinalizer? _finalizer;

  ffi.Pointer<corvid_pred>? _p;

  Predicate._ok(ffi.Pointer<corvid_pred> p) : _p = p {
    _predHandles[this] = p;
    _finalizer ??= ffi.NativeFinalizer(
      native.addresses.corvid_pred_free.cast(),
    );
    _finalizer!.attach(this, p.cast(), detach: this);
  }

  /// Frees a never-consumed predicate (idempotent; a NativeFinalizer
  /// backstops an abandoned root).
  void close() {
    final p = _p;
    if (p == null) return;
    _p = null;
    _predHandles[this] = null;
    _finalizer?.detach(this);
    native.corvid_pred_free(p);
  }
}

/// The raw-handle side table for Predicate (the public class carries no
/// FFI-typed members — FFI.md ruling 3).
final Expando<ffi.Pointer<corvid_pred>> _predHandles = Expando('corvidPred');

/// Marks the predicate's native handle as consumed by the ABI (spec §8 —
/// consumption happens even when the consuming call fails) and returns
/// it (internal layers only).
ffi.Pointer<corvid_pred> predConsume(Predicate pred) {
  final p = _predHandles[pred];
  if (p == null) {
    throw const CorvidException(
      CorvidErrorCode.argument,
      'predicate already consumed',
    );
  }
  _predHandles[pred] = null;
  // The handle now belongs to the ABI (consumed even when the consuming
  // call fails — spec §8): the backstop finalizer must let go, or a
  // later GC would double-free it.
  Predicate._finalizer?.detach(pred);
  return p;
}

/// Starts a predicate over a document field (dot path).
///
/// ```dart
/// field('age').ge(30)
/// field('user.name').eq('ada')
/// field('v').geoWithin(52.5, 13.4, 10)
/// ```
FieldExpr field(String path) => FieldExpr(path);

/// The fluent entry for field predicates.
class FieldExpr {
  final String _path;

  const FieldExpr(this._path);

  Predicate _ok(ffi.Pointer<corvid_pred> p) => Predicate._ok(p);

  /// Matches documents that carry the field.
  Predicate exists() => ffi2.using((arena) {
    final p = nativeUtf8(_path, arena);
    final h = native.corvid_pred_exists(p.ptr, p.len);
    if (h == ffi.nullptr) throw CorvidException.lastError();
    return _ok(h);
  });

  Predicate _compare(int op, Object? v) {
    final cv = encodeValue(v);
    try {
      return ffi2.using((arena) {
        final p = nativeUtf8(_path, arena);
        final h = native.corvid_pred_compare(p.ptr, p.len, op, cv);
        if (h == ffi.nullptr) throw CorvidException.lastError();
        return _ok(h);
      });
    } finally {
      freeValue(cv); // cloned into the tree (FFI.md §5)
    }
  }

  /// Matches field == v (the engine's semantic equality).
  Predicate eq(Object? v) => _compare(0, v);

  /// Matches field != v.
  Predicate ne(Object? v) => _compare(1, v);

  /// Matches field < v (numbers/text only).
  Predicate lt(Object? v) => _compare(2, v);

  /// Matches field <= v.
  Predicate le(Object? v) => _compare(3, v);

  /// Matches field > v.
  Predicate gt(Object? v) => _compare(4, v);

  /// Matches field >= v.
  Predicate ge(Object? v) => _compare(5, v);

  /// Matches lo <= field <= hi (inclusive).
  Predicate between(Object? lo, Object? hi) {
    final l = encodeValue(lo);
    final h = encodeValue(hi);
    try {
      return ffi2.using((arena) {
        final p = nativeUtf8(_path, arena);
        final handle = native.corvid_pred_between(p.ptr, p.len, l, h);
        if (handle == ffi.nullptr) throw CorvidException.lastError();
        return _ok(handle);
      });
    } finally {
      freeValue(l);
      freeValue(h);
    }
  }

  /// Matches a text field's prefix (false on non-text/missing).
  Predicate startsWith(String prefix) => ffi2.using((arena) {
    final p = nativeUtf8(_path, arena);
    final s = nativeUtf8(prefix, arena);
    final h = native.corvid_pred_starts_with(p.ptr, p.len, s.ptr, s.len);
    if (h == ffi.nullptr) throw CorvidException.lastError();
    return _ok(h);
  });

  /// Matches a text field's substring.
  Predicate contains(String substr) => ffi2.using((arena) {
    final p = nativeUtf8(_path, arena);
    final s = nativeUtf8(substr, arena);
    final h = native.corvid_pred_contains(p.ptr, p.len, s.ptr, s.len);
    if (h == ffi.nullptr) throw CorvidException.lastError();
    return _ok(h);
  });

  /// Matches field ∈ values.
  Predicate isIn(Iterable<Object?> values) {
    final vals = values.toList(growable: false);
    final ptrs = <ffi.Pointer<corvid_value>>[];
    for (final v in vals) {
      ptrs.add(encodeValue(v));
    }
    try {
      return ffi2.using((arena) {
        final p = nativeUtf8(_path, arena);
        final arr = vals.isEmpty
            ? ffi.nullptr
            : arena.allocate<ffi.Pointer<corvid_value>>(
                vals.length * ffi.sizeOf<ffi.Pointer<corvid_value>>(),
              );
        for (var i = 0; i < ptrs.length; i++) {
          arr[i] = ptrs[i];
        }
        final h = native.corvid_pred_in(p.ptr, p.len, arr, vals.length);
        if (h == ffi.nullptr) throw CorvidException.lastError();
        return _ok(h);
      });
    } finally {
      for (final v in ptrs) {
        freeValue(v);
      }
    }
  }

  /// Matches documents whose geo field (a `[lat, lon]` array or a
  /// `{lat, lon}` map) lies within [radiusKm] of ([lat], [lon]) —
  /// inclusive, haversine.
  Predicate geoWithin(double lat, double lon, double radiusKm) => ffi2.using((
    arena,
  ) {
    final p = nativeUtf8(_path, arena);
    final h = native.corvid_pred_geo_within(p.ptr, p.len, lat, lon, radiusKm);
    if (h == ffi.nullptr) throw CorvidException.lastError();
    return _ok(h);
  });
}

// The combinators live on Predicate (extension keeps the class API tidy
// while mirroring the go binding's method set).
extension PredicateCombinators on Predicate {
  /// Negates this predicate (consuming it).
  Predicate not() {
    final p = predConsume(this);
    final h = native.corvid_pred_not(p);
    if (h == ffi.nullptr) throw CorvidException.lastError();
    return Predicate._ok(h);
  }

  /// Conjoins this and [other] (consuming both).
  Predicate and(Predicate other) => _combine(this, other, true);

  /// Disjoins this and [other] (consuming both).
  Predicate or(Predicate other) => _combine(this, other, false);
}

Predicate _combine(Predicate a, Predicate b, bool isAnd) {
  final pa = predConsume(a);
  final pb = predConsume(b);
  final h = isAnd
      ? native.corvid_pred_and(pa, pb)
      : native.corvid_pred_or(pa, pb);
  if (h == ffi.nullptr) throw CorvidException.lastError();
  return Predicate._ok(h);
}

// ---------------------------------------------------------------------------
// Query builder
// ---------------------------------------------------------------------------

/// A single-shot query builder over one Collection. Chain the shaping
/// methods, then call exactly one terminal — [run] or an aggregation —
/// which consumes the builder. Single-isolate use (FFI.md §6); builders
/// are cheap.
class Query implements ffi.Finalizable {
  static ffi.NativeFinalizer? _finalizer;

  ffi.Pointer<corvid_query>? _p;
  bool _selected = false;

  Query.forCollection(Collection coll) {
    final handle = native.corvid_query_new(collHandleOf(coll));
    if (handle == ffi.nullptr) throw CorvidException.lastError();
    _p = handle;
    _finalizer ??= ffi.NativeFinalizer(
      native.addresses.corvid_query_free.cast(),
    );
    _finalizer!.attach(this, handle.cast(), detach: this);
  }

  ffi.Pointer<corvid_query> _raw() {
    final p = _p;
    if (p == null) {
      throw const CorvidException(
        CorvidErrorCode.argument,
        'query already consumed',
      );
    }
    return p;
  }

  void _step(void Function(ffi.Pointer<corvid_query> q) op) {
    op(_raw());
  }

  /// Frees a builder abandoned without a terminal (idempotent; a
  /// NativeFinalizer backstops it).
  void close() {
    final p = _p;
    if (p == null) return;
    _p = null;
    _finalizer?.detach(this);
    native.corvid_query_free(p);
  }

  ffi.Pointer<corvid_query> _consumeHandle() {
    final p = _raw();
    _p = null;
    _finalizer?.detach(this);
    return p;
  }

  /// Constrains the query with [pred] (consuming it).
  Query filter(Predicate pred) {
    final p = predConsume(pred);
    _step((q) => checkStatus(native.corvid_query_filter(q, p)));
    return this;
  }

  /// Adds an ANN vector source over [field] (top-[k], [metric]).
  Query vector(String field, Float32List query, int k, Metric metric) {
    return ffi2.using((arena) {
      final f = nativeUtf8(field, arena);
      final q = query.isEmpty
          ? arena.allocate<ffi.Float>(1 * ffi.sizeOf<ffi.Float>())
          : arena.allocate<ffi.Float>(query.length * ffi.sizeOf<ffi.Float>());
      if (query.isNotEmpty) q.asTypedList(query.length).setAll(0, query);
      _step(
        (h) => checkStatus(
          native.corvid_query_vector(
            h,
            f.ptr,
            f.len,
            q,
            query.length,
            k,
            metric.value,
          ),
        ),
      );
      return this;
    });
  }

  /// Adds a BM25 text source over [field] (top-[k]).
  Query text(String field, String query, int k) {
    return ffi2.using((arena) {
      final f = nativeUtf8(field, arena);
      final s = nativeUtf8(query, arena);
      _step(
        (h) => checkStatus(
          native.corvid_query_text(h, f.ptr, f.len, s.ptr, s.len, k),
        ),
      );
      return this;
    });
  }

  /// Fuses multiple sources with reciprocal-rank fusion ([k] is the RRF
  /// constant, e.g. 60). Validated at execution (FFI.md audit C6).
  Query fuseRRF(double k) {
    _step((q) => checkStatus(native.corvid_query_fuse_rrf(q, k)));
    return this;
  }

  /// Reranks fused sources with maximal-marginal-relevance ([lambda]
  /// trades relevance against diversity; anchored on the first vector
  /// source). Validated at execution.
  Query rerankMMR(double lambda) {
    _step((q) => checkStatus(native.corvid_query_rerank_mmr(q, lambda)));
    return this;
  }

  /// Relaxes vector execution to approximate scanning (a filtered
  /// single-vector-source query may use its ANN index with
  /// over-fetch-then-filter).
  Query approx() {
    _step((q) => checkStatus(native.corvid_query_approx(q)));
    return this;
  }

  /// Caps the result at [n] rows (applied after offset; 0 yields empty).
  Query limit(int n) {
    _step((q) => checkStatus(native.corvid_query_limit(q, n)));
    return this;
  }

  /// Skips the first [n] rows (applied after ordering, before limit).
  Query offset(int n) {
    _step((q) => checkStatus(native.corvid_query_offset(q, n)));
    return this;
  }

  /// Orders results by [field] instead of rank: numbers first in value
  /// order, texts lexically after them, incomparable values after those,
  /// rows missing the field last, ties by key; [descending] reverses
  /// within-class order only.
  Query orderBy(String field, {bool descending = false}) {
    return ffi2.using((arena) {
      final f = nativeUtf8(field, arena);
      _step(
        (q) => checkStatus(
          native.corvid_query_order_by(q, f.ptr, f.len, descending ? 1 : 0),
        ),
      );
      return this;
    });
  }

  /// Projects rows to the named top-level fields — the only shape in
  /// which run() materializes documents (Row.doc decodes from exactly
  /// these fields). An empty list projects map documents to empty maps
  /// (the engine's `select(vec![])`).
  Query select(List<String> fields) {
    if (fields.isNotEmpty) _selected = true;
    ffi2.using((arena) {
      final (ptrs, lens) = nativeStrArray(fields, arena);
      _step(
        (q) => checkStatus(
          native.corvid_query_select(q, ptrs, lens, fields.length),
        ),
      );
    });
    return this;
  }

  /// Executes the query and returns its rows (consuming the builder).
  /// Row.doc is non-null (when the document is a map) only under select
  /// — see the file comment.
  List<Row> run() {
    final rows = native.corvid_query_run(_consumeHandle());
    if (rows == ffi.nullptr) throw CorvidException.lastError();
    try {
      final out = <Row>[];
      while (true) {
        final step = rowsNext(rows);
        if (step == null) break;
        Object? doc;
        if (_selected) {
          doc = decodeValue(step.doc); // borrowed: decode before next step
        }
        out.add(Row(step.key, doc, step.score));
      }
      return out;
    } finally {
      native.corvid_rows_free(rows);
    }
  }

  /// The number of matching documents (terminal; O(1) when unfiltered).
  int count() {
    return ffi2.using((arena) {
      final out = arena.allocate<ffi.Size>(1 * ffi.sizeOf<ffi.Size>());
      checkStatus(native.corvid_query_count(_consumeHandle(), out));
      return out.value;
    });
  }

  /// The number of distinct values of [field] (terminal; the canonical
  /// group key — missing and container values ignored).
  int countDistinct(String field) {
    return ffi2.using((arena) {
      final out = arena.allocate<ffi.Size>(1 * ffi.sizeOf<ffi.Size>());
      final f = nativeUtf8(field, arena);
      checkStatus(
        native.corvid_query_count_distinct(_consumeHandle(), f.ptr, f.len, out),
      );
      return out.value;
    });
  }

  /// The sum of [field]'s numeric values (terminal; missing/non-numeric
  /// skipped, an all-skipped field sums to 0).
  double sum(String field) {
    return ffi2.using((arena) {
      final out = arena.allocate<ffi.Double>(1 * ffi.sizeOf<ffi.Double>());
      final f = nativeUtf8(field, arena);
      checkStatus(native.corvid_query_sum(_consumeHandle(), f.ptr, f.len, out));
      return out.value;
    });
  }

  /// The mean of [field]'s numeric values, or null when no document
  /// carries a numeric value there (terminal).
  double? avg(String field) {
    return ffi2.using((arena) {
      final out = arena.allocate<ffi.Double>(1 * ffi.sizeOf<ffi.Double>());
      final has = arena.allocate<ffi.Int>(1 * ffi.sizeOf<ffi.Int>());
      final f = nativeUtf8(field, arena);
      checkStatus(
        native.corvid_query_avg(_consumeHandle(), f.ptr, f.len, out, has),
      );
      return has.value != 0 ? out.value : null;
    });
  }

  /// [field]'s minimum comparable value, or null when absent (terminal).
  Object? min(String field) => _minmax(field, true);

  /// [field]'s maximum comparable value, or null when absent (terminal).
  Object? max(String field) => _minmax(field, false);

  Object? _minmax(String field, bool isMin) {
    return ffi2.using((arena) {
      final out = arena.allocate<ffi.Pointer<corvid_value>>(
        ffi.sizeOf<ffi.Pointer<corvid_value>>(),
      );
      final f = nativeUtf8(field, arena);
      checkStatus(
        isMin
            ? native.corvid_query_min(_consumeHandle(), f.ptr, f.len, out)
            : native.corvid_query_max(_consumeHandle(), f.ptr, f.len, out),
      );
      final v = out.value;
      if (v == ffi.nullptr) return null; // absence is a success
      try {
        return decodeValue(v);
      } finally {
        freeValue(v);
      }
    });
  }

  /// Counts matching documents grouped by the value at [field]
  /// (terminal), in ascending group-key order.
  List<Group> groupCount(String field) {
    return ffi2.using((arena) {
      final f = nativeUtf8(field, arena);
      final it = native.corvid_query_group_count(
        _consumeHandle(),
        f.ptr,
        f.len,
      );
      if (it == ffi.nullptr) throw CorvidException.lastError();
      return [for (final (k, v) in walkGroups(it)) Group(k, v)];
    });
  }

  /// Sums [valueField] grouped by [groupField] (terminal).
  List<Group> groupSum(String groupField, String valueField) {
    return ffi2.using((arena) {
      final g = nativeUtf8(groupField, arena);
      final v = nativeUtf8(valueField, arena);
      final it = native.corvid_query_group_sum(
        _consumeHandle(),
        g.ptr,
        g.len,
        v.ptr,
        v.len,
      );
      if (it == ffi.nullptr) throw CorvidException.lastError();
      return [for (final (k, x) in walkGroups(it)) Group(k, x)];
    });
  }

  /// Averages [valueField] grouped by [groupField] (terminal).
  List<Group> groupAvg(String groupField, String valueField) {
    return ffi2.using((arena) {
      final g = nativeUtf8(groupField, arena);
      final v = nativeUtf8(valueField, arena);
      final it = native.corvid_query_group_avg(
        _consumeHandle(),
        g.ptr,
        g.len,
        v.ptr,
        v.len,
      );
      if (it == ffi.nullptr) throw CorvidException.lastError();
      return [for (final (k, x) in walkGroups(it)) Group(k, x)];
    });
  }
}
