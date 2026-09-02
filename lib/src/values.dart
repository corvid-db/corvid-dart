// values.dart — the Dart ↔ C value mapping, plus the raw value/cursor
// machinery the wrapper and the golden harness drive.
//
// Value mapping (docs/PLAN.md):
//
//   C null      ↔ Dart null
//   C bool      ↔ Dart bool
//   C int (i64) ↔ Dart int          (Dart ints are 64-bit on the VM)
//   C float     ↔ Dart double       (NaN/±inf/-0.0 cross bit-exact)
//   C text      ↔ Dart String
//   C bytes     ↔ Dart Uint8List
//   C vector    ↔ Dart Float32List  (f32 elements bit-exact, NaN payloads
//                                     included)
//   C array     ↔ Dart List<Object?>
//   C map       ↔ Dart Map<String, Object?>
//
// Everything crossing into the engine is built as a fresh C value and
// freed inside the call (the ABI clones what it keeps — FFI.md §5);
// everything borrowed back is COPIED into Dart-owned memory before the
// borrow ends ("copies at the boundary", the same rule as every sibling
// binding). No C pointer escapes this package.
//
// Encode carries a nesting-depth cap ([maxNesting] = the engine's
// corvid::value::MAX_NESTING, 128): deeper graphs throw a typed
// CorvidException(argument) — converter-accepted == decodable, and the
// old catch-a-StackOverflowError-by-accident posture is retired.
//
// Map decoding enumerates keys with `corvid_value_map_keys` (the v0.3.0
// §4.4 addition — ascending key-BYTE order, whatever wrote the data), so
// a decoded map is always COMPLETE: get, scan, update callbacks, page
// rows, and query rows decode anything the engine can read, on any
// database.

import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:typed_data';

import 'package:ffi/ffi.dart' as ffi2;

import 'bindings.dart';
import 'errors.dart';
import 'native.dart';

// ---------------------------------------------------------------------------
// char* / byte* marshalling (arena-scoped native copies)
// ---------------------------------------------------------------------------

/// A borrowed-for-the-call native UTF-8 copy of a Dart string, with its
/// BYTE length (Dart's `String.length` is UTF-16 code units — never pass
/// it as the ABI's byte length; FFI.md §1.5).
({ffi.Pointer<ffi.Char> ptr, int len}) nativeUtf8(
  String s, [
  ffi.Allocator? allocator,
]) {
  final a = allocator ?? ffi2.malloc;
  final units = utf8.encode(s);
  final p = a.allocate<ffi.Uint8>(units.length + 1);
  final view = p.asTypedList(units.length + 1);
  view.setAll(0, units);
  view[units.length] = 0;
  return (ptr: p.cast(), len: units.length);
}

String readUtf8(ffi.Pointer<ffi.Char> p, int len) {
  if (p == ffi.nullptr || len == 0) return '';
  return utf8.decode(p.cast<ffi.Uint8>().asTypedList(len));
}

ffi.Pointer<ffi.Uint8> nativeBytes(Uint8List b, [ffi.Allocator? allocator]) {
  final a = allocator ?? ffi2.malloc;
  final p = a.allocate<ffi.Uint8>(b.isEmpty ? 1 : b.length);
  if (b.isNotEmpty) p.asTypedList(b.length).setAll(0, b);
  return p;
}

/// Copies `len` bytes from native memory into a Dart-owned Uint8List.
Uint8List copyBytes(ffi.Pointer<ffi.Uint8> p, int len) {
  if (p == ffi.nullptr || len == 0) return Uint8List(0);
  return Uint8List.fromList(p.cast<ffi.Uint8>().asTypedList(len));
}

/// Copies `dim` f32s from native memory into a Dart-owned Float32List.
Float32List copyFloats(ffi.Pointer<ffi.Float> p, int dim) {
  if (p == ffi.nullptr || dim == 0) return Float32List(0);
  return Float32List.fromList(p.asTypedList(dim));
}

/// The engine's thread-local last-error message (null when nothing is
/// recorded on this thread).
String? lastErrorMessage() {
  final len = ffi2.malloc<ffi.Size>(1);
  try {
    final p = native.corvid_last_error_message(len);
    if (p == ffi.nullptr) return null;
    return readUtf8(p, len.value);
  } finally {
    ffi2.malloc.free(len);
  }
}

// ---------------------------------------------------------------------------
// encode: Dart value → OWNED C value (caller frees with freeValue)
// ---------------------------------------------------------------------------

/// The engine's decode bound — `corvid::value::MAX_NESTING`
/// (crates/corvid/src/value.rs, = 128), the number every binding's
/// ENCODE cap agrees on. Converter-accepted == decodable: a deeper
/// graph could be BUILT through the value-constructor ABI but the
/// engine could never decode it back (dump/load), so encode rejects it
/// up front — a typed CorvidException(argument), not the accidental
/// Dart StackOverflowError the unguarded recursion used to throw (it
/// was catchable by accident, not by contract).
const int maxNesting = 128; // == corvid::value::MAX_NESTING

/// Builds an OWNED `corvid_value` from a Dart value. Throws
/// CorvidException(argument) on an unsupported Dart type or a graph
/// nested deeper than [maxNesting] (the engine decoder's own
/// convention: top-level value is depth 0, every container's children
/// one more, boundary inclusive — 128 nested containers round-trip,
/// 129 throw). Free the result with [freeValue] once the engine call
/// that consumed/borrowed it has returned.
ffi.Pointer<corvid_value> encodeValue(Object? v) => _encodeValue(v, 0);

ffi.Pointer<corvid_value> _encodeValue(Object? v, int depth) {
  if (depth > maxNesting) {
    throw CorvidException(
      CorvidErrorCode.argument,
      'value nesting exceeds the maximum depth of $maxNesting',
    );
  }
  if (v == null) return native.corvid_value_null();
  if (v is bool) return native.corvid_value_bool(v ? 1 : 0);
  if (v is int) return native.corvid_value_int(v);
  if (v is double) return native.corvid_value_float(v);
  if (v is String) {
    return ffi2.using((arena) {
      final p = nativeUtf8(v, arena);
      return native.corvid_value_text(p.ptr, p.len);
    });
  }
  if (v is Uint8List) {
    return ffi2.using((arena) {
      final p = nativeBytes(v, arena);
      return native.corvid_value_bytes(p, v.length);
    });
  }
  if (v is Float32List) {
    return ffi2.using((arena) {
      // §1.5: dim 0 is legal with any non-NULL pointer.
      final p = v.isEmpty
          ? arena.allocate<ffi.Float>(1 * ffi.sizeOf<ffi.Float>())
          : arena.allocate<ffi.Float>(v.length * ffi.sizeOf<ffi.Float>());
      if (v.isNotEmpty) p.asTypedList(v.length).setAll(0, v);
      return native.corvid_value_vector(p, v.length);
    });
  }
  if (v is List<Object?>) {
    final arr = native.corvid_value_array_new();
    for (final item in v) {
      final cv = _encodeValue(item, depth + 1); // throws past here are ours
      // array_push CONSUMES cv unconditionally (spec §8) — never free it
      // after the call, whatever the status.
      final st = native.corvid_value_array_push(arr, cv);
      if (st != 0) {
        freeValue(arr);
        throw CorvidException.lastError();
      }
    }
    return arr;
  }
  if (v is Map<String, Object?>) {
    final m = native.corvid_value_map_new();
    for (final entry in v.entries) {
      final cv = _encodeValue(entry.value, depth + 1);
      // map_put CONSUMES cv unconditionally (spec §8).
      final st = ffi2.using((arena) {
        final k = nativeUtf8(entry.key, arena);
        return native.corvid_value_map_put(m, k.ptr, k.len, cv);
      });
      if (st != 0) {
        freeValue(m);
        throw CorvidException.lastError();
      }
    }
    return m;
  }
  throw CorvidException(
    CorvidErrorCode.argument,
    'unsupported Dart type ${v.runtimeType} for a corvid value',
  );
}

/// Frees an OWNED value handle (never a borrowed child — FFI.md §4.4).
void freeValue(ffi.Pointer<corvid_value> v) => native.corvid_value_free(v);

/// Frees a native-heap buffer (the internal counterpart of malloc/calloc
/// in this file — harnesses pair ad-hoc allocations with it).
void ffiFree(ffi.Pointer<ffi.Void> p) => ffi2.malloc.free(p);

// ---------------------------------------------------------------------------
// decode: C value (owned or borrowed) → fully Dart-owned value
// ---------------------------------------------------------------------------

/// The value discriminants (FFI.md §1.4, frozen).
const int tagNull = 0,
    tagBool = 1,
    tagInt = 2,
    tagFloat = 3,
    tagText = 4,
    tagBytes = 5,
    tagArray = 6,
    tagMap = 7,
    tagVector = 8;

/// Copies a C value (owned or borrowed) into a fully Dart-owned value.
/// Maps enumerate their keys through `corvid_value_map_keys` — every
/// entry decodes, unknown keys included.
Object? decodeValue(ffi.Pointer<corvid_value> v) {
  switch (native.corvid_value_type(v)) {
    case tagNull:
      return null;
    case tagBool:
      return valueAsBool(v) ?? false;
    case tagInt:
      return valueAsInt(v);
    case tagFloat:
      return valueAsFloat(v);
    case tagText:
      return valueTextRef(v);
    case tagBytes:
      return valueBytesRef(v);
    case tagVector:
      return valueVectorRef(v);
    case tagArray:
      final n = native.corvid_value_len(v);
      final out = <Object?>[];
      for (var i = 0; i < n; i++) {
        out.add(decodeValue(native.corvid_value_array_get(v, i)));
      }
      return out;
    case tagMap:
      final n = native.corvid_value_len(v);
      if (n == 0) return <String, Object?>{};
      final keys = valueMapKeys(v);
      if (keys.length != n) {
        throw CorvidException(
          CorvidErrorCode.decode,
          'map decode: ${keys.length} of $n keys enumerated',
        );
      }
      final out = <String, Object?>{};
      for (final k in keys) {
        final child = ffi2.using((arena) {
          final kp = nativeUtf8(k, arena);
          return native.corvid_value_map_get(v, kp.ptr, kp.len);
        });
        if (child == ffi.nullptr) {
          throw CorvidException(
            CorvidErrorCode.decode,
            'map decode: enumerated key "$k" absent',
          );
        }
        out[k] = decodeValue(child);
      }
      return out;
    default:
      throw CorvidException(
        CorvidErrorCode.decode,
        'unknown value type tag ${native.corvid_value_type(v)}',
      );
  }
}

// ---------------------------------------------------------------------------
// Raw value reads (typed, with the §4.4 ok-flag discipline) — used by
// decode and, directly, by the golden harness's value-family OPs.
// ---------------------------------------------------------------------------

/// `corvid_value_as_bool` — null when the type is wrong (not an error).
bool? valueAsBool(ffi.Pointer<corvid_value> v) {
  final ok = ffi2.malloc<ffi.Int>(1);
  try {
    final r = native.corvid_value_as_bool(v, ok);
    return ok.value != 0 ? r != 0 : null;
  } finally {
    ffi2.malloc.free(ok);
  }
}

/// `corvid_value_as_int` — null when the type is wrong.
int? valueAsInt(ffi.Pointer<corvid_value> v) {
  final ok = ffi2.malloc<ffi.Int>(1);
  try {
    final r = native.corvid_value_as_int(v, ok);
    return ok.value != 0 ? r : null;
  } finally {
    ffi2.malloc.free(ok);
  }
}

/// `corvid_value_as_float` — null when the type is wrong.
double? valueAsFloat(ffi.Pointer<corvid_value> v) {
  final ok = ffi2.malloc<ffi.Int>(1);
  try {
    final r = native.corvid_value_as_float(v, ok);
    return ok.value != 0 ? r : null;
  } finally {
    ffi2.malloc.free(ok);
  }
}

/// `corvid_value_text_ref` COPIED into a Dart String (null on a
/// non-text value — not an error).
String? valueTextRef(ffi.Pointer<corvid_value> v) {
  final len = ffi2.malloc<ffi.Size>(1);
  try {
    final p = native.corvid_value_text_ref(v, len);
    if (p == ffi.nullptr) return null;
    return readUtf8(p, len.value);
  } finally {
    ffi2.malloc.free(len);
  }
}

/// `corvid_value_bytes_ref` COPIED (null on a non-bytes value).
Uint8List? valueBytesRef(ffi.Pointer<corvid_value> v) {
  final len = ffi2.malloc<ffi.Size>(1);
  try {
    final p = native.corvid_value_bytes_ref(v, len);
    if (p == ffi.nullptr) return null;
    return copyBytes(p.cast(), len.value);
  } finally {
    ffi2.malloc.free(len);
  }
}

/// `corvid_value_vector_ref` COPIED (null on a non-vector value).
Float32List? valueVectorRef(ffi.Pointer<corvid_value> v) {
  final dim = ffi2.malloc<ffi.Size>(1);
  try {
    final p = native.corvid_value_vector_ref(v, dim);
    if (p == ffi.nullptr) return null;
    return copyFloats(p, dim.value);
  } finally {
    ffi2.malloc.free(dim);
  }
}

/// The map's keys as an ascending key-BYTE-order Dart list (empty for
/// non-maps — inert; FFI.md §4.4). The strs cursor is walked and freed
/// inside the call.
List<String> valueMapKeys(ffi.Pointer<corvid_value> v) {
  final cur = native.corvid_value_map_keys(v);
  if (cur == ffi.nullptr) {
    throw CorvidException.lastError();
  }
  return walkStrs(cur);
}

/// Walks + frees a strs cursor into a Dart string list.
List<String> walkStrs(ffi.Pointer<corvid_strs> cur) {
  final out = <String>[];
  final str = ffi2.malloc<ffi.Pointer<ffi.Char>>(1);
  final len = ffi2.malloc<ffi.Size>(1);
  try {
    while (native.corvid_strs_next(cur, str, len) != 0) {
      out.add(readUtf8(str.value, len.value)); // borrowed: copy now
    }
  } finally {
    ffi2.malloc.free(str);
    ffi2.malloc.free(len);
    native.corvid_strs_free(cur);
  }
  return out;
}

/// Walks a child path like "a.b.0.c" over a C value handle: dot-separated
/// segments, all-digit segments index arrays, anything else keys maps.
/// Returns nullptr when the path is absent. The visited children are
/// borrowed views; the caller must not free them (FFI.md §5).
ffi.Pointer<corvid_value> walkValuePath(
  ffi.Pointer<corvid_value> root,
  String path,
) {
  var cur = root;
  var i = 0;
  while (i < path.length && cur != ffi.nullptr) {
    if (path[i] == '.') i++;
    var j = i;
    while (j < path.length && path[j] != '.') {
      j++;
    }
    final seg = path.substring(i, j);
    if (seg.isEmpty) break;
    if (_allDigits(seg)) {
      cur = native.corvid_value_array_get(cur, int.parse(seg));
    } else {
      cur = ffi2.using((arena) {
        final k = nativeUtf8(seg, arena);
        return native.corvid_value_map_get(cur, k.ptr, k.len);
      });
    }
    i = j;
  }
  return cur;
}

bool _allDigits(String s) =>
    s.isNotEmpty && s.codeUnits.every((c) => c >= 0x30 && c <= 0x39);

// ---------------------------------------------------------------------------
// Cursor walkers shared by the API layer (borrowed docs are decoded
// inside the step, per the "copies at the boundary" rule)
// ---------------------------------------------------------------------------

/// One step of a rows cursor: key (copied), borrowed doc handle, score.
/// Returns null at exhaustion.
({Uint8List key, ffi.Pointer<corvid_value> doc, double score})? rowsNext(
  ffi.Pointer<corvid_rows> rows,
) {
  final key = ffi2.malloc<ffi.Pointer<ffi.Uint8>>(1);
  final keyLen = ffi2.malloc<ffi.Size>(1);
  final doc = ffi2.malloc<ffi.Pointer<corvid_value>>(1);
  final score = ffi2.malloc<ffi.Float>(1);
  try {
    if (native.corvid_rows_next(rows, key, keyLen, doc, score) == 0) {
      return null;
    }
    return (
      key: copyBytes(key.value, keyLen.value),
      doc: doc.value,
      score: score.value,
    );
  } finally {
    ffi2.malloc.free(key);
    ffi2.malloc.free(keyLen);
    ffi2.malloc.free(doc);
    ffi2.malloc.free(score);
  }
}

/// Walks + frees a groupiter cursor into (key, value) pairs.
List<(String, double)> walkGroups(ffi.Pointer<corvid_groupiter> it) {
  final out = <(String, double)>[];
  final key = ffi2.malloc<ffi.Pointer<ffi.Char>>(1);
  final len = ffi2.malloc<ffi.Size>(1);
  final value = ffi2.malloc<ffi.Double>(1);
  try {
    while (native.corvid_groupiter_next(it, key, len, value) != 0) {
      out.add((readUtf8(key.value, len.value), value.value));
    }
  } finally {
    ffi2.malloc.free(key);
    ffi2.malloc.free(len);
    ffi2.malloc.free(value);
    native.corvid_groupiter_free(it);
  }
  return out;
}

/// One step of a geohits cursor. Returns null at exhaustion.
/// (`hasDoc` false for the weighted-neighbors shape, which carries no
/// document — FFI.md §4.12.)
({Uint8List key, double dist, ffi.Pointer<corvid_value>? doc})? geoNext(
  ffi.Pointer<corvid_geohits> h,
) {
  final hit = ffi2.malloc<corvid_geohit>(1);
  final doc = ffi2.malloc<ffi.Pointer<corvid_value>>(1);
  try {
    if (native.corvid_geohits_next(h, hit, doc) == 0) return null;
    return (
      key: copyBytes(hit.ref.key.cast(), hit.ref.key_len),
      dist: hit.ref.distance_km,
      doc: doc.value == ffi.nullptr ? null : doc.value,
    );
  } finally {
    ffi2.malloc.free(hit);
    ffi2.malloc.free(doc);
  }
}

/// One step of a schemaiter cursor. Returns null at exhaustion.
({String name, int type, bool required, bool unique})? schemaNext(
  ffi.Pointer<corvid_schemaiter> it,
) {
  final def = ffi2.malloc<corvid_field_def>(1);
  try {
    if (native.corvid_schemaiter_next(it, def) == 0) return null;
    return (
      name: readUtf8(def.ref.name, def.ref.name_len),
      type: def.ref.type,
      required: def.ref.required != 0,
      unique: def.ref.unique != 0,
    );
  } finally {
    ffi2.malloc.free(def);
  }
}

// ---------------------------------------------------------------------------
// Parallel-array marshalling (keys / UTF-8 field lists / kv PODs)
// ---------------------------------------------------------------------------

/// Parallel (ptrs, lens) arrays of borrowed byte keys, arena-scoped.
(ffi.Pointer<ffi.Pointer<ffi.Uint8>>, ffi.Pointer<ffi.Size>) nativeKeyArray(
  List<Uint8List> keys,
  ffi.Allocator a,
) {
  final n = keys.isEmpty ? 1 : keys.length;
  final ptrs = a.allocate<ffi.Pointer<ffi.Uint8>>(
    n * ffi.sizeOf<ffi.Pointer<ffi.Uint8>>(),
  );
  final lens = a.allocate<ffi.Size>(n * ffi.sizeOf<ffi.Size>());
  for (var i = 0; i < keys.length; i++) {
    ptrs[i] = nativeBytes(keys[i], a);
    lens[i] = keys[i].length;
  }
  return (ptrs.cast(), lens);
}

/// Parallel (ptrs, lens) arrays of borrowed UTF-8 strings, arena-scoped.
(ffi.Pointer<ffi.Pointer<ffi.Char>>, ffi.Pointer<ffi.Size>) nativeStrArray(
  List<String> strs,
  ffi.Allocator a,
) {
  final n = strs.isEmpty ? 1 : strs.length;
  final ptrs = a.allocate<ffi.Pointer<ffi.Char>>(
    n * ffi.sizeOf<ffi.Pointer<ffi.Char>>(),
  );
  final lens = a.allocate<ffi.Size>(n * ffi.sizeOf<ffi.Size>());
  for (var i = 0; i < strs.length; i++) {
    final s = nativeUtf8(strs[i], a);
    ptrs[i] = s.ptr;
    lens[i] = s.len;
  }
  return (ptrs.cast(), lens);
}
