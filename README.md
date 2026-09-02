# corvid

The Dart binding for [corvid](https://github.com/corvid-db/corvid) — an
embedded database with a typed C ABI. It links the engine's **published
FFI artifacts** (the platform cdylib and `corvid.h`) through
**`dart:ffi`** with **ffigen-generated bindings**, carries an idiomatic
Dart API on top — and it proves, continuously and outside the engine
repo, that the published artifacts drive a real Dart consumer to the
same verdicts the engine's own suite produces: the golden-suite port in
`test/golden_test.dart` replays the engine's 267-line fixture suite
through this binding.

**Publishing:** `publish_to: none` — the pub.dev publish is pending the
first announced release. Until then, consume from git:

```yaml
dependencies:
  corvid:
    git: https://github.com/corvid-db/corvid-dart.git
```

**Documentation:** the [corvid docs site](https://corvid-db.github.io/docs/)
is canonical — the [C ABI section](https://corvid-db.github.io/docs/ffi/)
documents every symbol this binding links (handles, ownership, errors,
threading), and [docs/PLAN.md](docs/PLAN.md) records this binding's
architecture ruling and lifetime mapping.

## The architecture ruling: dart:ffi over the C ABI, release artifacts only

Deliberately different from the node/python bindings (Rust-source
builds): Dart users expect a shared library or a bundled download, not
a Rust toolchain. `./fetch.sh` (macOS/Linux) or `./fetch.ps1`
(Windows) downloads the pinned engine release archive for the host
platform, sha256-verifies it against the release's `checksums.txt`,
byte-compares the release's golden fixtures against the ones vendored
here, and normalizes `corvid.h` + the cdylib into gitignored
`deps/current/`. Requirements stop at "the Dart SDK".

- **No Rust toolchain, ever** (the CI ffigen drift job needs libclang,
  on one Linux leg only).
- **One exact engine pin** — `v0.4.0`, living in one variable per fetch
  script (`CORVID_VERSION` in `fetch.sh`, `$CorvidVersion` in
  `fetch.ps1`), stamped into `deps/version.txt`.
- **No vendored binaries in git** (`deps/` is gitignored) and **no
  artifact network access at build/test time.**
- **Published-artifact defects are findings**, never local patches.

## Platform support (the shipped contract)

**Dart VM on desktop — macOS, Linux, Windows (x64; arm64 on
macOS/Linux)** — CI-verified on all three operating systems. The loader
(`lib/src/native.dart`) resolves the cdylib from:

1. the `CORVID_LIBRARY` environment variable (absolute path),
2. `deps/current/` under the working directory (the fetch scripts'
   output),
3. the OS search path (a system install, `DYLD_*`/`LD_LIBRARY_PATH`,
   `PATH` on Windows).

**Flutter is a documented follow-up, not shipped here**: bundling the
cdylib per platform (Android `.so` per ABI, iOS `.framework`, …)
changes the engine's published artifact set and cannot be faked without
device testing — see the trigger in
[docs/PLAN.md](docs/PLAN.md#platform-story-this-bootstrap-dart-vm-desktop-ci-verified).

## Quick start

Requirements: Dart ≥ 3.10 (CI exercises `stable` and `3.10.0`),
`curl` + `shasum`/`sha256sum` (macOS/Linux) or PowerShell 5+ (Windows).

```sh
./fetch.sh          # fetch + verify corvid v0.4.0 into deps/current
dart pub get
dart test           # the golden suite (267 executable lines, 8 fixtures)
```

Windows (PowerShell):

```powershell
./fetch.ps1
$env:CORVID_LIBRARY = "$(Get-Location)\deps\current\corvid.dll"
dart test
```

A taste of the API:

```dart
import 'dart:typed_data';

import 'package:corvid/corvid.dart';

void main() {
  final db = Db.openMemory();
  final docs = db.collection('docs');

  // Map<String, Object?> / List<Object?> / Float32List / Uint8List /
  // String / int / double / bool / null — NaN and ±inf cross bit-exactly.
  docs.insert(_k('p1'), {
    'name': 'ada',
    'v': Float32List.fromList([1, 0, 0]),
  });

  docs.createVectorIndex('v', Metric.cosine);

  // hybrid: filter + vector + text, RRF-fused, MMR-reranked
  final rows = docs
      .query()
      .filter(field('name').eq('ada'))
      .vector('v', Float32List.fromList([1, 0, 0]), 3, Metric.cosine)
      .select(['name'])
      .run();
  for (final r in rows) {
    print('${String.fromCharCodes(r.key)} ${r.score} ${r.doc}');
  }

  final n = docs.query().filter(field('name').startsWith('a')).count();
  print('matched: $n');

  docs.close();
  db.close();
}

Uint8List _k(String s) => Uint8List.fromList(s.codeUnits);
```

Failures throw `CorvidException` carrying the ABI's detailed
`code` + the engine-recorded message. `Db` and `Collection` are safe
for concurrent use; `Query`/`Predicate` builders are single-isolate,
build-once, consumed-by-the-terminal. `close()` deliberately on every
handle; `NativeFinalizer`s are backstops only. Concurrent use carries
the FFI §6 quiescence caveat: **close a `Db`/`Collection` only after
every concurrent operation on it has completed**, and close all
collection handles before `Db.compact` (the engine answers
`CorvidException(busy)` otherwise).

## Documents and maps

Engine v0.3.0 added the map-key iterator (`corvid_value_map_keys`, the
§4.4 erratum): every decode in this binding enumerates map keys through
it — `get`/`scan`/`page`/query rows decode documents COMPLETE on any
database, whatever wrote the data, unknown and UTF-8 keys included
(`test/mapkeys_test.dart` pins the across-a-reopen shape; the
VMAP_KEYS/GET_KEYS golden lines pin the iterator's order and inert
shapes). Retrieval queries still return `Row.doc == null` without
`Query.select(...)` (retrieval carries keys and scores; read the
document explicitly), and `Collection.phraseSearch` rows always carry
documents.

The ffigen bindings are COMMITTED output, drift-gated in CI (regenerate
with `dart run ffigen:ffigen --config ffigen.yaml` after a pin bump);
the cdylib resolves from `CORVID_LIBRARY`, then `deps/current/`, then
the OS search path. The golden-suite port replays all 267 fixture
lines through the binding, and the §1.6 callback contract (a Dart
exception in a scan/update closure surfaces verbatim at the call site,
engine left usable) has its own test.

## CI

A linux/macos/windows × Dart {`stable`, `3.10.0`} matrix
(`​.github/workflows/ci.yml`): fetch + verify the pinned artifacts,
`dart analyze`, `dart test` (the golden suite), and the examples tour on
every leg; an ffigen drift job (ubuntu + libclang) regenerates
`lib/src/bindings.dart` and fails on any byte difference; the surface
gate resolves the manifest against the pinned engine's surface list.

## Surface manifest (docs/SURFACE.tsv)

Every construct of the engine's public surface (the radar-enforced list
the engine publishes as `scripts/bindings/surface.tsv` at each release
tag) is resolved in `docs/SURFACE.tsv`: the Dart API exposing it plus
the test that proves it (golden fixture line references), or `N/A` +
reason where the v1 binding deliberately does not expose it.
`scripts/surface-gate.sh` fails CI when a line is unresolved, a cell is
empty, or the N/A count drifts from the committed baseline — so an
engine pin bump that changes the surface lands in this gate, not in a
user's bug report.

## Versioning

The engine pin lives in one variable in the fetch scripts
(`CORVID_VERSION=v0.4.0`). Artifacts always come from that exact tag's
GitHub release and are sha256-verified; `deps/` is never committed.

## License

MIT — see [LICENSE](LICENSE).
