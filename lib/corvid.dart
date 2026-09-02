// corvid.dart — the public API of package:corvid_dart.
//
// Dart FFI bindings for corvid (the embedded multi-modal data store) over
// the engine's published C-ABI artifacts. Idiomatic Dart on top of the
// frozen ABI (FFI.md ruling 3): handles become classes with close(), the
// typed value family becomes Map/List/String/int/double/Float32List/
// Uint8List, CORVID_ERR becomes CorvidException, and no FFI symbol leaks
// into this API.
//
// Quick start:
//
// ```dart
// final db = Db.openMemory();
// final docs = db.collection('docs');
// docs.insert(utf8.encode('p1'), {'title': 'rust embedded database', 'v': Float32List.fromList([1, 0])});
// final rows = docs.query()
//     .vector('v', Float32List.fromList([1, 0]), 3, Metric.cosine)
//     .select(['title'])
//     .run();
// docs.close();
// db.close();
// ```
//
// The engine's cdylib is resolved from CORVID_LIBRARY, deps/current/, or
// the OS search path (lib/src/native.dart); run fetch.sh / fetch.ps1 to
// populate deps/current from the pinned release.

export 'src/collection.dart' show Collection;
export 'src/db.dart' show Db;
export 'src/errors.dart' show CorvidErrorCode, CorvidException;
export 'src/query.dart'
    show
        FieldDef,
        FieldExpr,
        FieldType,
        field,
        GeoHit,
        Group,
        Metric,
        Page,
        Predicate,
        PredicateCombinators,
        Quant,
        Query,
        Row,
        Weighted;
