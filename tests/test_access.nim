## The tree screen readers read, headless: the controls a frame draws with
## their roles, names (a label names the box after it), values and states;
## the focus; what a screen reader asks back (press, focus, set a value, a
## step up) done by the next frame; and nothing built when no screen reader
## listens.

import retroui
import retroui/uirelays/access
import harness
import std/strutils

fakeDriver()

var sent: seq[seq[AccessNode]]
var sentFocus: seq[int]
accessRelays.update = proc (nodes: openArray[AccessNode]; focus: int) =
  sent.add @nodes
  sentFocus.add focus

var
  name = "World"
  greeted = ""
  autoSave = true
  size = 1
  volume = 40
  copies = 2
  lang = 0
  pick = 1
  items = @["Apples", "Pears", "Plums"]
  dlg = false

view = proc () =
  menubar:
    menu "&File":
      if menuItem("E&xit", "Alt+F4"): discard
  row([60, -1]):
    label "&Name:"
    edit name
  row:
    if button("&Greet", isDefault = true): greeted = "Hello, " & name & "!"
    checkbox "&Auto save", autoSave
  group "Size":
    radio "Small", size, 0
    radio "Large", size, 1
  label "Volume:"
  slider volume, 0, 100
  label "Copies:"
  spin copies, 1, 9
  label "Language:"
  combo ["English", "Deutsch"], lang
  label "Fruit:"
  listbox items, pick, rows = 3
  label greeted
  statusbar("Ready")

proc find(nodes: seq[AccessNode]; role: AccessRole; name = ""): int =
  for i, n in nodes:
    if n.role == role and (name.len == 0 or n.name == name): return i
  -1

startApp("access", 400, 420)

block nothingWithoutAScreenReader:
  run(3)
  doAssert not accessible()
  doAssert sent.len == 0
  doAssert accessTree.len == 0

accessListening = true
run(3)

block theTree:
  doAssert accessible()
  doAssert sent.len >= 1, "the tree went to the screen reader"
  let t = sent[^1]
  doAssert t[0].role == arWindow and t[0].parent == -1
  doAssert t[0].name == "access"
  let e = t.find(arTextField)
  doAssert e > 0
  doAssert t[e].name == "Name:", "the label names the box: " & t[e].name
  doAssert t[e].value == "World"
  doAssert asFocusable in t[e].states
  let b = t.find(arButton, "Greet")
  doAssert b > 0, "the button, its '&' left out"
  doAssert asDefault in t[b].states
  let c = t.find(arCheckBox, "Auto save")
  doAssert c > 0 and asChecked in t[c].states
  let g = t.find(arGroup, "Size")
  doAssert g > 0
  let r1 = t.find(arRadioButton, "Small")
  let r2 = t.find(arRadioButton, "Large")
  doAssert t[r1].parent == g and t[r2].parent == g, "the options are in their group"
  doAssert asChecked notin t[r1].states and asChecked in t[r2].states
  doAssert t[r2].pos == 2
  let s = t.find(arSlider)
  doAssert t[s].name == "Volume:" and t[s].now == 40 and t[s].hi == 100
  let sp = t.find(arSpinButton)
  doAssert sp > 0 and t[sp].name == "Copies:" and t[sp].value == "2"
  doAssert t.find(arTextField) == e, "the spin box's own box is not read twice"
  let cb = t.find(arComboBox)
  doAssert t[cb].name == "Language:" and t[cb].value == "English"
  let l = t.find(arList)
  doAssert t[l].name == "Fruit:"
  let items = childrenOf(t, l)
  doAssert items.len == 3
  doAssert t[items[1]].name == "Pears" and asSelected in t[items[1]].states
  doAssert t[items[1]].pos == 2 and t[items[1]].count == 3
  doAssert t.find(arMenuBar) > 0 and t.find(arMenu, "File") > 0
  doAssert t.find(arStatusBar, "Ready") > 0
  for n in t:
    doAssert n.w >= 0 and n.h >= 0
  # the same frame again: nothing sent
  let before = sent.len
  run(2)
  doAssert sent.len == before, "an unchanged tree is not sent again"

block focusAndTyping:
  let t = sent[^1]
  let e = t.find(arTextField)
  accessRequests.add AccessRequest(action: aaFocus, id: t[e].id)
  run(2)
  let t2 = sent[^1]
  doAssert sentFocus[^1] >= 0 and t2[sentFocus[^1]].role == arTextField
  doAssert asFocused in t2[sentFocus[^1]].states
  typeText("!")
  run(2)
  let typed = sent[^1][sent[^1].find(arTextField)].value
  doAssert typed in ["World!", "!", "!World"], typed
  echo "  typed after a focus from the screen reader: ", typed

block pressAndSet:
  let t = sent[^1]
  accessRequests.add AccessRequest(action: aaSetValue, id: t[t.find(arTextField)].id,
                                   text: "Sultan")
  run(2)
  doAssert name == "Sultan"
  accessRequests.add AccessRequest(action: aaPress, id: t[t.find(arButton, "Greet")].id)
  run(3)
  doAssert greeted == "Hello, Sultan!", greeted
  doAssert sent[^1].find(arLabel, "Hello, Sultan!") > 0
  accessRequests.add AccessRequest(action: aaPress, id: t[t.find(arCheckBox)].id)
  run(2)
  doAssert not autoSave
  accessRequests.add AccessRequest(action: aaPress, id: t[t.find(arRadioButton, "Small")].id)
  run(2)
  doAssert size == 0
  accessRequests.add AccessRequest(action: aaSetValue, id: t[t.find(arSlider)].id, num: 75)
  run(2)
  doAssert volume == 75
  accessRequests.add AccessRequest(action: aaIncrement, id: t[t.find(arSpinButton)].id)
  run(2)
  doAssert copies == 3, $copies
  accessRequests.add AccessRequest(action: aaSetValue, id: t[t.find(arSpinButton)].id,
                                   text: "7", num: 7)
  run(2)
  doAssert copies == 7, $copies
  accessRequests.add AccessRequest(action: aaSetValue, id: t[t.find(arComboBox)].id,
                                   text: "Deutsch")
  run(2)
  doAssert lang == 1
  let l = t.find(arList)
  accessRequests.add AccessRequest(action: aaPress, id: t[childrenOf(t, l)[2]].id)
  run(2)
  doAssert pick == 2
  let t3 = sent[^1]
  doAssert asFocused in t3[childrenOf(t3, t3.find(arList))[2]].states,
    "the chosen item has the focus"

block menus:
  let t = sent[^1]
  accessRequests.add AccessRequest(action: aaPress, id: t[t.find(arMenu, "File")].id)
  run(3)
  let t2 = sent[^1]
  let item = t2.find(arMenuItem, "Exit")
  doAssert item > 0, "the open menu's items"
  doAssert t2[item].key == "Alt+F4"
  doAssert t2[t2[item].parent].role == arMenu

var
  cols = @[column("Name", 100), checkColumn("Paid", 50)]
  people = @[@["Ann", "1"], @["Bob", "0"], @["Cy", "1"]]
  person = 0
  folder = ""
  homeOpen = true
  chosen = @[false, true]
  day = date(2026, 11, 5)

block businessControls:
  view = proc () =
    label "&People:"
    grid(cols, people, person, height = 3)
    label "Folders:"
    tree(folder, 4):
      branch("Home", homeOpen):
        leaf("Notes")
    checkList(["Mail", "Chat"], chosen, rows = 2)
    calendar(day)
    chart("Sales", chBar, ["Jan", "Feb"], [series("2026", [3.0, 5.0])], height = 120)
  run(3)
  let t = sent[^1]
  let g = t.find(arTable)
  doAssert g > 0 and t[g].name == "People:", "the grid, named by its label"
  let gk = childrenOf(t, g)
  doAssert t[gk[0]].role == arColumnHeader and t[gk[0]].name == "Name"
  doAssert t[gk[2]].role == arRow and t[gk[2]].pos == 1 and t[gk[2]].count == 3
  let cells = childrenOf(t, gk[3])
  doAssert t[cells[0]].name == "Bob" and t[cells[0]].help == "Name"
  doAssert t[cells[1]].role == arCheckBox and asChecked notin t[cells[1]].states
  doAssert asChecked in t[childrenOf(t, gk[2])[1]].states, "Ann has paid"
  accessRequests.add AccessRequest(action: aaPress, id: t[childrenOf(t, gk[4])[0]].id)
  run(2)
  doAssert person == 2, "a screen reader picked Cy's row: " & $person
  let tr = t.find(arTree)
  doAssert t[tr].name == "Folders:"
  let home = t.find(arTreeItem, "Home")
  let notes = t.find(arTreeItem, "Notes")
  doAssert asExpanded in t[home].states and t[home].level == 1 and t[notes].level == 2
  accessRequests.add AccessRequest(action: aaPress, id: t[notes].id)
  run(2)
  doAssert folder == "Home/Notes", folder
  let mail = t.find(arCheckBox, "Mail")
  doAssert mail > 0 and t[t[mail].parent].role == arList
  accessRequests.add AccessRequest(action: aaPress, id: t[mail].id)
  run(2)
  doAssert chosen[0], "the check list's item flipped"
  let month = t.find(arTable, "November 2026")
  doAssert month > 0, "the calendar's month"
  let d5 = t.find(arCell, "5 November 2026")
  doAssert asSelected in t[d5].states
  accessRequests.add AccessRequest(action: aaPress, id: t[t.find(arCell, "20 November 2026")].id)
  run(2)
  doAssert day == date(2026, 11, 20), $day
  let c = t.find(arImage, "Sales")
  doAssert c > 0 and "Bars" in t[c].help and "2026" in t[c].help, t[c].help

var
  dark = false
  sizeSel = 0
  docTabs = @["One.txt", "Two.txt"]
  docSel = 0
  stars = 2
  props = @[textProp("Name", "Ann"), boolProp("Active", true)]
  propSel = 0
  rowsT = @[TreeRow(level: 0, cells: @["Assets", "100"], open: true),
            TreeRow(level: 1, cells: @["Cash", "40"])]
  treeSel = 0
  treeCols = @[column("Account", 120), column("Balance", 80)]
  logSel = 0
  query = ""

block moreControls:
  view = proc () =
    toggle "Dark", dark
    label "Size:"
    segmented(["S", "M", "L"], sizeSel)
    discard tabStrip(docTabs, docSel)
    rating(stars)
    searchBox(query)
    propertyGrid(props, propSel, height = 80)
    treeGrid(treeCols, rowsT, treeSel, height = 3)
    lineView(3, proc (i: int): string = "line " & $(i + 1), logSel, height = 60)
    markdown("# Hello\n\nSome **bold** words and a [link](http://x).")
  run(3)
  let t = sent[^1]
  let d = t.find(arCheckBox, "Dark")
  doAssert d > 0 and asChecked notin t[d].states
  accessRequests.add AccessRequest(action: aaPress, id: t[d].id)
  run(2)
  doAssert dark, "the switch flipped"
  let g = t.find(arGroup)
  doAssert t[g].name == "Size:"
  let opts = childrenOf(t, g)
  doAssert opts.len == 3 and asChecked in t[opts[0]].states
  accessRequests.add AccessRequest(action: aaPress, id: t[opts[2]].id)
  run(2)
  doAssert sizeSel == 2
  let tab2 = t.find(arTab, "Two.txt")
  accessRequests.add AccessRequest(action: aaPress, id: t[tab2].id)
  run(2)
  doAssert docSel == 1 and docTabs.len == 2, "the tab picked, none closed"
  let s = t.find(arSlider)
  doAssert t[s].now == 2 and t[s].hi == 5
  accessRequests.add AccessRequest(action: aaSetValue, id: t[s].id, num: 4)
  run(2)
  doAssert stars == 4
  let q = t.find(arTextField, "Search")
  doAssert q > 0, "the search box named by its placeholder"
  let pv = t.find(arCell, "Name")
  doAssert pv > 0
  var nameValue = -1
  for i, n in t:
    if n.role == arCell and n.name == "Name" and n.value == "Ann": nameValue = i
  doAssert nameValue > 0, "the property's value"
  accessRequests.add AccessRequest(action: aaSetValue, id: t[nameValue].id, text: "Bea")
  run(2)
  doAssert props[0].text == "Bea"
  let cash = t.find(arTreeItem, "Cash")
  doAssert cash > 0 and t[cash].level == 2 and "Balance: 40" in t[cash].help
  accessRequests.add AccessRequest(action: aaPress, id: t[cash].id)
  run(2)
  doAssert treeSel == 1
  doAssert t.find(arListItem, "line 2") > 0
  var md = -1
  for i, n in t:
    if n.role == arTextArea and asReadOnly in n.states: md = i
  doAssert md > 0 and t[md].value == "Hello\n\nSome bold words and a link.", t[md].value

block stopsAndNames:
  # a range's two ends: two stops of Tab, each its own node; a time's hours
  # and minutes named; whether a control has the keyboard
  var lo = 10
  var hi = 80
  var hh = 9
  var mm = 30
  view = proc () =
    rangeSlider(lo, hi, 0, 100)
    timePicker(hh, mm)
    if button("OK"): discard
  run(3)
  let t = sent[^1]
  let f = t.find(arSlider, "From")
  let e = t.find(arSlider, "To")
  doAssert f > 0 and e > 0 and asFocusable in t[f].states and asFocusable in t[e].states
  doAssert t.find(arSpinButton, "Hours") > 0 and t.find(arSpinButton, "Minutes") > 0
  let stops = tabStops()
  doAssert Id(t[f].id) in stops and Id(t[e].id) in stops, "both ends are stops of Tab"
  accessRequests.add AccessRequest(action: aaFocus, id: t[f].id)
  run(2)
  key(KeyRight)
  run(2)
  doAssert lo == 11 and hi == 80
  key(KeyTab)
  run(2)
  key(KeyRight)
  run(2)
  doAssert lo == 11 and hi == 81, "Tab to the right end: the arrows move it"
  doAssert focusInControls()
  ui.focus = 0
  doAssert not focusInControls(), "nothing focused: an app may give Tab a meaning of its own"

block toolRunsAndNames:
  # a tool bar's run of buttons: one stop, its lit button the reader's
  # focus; a label of only an icon names nothing; a document by its heading
  var md = "# Notes\n\nSome text."
  view = proc () =
    toolbar:
      toolButton("B", "Bold")
      toolButton("I", "Italic")
    label "\uf02d"                       # (an icon alone)
    discard markdownView(md, height = 80)
  run(3)
  var t = sent[^1]
  let bold = t.find(arButton, "Bold")
  let italic = t.find(arButton, "Italic")
  doAssert bold > 0 and italic > 0
  doAssert asFocusable in t[bold].states and asFocusable notin t[italic].states,
           "the run's lit button is its stop"
  doAssert t.find(arTextArea, "Notes") > 0, "the document named by its heading: " &
           (if t.find(arTextArea) > 0: t[t.find(arTextArea)].name else: "none")
  ui.focus = 0
  key(KeyTab)
  run(2)
  key(KeyRight)
  run(2)
  t = sent[^1]
  doAssert asFocused in t[t.find(arButton, "Italic")].states, "the arrows: Italic lit, read as focused"

block openListsAndScrolling:
  # an open drop-down's items are read and pressed; a control a screen
  # reader asks to see is scrolled to
  var lang2 = 0
  var far = ""
  view = proc () =
    label "Language:"
    combo ["English", "Deutsch", "Français"], lang2
    scrollPanel 60:
      for i in 0 ..< 12: label "Line " & $i
      label "Far:"
      edit far
  run(3)
  var t = sent[^1]
  let c = t.find(arComboBox)
  doAssert c > 0
  accessRequests.add AccessRequest(action: aaPress, id: t[c].id)
  run(3)
  t = sent[^1]
  let fr = t.find(arListItem, "Français")
  doAssert t.find(arListItem, "Deutsch") > 0 and fr > 0, "the open list's items are read"
  accessRequests.add AccessRequest(action: aaPress, id: t[fr].id)
  run(3)
  doAssert lang2 == 2, "an item pressed is picked"
  t = sent[^1]
  let e = t.find(arTextField, "Far:")
  doAssert e > 0
  let y0 = t[e].y
  accessRequests.add AccessRequest(action: aaScrollIntoView, id: t[e].id)
  run(4)
  t = sent[^1]
  let e2 = t.find(arTextField, "Far:")
  doAssert t[e2].y < y0, "scrolled to it: " & $(y0, t[e2].y)

accessListening = false
run(2)
doAssert not accessible()
echo "test_access: ok"
