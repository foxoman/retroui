## Retro Script (retroui/rscript): the language feature by feature, errors
## with their line and column, closures and scopes, the host's objects and
## functions, the step budget and cancel, JSON, a few classic programs, and
## how fast it runs.

import std/[unittest, strutils, monotimes, times]
import retroui/rscript

proc ev(src: string): string =
  ## The script's last value, as console.log shows it.
  let vm = newVm(proc (s: string) = discard)
  vm.seedRandom(42)
  let v = vm.run(compile(src))
  if v.kind == vkStr: toJson(v) else: inspect(v)

proc outOf(src: string): string =
  ## What the script printed.
  var lines: seq[string]
  let vm = newVm(proc (s: string) = lines.add s)
  discard vm.run(compile(src))
  lines.join("\n")

proc errOf(src: string; vm: Vm = nil): ref ScriptError =
  let v = if vm == nil: newVm(proc (s: string) = discard) else: vm
  try:
    discard v.run(compile(src))
  except ScriptError as e:
    return e
  nil

var stopperStarted: bool

proc stopper(p: pointer) {.thread.} =
  ## (cancels the script running on the other thread once it started)
  let v {.cursor.} = cast[Vm](p)
  while not atomicLoadN(addr stopperStarted, ATOMIC_ACQUIRE): discard
  v.cancel()

proc startStopper(th: var Thread[pointer]; vm: Vm) =
  createThread(th, stopper, cast[pointer](vm))

suite "values and operators":
  test "numbers print as JavaScript prints them":
    check ev("0.1 + 0.2") == "0.30000000000000004"
    check ev("1e21") == "1e+21"
    check ev("1e20") == "100000000000000000000"
    check ev("1.5e-7") == "1.5e-7"
    check ev("0.000001") == "0.000001"
    check ev("-0") == "-0"
    check ev("String(-0) + (-0).toFixed(1) + JSON.stringify(-0)") == "\"00.00\""
    check ev("1/0") == "Infinity"
    check ev("-1/0") == "-Infinity"
    check ev("0/0") == "NaN"
    check ev("123456789012") == "123456789012"
    check ev("0x1F + 0b101 + 0o17 + 1_000") == "1051"
    check ev(".5 + 5.") == "5.5"
    check ev("2 ** 10") == "1024"
    check ev("2 ** 3 ** 2") == "512"
    check ev("7 % 3") == "1"
    check ev("-7 % 3") == "-1"
    check ev("5.5 % 2") == "1.5"
    check ev("String(1 ** Infinity)") == "\"NaN\""
  test "arithmetic, comparison and coercion":
    check ev("1 + '2'") == "\"12\""
    check ev("'3' * '4'") == "12"
    check ev("'10' - 1") == "9"
    check ev("true + 1") == "2"
    check ev("null + 1") == "1"
    check ev("undefined + 1") == "NaN"
    check ev("[1, 2] + [3]") == "\"1,23\""
    check ev("'b' > 'a'") == "true"
    check ev("'10' < '9'") == "true"
    check ev("'10' < 9") == "false"
    check ev("NaN < 1 || NaN >= 1") == "false"
    check ev("1 == '1'") == "true"
    check ev("1 === '1'") == "false"
    check ev("null == undefined") == "true"
    check ev("null === undefined") == "false"
    check ev("null == 0") == "false"
    check ev("NaN == NaN") == "false"
    check ev("[1] == 1") == "true"
    check ev("'a' != 'b'") == "true"
    check ev("let o = {}; o === o") == "true"
    check ev("({}) === ({})") == "false"
  test "bit operators work on 32 bits":
    check ev("5 & 3") == "1"
    check ev("5 | 3") == "7"
    check ev("5 ^ 3") == "6"
    check ev("~5") == "-6"
    check ev("1 << 31") == "-2147483648"
    check ev("-16 >> 2") == "-4"
    check ev("-1 >>> 0") == "4294967295"
    check ev("-16 >>> 28") == "15"
    check ev("4294967296 | 0") == "0"
    check ev("2147483648 | 0") == "-2147483648"
    check ev("1.9 | 0") == "1"
  test "logic, nullish, ternary, typeof, void, comma":
    check ev("0 || 'x'") == "\"x\""
    check ev("1 && 'y'") == "\"y\""
    check ev("0 && f()") == "0"
    check ev("null ?? 'd'") == "\"d\""
    check ev("0 ?? 'd'") == "0"
    check ev("!0") == "true"
    check ev("!!'a'") == "true"
    check ev("3 > 2 ? 'big' : 'small'") == "\"big\""
    check ev("typeof 1 + typeof 'a' + typeof true + typeof undefined + typeof null") ==
      "\"numberstringbooleanundefinedobject\""
    check ev("typeof [] + typeof {} + typeof (x => x) + typeof print") == "\"objectobjectfunctionfunction\""
    check ev("typeof notDeclared") == "\"undefined\""
    check ev("void 5") == "undefined"
    check ev("let a = (1, 2, 3); a") == "3"
    check ev("+'42' + -'1'") == "41"
  test "assignment operators":
    check ev("let a = 5; a += 2; a -= 1; a *= 3; a /= 2; a %= 5; a") == "4"
    check ev("let a = 2; a **= 10; a") == "1024"
    check ev("let a = 6; a &= 3; a |= 8; a ^= 1; a <<= 2; a >>= 1; a") == "22"
    check ev("let a = -8; a >>>= 28; a") == "15"
    check ev("let a = null; a ??= 4; a ??= 5; a") == "4"
    check ev("let a = 0; a ||= 7; a ||= 9; a") == "7"
    check ev("let a = 1; a &&= 3; a") == "3"
    check ev("let o = {n: 1}; o.n += 1; o['n'] *= 10; o.n") == "20"
    check ev("let a = [1, 2]; a[1] **= 3; a") == "[1, 8]"
    check ev("let s = 'a'; s += 'b'; s += 1; s") == "\"ab1\""
  test "increment and decrement":
    check ev("let i = 5; let j = i++; [i, j]") == "[6, 5]"
    check ev("let i = 5; let j = ++i; [i, j]") == "[6, 6]"
    check ev("let i = 5; i--; --i; i") == "3"
    check ev("let o = {n: 1}; o.n++; ++o['n']; o.n") == "3"
    check ev("let a = [1]; a[0]--; a") == "[0]"
    check ev("let s = '5'; s++; s") == "6"
    check ev("var g = 1; function f() { g++ } f(); f(); g") == "3"

suite "strings":
  test "literals, escapes and templates":
    check ev("'it\\'s'") == "\"it's\""
    check ev("\"a\\tb\\n\"") == "\"a\\tb\\n\""
    check ev("'\\x41\\u0042\\u{43}'") == "\"ABC\""
    check ev("'\\uD83D\\uDE00'.length") == "1"
    check ev("let n = 3; `n is ${n}, twice ${n * 2}`") == "\"n is 3, twice 6\""
    check ev("`a${`b${'c'}`}d`") == "\"abcd\""
    check ev("`{${ {a: 1}.a }}`") == "\"{1}\""
    check ev("`line1\nline2`") == "\"line1\\nline2\""
    check ev("`plain`") == "\"plain\""
  test "length and indexes count code points":
    check ev("'héllo'.length") == "5"
    check ev("'😀x'.length") == "2"
    check ev("'héllo'[1]") == "\"é\""
    check ev("'héllo'.charAt(4)") == "\"o\""
    check ev("'é'.charCodeAt(0)") == "233"
    check ev("'😀'.codePointAt(0)") == "128512"
    check ev("'abc'.charCodeAt(5)") == "NaN"
    check ev("String.fromCharCode(72, 105, 233)") == "\"Hié\""
    check ev("'naïve'.slice(2, 4)") == "\"ïv\""
    check ev("'naïve'.indexOf('v')") == "3"
    check ev("[...'aé😀']") == "[\"a\", \"é\", \"😀\"]"
  test "methods":
    check ev("'Hello World'.slice(-5)") == "\"World\""
    check ev("'Hello'.slice(1, -1)") == "\"ell\""
    check ev("'Hello'.substring(4, 1)") == "\"ell\""
    check ev("'Hello'.substr(1, 3)") == "\"ell\""
    check ev("'abcabc'.indexOf('c', 3)") == "5"
    check ev("'abcabc'.lastIndexOf('b')") == "4"
    check ev("'abcabc'.lastIndexOf('b', 3)") == "1"
    check ev("'abc'.indexOf('z')") == "-1"
    check ev("'abc'.includes('bc')") == "true"
    check ev("'abc'.startsWith('ab') && 'abc'.endsWith('bc') && 'abc'.startsWith('c', 2)") == "true"
    check ev("'a,b,,c'.split(',')") == "[\"a\", \"b\", \"\", \"c\"]"
    check ev("'abc'.split('')") == "[\"a\", \"b\", \"c\"]"
    check ev("'a b c'.split(' ', 2)") == "[\"a\", \"b\"]"
    check ev("'abc'.split()") == "[\"abc\"]"
    check ev("'  x  '.trim() + '|' + '  x '.trimStart() + '|' + ' x  '.trimEnd()") == "\"x|x | x\""
    check ev("'Straße'.toUpperCase() + 'ÉCOLE'.toLowerCase()") == "\"STRASSEécole\"" or
      ev("'Straße'.toUpperCase() + 'ÉCOLE'.toLowerCase()") == "\"STRAßEécole\""
    check ev("'a-b-c'.replace('-', '+')") == "\"a+b-c\""
    check ev("'a-b-c'.replaceAll('-', '+')") == "\"a+b+c\""
    check ev("'a-b'.replace('-', (m, i) => `[${m}${i}]`)") == "\"a[-1]b\""
    check ev("'cost'.replace('cost', '$$5 ($&)')") == "\"$5 (cost)\""
    check ev("'5'.padStart(3, '0') + '|' + 'ab'.padEnd(5, 'xy')") == "\"005|abxyx\""
    check ev("'ab'.repeat(3)") == "\"ababab\""
    check ev("'abc'.at(-1)") == "\"c\""
    check ev("'a'.concat('b', 1)") == "\"ab1\""
    check ev("['b', 'a', 'c'].sort((x, y) => x.localeCompare(y))") == "[\"a\", \"b\", \"c\"]"
    check ev("let f = 'abc'.toUpperCase; typeof f") == "\"function\""
  test "string building in a loop":
    check ev("""
      let s = ''
      for (let i = 0; i < 1000; i++) s += String.fromCharCode(97 + i % 26);
      [s.length, s.slice(0, 5), s.slice(-3)]
    """) == "[1000, \"abcde\", \"jkl\"]"
    check ev("let a = 'x'; let b = a; a += 'y'; [a, b]") == "[\"xy\", \"x\"]"

suite "arrays and objects":
  test "literals, access, length, holes":
    check ev("[1, 2, 3][1]") == "2"
    check ev("[1, 2, 3].length") == "3"
    check ev("[1, , 3]") == "[1, undefined, 3]"
    check ev("let a = []; a[3] = 'x'; a") == "[undefined, undefined, undefined, \"x\"]"
    check ev("let a = [1, 2, 3]; a.length = 1; a") == "[1]"
    check ev("[1, 2][5]") == "undefined"
    check ev("let o = {a: 1, 'b c': 2, 3: 'three', ['d' + 1]: 4}; [o.a, o['b c'], o[3], o.d1]") ==
      "[1, 2, \"three\", 4]"
    check ev("let x = 1, y = 2; ({x, y})") == "{x: 1, y: 2}"
    check ev("({a: 1}).b") == "undefined"
    check ev("let o = {b: 1, a: 2}; o.c = 3; Object.keys(o)") == "[\"b\", \"a\", \"c\"]"
    check ev("let o = {a: 1, b: 2}; delete o.a; [o, 'a' in o, 'b' in o]") == "[{b: 2}, false, true]"
    check ev("let o = {}; for (let i = 0; i < 20; i++) o['k' + i] = i; [o.k19, Object.keys(o).length]") ==
      "[19, 20]"
    check ev("let o = {f() { return 7 }}; o.f()") == "7"
    check ev("[1, 2, 3].includes(2) && 1 in [5, 6] && !(2 in [5, 6])") == "true"
  test "spread":
    check ev("[0, ...[1, 2], ...'ab', 3]") == "[0, 1, 2, \"a\", \"b\", 3]"
    check ev("Math.max(...[3, 9, 2])") == "9"
    check ev("function f(a, b, c) { return a + b + c } f(1, ...[2, 3])") == "6"
    check ev("({...{a: 1, b: 2}, b: 3, c: 4})") == "{a: 1, b: 3, c: 4}"
  test "array methods":
    check ev("let a = [1]; [a.push(2, 3), a]") == "[3, [1, 2, 3]]"
    check ev("let a = [1, 2]; [a.pop(), a]") == "[2, [1]]"
    check ev("let a = [1, 2]; [a.shift(), a]") == "[1, [2]]"
    check ev("let a = [3]; [a.unshift(1, 2), a]") == "[3, [1, 2, 3]]"
    check ev("[1, 2, 3, 4].slice(1, -1)") == "[2, 3]"
    check ev("let a = [1, 2, 3, 4, 5]; let r = a.splice(1, 2, 'x', 'y', 'z'); [r, a]") ==
      "[[2, 3], [1, \"x\", \"y\", \"z\", 4, 5]]"
    check ev("let a = [1, 2, 3]; a.splice(-1); a") == "[1, 2]"
    check ev("[1].concat([2, 3], 4, [[5]])") == "[1, 2, 3, 4, [5]]"
    check ev("[1, null, 'a', undefined].join('-')") == "\"1--a-\""
    check ev("[1, 2].join()") == "\"1,2\""
    check ev("[1, 2, 1].indexOf(1, 1) + [1, 2, 1].lastIndexOf(1)") == "4"
    check ev("[NaN].includes(NaN) && [NaN].indexOf(NaN) == -1") == "true"
    check ev("[1, 2, 3].reverse()") == "[3, 2, 1]"
    check ev("[1, 2, 3].map((x, i) => x * i)") == "[0, 2, 6]"
    check ev("[1, 2, 3, 4].filter(x => x % 2 == 0)") == "[2, 4]"
    check ev("[1, 2, 3].reduce((s, x) => s + x)") == "6"
    check ev("[1, 2, 3].reduce((s, x) => s + x, 10)") == "16"
    check ev("['a', 'b', 'c'].reduceRight((s, x) => s + x)") == "\"cba\""
    check ev("let t = 0; [1, 2, 3].forEach(x => { t += x }); t") == "6"
    check ev("[5, 12, 8].find(x => x > 6)") == "12"
    check ev("[5, 12, 8].findIndex(x => x > 6)") == "1"
    check ev("[5, 12, 8].findLast(x => x > 6)") == "8"
    check ev("[5, 12, 8].findLastIndex(x => x > 100)") == "-1"
    check ev("[1, 2].some(x => x > 1) && [1, 2].every(x => x > 0) && ![].some(x => true)") == "true"
    check ev("new Array(3).fill(0)") == "[0, 0, 0]"
    check ev("[1, [2, [3, [4]]]].flat()") == "[1, 2, [3, [4]]]"
    check ev("[1, [2, [3, [4]]]].flat(Infinity)") == "[1, 2, 3, 4]"
    check ev("[1, 2].flatMap(x => [x, x * 10])") == "[1, 10, 2, 20]"
    check ev("[1, 2, 3].at(-1)") == "3"
    check ev("Array.isArray([]) && !Array.isArray({})") == "true"
    check ev("Array.from('abc')") == "[\"a\", \"b\", \"c\"]"
    check ev("Array.from({length: 3}, (_, i) => i * i)") == "[0, 1, 4]"
    check ev("Array.of(7, 8)") == "[7, 8]"
    check ev("String([1, [2, 3]])") == "\"1,2,3\""
    check ev("[3, 1, 2].toString()") == "\"3,1,2\""
  test "sort: default order, comparators, stability, undefined last":
    check ev("[10, 9, 1, 100].sort()") == "[1, 10, 100, 9]"
    check ev("[10, 9, 1, 100].sort((a, b) => a - b)") == "[1, 9, 10, 100]"
    check ev("[3, undefined, 1].sort()") == "[1, 3, undefined]"
    check ev("""
      const people = [
        {n: 'ann', age: 30}, {n: 'bob', age: 25}, {n: 'cat', age: 30},
        {n: 'dan', age: 25}, {n: 'eve', age: 30}, {n: 'fay', age: 25}]
      people.sort((a, b) => a.age - b.age).map(p => p.n).join(' ')
    """) == "\"bob dan fay ann cat eve\""
    check ev("let a = []; for (let i = 0; i < 500; i++) a.push({k: i % 3, i}); " &
             "a.sort((x, y) => x.k - y.k); a.every((x, j) => j == 0 || a[j-1].k < x.k || a[j-1].i < x.i)") == "true"
  test "Object functions":
    check ev("Object.keys({a: 1, b: 2})") == "[\"a\", \"b\"]"
    check ev("Object.values({a: 1, b: 2})") == "[1, 2]"
    check ev("Object.entries({a: 1})") == "[[\"a\", 1]]"
    check ev("Object.keys([4, 5])") == "[\"0\", \"1\"]"
    check ev("Object.assign({a: 1}, {b: 2}, {a: 3})") == "{a: 3, b: 2}"
    check ev("Object.fromEntries([['x', 1], ['y', 2]])") == "{x: 1, y: 2}"
    check ev("({a: 1}).hasOwnProperty('a') && !({a: 1}).hasOwnProperty('b')") == "true"
    check ev("String({})") == "\"[object Object]\""

suite "functions and scope":
  test "declarations, defaults, rest, arrows, recursion":
    check ev("function add(a, b = 2) { return a + b } [add(1), add(1, 5)]") == "[3, 6]"
    check ev("function f(a, b = a * 2) { return b } f(4)") == "8"
    check ev("function f(first, ...rest) { return [first, rest] } f(1, 2, 3)") == "[1, [2, 3]]"
    check ev("function f(...all) { return all.length } f()") == "0"
    check ev("const sq = x => x * x; sq(7)") == "49"
    check ev("const f = (a, b) => { return a - b }; f(5, 3)") == "2"
    check ev("const mk = () => ({v: 1}); mk().v") == "1"
    check ev("function fact(n) { return n <= 1 ? 1 : n * fact(n - 1) } fact(10)") == "3628800"
    check ev("hoisted(); function hoisted() { return 'ok' } hoisted()") == "\"ok\""
    check ev("function f() { return } f()") == "undefined"
    check ev("function f(a, b) { return b } f(1)") == "undefined"
    check ev("(function (x) { return x + 1 })(1)") == "2"
    check ev("const fib = function f(n) { return n < 2 ? n : f(n - 1) + f(n - 2) }; fib(10)") == "55"
    check ev("function f(a, b) {} [f.length, f.name]") == "[2, \"f\"]"
    check ev("const g = () => 1; g.name") == "\"g\""
    check ev("function f() { return arguments.length + ':' + [...arguments].join() } f(1, 'a', 3)") == "\"3:1,a,3\""
    check ev("function f(a) { return () => arguments[1] } f(1, 2)()") == "2"
    check ev("function add(a, b) { return this.base + a + b } add.call({base: 10}, 1, 2)") == "13"
    check ev("function add(a, b) { return this.base + a + b } add.apply({base: 20}, [1, 2])") == "23"
    check ev("function add(a, b) { return this.base + a + b } const b = add.bind({base: 5}, 100); [b(1), b.name]") == "[106, \"bound add\"]"
    check ev("Math.max.apply(null, [4, 9, 2])") == "9"
    check ev("typeof (x => x).call") == "\"function\""
  test "destructuring":
    check ev("let [a, b = 5, ...c] = [1, undefined, 3, 4]; [a, b, c]") == "[1, 5, [3, 4]]"
    check ev("let {x, y: why = 2, ...rest} = {x: 1, z: 3, w: 4}; [x, why, rest]") == "[1, 2, {z: 3, w: 4}]"
    check ev("let {a: {b}} = {a: {b: 9}}; b") == "9"
    check ev("let a = 1, b = 2; [a, b] = [b, a]; [a, b]") == "[2, 1]"
    check ev("let o = {}; ({p: o.q} = {p: 5}); o") == "{q: 5}"
    check ev("function f({w = 1, h = 2} = {}) { return w * h } [f(), f({w: 5})]") == "[2, 10]"
    check ev("const [p, , q] = 'xyz'; p + q") == "\"xz\""
    check ev("let s = 0; for (const [k, v] of Object.entries({a: 1, b: 2})) s += v; s") == "3"
  test "closures keep their variables":
    check ev("""
      function counter() { let n = 0; return () => ++n }
      const c1 = counter(), c2 = counter()
      c1(); c1(); c2();
      [c1(), c2()]
    """) == "[3, 2]"
    check ev("""
      function make() {
        let x = 1
        const get = () => x
        const set = v => { x = v }
        return {get, set}
      }
      const o = make(); o.set(42); o.get()
    """) == "42"
    check ev("""
      const adders = []
      for (let i = 0; i < 3; i++) adders.push(n => n + i)
      adders.map(f => f(10))
    """) == "[10, 11, 12]"
    check ev("""
      const fs = []
      for (var i = 0; i < 3; i++) fs.push(() => i)
      fs.map(f => f())
    """) == "[3, 3, 3]"
    check ev("""
      const fs = []
      for (const x of [1, 2, 3]) fs.push(() => x * 10)
      for (let k in {a: 1, b: 2}) fs.push(() => k)
      fs.map(f => f())
    """) == "[10, 20, 30, \"a\", \"b\"]"
    check ev("""
      const fs = []
      let i = 0
      while (i < 3) { let j = i; fs.push(() => j); i++ }
      fs.map(f => f())
    """) == "[0, 1, 2]"
    check ev("""
      const fs = []
      for (let i = 0; i < 3; i++) { fs.push(() => i); i++ }
      fs.map(f => f())
    """) == "[1, 3]"
    check ev("""
      function outer() {
        let a = 1
        function mid() { let b = 2; return () => a + b + c }
        let c = 3
        return mid()
      }
      outer()()
    """) == "6"
    check ev("""
      let x = 'global'
      function f() { return x }
      function g() { let x = 'local'; return f() }
      g()
    """) == "\"global\""
  test "block scope and shadowing":
    check ev("let x = 1; { let x = 2 } x") == "1"
    check ev("let x = 1; { x = 2 } x") == "2"
    check ev("var v = 1; { var v = 2 } v") == "2"
    check ev("function f() { if (true) { var v = 5 } return v } f()") == "5"
    check ev("let x = 1; function f() { let x = 2; { let x = 3 } return x } [f(), x]") == "[2, 1]"
  test "this in methods and constructors":
    check ev("const o = {n: 2, twice() { return this.n * 2 }}; o.twice()") == "4"
    check ev("const o = {n: 1, inc() { this.n++; return this }}; o.inc().inc().n") == "3"
    check ev("const o = {n: 5, f() { return [1, 2].map(x => x * this.n) }}; o.f()") == "[5, 10]"
    check ev("function P(x) { this.x = x; this.get = () => this.x } const p = new P(3); [p.x, p.get()]") == "[3, 3]"
    check ev("function P() {} const p = new P(); p instanceof P") == "true"
    check ev("function f() { return this } f()") == "undefined"
  test "globals made by assignment, and seen by later runs":
    let vm = newVm()
    discard vm.run(compile("let total = 10; function bump(n) { total += n; return total }"))
    check vm.run(compile("bump(5)")).toNum == 15
    check vm.getGlobal("total").toNum == 15
    discard vm.run(compile("made = 'yes'"))
    check vm.getGlobal("made").toStr == "yes"

suite "control flow":
  test "if, while, do-while, for":
    check ev("let r; if (0) r = 'a'; else if (1) r = 'b'; else r = 'c'; r") == "\"b\""
    check ev("let i = 0, s = 0; while (i < 5) s += i++; s") == "10"
    check ev("let i = 10; do { i++ } while (i < 5); i") == "11"
    check ev("let s = 0; for (let i = 0, j = 10; i < j; i++, j--) s++; s") == "5"
    check ev("let n = 0; for (;;) { if (++n > 3) break } n") == "4"
  test "for-of and for-in":
    check ev("let s = ''; for (const ch of 'héllo') s = ch + s; s") == "\"olléh\""
    check ev("let r = []; for (const k in {a: 1, b: 2}) r.push(k); r") == "[\"a\", \"b\"]"
    check ev("let r = []; for (const i in ['x', 'y']) r.push(i); r") == "[\"0\", \"1\"]"
    check ev("let r = []; let k; for (k of [1, 2]) r.push(k); [r, k]") == "[[1, 2], 2]"
    check ev("let a = [1]; let n = 0; for (const x of a) { if (a.length < 5) a.push(x + 1); n++ } n") == "5"
  test "break, continue and labels":
    check ev("let s = 0; for (let i = 0; i < 10; i++) { if (i % 2) continue; if (i > 6) break; s += i } s") == "12"
    check ev("""
      let found = null
      outer: for (let i = 0; i < 5; i++) {
        for (let j = 0; j < 5; j++) {
          if (i * j == 6) { found = [i, j]; break outer }
        }
      }
      found
    """) == "[2, 3]"
    check ev("""
      let n = 0
      rows: for (let i = 0; i < 3; i++) {
        for (let j = 0; j < 3; j++) { if (j == 1) continue rows; n++ }
      }
      n
    """) == "3"
    check ev("let r = 0; blk: { r = 1; break blk; r = 2 } r") == "1"
    check ev("let i = 0; do { i++; if (i < 3) continue; break } while (true); i") == "3"
  test "switch":
    let src = """
      function name(n) {
        switch (n) {
          case 1: return 'one'
          case 2:
          case 3: return 'few'
          default: return 'many'
          case '1': return 'string one'
        }
      }
      [name(1), name(2), name(3), name(9), name('1')]
    """
    check ev(src) == "[\"one\", \"few\", \"few\", \"many\", \"string one\"]"
    check ev("let r = []; switch (2) { case 1: r.push(1); case 2: r.push(2); case 3: r.push(3); break; case 4: r.push(4) } r") ==
      "[2, 3]"
    check ev("let r = 0; for (let i = 0; i < 3; i++) { switch (i) { case 1: continue } r++ } r") == "2"
  test "try, catch, finally, throw":
    check ev("try { throw new Error('boom') } catch (e) { e.message }") == "\"boom\""
    check ev("try { null.x } catch (e) { e instanceof TypeError && e.name }") == "\"TypeError\""
    check ev("try { throw 42 } catch (e) { e + 1 }") == "43"
    check ev("try { throw {code: 7} } catch ({code}) { code }") == "7"
    check ev("let r = []; try { r.push(1) } finally { r.push(2) } r") == "[1, 2]"
    check ev("function f() { try { return 'try' } finally { log.push('fin') } } var log = []; [f(), log]") ==
      "[\"try\", [\"fin\"]]"
    check ev("function f() { try { throw 1 } finally { return 'fin wins' } } f()") == "\"fin wins\""
    check ev("let r = []; try { try { throw new Error('in') } finally { r.push('f') } } catch (e) { r.push(e.message) } r") ==
      "[\"f\", \"in\"]"
    check ev("let e2; try { undefinedFn() } catch (e) { e2 = e } [e2.name, e2.message]") ==
      "[\"ReferenceError\", \"undefinedFn is not defined\"]"
    check ev("let n = 0; for (let i = 0; i < 5; i++) { try { if (i % 2) throw i; n += 10 } catch (e) { n += e } } n") == "34"
    check ev("try { throw new RangeError('r') } catch { 'no binding' }") == "\"no binding\""
    check ev("String(new TypeError('bad'))") == "\"TypeError: bad\""
    check ev("const e = Error('plain'); [e.name, e.message, e instanceof Error]") == "[\"Error\", \"plain\", true]"
    check ev("function f(n) { if (n == 0) throw new Error('deep'); return f(n - 1) } try { f(50) } catch (e) { e.message }") ==
      "\"deep\""
  test "optional chaining":
    check ev("const o = {a: {b: 1}}; [o?.a?.b, o.x?.b, o.x?.b.c.d, o.a?.['b']]") == "[1, undefined, undefined, 1]"
    check ev("const o = {f() { return 3 }}; [o.f?.(), o.g?.(), o.g?.().x]") == "[3, undefined, undefined]"
    check ev("let n = null; n?.x ?? 'dflt'") == "\"dflt\""
    check ev("let calls = 0; const o = null; o?.f(calls++); calls") == "0"

suite "built-ins":
  test "Math":
    check ev("[Math.abs(-2), Math.floor(1.7), Math.ceil(1.2), Math.round(2.5), Math.round(-2.5), Math.round(0.49999999999999994)]") ==
      "[2, 1, 2, 3, -2, 0]"
    check ev("[Math.min(3, 1, 2), Math.max(), Math.min(), Math.max(1, NaN)]") == "[1, -Infinity, Infinity, NaN]"
    check ev("[Math.pow(2, 8), Math.sqrt(81), Math.sign(-3), Math.trunc(-4.7), Math.hypot(3, 4)]") == "[256, 9, -1, -4, 5]"
    check ev("Math.abs(Math.sin(Math.PI)) < 1e-15 && Math.cos(0) == 1 && Math.tan(0) == 0") == "true"
    check ev("[Math.atan2(1, 1) * 4 == Math.PI, Math.log(Math.E), Math.exp(0), Math.E > 2.718]") == "[true, 1, 1, true]"
    check ev("let ok = true; for (let i = 0; i < 1000; i++) { const r = Math.random(); if (r < 0 || r >= 1) ok = false } ok") == "true"
    let a = newVm()
    let b = newVm()
    a.seedRandom(7)
    b.seedRandom(7)
    let s = compile("[Math.random(), Math.random()]")
    check inspect(a.run(s)) == inspect(b.run(s))
  test "Number, parseInt, parseFloat, isNaN, toFixed, toPrecision, toString":
    check ev("[parseInt('42px'), parseInt('ff', 16), parseInt('0x1A'), parseInt('-12.9'), parseInt('abc')]") ==
      "[42, 255, 26, -12, NaN]"
    check ev("[parseFloat('3.14abc'), parseFloat('.5'), parseFloat('-1e3x'), parseFloat('x')]") == "[3.14, 0.5, -1000, NaN]"
    check ev("[Number('12'), Number(''), Number(' 7 '), Number('1e3'), Number('0x10'), Number('12px'), Number(null), Number(true)]") ==
      "[12, 0, 7, 1000, 16, NaN, 0, 1]"
    check ev("[isNaN('abc'), isNaN('12'), Number.isNaN('abc'), isFinite('5'), Number.isInteger(5.0), Number.isInteger(5.5)]") ==
      "[true, false, false, true, true, false]"
    check ev("[(1.005).toFixed(2), (3.14159).toFixed(2), (2.5).toFixed(0), (-0).toFixed(1), (1e21).toFixed(2), (12).toFixed()]") ==
      "[\"1.00\", \"3.14\", \"3\", \"0.0\", \"1e+21\", \"12\"]"
    check ev("[(123.456).toPrecision(4), (0.000123).toPrecision(2), (123456).toPrecision(2), (1.5).toPrecision()]") ==
      "[\"123.5\", \"0.00012\", \"1.2e+5\", \"1.5\"]"
    check ev("[(2.5).toPrecision(1), (9.99).toPrecision(2), (0).toPrecision(3), (-1.25).toFixed(1), (0.5).toFixed(0), (1e-10).toFixed(3)]") ==
      "[\"3\", \"10\", \"0.00\", \"-1.3\", \"1\", \"0.000\"]"
    check ev("[(1234.5678).toFixed(2), (0.1).toFixed(20), (5e-324).toFixed(2), (1.45).toFixed(1)]") ==
      "[\"1234.57\", \"0.10000000000000000555\", \"0.00\", \"1.4\"]"
    check ev("[(255).toString(16), (255).toString(2), (-10).toString(36), (0.5).toString(2), (17).toString()]") ==
      "[\"ff\", \"11111111\", \"-a\", \"0.1\", \"17\"]"
    check ev("[Number.MAX_SAFE_INTEGER, Number.EPSILON > 0, String(true), Boolean(''), Boolean('x')]") ==
      "[9007199254740991, true, \"true\", false, true]"
  test "JSON":
    check ev("JSON.stringify({a: 1, b: [true, null, 'x'], c: {d: 1.5}})") ==
      "\"{\\\"a\\\":1,\\\"b\\\":[true,null,\\\"x\\\"],\\\"c\\\":{\\\"d\\\":1.5}}\""
    check outOf("print(JSON.stringify({a: [1, {b: 2}], e: []}, null, 2))") ==
      "{\n  \"a\": [\n    1,\n    {\n      \"b\": 2\n    }\n  ],\n  \"e\": []\n}"
    check outOf("print(JSON.stringify({u: undefined, f() {}, n: NaN, s: 'q\"\\n\\u0001'}))") ==
      "{\"n\":null,\"s\":\"q\\\"\\n\\u0001\"}"
    check outOf("print(JSON.stringify([undefined, () => 1]), JSON.stringify(undefined), JSON.stringify('é'))") ==
      "[null,null] undefined \"é\""
    check ev("JSON.parse('{\"a\": [1, 2.5e1, -0.5], \"b\": {\"c\": null}, \"d\": \"\\\\u00e9\\\\n\"}')") ==
      "{a: [1, 25, -0.5], b: {c: null}, d: \"é\\n\"}"
    check ev("""
      const data = {name: 'Layer 1', opacity: 75, visible: true, tags: ['a', 'b'], pos: {x: -3.25, y: 1e-7}, none: null}
      JSON.stringify(JSON.parse(JSON.stringify(data))) === JSON.stringify(data)
    """) == "true"
    check ev("try { JSON.parse('{\"a\": }') } catch (e) { e.name + ': ' + e.message }") ==
      "\"SyntaxError: Unexpected token } in JSON at position 6\""
    check ev("try { JSON.parse('[1, 2') } catch (e) { e.message }") == "\"Unexpected end of JSON input\""
    check ev("const o = {}; o.self = o; try { JSON.stringify(o) } catch (e) { e.message }") ==
      "\"Converting circular structure to JSON\""
    check toJson(parseJson("""{"k": [1, "two", false]}""")) == """{"k":[1,"two",false]}"""
  test "print and console.log":
    check outOf("print('a', 1, [1, 'b'], {x: {y: 2}}, null, undefined, true)") ==
      "a 1 [1, \"b\"] {x: {y: 2}} null undefined true"
    check outOf("console.log('x'); console.warn('y'); console.error(new Error('z'))") == "x\ny\nError: z"
    check outOf("const o = {a: 1}; o.me = o; console.log(o)") == "{a: 1, me: [Circular]}"
    check outOf("print(x => x, function named() {})") == "[Function (anonymous)] [Function: named]"
  test "Date.now":
    check ev("typeof Date.now() == 'number' && Date.now() > 1.6e12") == "true"

suite "errors carry their place":
  test "syntax errors":
    let e = errOf("let a = 1;\nlet b = (2 + ;\n")
    check e != nil
    check e.line == 2
    check e.column == 14
    check "SyntaxError" in e.msg
    check e.msg.startsWith("script:2:14:")
    let e2 = errOf("let x = 'unterminated\nfoo")
    check e2.line == 1
    check "Unterminated string" in e2.msg
    let e3 = errOf("const k = 1\nk = 2")
    check e3.line == 2
    check e3.column == 1
    check "constant" in e3.msg
    check errOf("let q = 1; let q = 2").msg.contains("already been declared")
    check errOf("x = /ab+c/.test(s)").msg.contains("Regular expressions are not supported")
    check errOf("class A {}").msg.contains("Classes are not supported")
    check errOf("break").msg.contains("Illegal break")
    check errOf("if (true) let z = 1").msg.contains("needs braces")
    check errOf("while (false) function g() {}").msg.contains("needs braces")
    check errOf("x: const y = 1").msg.contains("needs braces")
    check errOf("blk: { for (;;) { continue blk } }").msg.contains("does not denote a loop")
    check errOf("for (;;) { break nowhere }").msg.contains("Undefined label")
    check errOf("`abc ${1 + }`").line == 1
    check errOf("foo(1, 2").msg.contains("end of input")
    check errOf("let s = 'é'; let t = s +* 2").column == 25
    var deep = ""
    for i in 0 ..< 400: deep.add '('
    check errOf(deep & "1" & ")".repeat(400)).msg.contains("nested too deeply")
    var long = "let v = 1"
    for i in 0 ..< 5000: long.add " + 1"
    check errOf(long).msg.contains("nested too deeply")
  test "runtime errors point at the failing spot":
    let e = errOf("let o = {}\nlet v = o.missing.deeper")
    check e.line == 2
    check e.column == 19
    check e.message == "TypeError: Cannot read properties of undefined (reading 'deeper')"
    let e2 = errOf("const o = {}\n\n   o.nothing(1)")
    check e2.line == 3
    check e2.column == 6
    check "o.nothing is not a function" in e2.msg
    let e3 = errOf("print(1)\nnotThere + 1")
    check e3.line == 2
    check e3.column == 1
    check e3.message == "ReferenceError: notThere is not defined"
    let e4 = errOf("function inner() {\n  throw new Error('bad thing')\n}\nfunction outer() { inner() }\nouter()")
    check e4.line == 2
    check e4.column == 9
    check e4.message == "Error: bad thing"
    check e4.stack.len == 3
    check e4.stack[0] == "at inner (script:2:9)"
    check e4.stack[1] == "at outer (script:4:20)"
    check e4.stack[2] == "at <main> (script:5:1)"
    let e5 = errOf("throw 'plain'")
    check e5.message == "Uncaught plain"
    check e5.value.toStr == "plain"
    let e6 = errOf("null.x = 1")
    check "Cannot set properties of null" in e6.msg
    let e7 = errOf("[].reduce((a, b) => a)")
    check "Reduce of empty array" in e7.msg
    let e8 = errOf("'x'.repeat(-1)")
    check "RangeError" in e8.msg
    let e9 = errOf("let a = 1; a()")
    check e9.message == "TypeError: a is not a function"
    check errOf("new (x => x)()").msg.contains("is not a constructor")
    check errOf("for (const x of 5) {}").msg.contains("is not iterable")
    check errOf("let {a} = null").msg.contains("Cannot destructure")
    let named = newVm()
    try:
      discard named.run(compile("\n\nboom()", "layers.js"))
      check false
    except ScriptError as e:
      check e.file == "layers.js"
      check e.msg.startsWith("layers.js:3:1:")

suite "the host":
  test "functions and objects round trip":
    let vm = newVm()
    var seen: seq[string]
    vm.defineFn("record", proc (args: seq[Value]): Value =
      for a in args: seen.add inspect(a)
      toValue(args.len))
    vm.defineFn("makeList", proc (args: seq[Value]): Value =
      var items: seq[Value]
      for i in 0 ..< args[0].toInt: items.add toValue(i * 10)
      toValue(items))
    vm.defineObject("app", {"name": toValue("Retro Photo"), "version": toValue(2.5),
      "info": toValue(proc (args: seq[Value]): Value =
        toValue({"w": toValue(640), "h": toValue(480), "tags": toValue(@[toValue("a"), toValue(true)])}))})
    let r = vm.run(compile("""
      record(1, 'two', [3], {four: 4}, null)
      const i = app.info()
      const l = makeList(3);
      ({n: app.name, v: app.version, area: i.w * i.h, tags: i.tags, l, count: record()})
    """))
    check seen == @["1", "two", "[3]", "{four: 4}", "null"]
    check r["n"].toStr == "Retro Photo"
    check r["area"].toNum == 307200
    check r["tags"].len == 2
    check r["tags"][1].toBool
    check r["l"].len == 3
    check r["l"][2].toNum == 20
    check r["count"].toNum == 0
    var keys: seq[string]
    for k in r.keys: keys.add k
    check keys == @["n", "v", "area", "tags", "l", "count"]
    var total = 0.0
    for x in r["l"]: total += x.toNum
    check total == 30
    for k, v in r:
      if k == "v": check v.toNum == 2.5
  test "live host objects: get, set, call, data":
    type Layer = ref object of RootObj
      name: string
      opacity: float
      fills: int
    proc layerValue(L: Layer): Value =
      hostObject(
        get = proc (key: string): Value =
          case key
          of "name": toValue(L.name)
          of "opacity": toValue(L.opacity)
          else: undefinedValue(),
        set = proc (key: string; v: Value): bool =
          case key
          of "opacity":
            if v.toNum < 0 or v.toNum > 100: raise newException(ValueError, "opacity must be 0 to 100")
            L.opacity = v.toNum
            true
          of "name":
            L.name = v.toStr
            true
          else: false,
        call = proc (key: string; args: seq[Value]): Value =
          case key
          of "fill":
            inc L.fills
            toValue(L.fills)
          else: raise newException(ValueError, "no method " & key),
        data = L)
    let a = Layer(name: "Sky", opacity: 100)
    let b = Layer(name: "Sea", opacity: 50)
    let vm = newVm()
    let la = layerValue(a)
    let lb = layerValue(b)
    var merged: seq[string]
    vm.defineObject("doc", {"layers": toValue(@[la, lb]), "width": toValue(800),
      "merge": toValue(proc (args: seq[Value]): Value =
        for v in args:
          let L = Layer(hostData(v))
          merged.add L.name
        undefinedValue())})
    let r = vm.run(compile("""
      const [sky, sea] = doc.layers
      sky.opacity = sky.opacity / 2
      sea.opacity += 10
      sky.name = sky.name.toUpperCase()
      sky.fill(); const fills = sky.fill()
      let caught = ''
      try { sea.opacity = 500 } catch (e) { caught = e.message }
      let caught2 = ''
      try { sea.explode() } catch (e) { caught2 = e.message }
      let caught3 = ''
      try { sea.width = 3 } catch (e) { caught3 = e.name }
      doc.merge(sky, sea);
      ({fills, caught, caught2, caught3, same: doc.layers[0] === sky, missing: sky.nothing})
    """))
    check a.opacity == 50
    check b.opacity == 60
    check a.name == "SKY"
    check a.fills == 2
    check r["fills"].toNum == 2
    check r["caught"].toStr == "opacity must be 0 to 100"
    check r["caught2"].toStr == "no method explode"
    check r["caught3"].toStr == "TypeError"
    check r["same"].toBool
    check r["missing"].kind == vkUndefined
    check merged == @["SKY", "Sea"]
  test "the host calls back into the script":
    let vm = newVm()
    var cb: Value
    vm.defineFn("onClick", proc (args: seq[Value]): Value =
      cb = args[0]
      undefinedValue())
    vm.defineFn("each", proc (args: seq[Value]): Value =
      var r: seq[Value]
      for i in 0 ..< 3: r.add vm.call(args[0], @[toValue(i)])
      toValue(r))
    let r = vm.run(compile("""
      let clicks = 0
      onClick((n) => { clicks += n; return clicks })
      function double(x) { return x * 2 }
      each(i => double(i) + 1)
    """))
    check inspect(r) == "[1, 3, 5]"
    check vm.call(cb, @[toValue(5)]).toNum == 5
    check vm.call(cb, @[toValue(2)]).toNum == 7
    check vm.call(vm.getGlobal("double"), @[toValue(21)]).toNum == 42
    try:
      discard vm.call(toValue(3), @[])
      check false
    except ScriptError as e:
      check "is not a function" in e.msg
    vm.setGlobal("limit", toValue(9))
    check vm.run(compile("limit * 2")).toNum == 18
  test "a script error inside a callback reaches the host":
    let vm = newVm()
    discard vm.run(compile("function bad() { return nope.x }"))
    try:
      discard vm.call(vm.getGlobal("bad"), @[])
      check false
    except ScriptError as e:
      check e.message == "ReferenceError: nope is not defined"
      check e.line == 1
    check vm.run(compile("1 + 1")).toNum == 2

  test "the module's own example":
    var printed: seq[string]
    let vm = newVm(proc (s: string) = printed.add s)
    vm.defineFn("alert", proc (args: seq[Value]): Value =
      printed.add "ALERT " & args[0].toStr
      undefinedValue())
    var opacity = 100.0
    var fills = 0
    let layer = hostObject(
      get = proc (key: string): Value =
        if key == "opacity": toValue(opacity) else: undefinedValue(),
      set = proc (key: string; v: Value): bool =
        result = key == "opacity"
        if result: opacity = v.toNum,
      call = proc (key: string; args: seq[Value]): Value =
        if key == "fill": inc fills
        undefinedValue())
    vm.defineObject("app", {"activeLayer": layer, "name": toValue("Retro Photo")})
    discard vm.run(compile("""
      const l = app.activeLayer
      l.opacity = l.opacity / 2
      l.fill()
      console.log(`${app.name}: opacity ${l.opacity}`)
      alert('done')
    """))
    check opacity == 50
    check fills == 1
    check printed == @["Retro Photo: opacity 50", "ALERT done"]

suite "limits":
  test "the step budget stops a loop, and the script can't catch it":
    let vm = newVm()
    let e = errOf("let i = 0; while (true) { i++ }", vm)
    check e != nil
    check e.fatal
    check "the script ran too long" in e.msg
    let e2 = errOf("while (true) { try { for (;;) {} } catch (e) {} finally { } }", vm)
    check e2.fatal
    try:
      discard vm.run(compile("let n = 0; for (let i = 0; i < 1000; i++) n++"), maxSteps = 500)
      check false
    except ScriptError as e3:
      check "too long" in e3.msg
    check vm.run(compile("let k = 0; for (let i = 0; i < 100; i++) k++; k"), maxSteps = 1000).toNum == 100
    check errOf("const f = () => f(); try { f() } catch (e) { while (true) {} }", vm).fatal
  test "cancel from a host function":
    let vm = newVm()
    var ticks = 0
    vm.defineFn("tick", proc (args: seq[Value]): Value =
      inc ticks
      if ticks == 100: vm.cancel()
      undefinedValue())
    let e = errOf("let n = 0; while (true) { tick(); try { n++ } catch (e) {} }", vm)
    check e.fatal
    check "cancelled" in e.msg
    check ticks == 100
    check vm.run(compile("2 + 2")).toNum == 4
  test "cancel from another thread":
    let vm = newVm()
    vm.defineFn("started", proc (args: seq[Value]): Value =
      atomicStoreN(addr stopperStarted, true, ATOMIC_RELEASE)
      undefinedValue())
    var th: Thread[pointer]
    startStopper(th, vm)
    let e = errOf("started(); let n = 0; for (;;) { n++ }", vm)
    joinThread(th)
    check e != nil and e.fatal
    check "cancelled" in e.msg
  test "recursion depth":
    let vm = newVm()
    let e = errOf("function down(n) { return down(n + 1) } down(0)", vm)
    check not e.fatal
    check "Maximum call stack size exceeded" in e.msg
    check e.stack.len == 11
    let deepest = vm.maxDepth - 1
    check vm.run(compile("function d(n) { return n == 0 ? 0 : 1 + d(n - 1) } d(" & $(deepest - 1) & ")")).toNum ==
      float(deepest - 1)
    check vm.run(compile("let depth = 0; function r() { depth++; r() } try { r() } catch (e) { depth }")).toNum ==
      float(deepest)
    vm.maxNativeStack = 64 * 1024
    check "Maximum call stack" in errOf("function d(n) { return [n].map(x => d(x + 1))[0] } d(0)", vm).msg
  test "string and array sizes":
    let vm = newVm()
    vm.maxStringLen = 1000
    vm.maxArrayLen = 1000
    check "Invalid string length" in errOf("'x'.repeat(2000)", vm).msg
    check "Invalid string length" in errOf("let s = 'x'; while (true) s += s", vm).msg
    check "Invalid array length" in errOf("new Array(5000)", vm).msg
    check "Invalid array length" in errOf("const a = []; a[5000] = 1", vm).msg
    check "Invalid array length" in errOf("const a = []; while (true) a.push(1)", vm).msg
    check vm.run(compile("'ab'.repeat(400).length")).toNum == 800

suite "classic programs":
  test "fib, primes, grouping, word count":
    check ev("function fib(n) { return n < 2 ? n : fib(n - 1) + fib(n - 2) } fib(20)") == "6765"
    check ev("""
      function sieve(n) {
        const isPrime = new Array(n + 1).fill(true)
        isPrime[0] = isPrime[1] = false
        for (let i = 2; i * i <= n; i++)
          if (isPrime[i]) for (let j = i * i; j <= n; j += i) isPrime[j] = false
        return isPrime.reduce((acc, p, i) => p ? [...acc, i] : acc, [])
      }
      const ps = sieve(100);
      [ps.length, ps.slice(-3)]
    """) == "[25, [83, 89, 97]]"
    check ev("""
      const layers = [
        {name: 'bg', kind: 'pixel'}, {name: 'title', kind: 'text'}, {name: 'logo', kind: 'pixel'},
        {name: 'sub', kind: 'text'}, {name: 'fx', kind: 'adjust'}]
      const byKind = {}
      for (const l of layers) (byKind[l.kind] ??= []).push(l.name)
      byKind
    """) == "{pixel: [\"bg\", \"logo\"], text: [\"title\", \"sub\"], adjust: [\"fx\"]}"
    check ev("""
      const text = 'the quick brown fox jumps over the lazy dog the end'
      const counts = text.split(' ').reduce((m, w) => { m[w] = (m[w] || 0) + 1; return m }, {})
      Object.entries(counts).sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0])).slice(0, 3)
    """) == "[[\"the\", 3], [\"brown\", 1], [\"dog\", 1]]"
    check ev("""
      function hanoi(n, from, to, via, moves) {
        if (n == 0) return moves
        hanoi(n - 1, from, via, to, moves)
        moves.push(from + to)
        return hanoi(n - 1, via, to, from, moves)
      }
      const m = hanoi(10, 'A', 'C', 'B', []);
      [m.length, m[0], m[m.length - 1]]
    """) == "[1023, \"AB\", \"BC\"]"
    check ev("""
      const pad = (s, n) => String(s).padStart(n)
      let rows = []
      for (let r = 1; r <= 3; r++) {
        let line = ''
        for (let c = 1; c <= 3; c++) line += pad(r * c, 3)
        rows.push(line)
      }
      rows.join('|')
    """) == "\"  1  2  3|  2  4  6|  3  6  9\""
    check ev("""
      function qsort(a) {
        if (a.length < 2) return a
        const [p, ...rest] = a
        return [...qsort(rest.filter(x => x < p)), p, ...qsort(rest.filter(x => x >= p))]
      }
      qsort([5, 3, 8, 1, 9, 2, 7])
    """) == "[1, 2, 3, 5, 7, 8, 9]"

suite "speed":
  test "fib(25) and a million-step loop":
    let vm = newVm()
    proc best(s: Script; expect: float): float =
      result = Inf
      for _ in 0 ..< 3:   # the best of three: the machine may be busy
        let t0 = getMonoTime()
        check vm.run(s).toNum == expect
        result = min(result, (getMonoTime() - t0).inNanoseconds.float / 1e9)
    let fibTime = best(compile("function fib(n) { return n < 2 ? n : fib(n - 1) + fib(n - 2) } fib(25)"), 75025)
    let loopTime = best(compile("let s = 0; for (let i = 0; i < 1000000; i++) { s += i * 2 % 7 } s"), 2999997)
    let fnLoopTime = best(compile("function f() { let s = 0; for (let i = 0; i < 1000000; i++) " &
                                  "{ s += i * 2 % 7 } return s } f()"), 2999997)
    echo "    fib(25): ", formatFloat(fibTime, ffDecimal, 3), " s;  1e6 loop (globals): ",
      formatFloat(loopTime, ffDecimal, 3), " s;  1e6 loop (locals): ", formatFloat(fnLoopTime, ffDecimal, 3), " s"
    when defined(release):
      check fibTime < 0.3
