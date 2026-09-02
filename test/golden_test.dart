// golden_test.dart — the golden-suite port, corvid-dart's port of the
// engine's reference harness (corvid-db/corvid, crates/corvid-ffi/c/
// smoke.c, MIT) as ported standalone by corvid-c/test/golden.c and
// through-the-binding by corvid-go/golden_test.go.
//
// Same job as upstream, different moment of truth: the engine's harness
// links the cdylib cargo just built and reads the golden/ fixtures
// committed in the engine repo; this one drives the cdylib DOWNLOADED
// from the pinned GitHub release (fetch.sh / fetch.ps1 put it, corvid.h,
// and the release's golden/ under deps/) through THIS BINDING — the Dart
// API wherever it can express the op, the raw value family where the op
// is inherently raw (VTYPE/VLEN/VAS_*/V*_REF/VNEST/VCLONE/VPUSH/VPUT
// are value-handle exercises and go through encodeValue + the internal
// read helpers in lib/src/values.dart). If the published .so/.dylib/.dll,
// header, or fixtures disagree with the engine's suite, THIS fails where
// that one stayed green — divergence is a finding for the engine repo,
// never patched around here.
//
// The mechanics are kept deliberately IDENTICAL to the C harness so the
// suites are diffable and their verdicts comparable: the same fixture
// grammar (OP<TAB>args<TAB>expected; value literals with bits:/bits32:
// NaN specials; ~x computed-double tolerance), the same dispatch, the
// same checks, one line at a time, every line dispatched, every
// expectation checked — no softened asserts. Two counting rules carry
// over verbatim: `lines` comes from an INDEPENDENT pre-scan (so a
// dispatch loop that skips a counted line diverges from `executed`),
// and the first failure names file:line + OP + expected-vs-got.
//
// Verdict protocol: stdout (test log) carries one
// "SMOKE <file> lines=<n> executed=<n>" line per fixture.

import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:typed_data';

import 'package:corvid/corvid.dart';
import 'package:corvid/src/collection.dart' as internal_coll;
import 'package:corvid/src/db.dart' as internal_db;
import 'package:corvid/src/errors.dart' as internal;
import 'package:corvid/src/native.dart' show native;
import 'package:corvid/src/values.dart' as v;
import 'package:corvid/src/bindings.dart' as b;
import 'package:ffi/ffi.dart' as ffi2;
import 'package:test/test.dart';

Uint8List kb(String s) => Uint8List.fromList(s.codeUnits);

// f32/f64 bit twiddling (NaN payloads cross bit-exactly).
final Float64List _f64 = Float64List(1);
final Uint64List _u64 = _f64.buffer.asUint64List();
double f64FromBits(int bits) {
  _u64[0] = bits;
  return _f64[0];
}

int f64Bits(double d) {
  _f64[0] = d;
  return _u64[0];
}

final Float32List _f32 = Float32List(1);
final Uint32List _u32 = _f32.buffer.asUint32List();
double f32FromBits(int bits) {
  _u32[0] = bits;
  return _f32[0];
}

int f32Bits(double d) {
  _f32[0] = d;
  return _u32[0];
}

// -------------------------------------------------------------------
// Scenario state
// -------------------------------------------------------------------

class Scenario {
  final String file;
  int line = 0;
  String op = '';
  Db? db;
  Collection? coll;
  int lastAutoID = 0;
  late final String dbPath, db2Path, dumpPath, backupPath;

  Scenario(this.file, String workdir, String stem) {
    dbPath = '$workdir/$stem.redb';
    db2Path = '$workdir/$stem-2.redb';
    dumpPath = '$workdir/$stem.dump';
    backupPath = '$workdir/$stem.backup.redb';
  }

  Never fail(String message) =>
      throw StateError('FAIL $file:$line OP=$op: $message');

  void check(bool cond, String message) {
    if (!cond) fail(message);
  }

  /// expect_ok: success or bust.
  void expectOK(void Function() body) {
    try {
      body();
    } on CorvidException catch (e) {
      fail('expected ok, got $e');
    }
  }

  /// expect_err: a failure with exactly this code AND a recorded message
  /// (driving the error-reporting pair through the Dart exception
  /// surface).
  void expectErr(void Function() body, CorvidErrorCode code) {
    try {
      body();
    } on CorvidException catch (e) {
      if (e.code != code) {
        fail(
          'expected error code ${code.value}, got ${e.code.value} (${e.message})',
        );
      }
      if (e.message.isEmpty) {
        fail('error code ${code.value} recorded but the message is missing');
      }
      return;
    } catch (e) {
      fail('expected a CorvidException (code ${code.value}), got $e');
    }
    fail('expected CORVID_ERR code ${code.value}, got success');
  }

  void closeColl() {
    coll?.close();
    coll = null;
  }

  void closeDB() {
    closeColl();
    db?.close();
    db = null;
  }

  /// (Re)acquires the primary "docs" collection handle.
  Collection docs() {
    if (coll == null) {
      final d = db;
      if (d == null) fail('no database open in this scenario');
      coll = d.collection('docs');
    }
    return coll!;
  }

  void openMemory() {
    closeDB();
    db = Db.openMemory();
    docs();
  }

  void openFile(String path) {
    closeDB();
    db = Db.open(path);
    docs();
  }

  void setColl(String name) {
    closeColl();
    final d = db;
    if (d == null) fail('no database open in this scenario');
    final c = d.collection(name);
    check(c.name == name, 'collection_name round trip failed');
    coll = c;
  }
}

// -------------------------------------------------------------------
// Spans and tokenizing (the C harness's split_top, verbatim)
// -------------------------------------------------------------------

/// Splits on top-level commas (depth-aware over []{}()), trimming
/// trailing spaces; empty input yields no tokens.
List<String> splitTop(String s) {
  final out = <String>[];
  var depth = 0;
  var start = 0;
  for (var i = 0; i <= s.length; i++) {
    final c = i < s.length ? s[i] : ',';
    switch (c) {
      case '[':
      case '{':
      case '(':
        depth++;
        break;
      case ']':
      case '}':
      case ')':
        depth--;
        break;
    }
    if (c == ',' && depth == 0) {
      var end = i;
      while (end > start && (s[end - 1] == ' ' || s[end - 1] == '\r')) {
        end--;
      }
      if (end > start) out.add(s.substring(start, end));
      start = i + 1;
    }
  }
  return out;
}

int parseI64(Scenario s, String tok) {
  final n = int.tryParse(tok);
  if (n == null) s.fail('bad int token "$tok"');
  return n;
}

int parseInt(Scenario s, String tok) => parseI64(s, tok);

/// strtoull(s, NULL, 16): an optional 0x/0X prefix, then hex digits.
int parseHex(Scenario s, String tok) {
  var t = tok;
  if (t.startsWith('0x') || t.startsWith('0X')) t = t.substring(2);
  final n = int.tryParse(t, radix: 16);
  if (n == null) s.fail('bad hex token "$tok"');
  return n;
}

/// The C harness's parse_double: bits:0x… (f64 from bits), inf/-inf/nan,
/// else decimal (correctly rounded).
double parseDouble(Scenario s, String tok) {
  if (tok.startsWith('bits:')) {
    return f64FromBits(parseHex(s, tok.substring(5)));
  }
  switch (tok) {
    case 'inf':
      return double.infinity;
    case '-inf':
      return double.negativeInfinity;
    case 'nan':
      return double.nan;
  }
  final f = double.tryParse(tok);
  if (f == null) s.fail('bad float token "$tok"');
  return f;
}

bool doubleExact(double got, double want) => f64Bits(got) == f64Bits(want);

bool doubleNear(double got, double want) =>
    (got - want).abs() <= 1e-6 * (1.0 + want.abs());

/// Matches one expected-double token: `~x` near; `=x`/bare/bits:/inf
/// bit-exact (NaN payloads included).
bool doubleMatches(Scenario s, double got, String tok) {
  if (tok.startsWith('~')) {
    return doubleNear(got, parseDouble(s, tok.substring(1)));
  }
  if (tok.startsWith('=')) {
    return doubleExact(got, parseDouble(s, tok.substring(1)));
  }
  return doubleExact(got, parseDouble(s, tok));
}

/// Parses the err:N expected token.
CorvidErrorCode errToken(Scenario s, String expected) {
  if (!expected.startsWith('err:')) {
    s.fail('error expectation must be err:N, got "$expected"');
  }
  final n = int.tryParse(expected.substring(4));
  if (n == null) s.fail('bad err token "$expected"');
  return CorvidErrorCode.fromValue(n);
}

// -------------------------------------------------------------------
// Value literals: parse into Dart values (then encodeValue builds the
// C side — exercising the binding's value mapping end to end)
// -------------------------------------------------------------------

bool startsWord(String s, int i, String word) {
  if (!s.startsWith(word, i)) return false;
  final after = i + word.length;
  if (after >= s.length) return true;
  final c = s[after];
  return c == ',' || c == ']' || c == '}' || c == ' ' || c == '\r';
}

int matchParen(Scenario s, String str, int open) {
  var depth = 0;
  for (var q = open; q < str.length; q++) {
    if (str[q] == '(') depth++;
    if (str[q] == ')') {
      depth--;
      if (depth == 0) return q;
    }
  }
  s.fail('unbalanced () in literal');
}

int matchBracket(Scenario s, String str, int open) {
  var depth = 0;
  final opener = str[open];
  final closer = opener == '['
      ? ']'
      : opener == '{'
      ? '}'
      : ')';
  for (var q = open; q < str.length; q++) {
    if (str[q] == opener) depth++;
    if (str[q] == closer) {
      depth--;
      if (depth == 0) return q;
    }
  }
  s.fail('unbalanced $opener in literal');
}

int skipWS(String s, int i) {
  while (i < s.length && (s[i] == ' ' || s[i] == '\r')) {
    i++;
  }
  return i;
}

/// Scans one numeric literal (int vs double classified by the characters
/// seen, exactly like the C harness).
(Object, int) buildNumber(Scenario s, String str, int i) {
  final start = i;
  if (startsWord(str, i, 'inf')) return (double.infinity, i + 3);
  if (startsWord(str, i, '-inf')) return (double.negativeInfinity, i + 4);
  if (startsWord(str, i, 'nan')) return (double.nan, i + 3);
  var isFloat = false, isBits = false;
  if (str.startsWith('bits:', i)) {
    isFloat = true;
    isBits = true;
    i += 5; // scan the hex payload only
  }
  while (i < str.length) {
    final c = str[i];
    if ((c.codeUnitAt(0) >= 0x30 && c.codeUnitAt(0) <= 0x39) ||
        c == '-' ||
        c == '+') {
      i++;
    } else if (c == '.' || c == 'e' || c == 'E') {
      isFloat = true;
      i++;
    } else if (isBits &&
        ((c.codeUnitAt(0) >= 0x61 && c.codeUnitAt(0) <= 0x66) || // a-f
            (c.codeUnitAt(0) >= 0x41 && c.codeUnitAt(0) <= 0x70) || // A-F
            c == 'x' ||
            c == 'X')) {
      i++;
    } else {
      break;
    }
  }
  final tok = str.substring(start, i);
  if (tok.isEmpty) s.fail('empty numeric literal');
  if (isBits) {
    // re-include the prefix, as the C harness does
    return (parseDouble(s, tok), i);
  }
  if (isFloat) {
    final f = double.tryParse(tok);
    if (f == null) s.fail('bad float literal "$tok"');
    return (f, i);
  }
  return (parseI64(s, tok), i);
}

/// Parses one literal at str[i:], returning its Dart value and the index
/// just past it.
(Object?, int) buildLit(Scenario s, String str, int i) {
  i = skipWS(str, i);
  if (i >= str.length) s.fail('empty literal');
  final start = i;
  final c = str[i];

  if (c == '-' || (c.codeUnitAt(0) >= 0x30 && c.codeUnitAt(0) <= 0x39)) {
    return buildNumber(s, str, i);
  }
  // bits:/inf/-inf/nan start with letters but are NUMBERS; they must win
  // over the b(...)/t(...) literal heads.
  if (str.startsWith('bits:', i) ||
      startsWord(str, i, 'inf') ||
      startsWord(str, i, '-inf') ||
      startsWord(str, i, 'nan')) {
    return buildNumber(s, str, i);
  }
  if (startsWord(str, i, 'null')) return (null, i + 4);
  if (startsWord(str, i, 'true')) return (true, i + 4);
  if (startsWord(str, i, 'false')) return (false, i + 5);

  if ((c == 't' || c == 'b') && i + 1 < str.length && str[i + 1] == '(') {
    final close = matchParen(s, str, i + 1);
    final body = str.substring(i + 2, close);
    i = close + 1;
    if (c == 't') return (body, i); // text: raw code units (ASCII fixtures)
    return (Uint8List.fromList(body.codeUnits), i);
  }
  if (str.startsWith('vec(', i)) {
    final close = matchParen(s, str, i + 3);
    final body = str.substring(i + 4, close);
    i = close + 1;
    return (buildVec(s, body), i);
  }

  if (c == '[') {
    final close = matchBracket(s, str, i);
    final arr = <Object?>[];
    var j = i + 1;
    while (j < close) {
      final (item, next) = buildLit(s, str, j);
      arr.add(item);
      j = skipWS(str, next);
      if (j < close && str[j] == ',') j++;
    }
    return (arr, close + 1);
  }

  if (c == '{') {
    final close = matchBracket(s, str, i);
    final m = <String, Object?>{};
    var j = i + 1;
    while (j < close) {
      j = skipWS(str, j);
      final ks = j;
      while (j < close && str[j] != '=' && str[j] != ',' && str[j] != '}') {
        j++;
      }
      if (j >= close || str[j] != '=') s.fail('map literal needs k=v pairs');
      var key = str.substring(ks, j);
      while (key.startsWith(' ')) {
        key = key.substring(1);
      }
      j++; // past '='
      final (val, next) = buildLit(s, str, j);
      m[key] = val;
      j = skipWS(str, next);
      if (j < close && str[j] == ',') j++;
    }
    return (m, close + 1);
  }

  var snippet = str.substring(start);
  if (snippet.length > 24) snippet = snippet.substring(0, 24);
  s.fail('unparseable literal at "$snippet"');
}

Float32List buildVec(Scenario s, String body) {
  final toks = splitTop(body);
  final vals = <double>[];
  for (final tk in toks) {
    if (tk.startsWith('bits32:')) {
      vals.add(f32FromBits(parseHex(s, tk.substring(7))));
    } else {
      vals.add(parseDouble(s, tk));
    }
  }
  return Float32List.fromList(vals);
}

Object? lit(Scenario s, String str) => buildLit(s, str, 0).$1;

/// Builds an OWNED C value from a literal token (the internal encoder).
ffi.Pointer<b.corvid_value> encode(Scenario s, String literal) {
  try {
    return v.encodeValue(lit(s, literal));
  } on CorvidException catch (e) {
    s.fail('encode: $e');
  }
}

// -------------------------------------------------------------------
// Structural comparison of Dart-side values (bit-exact floats — the
// decode side of the C harness's read-API comparison)
// -------------------------------------------------------------------

bool valuesEqualDart(Object? a, Object? other) {
  if (a == null) return other == null;
  if (a is bool) return other is bool && a == other;
  if (a is int) return other is int && a == other;
  if (a is double) {
    return other is double && f64Bits(a) == f64Bits(other);
  }
  if (a is String) return other is String && a == other;
  if (a is Uint8List) {
    return other is Uint8List && _bytesEqual(a, other);
  }
  if (a is Float32List) {
    if (other is! Float32List || a.length != other.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (f32Bits(a[i]) != f32Bits(other[i])) return false;
    }
    return true;
  }
  if (a is List<Object?>) {
    if (other is! List<Object?> || a.length != other.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!valuesEqualDart(a[i], other[i])) return false;
    }
    return true;
  }
  if (a is Map<String, Object?>) {
    if (other is! Map<String, Object?> || a.length != other.length) {
      return false;
    }
    for (final e in a.entries) {
      if (!other.containsKey(e.key)) return false;
      if (!valuesEqualDart(e.value, other[e.key])) return false;
    }
    return true;
  }
  return false;
}

bool _bytesEqual(Uint8List x, Uint8List y) {
  if (x.length != y.length) return false;
  for (var i = 0; i < x.length; i++) {
    if (x[i] != y[i]) return false;
  }
  return true;
}

String repr(Object? v) {
  if (v is Uint8List) return 'b(${String.fromCharCodes(v)})';
  if (v is Float32List) return 'vec(${v.join(",")})';
  return '$v';
}

/// Compares a decoded Dart value against an expected literal token
/// (bit-exact; NaN payloads included).
void checkValue(Scenario s, Object? got, String wantTok) {
  final want = lit(s, wantTok);
  if (!valuesEqualDart(got, want)) {
    s.fail('value mismatch: got ${repr(got)}, want ${repr(want)}');
  }
}

// -------------------------------------------------------------------
// Cursor walkers (keyed off the Dart API's returned rows/lists)
// -------------------------------------------------------------------

List<String> rowKeys(List<Row> rows) => [
  for (final r in rows) String.fromCharCodes(r.key),
];

List<double> rowScores(List<Row> rows) => [for (final r in rows) r.score];

List<String> bytesKeys(List<Uint8List> keys) => [
  for (final k in keys) String.fromCharCodes(k),
];

/// Matches "k(a,b,c)" — key order exact.
void checkKeys(Scenario s, List<String> keys, String expected) {
  if (expected.length < 3 ||
      expected[0] != 'k' ||
      expected[1] != '(' ||
      expected[expected.length - 1] != ')') {
    s.fail('key expectation must be k(...), got "$expected"');
  }
  final body = expected.substring(2, expected.length - 1);
  final want = body.isEmpty ? <String>[] : splitTop(body);
  if (keys.length != want.length) {
    s.fail('row count ${keys.length}, expected ${want.length} ($keys)');
  }
  for (var i = 0; i < want.length; i++) {
    if (keys[i] != want[i]) {
      s.fail('row $i key "${keys[i]}", expected "${want[i]}"');
    }
  }
}

/// Matches a "|~s1,~s2" suffix — one double token per row.
void checkScores(Scenario s, List<double> scores, String suffix) {
  if (suffix.isEmpty) return;
  if (suffix[0] != '|') s.fail('score suffix must start with |, got "$suffix"');
  final body = suffix.substring(1);
  if (body.isEmpty) return;
  final toks = splitTop(body);
  if (scores.length != toks.length) {
    s.fail('score count ${scores.length}, expected ${toks.length}');
  }
  for (var i = 0; i < toks.length; i++) {
    if (!doubleMatches(s, scores[i], toks[i])) {
      s.fail('row $i score ${scores[i]} does not match "${toks[i]}"');
    }
  }
}

String keyPart(String expected) {
  final i = expected.indexOf('|');
  return i >= 0 ? expected.substring(0, i) : expected;
}

String suffixPart(String expected) {
  final i = expected.indexOf('|');
  return i >= 0 ? expected.substring(i) : '';
}

/// Extracts the t(...) literal body.
String textBody(Scenario s, String tok) {
  if (tok.length < 3 ||
      tok[0] != 't' ||
      tok[1] != '(' ||
      tok[tok.length - 1] != ')') {
    s.fail('expected a t(...) literal, got "$tok"');
  }
  return tok.substring(2, tok.length - 1);
}

/// Extracts the k(...) list body.
String listBody(Scenario s, String tok) {
  if (tok.length < 3 ||
      tok[0] != 'k' ||
      tok[1] != '(' ||
      tok[tok.length - 1] != ')') {
    s.fail('expected a k(...) list, got "$tok"');
  }
  return tok.substring(2, tok.length - 1);
}

// -------------------------------------------------------------------
// Predicate / enum parse helpers
// -------------------------------------------------------------------

final Map<String, int> _cmpOps = {
  'eq': 0,
  'ne': 1,
  'lt': 2,
  'le': 3,
  'gt': 4,
  'ge': 5,
};

Predicate fieldCmp(Scenario s, String path, String opTok, Object? val) {
  final op = _cmpOps[opTok];
  if (op == null) s.fail('bad cmp op "$opTok"');
  final f = field(path);
  return switch (op) {
    0 => f.eq(val),
    1 => f.ne(val),
    2 => f.lt(val),
    3 => f.le(val),
    4 => f.gt(val),
    _ => f.ge(val),
  };
}

Metric parseMetric(Scenario s, String tok) => switch (tok) {
  'cosine' => Metric.cosine,
  'dot' => Metric.dot,
  'l2' => Metric.l2,
  _ => s.fail('bad metric "$tok"'),
};

Quant parseQuant(Scenario s, String tok) => switch (tok) {
  'none' => Quant.none,
  'binary' => Quant.binary,
  'scalar' => Quant.scalar,
  _ => s.fail('bad quant "$tok"'),
};

FieldType parseFieldType(Scenario s, String tok) => switch (tok) {
  'any' => FieldType.any,
  'bool' => FieldType.boolean,
  'int' => FieldType.integer,
  'float' => FieldType.float,
  'text' => FieldType.text,
  'bytes' => FieldType.bytes,
  'vector' => FieldType.vector,
  'array' => FieldType.array,
  'map' => FieldType.map,
  _ => s.fail('bad field type "$tok"'),
};

/// The (filter) → count workhorse: builds, filters, counts — all
/// consumed by the terminal.
int filteredCount(Scenario s, Predicate p) =>
    s.docs().query().filter(p).count();

void expectNum(Scenario s, String expected, int got) {
  if (parseI64(s, expected) != got) {
    s.fail('expected $got, want "$expected"');
  }
}

// -------------------------------------------------------------------
// OP implementations (the C harness's run_line, op for op)
// -------------------------------------------------------------------

void runLine(Scenario S, String op, String args, String expected) {
  final a = splitTop(args);

  // ---- pure value ops (no db) ----
  switch (op) {
    case 'VERSION':
      S.check(
        native.corvid_ffi_version() == 1,
        'FFI_VERSION must be 1, got ${native.corvid_ffi_version()}',
      );
      return;

    case 'VTYPE':
      const names = [
        'null',
        'bool',
        'int',
        'float',
        'text',
        'bytes',
        'array',
        'map',
        'vector',
      ];
      final val = encode(S, a[0]);
      try {
        final t = native.corvid_value_type(val);
        S.check(t <= 8, 'type tag $t out of range');
        S.check(expected == names[t], 'type ${names[t]}, want "$expected"');
      } finally {
        v.freeValue(val);
      }
      return;

    case 'VLEN':
      final val = encode(S, a[0]);
      try {
        expectNum(S, expected, native.corvid_value_len(val));
      } finally {
        v.freeValue(val);
      }
      return;

    case 'VAS_INT':
    case 'VAS_FLOAT':
    case 'VAS_BOOL':
      final val = encode(S, a[0]);
      try {
        if (op == 'VAS_INT') {
          final got = v.valueAsInt(val);
          if (expected == 'fail') {
            S.check(got == null, 'as_int unexpectedly ok ($got)');
          } else {
            S.check(got != null, 'as_int failed');
            S.check(expected == 'ok:$got', 'as_int ok:$got, want "$expected"');
          }
        } else if (op == 'VAS_FLOAT') {
          final got = v.valueAsFloat(val);
          if (expected == 'fail') {
            S.check(got == null, 'as_float unexpectedly ok');
          } else {
            S.check(got != null, 'as_float failed');
            S.check(
              expected.startsWith('ok:'),
              'as_float expectation must be ok:<double>, got "$expected"',
            );
            S.check(
              doubleMatches(S, got!, expected.substring(3)),
              'as_float ${got.toStringAsPrecision(17)} does not match "${expected.substring(3)}"',
            );
          }
        } else {
          final got = v.valueAsBool(val);
          if (expected == 'fail') {
            S.check(got == null, 'as_bool unexpectedly ok');
          } else {
            S.check(got != null, 'as_bool failed');
            final want = got! ? 'ok:1' : 'ok:0';
            S.check(expected == want, 'as_bool $want, want "$expected"');
          }
        }
      } finally {
        v.freeValue(val);
      }
      return;

    case 'VTEXT_REF':
    case 'VBYTES_REF':
    case 'VVECTOR_REF':
      final val = encode(S, a[0]);
      try {
        if (op == 'VTEXT_REF') {
          final got = v.valueTextRef(val);
          S.check(got != null, 'text_ref returned NULL for a text value');
          final body = textBody(S, expected);
          S.check(got == body, 'text bytes differ: got "$got", want "$body"');
        } else if (op == 'VBYTES_REF') {
          final got = v.valueBytesRef(val);
          S.check(got != null, 'bytes_ref returned NULL for a bytes value');
          S.check(
            expected.length >= 3 && expected[0] == 'b' && expected[1] == '(',
            'bytes expectation must be b(...), got "$expected"',
          );
          final body = expected.substring(2, expected.length - 1);
          S.check(
            String.fromCharCodes(got!) == body,
            'bytes differ: got "${String.fromCharCodes(got)}", want "$body"',
          );
        } else {
          final got = v.valueVectorRef(val);
          S.check(got != null, 'vector_ref returned NULL for a vector value');
          final want = lit(S, a[0]) as Float32List;
          S.check(
            got!.length == want.length,
            'ref dim ${got.length}, rebuilt dim ${want.length}',
          );
          for (var i = 0; i < want.length; i++) {
            S.check(
              f32Bits(got[i]) == f32Bits(want[i]),
              'vector elem $i differs bit-exactly',
            );
          }
        }
      } finally {
        v.freeValue(val);
      }
      return;

    case 'VNEST':
    case 'VCLONE':
      final root = encode(S, a[0]);
      ffi.Pointer<b.corvid_value> holder = root;
      try {
        if (op == 'VCLONE') {
          holder = native.corvid_value_clone(root);
          S.check(holder != ffi.nullptr, 'clone failed');
        }
        final child = v.walkValuePath(holder, a[1]);
        if (expected == 'absent') {
          S.check(child == ffi.nullptr, 'path unexpectedly present');
        } else {
          S.check(
            child != ffi.nullptr,
            'path unexpectedly absent, want "$expected"',
          );
          checkValue(S, v.decodeValue(child), expected);
        }
      } finally {
        if (op == 'VCLONE' && holder != ffi.nullptr) v.freeValue(holder);
        v.freeValue(root);
      }
      return;

    case 'VPUSH':
      final arr = encode(S, a[0]);
      final item = encode(S, a[1]);
      try {
        final st = native.corvid_value_array_push(arr, item); // consumes item
        S.check(st == 0, 'array_push failed');
      } finally {
        // item was consumed unconditionally (§8) — never freed here
        expectNum(S, expected, native.corvid_value_len(arr));
        v.freeValue(arr);
      }
      return;

    case 'VPUT':
      final m = encode(S, a[0]);
      final val = encode(S, a[2]);
      try {
        final kp = v.nativeUtf8(a[1]);
        final st = native.corvid_value_map_put(m, kp.ptr, kp.len, val);
        v.ffiFree(kp.ptr.cast());
        S.check(st == 0, 'map_put failed');
      } finally {
        expectNum(S, expected, native.corvid_value_len(m));
        v.freeValue(m);
      }
      return;

    case 'VMAP_KEYS':
      // The v0.3.0 key iterator over a LITERAL: ascending key-BYTE order
      // whatever the construction order; empty maps, non-maps, and
      // scalars answer an EMPTY cursor — inert.
      final val = encode(S, a[0]);
      try {
        final keys = v.valueMapKeys(val);
        checkKeys(S, keys, expected);
      } finally {
        v.freeValue(val);
      }
      return;

    case 'NULLFREES':
      // every _free(NULL) shape is a documented no-op (§7)
      native.corvid_value_free(ffi.nullptr.cast());
      native.corvid_pred_free(ffi.nullptr.cast());
      native.corvid_query_free(ffi.nullptr.cast());
      native.corvid_rows_free(ffi.nullptr.cast());
      native.corvid_strs_free(ffi.nullptr.cast());
      native.corvid_geohits_free(ffi.nullptr.cast());
      native.corvid_groupiter_free(ffi.nullptr.cast());
      native.corvid_schemaiter_free(ffi.nullptr.cast());
      native.corvid_collection_free(ffi.nullptr.cast());
      native.corvid_free(ffi.nullptr.cast());
      return;
  }

  // ---- db-required ops from here on ----
  switch (op) {
    case 'COLL':
      S.setColl(a[0]);
      return;

    case 'INSERT':
    case 'INSERT_ERR':
      void body() => S.docs().insert(kb(a[0]), lit(S, a[1]));
      if (op == 'INSERT_ERR') {
        S.expectErr(body, errToken(S, expected));
      } else {
        S.expectOK(body);
      }
      return;

    case 'LEN':
      S.expectOK(() {});
      expectNum(S, expected, S.docs().length());
      return;

    case 'GET':
      if (expected == 'absent') {
        final doc = S.docs().get(kb(a[0]));
        S.check(doc == null, 'expected absence, got a document: $doc');
        return;
      }
      final doc = S.docs().get(kb(a[0]));
      S.check(doc != null, 'expected a document, got absence');
      checkValue(S, doc, expected);
      return;

    case 'GETFIELD':
      final m = S.docs().getFields(kb(a[0]), [a[1]]);
      final got = m[a[1]];
      if (expected == 'absent') {
        S.check(!m.containsKey(a[1]), 'field unexpectedly present');
      } else {
        S.check(
          m.containsKey(a[1]),
          'field unexpectedly absent, want "$expected"',
        );
        checkValue(S, got, expected);
      }
      return;

    case 'GET_KEYS':
      // Key enumeration over a document fetched by key first (the
      // decode-from-storage half bindings need): the storage round-trip
      // keeps every key; ascending byte order.
      final out = ffi2.malloc<ffi.Pointer<b.corvid_value>>(
        ffi.sizeOf<ffi.Pointer<b.corvid_value>>(),
      );
      final kp = v.nativeBytes(kb(a[0]));
      ffi.Pointer<b.corvid_value> got = ffi.nullptr;
      try {
        final st = native.corvid_get(
          internal_coll.collHandleOf(S.docs()),
          kp,
          a[0].length,
          out,
        );
        S.check(st == 0, 'get failed (status $st)');
        got = out.value;
        S.check(got != ffi.nullptr, 'GET_KEYS on an absent document');
        final keys = v.valueMapKeys(got);
        checkKeys(S, keys, expected);
      } finally {
        v.ffiFree(kp.cast());
        v.ffiFree(out.cast());
        if (got != ffi.nullptr) v.freeValue(got);
      }
      return;

    case 'PUTMANY':
    case 'PUTMANY_ROLLBACK':
      S.check(a.length % 2 == 0, 'PUTMANY wants key/literal pairs');
      final count = a.length ~/ 2;
      final keys = <Uint8List>[];
      final docs = <Object?>[];
      for (var i = 0; i < count; i++) {
        keys.add(kb(a[2 * i]));
        docs.add(lit(S, a[2 * i + 1]));
      }
      void body() => S.docs().putMany(keys, docs);
      if (op == 'PUTMANY_ROLLBACK') {
        S.expectErr(body, errToken(S, expected));
      } else {
        S.expectOK(body);
      }
      return;

    case 'INSERT_AUTO':
      final key = S.docs().insertAuto(lit(S, a[0]));
      S.check(key.length == 20, 'auto key length ${key.length}, want 20');
      var id = 0;
      for (final byte in key) {
        S.check(
          byte >= 0x30 && byte <= 0x39,
          'auto key not zero-padded digits: ${String.fromCharCodes(key)}',
        );
        id = id * 10 + (byte - 0x30);
      }
      S.check(
        S.lastAutoID == 0 || id > S.lastAutoID,
        'auto id $id not monotonic (previous ${S.lastAutoID})',
      );
      S.lastAutoID = id;
      return;

    case 'UPDATE':
      S.expectOK(
        () => S.docs().update(kb(a[0]), (current) {
          var n = 0;
          if (current != null) {
            final m = current;
            if (m is! Map<String, Object?>) {
              throw CorvidException(
                CorvidErrorCode.argument,
                'update_bump: not a map',
              );
            }
            final f = m['n'];
            if (f is! int) {
              throw CorvidException(
                CorvidErrorCode.argument,
                'update_bump: n is not an int',
              );
            }
            n = f;
          }
          return {'n': n + 1};
        }),
      );
      return;

    case 'UPDATE_ABORT':
      S.expectErr(
        () => S.docs().update(
          kb(a[0]),
          (current) => throw CorvidException(
            CorvidErrorCode.argument,
            'update_abort: aborting per the fixture',
          ),
        ),
        CorvidErrorCode.argument,
      );
      return;

    case 'PATCH':
      S.expectOK(() => S.docs().patch(kb(a[0]), lit(S, a[1])));
      return;

    case 'CAS':
      Object? ex, re;
      if (a[1] != 'absent') ex = lit(S, a[1]);
      if (a[2] != 'absent') re = lit(S, a[2]);
      var applied = false;
      S.expectOK(() {
        applied = S.docs().compareAndSet(kb(a[0]), ex, re);
      });
      final want = applied ? 'applied:1' : 'applied:0';
      S.check(
        expected == want,
        'CAS applied=$applied, want "$want" (expected "$expected")',
      );
      return;

    case 'DELETE':
      var existed = false;
      S.expectOK(() {
        existed = S.docs().delete(kb(a[0]));
      });
      final want = existed ? 'existed:1' : 'existed:0';
      S.check(expected == want, 'delete existed=$existed, want "$want"');
      return;

    case 'DELETE_WHERE':
      var removed = 0;
      S.expectOK(() {
        removed = S.docs().deleteWhere(fieldCmp(S, a[0], a[1], lit(S, a[2])));
      });
      S.check(
        expected == 'removed:$removed',
        'removed $removed, want "$expected"',
      );
      return;

    case 'DELETE_IN':
      final vals = [for (var i = 1; i < a.length; i++) lit(S, a[i])];
      var removed = 0;
      S.expectOK(() {
        removed = S.docs().deleteWhere(field(a[0]).isIn(vals));
      });
      S.check(
        expected == 'removed:$removed',
        'removed $removed, want "$expected"',
      );
      return;

    case 'DELETE_BATCH':
      final keys = [for (final k in a) kb(k)];
      var removed = 0;
      S.expectOK(() {
        removed = S.docs().deleteBatch(keys);
      });
      S.check(
        expected == 'removed:$removed',
        'removed $removed, want "$expected"',
      );
      return;

    case 'INSERT_TTL':
      S.expectOK(
        () => S.docs().insertTTL(kb(a[0]), lit(S, a[1]), parseI64(S, a[2])),
      );
      return;

    case 'GET_TTL':
      int? at;
      S.expectOK(() {
        at = S.docs().getTTL(kb(a[0]));
      });
      final got = at == null ? 'nottl' : 'ttl:$at';
      S.check(expected == got, 'ttl $got, want "$expected"');
      return;

    case 'SET_TTL':
      S.expectOK(() => S.docs().setTTL(kb(a[0]), parseI64(S, a[1])));
      return;

    case 'PURGE':
      var purged = 0;
      S.expectOK(() {
        purged = S.docs().purgeExpired(parseI64(S, a[0]));
      });
      S.check(expected == 'purged:$purged', 'purged $purged, want "$expected"');
      return;

    case 'SCAN':
    case 'SCAN_STOP':
      final stop = op == 'SCAN_STOP' ? parseInt(S, a[0]) : 0;
      var count = 0;
      S.expectOK(
        () => S.docs().scan((key, doc) {
          count++;
          return stop <= 0 || count < stop;
        }),
      );
      expectNum(S, expected, count);
      return;

    case 'PAGE':
      final after = a[0] == '-' ? null : kb(a[0]);
      late final Page page;
      S.expectOK(() {
        page = S.docs().page(after, parseInt(S, a[1]));
      });
      checkKeys(S, rowKeys(page.rows), keyPart(expected));
      final sp = suffixPart(expected);
      final want = page.next == null ? '|end' : '|more';
      S.check(sp == want, 'page cursor $want, want "$sp"');
      return;
  }

  // ---- predicates + queries ----
  switch (op) {
    case 'QF_COUNT':
      expectNum(
        S,
        expected,
        filteredCount(S, fieldCmp(S, a[0], a[1], lit(S, a[2]))),
      );
      return;

    case 'QF_EXISTS':
      expectNum(S, expected, filteredCount(S, field(a[0]).exists()));
      return;

    case 'QF_BETWEEN':
      expectNum(
        S,
        expected,
        filteredCount(S, field(a[0]).between(lit(S, a[1]), lit(S, a[2]))),
      );
      return;

    case 'QF_STARTS':
    case 'QF_CONTAINS':
      final body = textBody(S, a[1]);
      final p = op == 'QF_STARTS'
          ? field(a[0]).startsWith(body)
          : field(a[0]).contains(body);
      expectNum(S, expected, filteredCount(S, p));
      return;

    case 'QF_GEO':
      expectNum(
        S,
        expected,
        filteredCount(
          S,
          field(a[0]).geoWithin(
            parseDouble(S, a[1]),
            parseDouble(S, a[2]),
            parseDouble(S, a[3]),
          ),
        ),
      );
      return;

    case 'QF_AND':
    case 'QF_OR':
      final l = fieldCmp(S, a[0], a[1], lit(S, a[2]));
      final r = fieldCmp(S, a[3], a[4], lit(S, a[5]));
      final p = op == 'QF_AND' ? l.and(r) : l.or(r);
      expectNum(S, expected, filteredCount(S, p));
      return;

    case 'QF_NOT':
      expectNum(
        S,
        expected,
        filteredCount(S, fieldCmp(S, a[0], a[1], lit(S, a[2])).not()),
      );
      return;

    case 'PRED_FREE':
      fieldCmp(S, a[0], a[1], lit(S, a[2])).close(); // never-consumed free
      return;

    case 'Q_ABANDON':
      S.docs().query().close(); // the abandoned-builder free path
      return;

    case 'QVEC':
    case 'APPROX':
      late final List<Row> rows;
      S.expectOK(() {
        final q = S.docs().query();
        if (op == 'APPROX') q.approx();
        rows = q
            .vector(
              a[0],
              lit(S, a[1]) as Float32List,
              parseInt(S, a[2]),
              Metric.cosine,
            )
            .run();
      });
      checkKeys(S, rowKeys(rows), keyPart(expected));
      checkScores(S, rowScores(rows), suffixPart(expected));
      return;

    case 'QTEXT':
      late final List<Row> rows;
      S.expectOK(() {
        rows = S
            .docs()
            .query()
            .text(a[0], textBody(S, a[1]), parseInt(S, a[2]))
            .run();
      });
      checkKeys(S, rowKeys(rows), expected);
      return;

    case 'PHRASE':
    case 'PHRASE_K0':
      // The v0.3.0 direct positional search through the binding's
      // phraseSearch: order-sensitive adjacency, BM25 phrase scores in
      // the score suffix; PHRASE_K0 is the inert k==0 shape — an EMPTY
      // result, never an error.
      late final List<Row> rows;
      S.expectOK(() {
        rows = S.docs().phraseSearch(
          a[0],
          textBody(S, a[1]),
          parseInt(S, a[2]),
        );
      });
      checkKeys(S, rowKeys(rows), keyPart(expected));
      checkScores(S, rowScores(rows), suffixPart(expected));
      if (op == 'PHRASE_K0') {
        S.check(rows.isEmpty, 'k == 0 must answer an empty cursor');
      }
      return;

    case 'HYBRID':
    case 'HYBRID_F':
      // args: vfield vec k tfield t(query) tk [tagvalue] limit — the
      // tagvalue (HYBRID_F) slides the limit to the LAST slot.
      // (HYBRID adds a kind=doc filter; HYBRID_F a tag=<arg6> filter)
      final tagged = op == 'HYBRID_F';
      final vk = parseInt(S, a[2]);
      final tk = parseInt(S, a[5]);
      var limitIdx = 6;
      Predicate filter;
      if (tagged) {
        filter = field('tag').eq(lit(S, a[6]));
        limitIdx = 7;
      } else {
        filter = field('kind').eq('doc');
      }
      late final List<Row> rows;
      S.expectOK(() {
        rows = S
            .docs()
            .query()
            .filter(filter)
            .vector(a[0], lit(S, a[1]) as Float32List, vk, Metric.cosine)
            .text(a[3], textBody(S, a[4]), tk)
            .fuseRRF(60.0)
            .rerankMMR(1.0)
            .limit(parseInt(S, a[limitIdx]))
            .run();
      });
      checkKeys(S, rowKeys(rows), keyPart(expected));
      checkScores(S, rowScores(rows), suffixPart(expected));
      return;

    case 'ORDER_BY':
      late final List<Row> rows;
      S.expectOK(() {
        rows = S
            .docs()
            .query()
            .orderBy(a[0], descending: parseInt(S, a[1]) != 0)
            .offset(parseInt(S, a[2]))
            .limit(parseInt(S, a[3]))
            .run();
      });
      checkKeys(S, rowKeys(rows), expected);
      return;

    case 'SELECT':
      // args: (field,field,...) k(row-key); expected: that row's
      // projected document.
      S.check(
        a[0].length >= 2 && a[0][0] == '(' && a[0][a[0].length - 1] == ')',
        'SELECT\'s first arg must be a (field,...) group, got "${a[0]}"',
      );
      final fields = splitTop(a[0].substring(1, a[0].length - 1));
      late final List<Row> rows;
      S.expectOK(() {
        rows = S.docs().query().select(fields).run();
      });
      final wantKey = listBody(S, a[1]);
      Object? doc;
      var found = false;
      for (final r in rows) {
        if (String.fromCharCodes(r.key) == wantKey) {
          doc = r.doc;
          found = true;
        }
      }
      S.check(found, 'row "$wantKey" not in the result');
      checkValue(S, doc, expected);
      return;

    case 'AGG_COUNT':
      expectNum(S, expected, S.docs().query().count());
      return;

    case 'AGG_DISTINCT':
      expectNum(S, expected, S.docs().query().countDistinct(a[0]));
      return;

    case 'AGG_SUM':
      final sum = S.docs().query().sum(a[0]);
      S.check(doubleMatches(S, sum, expected), 'sum $sum vs "$expected"');
      return;

    case 'AGG_AVG':
      final avg = S.docs().query().avg(a[0]);
      if (expected == 'none') {
        S.check(avg == null, 'avg ${avg != null}, want none');
      } else {
        S.check(avg != null, 'avg null, want "$expected"');
        S.check(doubleMatches(S, avg!, expected), 'avg $avg vs "$expected"');
      }
      return;

    case 'AGG_MIN':
    case 'AGG_MAX':
      final out = op == 'AGG_MIN'
          ? S.docs().query().min(a[0])
          : S.docs().query().max(a[0]);
      if (expected == 'absent') {
        S.check(out == null, 'expected absence');
      } else {
        S.check(out != null, 'expected a value, got absence');
        checkValue(S, out, expected);
      }
      return;

    case 'AGG_GCOUNT':
    case 'AGG_GSUM':
    case 'AGG_GAVG':
      final q = S.docs().query();
      late final List<Group> groups;
      if (op == 'AGG_GCOUNT') {
        groups = q.groupCount(a[0]);
      } else if (op == 'AGG_GSUM') {
        groups = q.groupSum(a[0], a[1]);
      } else {
        groups = q.groupAvg(a[0], a[1]);
      }
      // §7 inert rule exercised once with a NULL handle.
      S.check(
        native.corvid_groupiter_next(
              ffi.nullptr.cast(),
              ffi.nullptr.cast(),
              ffi.nullptr.cast(),
              ffi.nullptr.cast(),
            ) ==
            0,
        'NULL-handle groupiter_next must answer 0',
      );
      S.check(
        expected.length >= 3 &&
            expected[0] == 'g' &&
            expected[1] == '(' &&
            expected[expected.length - 1] == ')',
        'group expectation must be g(...), got "$expected"',
      );
      final body = expected.substring(2, expected.length - 1);
      final pairs = body.isEmpty ? <String>[] : splitTop(body);
      S.check(
        groups.length == pairs.length,
        'group count ${groups.length}, expected ${pairs.length}',
      );
      for (var i = 0; i < pairs.length; i++) {
        final eq = pairs[i].lastIndexOf('=');
        S.check(eq > 0, 'group pair needs key=val, got "${pairs[i]}"');
        final key = pairs[i].substring(0, eq);
        final vtok = pairs[i].substring(eq + 1);
        S.check(
          groups[i].key == key,
          'group key "${groups[i].key}", want "$key"',
        );
        S.check(
          doubleMatches(S, groups[i].value, vtok),
          'group "$key" value ${groups[i].value} vs "$vtok"',
        );
      }
      return;
  }

  // ---- graph ----
  switch (op) {
    case 'LINK':
      S.expectOK(() => S.docs().link(kb(a[0]), a[1], kb(a[2])));
      return;

    case 'LINK_W':
      S.expectOK(
        () => S.docs().linkWeighted(
          kb(a[0]),
          a[1],
          kb(a[2]),
          parseDouble(S, a[3]),
        ),
      );
      return;

    case 'UNLINK':
      var removed = false;
      S.expectOK(() {
        removed = S.docs().unlink(kb(a[0]), a[1], kb(a[2]));
      });
      final want = removed ? 'removed:1' : 'removed:0';
      S.check(expected == want, 'unlink removed=$removed, want "$want"');
      return;

    case 'NEIGHBORS':
    case 'IN_NEIGHBORS':
      late final List<Uint8List> keys;
      S.expectOK(() {
        keys = op == 'NEIGHBORS'
            ? S.docs().neighbors(kb(a[0]), a[1])
            : S.docs().inNeighbors(kb(a[0]), a[1]);
      });
      checkKeys(S, bytesKeys(keys), expected);
      return;

    case 'NEIGHBORS_W':
      late final List<Weighted> weighted;
      S.expectOK(() {
        weighted = S.docs().neighborsWeighted(kb(a[0]), a[1]);
      });
      S.check(
        expected.length >= 3 &&
            expected[0] == 'g' &&
            expected[1] == '(' &&
            expected[expected.length - 1] == ')',
        'weighted expectation must be g(...), got "$expected"',
      );
      final body = expected.substring(2, expected.length - 1);
      final pairs = body.isEmpty ? <String>[] : splitTop(body);
      S.check(
        weighted.length == pairs.length,
        'weighted hits ${weighted.length}, expected ${pairs.length}',
      );
      for (var i = 0; i < pairs.length; i++) {
        final eq = pairs[i].lastIndexOf('=');
        S.check(eq > 0, 'weighted pair needs key=val, got "${pairs[i]}"');
        final key = pairs[i].substring(0, eq);
        final vtok = pairs[i].substring(eq + 1);
        S.check(
          String.fromCharCodes(weighted[i].key) == key,
          'weighted key "${String.fromCharCodes(weighted[i].key)}", want "$key"',
        );
        S.check(
          doubleMatches(S, weighted[i].weight, vtok),
          'weight of "$key" ${weighted[i].weight} vs "$vtok"',
        );
      }
      return;

    case 'TRAVERSE':
      late final List<Uint8List> keys;
      S.expectOK(() {
        keys = S.docs().traverse(kb(a[0]), a[1], parseInt(S, a[2]));
      });
      checkKeys(S, bytesKeys(keys), expected);
      return;
  }

  // ---- geo ----
  switch (op) {
    case 'GINSERT':
    case 'GINSERT_M':
      Object loc;
      if (op == 'GINSERT_M') {
        // {lat, lon} map form
        loc = {'lat': parseDouble(S, a[1]), 'lon': parseDouble(S, a[2])};
      } else {
        loc = [parseDouble(S, a[1]), parseDouble(S, a[2])];
      }
      S.expectOK(() => S.docs().insert(kb(a[0]), {'loc': loc}));
      return;

    case 'RADIUS':
    case 'NEAREST':
    case 'BBOX':
      late final List<GeoHit> hits;
      S.expectOK(() {
        if (op == 'RADIUS') {
          hits = S.docs().geoWithinRadius(
            a[0],
            parseDouble(S, a[1]),
            parseDouble(S, a[2]),
            parseDouble(S, a[3]),
          );
        } else if (op == 'NEAREST') {
          hits = S.docs().geoNearest(
            a[0],
            parseDouble(S, a[1]),
            parseDouble(S, a[2]),
            parseInt(S, a[3]),
          );
        } else {
          hits = S.docs().geoWithinBBox(
            a[0],
            parseDouble(S, a[1]),
            parseDouble(S, a[2]),
            parseDouble(S, a[3]),
            parseDouble(S, a[4]),
          );
        }
      });
      final keys = [for (final h in hits) String.fromCharCodes(h.key)];
      final dists = [for (final h in hits) h.distanceKm];
      checkKeys(S, keys, keyPart(expected));
      final sp = suffixPart(expected);
      if (sp.isNotEmpty) {
        S.check(sp[0] == '|', 'geo suffix must start with |, got "$sp"');
        final body = sp.substring(1);
        final toks = body.isEmpty ? <String>[] : splitTop(body);
        S.check(
          dists.length == toks.length,
          'distance count ${dists.length}, expected ${toks.length}',
        );
        for (var i = 0; i < toks.length; i++) {
          S.check(
            doubleMatches(S, dists[i], toks[i]),
            'hit $i distance ${dists[i]} vs "${toks[i]}"',
          );
        }
      }
      return;

    case 'BBOX_ERR':
      S.expectErr(
        () => S.docs().geoWithinBBox(
          a[0],
          parseDouble(S, a[1]),
          parseDouble(S, a[2]),
          parseDouble(S, a[3]),
          parseDouble(S, a[4]),
        ),
        errToken(S, expected),
      );
      return;
  }

  // ---- schema & indexes ----
  switch (op) {
    case 'SET_SCHEMA':
      final specs = splitTop(args);
      final defs = <FieldDef>[];
      for (final spec in specs) {
        // field specs split on '#' (no nesting inside a spec)
        final part = spec.split('#');
        S.check(
          part.length == 4,
          'field spec needs name#type#required#unique, got "$spec"',
        );
        defs.add(
          FieldDef(
            part[0],
            parseFieldType(S, part[1]),
            required: part[2] == '1',
            unique: part[3] == '1',
          ),
        );
      }
      S.expectOK(() => S.docs().setSchema(defs));
      return;

    case 'SCHEMA':
      final tn = <FieldType, String>{
        FieldType.any: 'any',
        FieldType.boolean: 'bool',
        FieldType.integer: 'int',
        FieldType.float: 'float',
        FieldType.text: 'text',
        FieldType.bytes: 'bytes',
        FieldType.vector: 'vector',
        FieldType.array: 'array',
        FieldType.map: 'map',
      };
      final defs = S.docs().schema();
      S.check(defs != null, 'a schema must be declared first');
      final parts = <String>[];
      for (final f in defs!) {
        parts.add(
          '${f.name}/${tn[f.type]}/${f.required ? 1 : 0}/${f.unique ? 1 : 0}',
        );
      }
      final got = parts.join(',');
      S.check(expected == got, 'schema $got, want "$expected"');
      return;

    case 'SCHEMA9':
      final names = [
        'f_any',
        'f_bool',
        'f_int',
        'f_float',
        'f_text',
        'f_bytes',
        'f_vector',
        'f_array',
        'f_map',
      ];
      final types = [
        FieldType.any,
        FieldType.boolean,
        FieldType.integer,
        FieldType.float,
        FieldType.text,
        FieldType.bytes,
        FieldType.vector,
        FieldType.array,
        FieldType.map,
      ];
      final defs = <FieldDef>[];
      for (var i = 0; i < 9; i++) {
        defs.add(
          FieldDef(names[i], types[i], required: i == 1, unique: i == 8),
        );
      }
      S.expectOK(() => S.docs().setSchema(defs));
      final got = S.docs().schema();
      S.check(got != null, 'the 9-field schema must be declared');
      final tags = <String>[];
      for (var i = 0; i < got!.length; i++) {
        S.check(
          i < 9 && got[i].type == types[i] && got[i].name == names[i],
          'field $i did not round-trip',
        );
        tags.add('${got[i].type.value}');
      }
      S.check(got.length == 9, 'expected exactly 9 fields, saw ${got.length}');
      final joined = tags.join(',');
      S.check(expected == joined, 'schema9 $joined, want "$expected"');
      return;

    case 'SCHEMA_ERR':
      S.expectErr(
        () => S.docs().insert(kb(a[0]), lit(S, a[1])),
        errToken(S, expected),
      );
      return;

    case 'IDX_SCALAR':
      S.expectOK(() => S.docs().createScalarIndex(a[0]));
      return;

    case 'IDX_COMPOUND':
      S.expectOK(() => S.docs().createCompoundIndex(splitTop(args)));
      return;

    case 'IDX_TEXT':
      S.expectOK(() => S.docs().createTextIndex(a[0]));
      return;

    case 'IDX_TEXT_DISK':
      S.expectOK(() => S.docs().createTextIndexOnDisk(a[0]));
      return;

    case 'IDX_GEO':
      S.expectOK(() => S.docs().createGeoIndex(a[0]));
      return;

    case 'IDX_VEC':
      S.expectOK(() => S.docs().createVectorIndex(a[0], parseMetric(S, a[1])));
      return;

    case 'IDX_VEC_Q':
      S.expectOK(
        () => S.docs().createVectorIndexQuantized(
          a[0],
          parseMetric(S, a[1]),
          parseQuant(S, a[2]),
        ),
      );
      return;

    case 'IDX_VEC_DISK':
      S.expectOK(
        () => S.docs().createVectorIndexOnDisk(a[0], parseMetric(S, a[1])),
      );
      return;

    case 'IDX_VEC_DISK_Q':
      S.expectOK(
        () => S.docs().createVectorIndexOnDiskQuantized(
          a[0],
          parseMetric(S, a[1]),
          parseQuant(S, a[2]),
        ),
      );
      return;

    case 'IDX_PQ':
    case 'IDX_PQ_DISK':
    case 'IDX_PQ_ERR':
      void body() {
        if (op == 'IDX_PQ_DISK') {
          S.docs().createVectorIndexOnDiskPQ(
            a[0],
            parseMetric(S, a[1]),
            parseInt(S, a[2]),
            parseInt(S, a[3]),
          );
        } else {
          S.docs().createVectorIndexPQ(
            a[0],
            parseMetric(S, a[1]),
            parseInt(S, a[2]),
            parseInt(S, a[3]),
          );
        }
      }

      if (op == 'IDX_PQ_ERR') {
        S.expectErr(body, errToken(S, expected));
      } else {
        S.expectOK(body);
      }
      return;
  }

  // ---- admin & persistence ----
  switch (op) {
    case 'FILEDB':
      S.openFile(S.dbPath);
      return;

    case 'FILEDB2':
      S.openFile(S.db2Path);
      return;

    case 'DUMP':
      S.expectOK(() => S.db!.dump(S.dumpPath));
      return;

    case 'LOAD':
      S.expectOK(() => S.db!.load(S.dumpPath));
      return;

    case 'LOAD_RENAMES':
      void body() => S.db!.loadWithRenames(S.dumpPath, {a[0]: a[1]});
      if (expected.startsWith('err:')) {
        S.expectErr(body, errToken(S, expected));
      } else {
        S.expectOK(body);
      }
      return;

    case 'COLLECTIONS':
      late final List<String> names;
      S.expectOK(() {
        names = S.db!.collections();
      });
      checkKeys(S, names, expected);
      return;

    case 'BACKUP':
      S.expectOK(() => S.db!.backup(S.backupPath));
      return;

    case 'BACKUP_DUP':
      S.expectErr(
        () => S.db!.backup(S.backupPath),
        CorvidErrorCode.backupTargetExists,
      );
      return;

    case 'COMPACT_BUSY':
      // compact with the live derived-handle counter (§4.13): the
      // FFI-only CORVID_E_BUSY, read through the error-reporting pair.
      final st = native.corvid_compact(
        internal_db.dbHandleOf(S.db!),
        ffi.nullptr.cast(),
      );
      S.check(st != 0, 'expected CORVID_ERR from busy compact');
      final e = internal.CorvidException.lastError();
      S.check(
        e.code == CorvidErrorCode.busy,
        'expected busy (19), got ${e.code.value}',
      );
      S.check(e.message.isNotEmpty, 'busy error recorded without a message');
      return;

    case 'COMPACT':
      S.closeColl(); // quiesce: the derived-handle gate (§4.13)
      S.expectOK(S.db!.compact); // moved_out folded into the API's bool
      S.docs(); // re-acquire for subsequent lines
      return;

    case 'REOPEN':
      final path = S.dbPath;
      S.closeDB();
      S.db = Db.open(path);
      S.docs();
      return;
  }

  S.fail('unknown OP "$op"');
}

// -------------------------------------------------------------------
// Fixture-file driver
// -------------------------------------------------------------------

/// values.txt runs against no db; every other file starts in-memory
/// (admin/persist switch to file dbs via their OPs).
bool startsWithDB(String path) => path.split('/').last != 'values.txt';

String _readFile(String path) {
  try {
    return File(path).readAsStringSync();
  } catch (e) {
    throw StateError('cannot open fixture $path: $e');
  }
}

void runFixture(String path) {
  final data = _readFile(path);
  final base = path.split('/').last;
  final stem = base.substring(0, base.length - 4);
  final dir = Directory.systemTemp.createTempSync('corvid-golden-');
  addTearDown(() {
    dir.deleteSync(recursive: true);
  });

  final S = Scenario(path, dir.path, stem);
  addTearDown(S.closeDB);
  if (startsWithDB(path)) {
    S.openMemory();
  }

  final lines = data.split('\n');

  // `lines` is counted in an INDEPENDENT pre-scan (the same rule the
  // Rust/C drivers apply), so a dispatch loop that skips a counted
  // line — a stray continue, a swallowed branch — diverges from
  // `executed` below, instead of the two fields silently reading one
  // counter.
  var counted = 0;
  for (final raw in lines) {
    var first = 0;
    while (first < raw.length && (raw[first] == ' ' || raw[first] == '\r')) {
      first++;
    }
    if (first < raw.length && raw[first] != '#') counted++;
  }

  var executed = 0;
  for (final raw in lines) {
    final line = raw.endsWith('\r') ? raw.substring(0, raw.length - 1) : raw;
    if (line.isEmpty || line[0] == '#') continue;
    S.line = executed + 1;
    S.op = line; // refined below; kept whole for the unknown-OP message

    // OP \t ARGS \t EXPECTED
    final parts = line.split('\t');
    final op = parts[0];
    var args = '', expected = '';
    if (parts.length >= 2) args = parts[1];
    if (parts.length >= 3) expected = parts[2];
    S.op = op;
    runLine(S, op, args, expected);
    executed++;
  }

  if (executed != counted) {
    S.fail('dispatched $executed of $counted counted executable lines');
  }
  // ignore: avoid_print
  print('SMOKE $path lines=$counted executed=$executed');
}

void main() {
  if (native.corvid_ffi_version() != 1) {
    fail('FAIL wrong FFI_VERSION ${native.corvid_ffi_version()}');
  }
  for (final name in [
    'values',
    'mutations',
    'queries',
    'schema',
    'geo',
    'graph',
    'admin',
    'persist',
  ]) {
    test(name, () => runFixture('golden/$name.txt'));
  }
}
