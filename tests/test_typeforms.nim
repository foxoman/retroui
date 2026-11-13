## Tests of retroui/typeforms: a form and a grid made from an object's
## fields, its pragmas' checks, captions from names.

import std/strutils
import harness, retroui
import retroui/uirelays/input

fakeDriver()
startApp("t", W, H)

type
  Shift = enum Morning, Evening, Night
  Person = object
    name {.caption: "Full name", required, maxLen: 5.}: string
    age {.limits: (16, 70).}: int
    shift: Shift
    rate {.decimals: 1.}: float
    remote: bool
    secret {.noForm.}: int

doAssert niceCaption("startDate") == "Start date"
doAssert niceCaption("start_date") == "Start date"
doAssert niceCaption("ID") == "ID"

var p = Person(name: "", age: 10)
let errs = formErrors(p)
doAssert errs.len == 2 and errs[0].field == "Full name" and errs[1].field == "Age", $errs
doAssert not formValid(p)
p.name = "Toolong"
doAssert formErrors(p)[0].error.startsWith("At most"), $formErrors(p)
p.name = "Ann"
p.age = 30
doAssert formValid(p)

doAssert columnsOf(Person).len == 5        # (secret left out)
doAssert cellOf(Person(name: "Ann", shift: Night, rate: 2.5, remote: true), 2) == "Night"
doAssert cellOf(Person(rate: 2.5), 3) == "2.50"
doAssert cellOf(Person(remote: true), 4) == "Yes"

var changed = false
var nameBox: Rect
view = proc () =
  if formOf(p): changed = true
run(2)
# the first field's box: right of the captions' column (110), on the first row
nameBox = rect(Pad + 110 + Gap + 4, Pad, 120, CtrlH)
click(nameBox)
key(KeyEnd)
typeText("e")
run()
doAssert p.name == "Anne" and changed, p.name

var rows = @[Person(name: "Cy", age: 50), Person(name: "Al", age: 20), Person(name: "Bo", age: 35)]
var sel = 0
var gridRect: Rect
view = proc () =
  gridOf(rows, sel, height = 5)
  gridRect = ui.lastRect
run(2)
# a click on the Age header sorts by age
click(gridRect, dx = columnsOf(Person)[0].width + 10, dy = 6)
run()
doAssert rows[0].name == "Al" and rows[2].name == "Cy", $rows

echo "typeforms OK"
