// native.dart — the library-loading layer.
//
// The single place the engine's cdylib is opened. Resolution order
// (docs/PLAN.md "Platform story"):
//
//   1. CORVID_LIBRARY  — absolute path to the cdylib (env override; what
//                        CI uses, and what an embedding app sets).
//   2. deps/current/…  — the fetch.sh / fetch.ps1 output next to the
//                        working directory (running tests and examples
//                        from a checkout of this repo, or an app that
//                        vendors the artifacts the same way).
//   3. bare soname     — libcorvid.dylib / libcorvid.so / corvid.dll on
//                        the OS search path (DYLD_*/LD_LIBRARY_PATH, a
//                        system install, or PATH on Windows).
//
// The resolved symbols are wrapped by the ffigen-generated CorvidNative
// (lib/src/bindings.dart) — this file only owns the DynamicLibrary and the
// singleton. Nothing here is exported by the public API.

import 'dart:ffi' as ffi;
import 'dart:io';

import 'bindings.dart';

/// The generated bindings over the loaded cdylib. Initialized lazily on
/// first use (the first `Db.open` / `Db.openMemory` in a process).
CorvidNative? _native;

CorvidNative get native {
  final n = _native;
  if (n != null) return n;
  return _native = CorvidNative(_openEngine());
}

/// The ABI version the loaded engine speaks (FFI.md §4.1: `1`).
int get ffiVersion => native.corvid_ffi_version();

ffi.DynamicLibrary _openEngine() {
  final override = Platform.environment['CORVID_LIBRARY'];
  if (override != null && override.isNotEmpty) {
    return ffi.DynamicLibrary.open(override);
  }
  final soname = _soname;
  final sep = Platform.isWindows ? r'\' : '/';
  try {
    // deps/current — the fetch scripts' normalized output.
    return ffi.DynamicLibrary.open(['deps', 'current', soname].join(sep));
  } on ArgumentError {
    // Fall through to the OS search path.
  }
  return ffi.DynamicLibrary.open(soname);
}

String get _soname {
  if (Platform.isMacOS) return 'libcorvid.dylib';
  if (Platform.isWindows) return 'corvid.dll';
  return 'libcorvid.so';
}
