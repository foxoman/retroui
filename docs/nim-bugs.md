# Three leaks in Nim 2.2 (ORC), an overflow and a cut letter, ready to report

Retro Nim UI works around the leaks (see `tools/returncheck.py`,
`tools/writecheck.py` and AGENTS.md) and the cut letter (`import std/unicode except strip`, kept by
`tests/test_hardening.nim`), but they belong in Nim itself, as does the
overflow. Each report
below is what goes on https://github.com/nim-lang/Nim/issues: the
program, what it prints, what it should print. They are seen with Nim 2.2.6 (Linux, amd64), `--mm:orc`
(the default), with and without `-d:useMalloc`, in debug and release.

---

## 1. `return x` after `result` was set does not free the old `result`

**Title:** ORC: `return expr` leaks the value already in `result`

A proc that sets `result` and then leaves with `return x` (where `x` is
not `result` itself: `nil`, another value, or a call that takes `result`)
never destroys what `result` held. Strings, seqs and refs alike.

```nim
type R = ref object
  data: seq[int]
var made, freed = 0
proc `=destroy`(x: typeof(R()[])) =
  inc freed
  `=destroy`(x.data)
proc mk(): R =
  inc made
  R(data: newSeq[int](10))
proc same(r: R): R = r
proc a(n: int): R =
  result = mk()
  if n > 0: return nil            # (the R in result is never freed)
proc b(n: int): R =
  result = mk()
  return same(result)             # (nor here)
for i in 0 ..< 10: discard a(1)
echo "return nil after result:    made ", made, ", freed ", freed
made = 0; freed = 0
for i in 0 ..< 10: discard b(1)
echo "return f(result):           made ", made, ", freed ", freed
```

`nim c -r leak1.nim` prints:

```
return nil after result:    made 10, freed 0
return f(result):           made 10, freed 0
```

Expected: `freed 10` both times. The same happens with `result = "..."`
then `return ""`, and with `result = newSeq...` then `return @[]`
(AddressSanitizer reports the old buffers as leaked).

Writing it as `result = nil; return` (or `result = same(result); return`)
frees the old value: the problem is only in how `return x` is lowered
(`result = x` is not treated as an assignment over a live value).

---

## 2. A proc that raises after filling `result` leaks it when the caller assigns into an existing variable

**Title:** ORC: `v = f()` leaks f's partly built result when f raises

When `f` has put something in `result` and then raises, and the call is
`v = f()` (an existing variable, not `let v = f()`), what `f` put in
`result` is never destroyed.

```nim
proc fail() {.noreturn.} = raise newException(ValueError, "x")
proc text(n: int): string =
  result = "abc" & $n & "defghijklmnopqrstuvwxyz"
  if n > 0: fail()
proc filled(n: int): seq[string] =
  for i in 0 ..< 3:
    result.add "item " & $i & " of a list long enough"
    if i == 1 and n > 0: fail()
for round in 0 ..< 10:
  var s = "before"
  try: s = text(1)
  except ValueError: discard
  var q = @["before"]
  try: q = filled(1)
  except ValueError: discard
```

```
nim c -r --cc:clang -d:useMalloc --debugger:native \
  --passC:-fsanitize=address --passL:-fsanitize=address leak2.nim
```

AddressSanitizer:

```
Direct leak of 360 byte(s) in 10 object(s) allocated from:
    #0 malloc
    #1 system::allocImpl  lib/system/mm/malloc.nim:5
    #2 allocSharedImpl    lib/system/mm/malloc.nim:34
    #3 rawNewString       lib/system/strs_v2.nim:39
    #4 leak2::text(int)   leak2.nim:3
    #5 NimMainModule      leak2.nim:11
SUMMARY: AddressSanitizer: ... leaked
```

(and the strings `filled` added, likewise). Expected: nothing leaked.
It does not leak when the result is a `ref` destroyed by its `=destroy`,
nor with `let s = text(1)`.

The kit's workaround: fill a local variable and move it into `result` at
the end (`var r: T; ...; result = move r`), so nothing is in `result` when
an exception leaves the proc.

---

## 3. `parseFloat` (and `parseJson`) overflow a signed integer on a long exponent

**Title:** parseFloat: a long exponent is signed integer overflow (undefined behaviour in C)

```nim
import std/[strutils, json]
echo parseFloat("1e99999999999999999999")
echo parseJson("[1e99999999999999999999]")
```

```
nim c -r --cc:clang -d:release --passC:-fsanitize=undefined --passL:-fsanitize=undefined ub.nim
```

```
@psystem.nim.c: runtime error: signed integer overflow: 999999999999999999 * 10
  cannot be represented in type 'NI' (aka 'long')
inf
[inf]
```

`nimParseBiggestFloat` (lib/system/strmantle.nim) adds up the exponent's
digits in an `int` (`exponent = exponent * 10 + ...`) with no limit; C
compilers may do anything with the overflow (here it happens to give
`inf`). Any JSON from outside (a glTF model, a web service's answer) can
carry such a number. Expected: the exponent stops growing once it is past
what a float can hold (as `strtod` does). libFuzzer found it in a glTF
model (`tests/fuzz/libfuzz.nim`, `-d:fuzzTarget=gltf`).

---

## 4. `unicode.strip` cuts the last letter when its last byte is 0x85 or 0xA0

**Title:** std/unicode: `strip` drops the last byte of a line ending in a
3- or 4-byte letter whose last byte is 0x85 or 0xA0

```nim
import std/unicode
for s in ["ภาษาไทย ภ", "†", "丠", "\u{10F005}"]:
  let t = s.strip
  echo s.len, " -> ", t.len, " valid: ", t.validateUtf8 == -1
```

```
nim c -r strip.nim
```

```
25 -> 24 valid: false
3 -> 2 valid: false
3 -> 2 valid: false
4 -> 3 valid: false
```

The trailing loop (lib/pure/unicode.nim, `strip`) walks back from the
last byte and reads it as a letter of its own: 0x85 and 0xA0 are U+0085
and U+00A0, both in `unicodeSpaces`, so the byte goes. A two-byte letter
(Å, the Arabic meem) is read right; a longer one -- Thai ภ (U+0E20), †
(U+2020), one Chinese character in 32, the private-use letters of icon
fonts -- loses its last byte, and the line is no longer UTF-8. And it is
the `strip` a module that imports `std/[strutils, unicode]` calls: a plain
`s.strip` picks it over strutils'. Expected: each letter kept whole (walk
back over the continuation bytes, 0x80..0xBF, to the letter's first byte
before reading it). Found when the driver's tree of the control gallery
was not UTF-8 (a pixel icon's name, U+10F005, cut).

---

## 5. A `var` given a value in a branch or a loop is not freed when it is given another

**Title:** ORC: a variable declared without a value, set in an `if` or a
loop, leaks that value when it is assigned again

`var x: T` (no value), given one in an `if` without an `else`, a `case`,
a `try`, or filled in a loop (`x.add`), and then assigned again in the
block it was declared in: the second assignment copies over the first
without destroying it. `result` does the same.

```nim
type R = ref object
  data: seq[int]
var made, freed = 0
proc `=destroy`(x: typeof(R()[])) =
  inc freed
  `=destroy`(x.data)
proc mk(): R =
  inc made
  R(data: newSeq[int](10))

proc inBranch(n: int) =
  var x: R
  if n > 0: x = mk()
  x = mk()                        # (the first R is never freed)

proc inLoop(n: int) =
  var xs: seq[R]
  for i in 0 ..< n: xs.add mk()
  xs = @[]                        # (nor the ones the loop added)

proc inResult(n: int): R =
  if n > 0: result = mk()
  result = mk()                   # (nor here)

proc withValue(n: int) =
  var x: R = nil
  if n > 0: x = mk()
  x = mk()                        # (freed: x had a value from the start)

for i in 0 ..< 10: inBranch(1)
echo "var given in an if, then again:  made ", made, ", freed ", freed
made = 0; freed = 0
for i in 0 ..< 10: inLoop(1)
echo "var filled in a loop, then given: made ", made, ", freed ", freed
made = 0; freed = 0
for i in 0 ..< 10: discard inResult(1)
echo "result given in an if, then again: made ", made, ", freed ", freed
made = 0; freed = 0
for i in 0 ..< 10: withValue(1)
echo "the same with var x: R = nil:     made ", made, ", freed ", freed
```

`nim c -r leak5.nim` prints (Nim 2.2.6, and devel d61298c of
2026-11-11):

```
var given in an if, then again:  made 20, freed 10
var filled in a loop, then given: made 10, freed 0
result given in an if, then again: made 20, freed 10
the same with var x: R = nil:     made 20, freed 20
```

Expected: `freed 20`, `freed 10`, `freed 20`, `freed 20`. In the C code
the second assignment is a plain copy (`x = mk()`; for `xs = @[]`,
`xs.len = 0; xs.p = newSeqPayload(...)`) with no `eqdestroy` before it.

The cause looks to be `initVar` in compiler/sempass2.nim: an assignment
to a local that is not in `a.init` gets `nfFirstWrite` (when it is in the
block the local was declared in), and injectdestructors.nim's `genSink`
then turns it into a bitwise copy. But `a.init` holds what is *surely*
initialized, so after `if n > 0: x = mk()` (no `else`) -- or after a loop,
which is taken as maybe never run -- `x` is not in it, and the next
assignment is taken for the first although the first may well have run.
A first write wants "surely not initialized yet" (no path has written
it), not "not surely initialized".

Retro Nim UI had some 70 of these (a chart's area points every frame, the
names a screen reader is given every frame, a picture's dash lists, a
whole picture opened to make a layer); `tools/writecheck.py` lists them,
and each now has its value where it is declared.

---

The first two were found while running Retro Nim UI's tests under
AddressSanitizer (`nimble test` with `-fsanitize=address`, BUILDING.md).
