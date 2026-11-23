## Tests of retroui/signals (values that know what was worked out from them) and retroui/keep
## (values kept across the runs of `retrokit run --watch`).

import std/[os, json, strutils, osproc]
import retroui/[core, signals, keep]

block signalsAndComputed:
  let a = signal(2)
  let b = signal(3)
  let sum = computed(proc (): int = a.value + b.value)
  doAssert sum.value == 5 and sum.runs == 1
  doAssert sum.value == 5 and sum.runs == 1, "read again: not worked out again"
  a.value = 10
  doAssert sum.value == 13 and sum.runs == 2, "a signal it read changed: worked out again"
  a.value = 10
  doAssert sum.value == 13 and sum.runs == 2, "set to the value it had: nothing changed"
  doAssert a.peek == 10
  # a computed value of a computed value; only the branch that ran counts
  let flag = signal(true)
  let other = signal("x")
  let pick = computed(proc (): string = (if flag.value: $sum.value else: other.value))
  let shout = computed(proc (): string = pick.value.toUpperAscii & "!")
  doAssert shout.value == "13!" and pick.runs == 1 and shout.runs == 1
  other.value = "y"
  doAssert shout.value == "13!" and pick.runs == 1, "a signal not read this time: no reason to work again"
  b.value = 4
  doAssert shout.value == "14!" and pick.runs == 2 and shout.runs == 2, "through two computed values"
  flag.value = false
  doAssert shout.value == "Y!"
  b.value = 100
  doAssert shout.value == "Y!" and pick.runs == 3, "sum no longer read by the branch that ran"
  # a computed value whose answer did not change: what reads it is not worked out again
  let n = signal(5)
  let odd = computed(proc (): bool = n.value mod 2 == 1)
  let word = computed(proc (): string = (if odd.value: "odd" else: "even"))
  doAssert word.value == "odd" and word.runs == 1
  n.value = 7
  doAssert word.value == "odd" and odd.runs == 2 and word.runs == 1, "its input's answer was the same"
  # in place
  let list = signal(@[1, 2])
  let total = computed(proc (): int =
    for x in list.value: result += x)
  doAssert total.value == 3
  list.update(proc (v: var seq[int]) = v.add 4)
  doAssert total.value == 7

block effects:
  let s = signal(1)
  var seen: seq[int]
  let e = effect(proc () = seen.add s.value)
  doAssert seen == @[1] and e.runs == 1
  runEffects()
  doAssert seen == @[1], "nothing changed: not run"
  s.value = 2
  runEffects()
  doAssert seen == @[1, 2]
  e.stop()
  s.value = 3
  runEffects()
  doAssert seen == @[1, 2], "stopped"

block keptAcrossRuns:
  # one run writes what `keep` names; the next, started again, gets it back
  let state = getTempDir() / "retro-keep-test.json"
  removeFile(state)
  doAssert not keepsState()
  var off = 5
  keep off
  doAssert off == 5, "not in --watch: nothing"
  putEnv("RETRO_KEEP_STATE", state)
  type Page = object
    step: int
    name: string
  var count = 1
  var page = Page(step: 2, name: "ab")
  var tags = @["a"]
  keep count, page, tags
  count = 42
  page.name = "Sultan"
  tags.add "b"
  saveKept()
  let j = parseFile(state)
  doAssert j["count"].getInt == 42 and j["page"]["name"].getStr == "Sultan" and j["tags"].len == 2, $j
  # the next run (a program of its own, with the same file)
  let src = getTempDir() / "retro_keep_next.nim"
  writeFile(src, """
import retroui/[core, keep]
type Page = object
  step: int
  name: string
var count = 1
var page = Page(step: 0, name: "")
var tags: seq[string]
var gone = 7
keep count, page, tags, gone
echo count, " ", page.step, " ", page.name, " ", tags.len, " ", gone
""")
  let here = currentSourcePath().parentDir.parentDir / "src"
  let (o, code) = execCmdEx("nim c -r --hints:off --warnings:off --path:" & quoteShell(here) &
                            " --nimcache:" & quoteShell(getTempDir() / "retro_keep_nc") & " " & quoteShell(src))
  doAssert code == 0, o
  doAssert o.strip.splitLines[^1] == "42 2 Sultan 2 7", o
  delEnv("RETRO_KEEP_STATE")

echo "signals: ok"
