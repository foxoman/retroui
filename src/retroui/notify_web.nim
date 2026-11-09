# (the notifications of a web page: `notify.nim` includes this; see its
# documentation)

import std/strutils
import uirelays/services

var badgeNow = 0

proc jsonText(s: string): string =
  result = "\""
  for c in s:
    case c
    of '"': result.add "\\\""
    of '\\': result.add "\\\\"
    of '\n': result.add "\\n"
    of '\r', '\t': result.add ' '
    of '\0' .. '\x08', '\x0b', '\x0c', '\x0e' .. '\x1f': discard
    else: result.add c
  result.add '"'

proc notifyAvailable*(): bool =
  ## The browser shows notifications and the user did not refuse them.
  systemCall("notify.allowed", "") notin ["no", "denied", "\0"]

proc notify*(title, body: string; app = ""; icon = ""; tag = ""): bool {.discardable.} =
  ## A notification of the browser (it asks the user the first time).
  if title.len == 0 and body.len == 0: return false
  systemCall("notify", "{\"title\":" & jsonText(title[0 ..< min(title.len, 120)]) &
             ",\"body\":" & jsonText(body[0 ..< min(body.len, 600)]) &
             ",\"tag\":" & jsonText(tag) & "}") == "1"

proc clearNotification*(tag = "") =
  ## Takes the notification with `tag` away.
  discard systemCall("notify.close", tag)

proc setBadge*(count: int) =
  ## The count on the installed app's icon (where the browser can).
  let c = max(0, count)
  if c == badgeNow: return
  badgeNow = c
  discard systemCall("badge", $c)

proc badgeCount*(): int = badgeNow
  ## The count `setBadge` set last.

proc notifyWait*(timeoutMs = 3000): bool = true
  ## (a page hands notifications over at once)
