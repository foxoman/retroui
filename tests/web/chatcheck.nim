## Chat in a web page (`retroweb --threads`): XMPP over a WebSocket the
## page opens (tests/web/xmppws.py, a small server), signed on, the
## contact list, a message and its answer, signed off. The page's checks
## for tests/web/threads.js ("chat"). (In frames, as an app has it: the
## page does what the connection's thread asks of it between them.)

import retroui
import retroui/xmpp

proc check(ok: bool; what: string) =
  echo (if ok: "PASS " else: "FAIL "), what

var
  online, roster, answer, offline, sent, told = false
  why = ""
  frames = 0

xmppStart("me@localhost", "secret", host = "ws://127.0.0.1:8774/xmpp-websocket")

app "chatcheck", 320, 200:
  inc frames
  wakeIn(30)
  for e in xmppEvents():
    case e.kind
    of xeOnline: online = true
    of xeRoster: roster = e.contacts.len == 1 and e.contacts[0].name == "Echo Bot"
    of xeMessage:
      if e.text == "echo: hello over a WebSocket":
        answer = true
        xmppStop()
    of xeError: why = e.text
    of xeOffline: offline = true
    else: discard
  if online and roster and not sent:
    sent = true
    discard sendChat("bot@localhost", "hello over a WebSocket")
  label (if offline: "signed off" elif online: "online" else: "signing on")
  if (offline or frames > 600) and not told:
    told = true
    check(online, "signed on over a WebSocket" & (if why.len > 0: " (" & why & ")" else: ""))
    check(roster, "the contact list")
    check(answer, "a message and its answer")
    check(offline, "signed off")
    echo "CHAT DONE"
