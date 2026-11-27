## Tests of Retro DNS's pages on a phone and a tablet (examples/retrodns.nim, built without its
## frame loop: -d:retrodnsTest): the state at the top of DNS, the fastest servers numbered and one
## tapped, a server row held (its menu: Add to Favourites), Favourites' Edit (a row's minus, then
## Done), Activity's names (one held, Blocked), the sections down the left on a tablet with the
## state over them -- every page in every look, light and dark, and Gloss Onyx.

import std/[os, strutils, tables]
import retroui/uirelays/[services, coords, screen, input]
import harness

let home = getTempDir() / "retro-dnsapp"
removeDir(home)
createDir(home)
putEnv("HOME", home)
putEnv("XDG_DATA_HOME", home / ".local" / "share")
putEnv("XDG_CONFIG_HOME", home / ".config")
putEnv("RETRO_TOUCH", "1")

include ../examples/retrodns

var passed = 0
template check(cond: bool; what: string) =
  doAssert cond, what
  inc passed
  echo "  ok   ", what

const winW = 900
const winH = 700
var shot = newSeq[uint32](winW * winH)
fakeDriver()
windowRelays.createWindow = proc (l: var ScreenLayout; icon: pointer; iconLen: int) =
  l.width = winW; l.height = winH; l.scaleX = 1; l.scaleY = 1; l.uiScale = 100
windowRelays.getWindowLayout = proc (): ScreenLayout =
  ScreenLayout(width: winW, height: winH, scaleX: 1, scaleY: 1, uiScale: 100)
drawRelays.blitRGBA = proc (p: ptr UncheckedArray[uint32]; w, h: int; dst: Rect; f: RGBAFormat): bool =
  for y in 0 ..< h:
    for x in 0 ..< w:
      if dst.y + y < winH and dst.x + x < winW: shot[(dst.y + y) * winW + dst.x + x] = p[y * w + x]
  true
appNavBars = true
startApp("dnsapp", winW, winH)
accessKeep = true
servers = builtinServers()
loadState()
uiLook = lookGloss
ui.theme = GlossLight
layoutWanted = 1                          # (a phone's pages: the tab bar, a page over another)
showActivity = true                       # (Android's Activity, here too)
view = proc () =
  shell()
run(3)

proc settle(frames = 12) =
  for _ in 0 ..< frames:
    ticks += 40
    run(1)

let shots = getEnv("DNSSHOTS")
proc save(name: string) =
  ## (DNSSHOTS=folder: the screen as a picture, to look at)
  if shots.len == 0: return
  var bm = newBitmap(winW, winH)
  for i in 0 ..< winW * winH: bm.px[i] = 0xFF000000'u32 or shot[i]
  createDir(shots)
  writeFile(shots / name & ".png", encodePng(bm))

proc has(name: string; roles: set[AccessRole] = {}): bool = findNode(accessLast, name, roles) >= 0

proc tapNode(name: string; roles: set[AccessRole] = {}; nth = 0) =
  let n = findNode(accessLast, name, roles, nth)
  doAssert n >= 0, "no " & name & " on the screen"
  let r = nodeRect(accessLast[n])
  click(r, dx = r.w div 2)
  settle()

proc holdNode(name: string; roles: set[AccessRole] = {}) =
  ## (a right click: a finger held)
  let n = findNode(accessLast, name, roles)
  doAssert n >= 0, "no " & name & " on the screen"
  let r = nodeRect(accessLast[n])
  queue.add Event(kind: MouseMoveEvent, x: r.x + r.w div 2, y: r.y + r.h div 2)
  queue.add Event(kind: MouseDownEvent, x: r.x + r.w div 2, y: r.y + r.h div 2, button: RightButton)
  queue.add Event(kind: MouseUpEvent, x: r.x + r.w div 2, y: r.y + r.h div 2, button: RightButton)
  settle()

# ---- DNS: the state, the fastest --------------------------------------------------------------------

check has("Automatic DNS"), "DNS: the state at its top, in words"
check not has("Fastest from Here", {arHeading}), "nothing tested: no Fastest from Here yet"
let a = servers[0]
let b = servers[1]
let c = servers[2]
timings[a.key] = 40
timings[b.key] = 12
timings[c.key] = 25
timings[servers[3].key] = -1
settle()
check has("Fastest from Here", {arHeading}), "tested: the fastest from here"
check fastest(5) == @[1, 2, 0], "the fastest first, a server that did not answer left out"
save("phone-dns")
tapNode(b.name, {arButton, arListItem})
check selKey == b.key, "the fastest tapped: picked"

# ---- Servers: a row held, its menu ----------------------------------------------------------------

tapNode("Servers", {arTab})
check phoneSec == secServers and has("Search servers"), "the Servers tab: the list and its search"
holdNode(c.name, {arButton, arListItem})
check rowMenuOpen and rowMenuKey == c.key, "a server held: its menu"
save("phone-rowmenu")
tapNode("Add to Favourites", {arButton})
check c.key in favs and not rowMenuOpen, "Add to Favourites: a favourite, the menu gone"
holdNode(a.name, {arButton, arListItem})
tapNode("Add to Favourites", {arButton})
check favs == @[c.key, a.key], "another: after it"

# ---- Favourites: Edit ----------------------------------------------------------------------------------

tapNode("Favourites", {arTab})
check phoneSec == secFavourites and has("Edit", {arButton}), "Favourites: its list, Edit on its bar"
tapNode("Edit", {arButton})
check favEditing and has("Done", {arButton}), "Edit: the rows edited, Done on the bar"
save("phone-favedit")
tapNode("Done", {arButton})
check not favEditing, "Done: as it was"

# ---- Activity: a name held, blocked ------------------------------------------------------------------

recentNow = @[(app: "", name: "news.example.org", count: 1, agoMs: 9000),     # (the newest last)
              (app: "com.example.reader", name: "ads.example.com", count: 3, agoMs: 2000)]
recentAt = ui.now + 1_000_000           # (no VPN here to ask again)
tapNode("Activity", {arTab})
check phoneSec == secActivity and has("news.example.org"), "Activity: the names looked up"
save("phone-activity")
check findNode(accessLast, "ads.example.com") < findNode(accessLast, "news.example.org"),
      "the newest first"
holdNode("ads.example.com")
check nameMenuOpen and nameMenuName == "ads.example.com", "a name held: Block, Copy"
tapNode("Block ads.example.com", {arButton})
check blocked("ads.example.com") and not nameMenuOpen, "Block: on the block list"
holdNode("ads.example.com")
tapNode("Unblock", {arButton})
check not blocked("ads.example.com"), "Unblock: off it again"

# ---- a tablet: the state and the sections down the left ------------------------------------------------

layoutWanted = 2
phoneSec = secDns
settle()
check has("Automatic DNS") and has("Servers", {arButton, arListItem}) and not has("Servers", {arTab}),
      "a tablet: the state and the sections down the left, no tab bar"
tapNode("More", {arButton, arListItem})
check phoneSec == secMore and has("About Retro DNS"), "More tapped on the left: its page beside"
phoneSec = secDns
settle()
save("tablet-dns")
for (n, look, t) in [("glass", lookGlass, GlassLight), ("glassdark", lookGlass, GlassDark),
                     ("onyx", lookGloss, GlossOnyx)]:
  uiLook = look
  ui.theme = t
  layoutWanted = 1
  settle(4)
  save("phone-dns-" & n)
  layoutWanted = 2
  settle(4)
  save("tablet-dns-" & n)
uiLook = lookGloss
ui.theme = GlossLight

# ---- every page in every look ---------------------------------------------------------------------------

for (look, schemes) in [(lookClassic, @[Classic, Dark]), (lookGlass, @[GlassLight, GlassDark]),
                        (lookMatte, @[MatteLight, MatteDark]), (lookGloss, @[GlossLight, GlossDark, GlossOnyx])]:
  uiLook = look
  for t in schemes:
    ui.theme = t
    for lw in [1, 2]:
      layoutWanted = lw
      for s in Section:
        phoneSec = s
        run(2)
      phoneSec = secServers
      openServer(b.key)
      run(2)
      discard phoneNav[secServers].pop()
check true, "every page drawn in every look, light and dark, on a phone and a tablet"
uiLook = lookClassic
ui.theme = Classic
removeDir(home)
echo "dnsapp: ", passed, " ok"
