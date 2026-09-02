# corvid-dart — the binding's plan

corvid-dart is the **Dart binding** for the `corvid` embedded database.
Like its sibling `corvid-go`, it exists to prove, continuously and
outside the engine repo, that corvid's **published FFI artifacts** — the
platform cdylib, `corvid.h`, and the golden fixtures shipped in each
release archive — drive a real consumer to the same verdicts the
engine's own suite produces; on top of that proof it carries the
idiomatic Dart API.

Engine repo: `corvid-db/corvid` (read-only upstream; never a submodule,
never vendored). Canonical docs: the corvid docs site's FFI section (the
`docs/FFI.md` contract — 124 symbols, frozen enums, §8 idiom gate).

## The architecture ruling: dart:ffi over the typed C ABI, release
artifacts only

**Deliberately different from corvid-node/corvid-python** (Rust-source
bindings): corvid-dart links the **published cdylib through `dart:ffi`**
with **ffigen-generated bindings** from the release's `corvid.h`, the
corvid-c/corvid-go pattern. Why:

- Dart users (VM apps, CLIs, servers — and Flutter through the follow-up
  below) expect a shared library or a bundled download, not a Rust
  toolchain. A binding whose install invokes `cargo` is a non-starter
  for the pub.dev ecosystem; `fetch.sh` + `dart test` keeps the
  requirement at "the Dart SDK".
- The C ABI is the engine's *locked*, stability-governed surface
  (FFI.md §8): enum values frozen, symbols append-only, breaks are loud
  version bumps. Binding to it binds to the contract, not to Rust crate
  internals that are `#[non_exhaustive]` and pre-1.0.
- Consuming the release artifacts keeps this repo an independent
  verifier: if a published dylib/header/fixture set disagrees with the
  spec, the golden suite here catches it (that is exactly how corvid-c
  found the v0.2.0 install-name defect, its finding F1).
- ffigen (the toolchain-blessed generator) turns the release header into
  the raw bindings layer; the config (`ffigen.yaml`) and the generated
  file (`lib/src/bindings.dart`) are COMMITTED, and the generated file
  is DRIFT-GATED (a CI job re-runs ffigen against the freshly fetched
  header and fails on any byte difference — an engine pin bump cannot
  change the ABI surface silently). `sort: true` plus
  `headers.include-directives: ['**corvid.h']` keep the generated file
  host-independent (system-header strays are excluded), so the byte
  gate is deterministic across runner OSes.

Consequences, all locked:

- **No Rust toolchain, ever** (except inside the optional ffigen drift
  job, which needs only libclang — and only on ONE Linux leg).
- **Pin EXACT engine tags.** One engine version at a time; today it is
  `v0.3.0`. The pin lives in exactly one variable per fetch script
  (`CORVID_VERSION` / `$CorvidVersion`) and is stamped into
  `deps/version.txt`.
- **No vendored binaries in git.** `deps/` is gitignored.
- **No network at build/test time** beyond `pub get` (pub.dev only);
  everything else consumes `deps/`.
- **Published-artifact defects are findings, not patches.** Divergence
  is reported upstream (`corvid-db/corvid`), never worked around
  locally. The fetch scripts also byte-compare the release's
  `golden/*.txt` against the fixtures vendored in this repo — a mismatch
  is a hard fetch failure.

## Platform story (this bootstrap): Dart VM, desktop, CI-verified

**The shipped contract of this bootstrap is the pure-Dart package on the
Dart VM** (macOS / Linux / Windows x64, macOS + Linux arm64): the loader
(`lib/src/native.dart`) resolves the engine's cdylib in this order —

1. `CORVID_LIBRARY` (absolute path — what CI uses and what an embedding
   app sets),
2. `deps/current/<soname>` relative to the working directory (the
   fetch scripts' normalized output — running the tests and examples
   from a checkout, or an app vendoring the artifacts the same way),
3. the bare soname on the OS search path (`DYLD_*`/`LD_LIBRARY_PATH`, a
   system install, or `PATH` on Windows).

**The Flutter plugin packaging is a documented follow-up with a trigger,
deliberately not faked here**: bundling per-platform binaries inside a
Flutter plugin (Android `.so` per ABI under `android/src/main/jniLibs/`,
iOS `.framework`, macOS `.xcframework`, Windows `corvid.dll` beside the
executable) changes the artifact set the engine publishes (today:
desktop targets only — no android/ios cross-compiles in the release
matrix) and cannot be shipped untested. **Trigger:** a real Flutter app
needs it AND the engine's release pipeline ships android/ios (and the
existing desktop) cdylibs; then this package grows the plugin packages
(`corvid_dart_flutter` or a federated `corvid_dart: ^0.x + corvid`
endorsed implementation) with per-device CI (emulator/simulator legs).
Until then the README states the platform support honestly: Dart VM
desktop, CI-verified on all three OSes.

## The locked rule: golden port BEFORE ergonomic sugar

Inherited from the bindings program's master plan and non-negotiable:

> **A binding opens with the golden-suite port.** The engine's golden
> fixtures (267 executable lines across 8 files) are the contract; a
> binding that wraps the ABI before it can replay the contract is
> building on unverified ground.

corvid-dart's first substantive deliverable is `test/golden_test.dart` —
a port of the engine's harness (`c/smoke.c`, as ported standalone by
`corvid-c/test/golden.c` and through-the-binding by
`corvid-go/golden_test.go`) — replaying every fixture line **through
this binding** (the Dart API wherever it can express the op, the raw
value family in `lib/src/values.dart` where the op is inherently raw —
the VTYPE/VLEN/VAS_*/V*_REF/VNEST/VCLONE/VPUSH/VPUT exercises). The
fixtures are vendored byte-identical under `golden/`. No softened
asserts: the same expectation checks, the same `executed == counted`
dispatch rule, first failure naming file:line + OP + expected-vs-got.

Only with the port green does the ergonomic surface count.

## C-handle lifetime mapping (FFI.md §2 → Dart)

Each C handle becomes a Dart class with **explicit `close()` and a
`NativeFinalizer` attached as a BACKSTOP only** (the Dart shape of the
go binding's `runtime.SetFinalizer` discipline) — close deliberately;
the finalizer exists so a leaked handle cannot pin engine memory
forever. CorvidException (never a raw status, never a crash) for every
failure path. No `dart:ffi` type appears in any public signature — the
raw handles live in `Expando` side tables resolved by internal-only
functions, so even the internal accessors are invisible through
`package:corvid_dart/corvid.dart` (FFI.md ruling 3).

| C handle | Dart owner | Explicit release | Backstop finalizer |
|---|---|---|---|
| `corvid_db` | `Db` | `close()` (idempotent) | `corvid_close` |
| `corvid_coll` | `Collection` | `close()` (idempotent) | `corvid_collection_free` |
| `corvid_value` (owned) | transient inside a call, or decoded-then-freed | freed deterministically at the end of the wrapper call | not needed |
| `corvid_pred` | `Predicate` | consumed by `and/or/not`/`filter`/`deleteWhere`; `close()` frees a never-consumed root | `corvid_pred_free`, detached on consumption (spec §8 — consumption happens even when the consuming call fails) |
| `corvid_query` | `Query` | consumed by `run`/every aggregate; `close()` frees an abandoned builder | `corvid_query_free`, detached on consumption |
| cursors (`rows`, `strs`, `geohits`, `groupiter`, `schemaiter`) | walked to exhaustion inside the single wrapper call | freed in `finally` | not needed |
| buffers (`insertAuto` key, `page` next-after) | copied to Dart memory | `corvid_free`'d in the wrapper | not needed |

## Borrowed-doc rules mapped to Dart: copies at the boundary

FFI.md §5: `rows_next`/`geohits_next`/callback keys and docs are
**BORROWED until the next `next`/`free`**; `_ref` views are borrowed
until the parent mutates or dies; writing through or freeing them is
UB. The Dart answer is the same as every sibling binding's — copies at
the boundary, mechanically:

- Every key/doc/`_ref` buffer is **copied into Dart-owned memory inside
  the wrapper call** (`Uint8List.fromList`, `Float32List.fromList`,
  `utf8.decode`) before the next `next` call or the parent's free.
  Nothing borrowed is ever retained past the call.
- Values crossing **into** the engine are built as fresh `corvid_value`
  handles and freed immediately after the call; the caller's Dart data
  is never handed over as anything but a borrowed, read-only,
  call-scoped pointer.
- Decoding a map is read-only over the borrowed handle and copies
  everything it touches (keys enumerate through `corvid_value_map_keys`
  — the v0.3.0 §4.4 addition — so every decode is COMPLETE, whatever
  wrote the data; `mapkeys_test.dart` pins the across-a-reopen shape).

### Allocation discipline (the one real trap, found the hard way)

`package:ffi` ≥ 2.1's `Allocator.allocate<T>(byteCount)` takes a BYTE
count, not an element count (this bit the parallel-array marshalling:
`deleteBatch`/`putMany`/`select`/schema arrays). Every allocation in
this repo is `count * sizeOf<T>()`; if a new call site ever writes
pointer-sized elements into a byte-counted buffer, the heap corruption
surfaces in the engine's `memmove` — far from the bug. Code review
rule: an `allocate` without `sizeOf` is wrong unless `T` is `Uint8`.

## The §1.6 callbacks: NativeCallable.isolateLocal + exception capture

The engine's two callbacks (`scan`, `update`) run **synchronously on
the caller's thread between engine operations** — exactly the
`NativeCallable.isolateLocal` contract (the callable is invoked on the
creating isolate's thread; NOT `.listener`, which is for messages
posted from other threads and would be wrong for same-thread sync
calls).

- **No Dart object pointer crosses into C memory.** The callback
  closure captures its job state directly (one NativeCallable per
  engine call, `close()`d after it returns), and the ABI's `ctx` slot
  is passed as `nullptr` — the Dart-side equivalent of the go binding's
  integer-registry rule.
- **A Dart exception must never unwind through the native frames.** The
  trampoline wraps the user closure in a catch-all, stashes the thrown
  object + stack trace, and stops the scan (`return 0`) / aborts the
  update (`*out = NULL`, `return CORVID_ERR`) at the ABI level; once
  the engine call has returned, the wrapper rethrows the ORIGINAL
  object with its ORIGINAL stack trace (`Error.throwWithStackTrace`) —
  the Dart shape of the go binding's recover-and-repanic ruling. A
  callback exception surfaces at the `scan()`/`update()` call site
  (`callback_test.dart` pins both halves: verbatim surfacing, and the
  engine left usable).
- **Abort idiom:** throwing a `CorvidException(argument, …)` inside an
  `update` closure is the canonical abort — it matches the ABI's §1.6
  aborting-callback contract (`CORVID_E_ARGUMENT` recorded, nothing
  written), which is what the golden suite's UPDATE_ABORT line pins.
- **Reentrancy:** the callback must not call back into the engine
  (FFI.md §1.6) — the same portable contract as every binding. The
  decode inside the scan trampoline performs read-side value calls on
  the callback's own borrowed argument only (the same class as the
  sanctioned `corvid_value_clone` escape), which cannot disturb engine
  or transaction state.

## Isolate-safety mapping (FFI.md §6)

The engine contract, restated as Dart:

- `Db` and `Collection` are **safe for concurrent use from multiple
  isolates/threads** (backed by `Arc<Db>`; reads concurrent, writes
  serialized by the engine). No extra locking is added in the binding.
- `Query`, `Predicate`, and every result cursor are **single-isolate**
  (the ABI calls concurrent use of one such handle UB). Documented, not
  policed — builders are cheap, chainable, consumed by the terminal.
- The last-error slot is thread-local: every wrapper reads
  `corvid_last_error_code/message` **immediately** after the failing
  call, on the thread the failing call ran on, which shrinks the
  exposure to the theoretical minimum. A failure whose slot reads empty
  surfaces as a loud zero/none-coded `CorvidException` ("failure
  recorded without a message"), never as another call's error silently
  misattributed.
- v1 is **synchronous** (the engine is sync; async wrappers would be a
  lie over a synchronous ABI).
- **The §6 quiescence contract on close/compact** carries over
  verbatim: close a `Db`/`Collection` only after every concurrent
  operation on it has completed (freeing engine memory while another
  thread is inside a call on it is UB — the closed-handle gate is a
  loud TOCTOU rejection, not a lock), and reach a quiescent point
  (all collection handles closed) before `Db.compact` — the engine
  answers `CorvidException(busy)` otherwise, which the golden suite's
  COMPACT_BUSY line pins.

## Toolchain policy

Per the engine's `scripts/bindings/README.md`: modern minimums, CI
tests latest + previous, no EOL lines. The SDK floor is `^3.10`
(latest-minus-one at bootstrap); CI runs the `stable` channel and the
`3.10.0` floor across the OS matrix. Actions stay current-major
(`actions/checkout@v7`, `dart-lang/setup-dart@v1.8.1`).

## Phase DART1 (this bootstrap) — scope

1. **Plan doc** (this file) — ruling, lifetime mapping, allocation
   discipline, callback ruling, isolate mapping, platform story +
   follow-up trigger.
2. **Repo scaffold** — pubspec (`corvid_dart`, `publish_to: none`
   until announced), MIT LICENSE (engine's copyright line),
   `.gitignore` (`deps/`, Dart artifacts), README (requirements; the
   engine artifacts are NOT vendored).
3. **Fetch + verify** — `fetch.sh` / `fetch.ps1` (the corvid-c/go
   pattern): platform archive from the pinned release, sha256-verified
   against `checksums.txt`, extracted into gitignored `deps/`,
   normalized to `deps/current/`, golden fixtures byte-verified.
4. **ffigen layer** — `ffigen.yaml` (committed) + `lib/src/bindings.dart`
   (committed, host-stable, drift-gated) + `lib/src/native.dart` (the
   loader).
5. **The Dart API** — `lib/corvid.dart`: `Db.open/openMemory`,
   `collection`/`collections`/dump/load(+renames)/backup/compact, the
   `Collection` surface (insert/putMany/insertAuto/TTL family/patch/
   update/compareAndSet/delete family/get/getFields/scan/page/
   phraseSearch/length + all index creates + schema + graph + geo), the
   fluent `Query` builder (`filter`+`field(path)` predicates,
   vector/text/fuseRRF/rerankMMR/approx/limit/offset/orderBy/select,
   `run → List<Row>` and the aggregation terminals). Value mapping:
   `Map<String,Object?>`/`List<Object?>`/`String`/`int` (int64)/
   `double`/`Float32List`/`Uint8List`; NaN/±inf/-0.0 cross bit-exact
   (documented + pinned by the fixtures' `bits:` literals). Errors are
   `CorvidException` with the ABI code.
6. **The golden port** — `test/golden_test.dart`: 267 executable
   fixture lines through the binding, first failure named per
   file:line, dispatch count enforced, one `SMOKE <file> lines=<n>
   executed=<n>` line per fixture.
7. **Supplemental tests** — `callback_test.dart` (the §1.6
   exception-surfacing contract), `mapkeys_test.dart` (complete decode
   across a reopen), `errcodes_test.dart` (the frozen 0..19 table).
8. **Examples tour** — six runnable programs under `examples/`
   (`dart run examples/<name>.dart`), deterministic output, executed on
   every CI leg: quickstart, hybrid, vector-index, text-search (BM25
   incl. CJK + PhraseSearch), graph, geo. The quickstart + hybrid
   bodies carry `docs:begin/end` markers for the docs-site splice.
9. **CI** — `.github/workflows/ci.yml`: linux/macos/windows ×
   {stable, 3.10.0} fetching + verifying the artifacts, `dart analyze`,
   `dart test` (the golden suite), the examples tour; an ffigen drift
   job (ubuntu, libclang) re-generating `lib/src/bindings.dart` and
   byte-diffing the commit; the surface-gate job.
10. **Surface manifest** — `docs/SURFACE.tsv` (every engine construct
    at the pin resolved: binding API + proving test, or N/A + reason)
    + `scripts/surface-gate.sh` in CI.

Out of scope for DART1 (follow-ups with triggers):
- **Flutter plugin packaging** — see the platform story above.
- pub.dev publish — prepared (`publish_to: none` today); flip when the
  tour is announced.
- async/streaming wrappers, batch iterators beyond the ABI's.

## Verdict protocol

Same as corvid-c's/corvid-go's: the golden suite logs one
`SMOKE <file> lines=<n> executed=<n>` line per fixture; green means
every expectation of every executable line passed and the dispatch
count matches the pre-scan count. Divergence from the engine-side
suite's verdicts is a defect here; divergence of the artifacts from the
engine repo is a finding for the engine repo.
