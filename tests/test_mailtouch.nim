## Retro Mail on a phone and a tablet in the newer looks (examples/mail/ui_touch): Mailboxes -- All
## Inboxes with its unread, an account's inbox, Flagged --, a folder's messages (the unread one's
## dot, a tap: the message, "1 of 2" and its arrows), the message's sheets (Flag, Mark as Unread;
## Reply), a finger held on a row: choosing several, Mark; writing (Cancel: keep it or not); an
## account's folders; on a tablet the list down the left and the message beside it -- every page
## in every look, light and dark.

import std/[os, json, strutils, times]
import retroui/uirelays/[services, coords, screen]
from retroui/uirelays/input import nil

let home = getTempDir() / "retro-mailtouch-" & $getCurrentProcessId()
removeDir(home)
createDir(home)
putEnv("HOME", home)
putEnv("RETRO_MAIL_HOME", home)
putEnv("RETRO_SECRETS_DIR", home / "secrets")
putEnv("RETRO_TOUCH", "1")

const mailUnderTest = true
include ../examples/mail
import harness

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
startApp("mailtouch", winW, winH)
accessKeep = true
appNavBars = true

prefs = loadSettings("retro-mail")
store0 = openStore()
link.cmds.open()          # (what the app asks of its sync thread: kept, none runs here)
link.events.open()
fetchIn.open()            # (the pictures' thread's: none runs here either)
fetchOut.open()
fetchLink = addr fetchIn
fetchDone = addr fetchOut
let acc = store0.addAccount(akImap, "me@example.com", "Me", "", "")
let inbox = store0.upsertFolder(acc, "INBOX", "Inbox", "inbox", "")
discard store0.upsertFolder(acc, "Sent", "Sent", "sent", "")
let t0 = epochTime()
let bill = store0.upsertMessage(Msg(account: acc, folder: inbox, remoteId: "1", thread: "t1",
  subject: "Invoice for March", fromName: "Bank", fromEmail: "bank@example.com",
  toList: "Me <me@example.com>, Sara <sara@example.com>", date: t0 - 3600,
  snippet: "Your invoice is ready to download", unread: true, focused: true))
store0.setBody(bill, "", "Your invoice is 20 OMR.")
let lunch = store0.upsertMessage(Msg(account: acc, folder: inbox, remoteId: "2", thread: "t2",
  subject: "Lunch", fromName: "Sara", fromEmail: "sara@example.com", toList: "me@example.com",
  date: t0 - 60, snippet: "Monday?", unread: false, focused: true))
store0.setBody(lunch, "", "Monday at one?")
store0.recount(acc)
mailOpen = true
started = true
uiLook = lookGloss
ui.theme = GlossLight
touchLayout = 1                           # (a phone's pages)
view = vMail
reload()
harness.view = proc () = mailFrame()
run(3)

proc settle(frames = 8) =
  for _ in 0 ..< frames:
    ticks += 40
    run(1)

let shots = getEnv("MAILSHOTS")
proc save(name: string) =
  ## (MAILSHOTS=folder: the screen as a picture, to look at)
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
  let n = findNode(accessLast, name, roles)
  doAssert n >= 0, "no " & name & " on the screen"
  let r = nodeRect(accessLast[n])
  harness.queue.add input.Event(kind: input.MouseMoveEvent, x: r.x + r.w div 2, y: r.y + r.h div 2)
  harness.queue.add input.Event(kind: input.MouseDownEvent, x: r.x + r.w div 2, y: r.y + r.h div 2, button: input.RightButton)
  harness.queue.add input.Event(kind: input.MouseUpEvent, x: r.x + r.w div 2, y: r.y + r.h div 2, button: input.RightButton)
  settle()

check touchUi() and tPage() == tpBoxes and has("Mailboxes", {arHeading}), "Mailboxes first"
check has("All Inboxes") and has("Accounts", {arHeading}) and has("Add Account"), "the inboxes, the accounts"
save("phone-boxes")
tapNode("All Inboxes", {arButton})
check tPage() == tpList and place.kind == plAllInbox and has("Lunch") and has("Invoice"),
      "All Inboxes: its messages"
check has("Focused") and has("Other"), "the Inbox: Focused and Other"
save("phone-list")
tapNode("Bank", {arListItem})
check tPage() == tpMessage and selectedConv() != nil and selectedConv().subject == "Invoice for March",
      "a message tapped: open"
settle()
check not store0.message(bill).unread, "opened: read"
check has("2 of 2", {arHeading}) or has("1 of 2", {arHeading}), "its place in the list on the bar"
save("phone-message")
tapNode("Flag or Mark", {arButton})
tapNode("Mark as Unread", {arButton})
check store0.message(bill).unread, "Mark as Unread: unread again"
tapNode("Flag or Mark", {arButton})
tapNode("Flag", {arButton})
check store0.message(bill).flagged, "Flag: flagged"
tapNode("The message before", {arButton})
check selectedConv().subject == "Lunch", "the arrow up: the message before it"
tapNode("Reply", {arButton})
check has("Reply All", {arButton}) and has("Forward", {arButton}), "Reply: Reply, Reply All, Forward"
tapNode("Reply", {arButton}, nth = 1)          # (the sheet's, over the toolbar's)
check composing and cSubject == "Re: Lunch" and "sara@example.com" in cTo, "Reply: writing, to her"
save("phone-compose")
tapNode("Cancel", {arButton})
tapNode("Delete Draft", {arButton})
check not composing, "Cancel, Delete Draft: not writing"
tapNode("Inbox", {arButton})
check tPage() == tpList, "Back: the list"
holdNode("Sara", {arListItem})
check tEditing and multiSel.len == 1 and has("Mark", {arButton}), "a finger held: choosing, Mark on the bar"
save("phone-editing")
tapNode("Done", {arButton})
check not tEditing and multiSel.len == 0, "Done: as it was"
tapNode("Mailboxes", {arButton})
tapNode("Me", {arButton}, nth = 1)        # (Accounts' row, after its inbox)
check tPage() == tpAccount and has("Inbox") and has("Sent"), "an account: its folders"
tapNode("Sent", {arButton})
check tPage() == tpList and place.kind == plFolder, "a folder: its messages"

# ---- Settings, as a phone's -----------------------------------------------------------------------------------

tStack = @[tpBoxes]
settle()
check has("Settings", {arButton}), "Mailboxes: Settings at their foot"
tPush(tpSettings)           # (its row under the toolbar on this screen: as a tap on it does)
settle()
check tPage() == tpSettings and has("Organize by Thread", {arCheckBox}) and has("Check every", {arComboBox}),
      "Settings: a page of groups"
save("phone-settings")
tapNode("Organize by Thread", {arCheckBox})
check not prefs.getBool("threads", true), "a switch: kept at once"
tapNode("Check every", {arComboBox})
check has("5 minutes", {arListItem}), "a choice: its own page of them"
save("phone-settings-choice")
tapNode("5 minutes", {arListItem})
check prefs.getInt("interval", 1) == 5, "one tapped: chosen, kept"
tapNode("Close", {arButton})
check not has("5 minutes", {arListItem}), "Close: back to Settings"
tPush(tpLook)               # (as a tap on Appearance, at the page's foot)
settle()
check tPage() == tpLook and has("Look", {arComboBox}) and has("Size of everything"), "Appearance: the look, framed"
save("phone-look")
tStack = @[tpBoxes]
settle()

# ---- a tablet: the list down the left, the message beside it ----------------------------------------------

touchLayout = 2
tStack = @[tpBoxes, tpList]
goPlace(Place(kind: plAllInbox))
settle()
tapNode("Bank", {arListItem})
check tPage() == tpList and selectedConv() != nil and has("Invoice for March"), "a tablet: the message beside the list"
save("tablet")

# ---- every page in every look ------------------------------------------------------------------------------------

for (look, schemes) in [(lookClassic, @[Classic, Dark]), (lookGlass, @[GlassLight, GlassDark]),
                        (lookMatte, @[MatteLight, MatteDark]), (lookGloss, @[GlossLight, GlossDark, GlossOnyx])]:
  uiLook = look
  for t in schemes:
    ui.theme = t
    for lw in [1, 2]:
      touchLayout = lw
      for st in [@[tpBoxes], @[tpBoxes, tpAccount], @[tpBoxes, tpList], @[tpBoxes, tpList, tpMessage],
                 @[tpBoxes, tpMore], @[tpBoxes, tpSettings], @[tpBoxes, tpSettings, tpLook]]:
        tStack = st
        run(2)
      openCompose("new")
      run(2)
      composing = false
check true, "every page drawn in every look, light and dark, on a phone and a tablet"
store0.close()
removeDir(home)
echo "mailtouch: ", passed, " ok"
