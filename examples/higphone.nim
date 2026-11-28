## Retro Groceries -- the phone app of the Retro UI Interface Guidelines (docs/hig.md): a
## shopping list that does what the guidelines ask of an app on a phone or a tablet, each rule
## with the call it takes. Read it beside them.
##
## - a navigation bar on every page, its title large at the top of the list (`largeTitle`)
## - a tab bar of the app's places, a number on the one with news, search apart (`bottomNav`)
## - rows in groups; Edit puts them in edit mode: a minus to delete, a grip to move
##   (`editTableGroup`); a finger held on a row lifts it with its menu (`liftMenu`)
## - a new item in a modal sheet with Cancel and Add (`modalSheet`)
## - Clear from an action sheet that comes out of its button (`actionSheet(anchor)`)
## - search with a scope bar (`searchBar`, `scopeBar`)
## - placeholders while the list loads (`skeletonRows`), a page that says what to do when it is
##   empty (`emptyState`)
## - work kept by itself: the list and the place the user was are written as the app goes to the
##   background and read back as it starts (`keepState`, `restoreState`) -- no Save
## - a tablet's wider screen: the content in a column of a comfortable width, the sheet in the
##   middle; the Glass look's glass and its settings (`appearanceSettings`)
##
##   nim c -r examples/higphone.nim
##   retroapk examples/higphone.nim --name:"Retro Groceries" --id:org.retro.groceries
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[strutils, sequtils]
import retroui, retroui/system

type Item = object
  name: string
  aisle: int
  done: bool

const aisles = ["Produce", "Dairy", "Bakery", "Other"]

var
  items = restoreState("groceries.items", @[
    Item(name: "Apples", aisle: 0), Item(name: "Spinach", aisle: 0),
    Item(name: "Milk", aisle: 1), Item(name: "Yogurt", aisle: 1, done: true),
    Item(name: "Bread", aisle: 2), Item(name: "Coffee", aisle: 3)])
  place = restoreState("groceries.place", 0)
  editing = false
  startedAt = -1
  addOpen = false
  newName = ""
  newAisle = 0
  clearOpen = false
  clearFrom: Rect
  query = ""
  scope = 0

proc left(): int = items.countIt(not it.done)

proc pageColumn(key: string; body: proc ()) =
  ## (a page that scrolls under the bars; on a tablet its rows in a column of a reading width)
  beginPanel(-1, key, plain = true)
  let (fx, _) = layoutOrigin()
  let w = layoutWidth()
  let cw = if isCompact(): w else: min(w - 2 * dp(24), dp(600))
  pushFrame(rect(fx + (w - cw) div 2, layoutY() + dp(4), cw, 0))
  body()
  discard place(0, popFrame() + dp(12))
  endPanel()

proc listPage() =
  if navBar("Groceries", action = if editing: "Done" else: "Edit", done = editing) == npAction:
    editing = not editing
  pageColumn("groceries:list") do ():
    largeTitle("Groceries", if left() == 0: "Everything bought" else: $left() & " to buy")
    if ui.now - startedAt < 600:
      skeletonRows(4, lines = 1, picture = false)      # (as the list loads: its shape at once)
      wakeIn(100)
      return
    if items.len == 0:
      emptyState(nfShoppingCart, "Nothing on the list", h = 180,
                 detail = "Tap Add Item to put something on it.")
    for a, aisle in aisles:
      var shown: seq[int]                              # (the items of this aisle: their places)
      for i, it in items:
        if it.aisle == a: shown.add i
      if shown.len == 0: continue
      var gone = -1
      editTableGroup(aisle, editing):
        for i in shown:
          var done = items[i].done
          let hit = checkRow(items[i].name, done, key = "item" & $i)
          if done != items[i].done:
            items[i].done = done
            haptic(if done: hSuccess else: hTap)
          if hit.deleted: gone = i
          if not editing:
            case liftMenu(ui.lastRect, "item" & $i, [if done: "Not Bought" else: "Bought", "Delete"],
                          destructive = 1)
            of 0: items[i].done = not items[i].done
            of 1: gone = i
            else: discard
      let moved = tableMoved()
      if moved.moved:
        let it = items[shown[moved.a]]
        items.delete(shown[moved.a])
        let at = if moved.b < shown.len: shown[moved.b] else: shown[^1]
        items.insert(it, min(at, items.len))
      if gone >= 0: items.delete(gone)
    tableGroup(""):
      if tableButton("Add Item"):
        newName = ""
        addOpen = true
        focusFirstText(inDialog = true)          # (the name's box takes the keys: type at once)
      if tableButton("Clear Bought Items", destructive = true, enabled = items.anyIt(it.done)):
        clearOpen = true
      clearFrom = ui.lastRect

proc searchPage() =
  discard navBar("Search")
  searchBar(query, "Search the list")
  scopeBar(["All", "To Buy", "Bought"], scope)
  pageColumn("groceries:search") do ():
    let q = query.strip.toLowerAscii
    var found = 0
    tableGroup(if q.len == 0: "" else: "Found"):
      for it in items:
        if q.len > 0 and q notin it.name.toLowerAscii: continue
        if scope == 1 and it.done or scope == 2 and not it.done: continue
        discard tableRow(it.name, aisles[it.aisle], if it.done: taCheck else: taNone)
        inc found
    if found == 0:
      emptyState(nfSearch, "No items", h = 180, detail = "Nothing on the list has those letters.")

proc settingsPage() =
  discard navBar("Settings")
  pageColumn("groceries:settings") do ():
    appearanceSettings()

app "Retro Groceries", 390, 760:
  if startedAt < 0: startedAt = ui.now
  keepState("groceries.items", items)          # (written as the app goes to the background)
  keepState("groceries.place", place)
  let before = place
  bottomNav([(nfList, "List"), (nfCog, "Settings"), (nfSearch, "Search")], place,
            [if left() > 0: $left() else: "", "", ""], search = 2)
  if place != before: editing = false
  case place
  of 0: listPage()
  of 1: settingsPage()
  else: searchPage()

  # a new item: a task of its own, in a sheet -- Cancel and Add on its bar
  if beginModalSheet(addOpen, "New Item", done = "Add", doneEnabled = newName.strip.len > 0):
    tableGroup(""):
      edit(newName, hint = "Name")
    tableGroup("Aisle"):
      for a, aisle in aisles:
        if tableRow(aisle, accessory = if a == newAisle: taCheck else: taNone).clicked: newAisle = a
    if endModalSheet(addOpen) == shDone:
      items.add Item(name: newName.strip, aisle: newAisle)

  case actionSheet(clearOpen, "", ["Clear Bought Items"], destructive = 0, anchor = clearFrom,
                   message = "The items you ticked leave the list.")
  of 0: items.keepItIf(not it.done)
  else: discard
