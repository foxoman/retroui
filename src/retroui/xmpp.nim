## XMPP (Jabber) for chat apps: an account on any public server -- yours to
## pick, nobody's to run -- with what an instant messenger needs: signing on
## (STARTTLS, then SASL PLAIN inside it), the contact list with its groups,
## presence and status messages, one-to-one messages with typing
## notifications and delivery receipts, the messages you send from another
## device (carbons), asking to add someone and answering who asks, profiles
## (vCard: a name, words about you, a picture), chat rooms (MUC), sending a
## file (HTTP upload: its address goes in the message), making an
## account from inside the app (in-band registration) where the server
## allows it, and the history kept by the server (the message archive,
## XEP-0313): what was said from your other devices, or while you were
## away, and the conversations of before on a new device.
##
## The connection lives on a thread of its own; the app sends with the
## procs below and takes what came, every frame, with `xmppEvents`.
##
## .. code-block:: nim
##   import retroui, retroui/xmpp
##   xmppStart("me@yax.im", "my password")
##   app "Chat", 400, 300:
##     for e in xmppEvents():
##       if e.kind == xeMessage: echo e.jid, ": ", e.text
##     if xmppRunning(): wakeIn(250)      # (to take the next ones)
##
## The server's address comes from DNS (its _xmpp-client._tcp SRV record,
## asked of a DNS-over-HTTPS resolver) unless `host` is given; port 5222.
## Certificates are checked against the system's authorities unless
## `insecure` (a server of your own with a self-signed certificate).
##
## Compile with `-d:ssl` (OpenSSL, loaded at run time).
##
## In a web page (`retrokit web --threads`) the connection is a WebSocket
## (RFC 7395) the page opens, to the address the server's host-meta names
## (XEP-0156: /.well-known/host-meta), else wss://DOMAIN/xmpp-websocket;
## `host` may be that address itself (wss://...). The page has no sockets
## of its own and the connection needs a thread: built without threads,
## `xmppStart` answers xeError.
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

when defined(wasm):
  import std/[strutils, xmlparser, xmltree, base64, os, json, times, random, locks]
  import uirelays/services
  when compileOption("threads"): import std/typedthreads
else:
  import std/[net, strutils, xmlparser, xmltree, base64, os, json, times, typedthreads, random, locks]
  from std/posix import poll, TPollfd, POLLIN
import http

when defined(android) and defined(ssl):
  # (bionic has glob() only from Android 9, and std/net looks for the
  # certificate authorities with it: ours before that)
  {.passC: "-include " & quoteShell(currentSourcePath().parentDir / "androidglob.h").}
  {.compile: "androidglob.c".}

type
  XmppEventKind* = enum
    ## What came from the server.
    xeConnecting     ## the connection is being made (`text`: what it does now)
    xeOnline         ## signed on (`jid`: the full address given to this session)
    xeOffline        ## the connection ended (`text`: why, "" when asked)
    xeError          ## something went wrong (`text`; `id` of the request when it was one)
    xeRoster         ## the contact list: `contacts` (`removed` a push that took one out)
    xePresence       ## someone's presence: `jid`, `resource`, `show` ("unavailable" gone), `text` the status
    xeMessage        ## a message: `jid` from, `text`, `id`, `stamp` (sent while you were away), `url` (a file), `carbon`
    xeState          ## typing: `jid`, `show` ("composing", "paused", "active", "inactive", "gone")
    xeReceipt        ## a message arrived: `jid`, `id` (the message's)
    xeAsk            ## `jid` asks to see your presence (to add you); `text` its name if it said one
    xeAnswer         ## `jid` answered your asking: `show` "subscribed" or "unsubscribed"
    xeVcard          ## a profile: `jid`, `fields` (FN, NICKNAME, DESC, PHOTO base64, TYPE)
    xeRegistered     ## the account was made (`jid`)
    xeRoomMessage    ## a chat room's message: `jid` the room, `resource` who, `text`, `stamp`
    xeRoomPresence   ## someone in a room: `jid` the room, `resource` the nickname, `show`
    xeRoomSubject    ## a room's subject: `jid`, `text`
    xeSlot           ## an upload slot: `id`, `putUrl`, `url` (the address to send), `headers`
    xeServices       ## the server's services: `fields` ("upload", jid), ("rooms", jid), ("archive", jid)
    xeArchived       ## a message from the archive (`askArchive`): `jid` the other one, `text`, `id`, `stamp`, `url`, `mine`, `archiveId`; `resource` the asking's id
    xeArchiveDone    ## an `askArchive` answered: `id` its id, `text` the last one's `archiveId` ("" none), `show` "complete" when there is no more; `fields` ("first", id), ("count", n)
    xeStanza         ## a stanza as it came (`text` its XML): the answer to an iq you sent with an id that starts "q-" (`id`), or a server's notice of a change (pubsub)

  Contact* = object
    ## Someone on the contact list.
    jid*, name*: string
    subscription*: string      ## "both", "to" (you see them), "from" (they see you), "none"
    ask*: bool                 ## you asked them, and they have not answered yet
    groups*: seq[string]       ## the groups they are in on your list ("" none: no group)

  XmppEvent* = object
    ## One thing from the server; which fields it fills depends on `kind`.
    kind*: XmppEventKind       ## what it is
    jid*: string               ## whose (a bare address, or a room's)
    resource*: string          ## from which of their devices (a room: the nickname)
    text*: string              ## a message's words, a status, an error, a subject
    show*: string              ## presence: "" there, "away", "xa", "dnd", "chat", "offline"
    id*: string                ## the message's or the request's id
    stamp*: string             ## when it was sent, when it came late (ISO 8601; "" now)
    url*: string               ## a file sent with the message (out of band), an upload's address
    putUrl*: string            ## an upload slot: where to PUT the file
    headers*: seq[(string, string)]  ## ... and the headers the PUT carries
    contacts*: seq[Contact]    ## xeRoster: the contacts that came (all, or the ones changed)
    fields*: seq[(string, string)]   ## xeVcard: FN, NICKNAME, DESC, URL, PHOTO, TYPE; xeServices
    removed*: bool             ## xeRoster: these contacts were taken off the list
    carbon*: bool              ## xeMessage: you sent it, from another device
    mine*: bool                ## xeArchived: you sent it (from this device or another)
    archiveId*: string         ## xeMessage, xeArchived: its id in the server's archive ("" none)
    raw*: string               ## xeMessage, xeArchived: the whole message's XML when it is encrypted (`retroui/omemo`)

  Config = object
    jid, password, host, resource, show, status: string
    port: int
    insecure, register: bool

var
  lock: Lock                   # (the two queues between the app and the thread)
  outbox {.guard: lock.}: seq[string]
  inbox {.guard: lock.}: seq[XmppEvent]
  running: bool
  myJid*: string               ## the full address of this session (after xeOnline)

when not defined(wasm) or compileOption("threads"):
  var worker: Thread[Config]

proc bareJid*(jid: string): string =
  ## "me@yax.im/Retro" -> "me@yax.im".
  let k = jid.find('/')
  if k >= 0: jid[0 ..< k] else: jid

proc resourceOf*(jid: string): string =
  ## "me@yax.im/Retro" -> "Retro" ("" when it has none).
  let k = jid.find('/')
  if k >= 0: jid[k + 1 .. ^1] else: ""

proc domainOf*(jid: string): string =
  ## "me@yax.im/Retro" -> "yax.im": the server.
  let b = bareJid(jid)
  let k = b.find('@')
  if k >= 0: b[k + 1 .. ^1] else: b

proc localOf*(jid: string): string =
  ## "me@yax.im/Retro" -> "me".
  let b = bareJid(jid)
  let k = b.find('@')
  if k >= 0: b[0 ..< k] else: ""

proc esc(s: string): string = xmltree.escape(s)

# ---- the stream: bytes in, elements out ------------------------------------------------------------

type
  Piece = enum pNone, pStart, pEnd, pElement
  Reader = object
    buf: string

proc next(r: var Reader): (Piece, XmlNode) =
  ## The next whole piece of the stream (the stream's start or end, or a
  ## complete top-level element); pNone until it has all come.
  var p = 0
  while p < r.buf.len and r.buf[p] in {' ', '\t', '\r', '\n'}: inc p
  if p > 0: r.buf = r.buf[p .. ^1]
  if r.buf.len == 0 or r.buf[0] != '<':
    # (text outside elements: nothing here uses it)
    let k = r.buf.find('<')
    if k < 0:
      r.buf = ""
      return (pNone, nil)
    r.buf = r.buf[k .. ^1]
  if r.buf.startsWith("<?"):
    let k = r.buf.find("?>")
    if k < 0: return (pNone, nil)
    r.buf = r.buf[k + 2 .. ^1]
    return r.next()
  if r.buf.startsWith("</stream:stream") or r.buf.startsWith("<close ") or r.buf.startsWith("<close/"):
    r.buf = ""
    return (pEnd, nil)
  # (a tag's end: its '>' outside quotes)
  proc tagEnd(s: string; a: int): int =
    var q = '\0'
    for i in a ..< s.len:
      let c = s[i]
      if q != '\0':
        if c == q: q = '\0'
      elif c in {'"', '\''}: q = c
      elif c == '>': return i
    -1
  if r.buf.startsWith("<stream:stream") or r.buf.startsWith("<open ") or r.buf.startsWith("<open/"):
    # (a stream's start; over a WebSocket, RFC 7395's <open/>)
    let e = tagEnd(r.buf, 0)
    if e < 0: return (pNone, nil)
    r.buf = r.buf[e + 1 .. ^1]
    let n = newElement("stream:stream")
    return (pStart, n)
  var depth = 0
  var i = 0
  while true:
    let lt = r.buf.find('<', i)
    if lt < 0: return (pNone, nil)
    if r.buf.continuesWith("<!--", lt):
      let k = r.buf.find("-->", lt)
      if k < 0: return (pNone, nil)
      i = k + 3
      continue
    if r.buf.continuesWith("<![CDATA[", lt):
      let k = r.buf.find("]]>", lt)
      if k < 0: return (pNone, nil)
      i = k + 3
      continue
    let gt = tagEnd(r.buf, lt)
    if gt < 0: return (pNone, nil)
    if r.buf[lt + 1] == '/': dec depth
    elif r.buf[gt - 1] != '/': inc depth
    i = gt + 1
    if depth == 0:
      let text = r.buf[0 ..< i]
      r.buf = r.buf[i .. ^1]
      try: return (pElement, parseXml(text))
      except CatchableError: return r.next()

# ---- the thread -------------------------------------------------------------------------------------

proc emit(e: XmppEvent) =
  {.cast(gcsafe).}:
    withLock lock: inbox.add e

proc emit(kind: XmppEventKind; text = ""; jid = ""; id = "") =
  emit(XmppEvent(kind: kind, text: text, jid: jid, id: id))

proc takeOut(): seq[string] =
  {.cast(gcsafe).}:
    withLock lock:
      result = move outbox
      outbox = @[]

proc srvLookup(domain: string): (string, int) =
  ## The host and port of `domain`'s XMPP service, from its SRV record (asked
  ## of a DNS-over-HTTPS resolver); the domain itself, 5222, without one.
  result = (domain, 5222)
  try:
    let r = httpRequest("GET", "https://dns.google/resolve?name=_xmpp-client._tcp." & domain &
                        "&type=SRV", timeoutSec = 8)
    if not r.ok: return
    var best = 1_000_000
    for a in parseJson(r.body){"Answer"}.getElems:
      if a{"type"}.getInt != 33: continue
      let f = a{"data"}.getStr.splitWhitespace     # priority weight port target
      if f.len == 4 and f[3] != ".":
        let pri = parseInt(f[0])
        if pri < best:
          best = pri
          result = (f[3].strip(chars = {'.'}), parseInt(f[2]))
  except CatchableError: discard

proc caFile(): string =
  for f in [getEnv("SSL_CERT_FILE"), getEnv("PREFIX") / "etc/tls/cert.pem",
            "/data/data/com.termux/files/usr/etc/tls/cert.pem", "/etc/ssl/certs/ca-certificates.crt",
            "/etc/pki/tls/certs/ca-bundle.crt", "/etc/ssl/cert.pem"]:
    if f.len > 0 and fileExists(f): return f
  ""

proc streamOpen(domain: string): string =
  when defined(wasm):
    "<open xmlns='urn:ietf:params:xml:ns:xmpp-framing' to='" & esc(domain) & "' version='1.0'/>"
  else:
    "<?xml version='1.0'?><stream:stream to='" & esc(domain) & "' xmlns='jabber:client' " &
    "xmlns:stream='http://etherx.jabber.org/streams' version='1.0'>"

const streamClose = when defined(wasm): "<close xmlns='urn:ietf:params:xml:ns:xmpp-framing'/>"
                    else: "</stream:stream>"

when defined(wasm):
  proc webSocketUrl(domain, host: string): string =
    ## Where the server takes XMPP over a WebSocket: `host` when it is that
    ## address, else what its host-meta says (XEP-0156), else the usual place.
    if host.startsWith("wss://") or host.startsWith("ws://"): return host
    try:
      let r = httpRequest("GET", "https://" & domain & "/.well-known/host-meta.json", timeoutSec = 8)
      if r.ok:
        for l in parseJson(r.body){"links"}.getElems:
          if l{"rel"}.getStr == "urn:xmpp:alt-connections:websocket" and l{"href"}.getStr.len > 0:
            return l{"href"}.getStr
    except CatchableError: discard
    try:
      let r = httpRequest("GET", "https://" & domain & "/.well-known/host-meta", timeoutSec = 8)
      if r.ok:
        for l in parseXml(r.body).findAll("Link"):
          if l.attr("rel") == "urn:xmpp:alt-connections:websocket" and l.attr("href").len > 0:
            return l.attr("href")
    except CatchableError: discard
    "wss://" & (if host.len > 0: host else: domain) & "/xmpp-websocket"

proc runWorker(cfg: Config) {.thread.} =
  when defined(wasm):
    var sock = 0                 # (the page's WebSocket, by its number)
  else:
    var sock: Socket
  var r: Reader
  var lastSend = epochTime()
  let domain = domainOf(cfg.jid)

  proc put(s: string) =
    when defined(wasm): discard systemCall("ws.send", $sock & "\n" & s)
    else: sock.send(s)
    lastSend = epochTime()

  proc closeSock() =
    when defined(wasm):
      if sock > 0: discard systemCall("ws.close", $sock)
    else:
      if sock != nil: sock.close()

  proc pump(timeout: int): bool =
    ## Bytes from the server into the reader, when some come within
    ## `timeout` ms; false when it closed.
    when defined(wasm):
      let until = epochTime() + timeout / 1000
      while true:
        let got = systemCall("ws.recv", $sock)
        if got == "\x01": return false
        if got.len > 0 and got != "\0":
          r.buf.add got
          return true
        if epochTime() >= until: return true
        sleep(15)
    else:
      if not sock.hasDataBuffered:
        var fds = [TPollfd(fd: cint(sock.getFd), events: POLLIN)]
        if poll(addr fds[0], 1, cint(timeout)) <= 0: return true
      var data = newString(16384)
      let n = sock.recv(addr data[0], data.len)
      if n <= 0: return false
      data.setLen(n)
      r.buf.add data
      true

  proc wait(seconds = 20.0): (Piece, XmlNode) =
    ## The next piece, waiting for it.
    let until = epochTime() + seconds
    while true:
      let got = r.next()
      if got[0] != pNone: return got
      if epochTime() > until: raise newException(IOError, "the server did not answer")
      if not pump(500): raise newException(IOError, "the server closed the connection")

  proc features(): XmlNode =
    var start = wait()
    if start[0] != pStart: raise newException(IOError, "the server did not open its stream")
    let f = wait()
    if f[0] != pElement or f[1].tag != "stream:features":
      raise newException(IOError, "the server sent no features")
    f[1]

  proc iq(xml, id: string): XmlNode =
    ## A request, and its answer (what comes in between is handled later).
    put(xml)
    var held: seq[string]
    while true:
      let (k, n) = wait()
      if k == pEnd: raise newException(IOError, "the server closed the stream")
      if k == pElement and n.tag == "iq" and n.attr("id") == id:
        r.buf = held.join("") & r.buf
        return n
      if k == pElement: held.add $n

  try:
    emit(xeConnecting, "Looking up " & domain)
    when defined(wasm):
      # (a WebSocket the page opens: wss is encrypted, no STARTTLS in it)
      let url = webSocketUrl(domain, cfg.host)
      emit(xeConnecting, "Connecting to " & url)
      sock = try: parseInt(systemCall("ws.open", url)) except ValueError: 0
      if sock <= 0: raise newException(IOError, "this browser has no WebSockets")
      let until = epochTime() + 15
      while true:
        let st = systemCall("ws.state", $sock)
        if st == "open": break
        if st == "closed" or epochTime() > until:
          raise newException(IOError, "the server did not take a WebSocket at " & url)
        sleep(20)
      put(streamOpen(domain))
      var f = features()
    else:
      var (host, port) = (cfg.host, cfg.port)
      if host.len == 0: (host, port) = srvLookup(domain)
      if port <= 0: port = 5222
      emit(xeConnecting, "Connecting to " & host)
      sock = newSocket(buffered = false)
      sock.connect(host, Port(port), timeout = 15000)
      put(streamOpen(domain))
      var f = features()
    # (encryption first: the password never goes in the clear)
    when not defined(wasm):
      if f.child("starttls") != nil:
        put("<starttls xmlns='urn:ietf:params:xml:ns:xmpp-tls'/>")
        let (k, n) = wait()
        if k != pElement or n.tag != "proceed": raise newException(IOError, "the server refused TLS")
        let ca = caFile()
        let ctx = newContext(verifyMode = (if cfg.insecure: CVerifyNone else: CVerifyPeer), caFile = ca)
        wrapConnectedSocket(ctx, sock, handshakeAsClient, domain)
        r.buf = ""
        emit(xeConnecting, "Secured")
        put(streamOpen(domain))
        f = features()
      elif not cfg.insecure:
        raise newException(IOError, "the server offers no encryption")
    if cfg.register:
      # in-band registration (XEP-0077)
      let q = iq("<iq type='get' id='reg1' to='" & esc(domain) & "'><query xmlns='jabber:iq:register'/></iq>", "reg1")
      if q.attr("type") == "error":
        raise newException(IOError, "this server does not make accounts from apps")
      let query = q.child("query")
      if query != nil and query.child("x") != nil:
        var needs: seq[string]
        for fld in query.child("x").findAll("field"):
          let v = fld.attr("var")
          if fld.child("required") != nil and v notin ["username", "password", "FORM_TYPE"]: needs.add v
        if needs.len > 0:
          var url = ""
          for u in query.findAll("url"): url = u.innerText
          raise newException(IOError, "this server asks for more (" & needs.join(", ") &
                             (if url.len > 0: "): make the account at " & url else: ")"))
      let a = iq("<iq type='set' id='reg2' to='" & esc(domain) & "'><query xmlns='jabber:iq:register'>" &
                 "<username>" & esc(localOf(cfg.jid)) & "</username><password>" & esc(cfg.password) &
                 "</password></query></iq>", "reg2")
      if a.attr("type") == "result":
        emit(xeRegistered, jid = bareJid(cfg.jid))
      else:
        let e = a.child("error")
        var why = "the server would not make it"
        if e != nil:
          if e.child("conflict") != nil: why = "that name is taken"
          elif e.child("not-acceptable") != nil: why = "the server does not accept that name or password"
          elif e.child("not-allowed") != nil or e.child("forbidden") != nil:
            why = "this server does not make accounts from apps"
          elif e.child("resource-constraint") != nil: why = "too many accounts made from here: try later"
          let t = e.child("text")
          if t != nil and t.innerText.len > 0: why &= " (" & t.innerText & ")"
        emit(xeError, why)
      put(streamClose)
      closeSock()
      emit(xeOffline)
      return
    # signing on: SASL PLAIN, inside TLS
    let mechs = f.child("mechanisms")
    var plain = false
    if mechs != nil:
      for m in mechs.findAll("mechanism"):
        if m.innerText == "PLAIN": plain = true
    if not plain: raise newException(IOError, "the server does not take a password this app can give")
    emit(xeConnecting, "Signing on")
    put("<auth xmlns='urn:ietf:params:xml:ns:xmpp-sasl' mechanism='PLAIN'>" &
        encode("\0" & localOf(cfg.jid) & "\0" & cfg.password) & "</auth>")
    let (ak, an) = wait()
    if ak != pElement or an.tag != "success":
      var why = "the address or the password is wrong"
      if an != nil and an.child("account-disabled") != nil: why = "this account is disabled"
      raise newException(IOError, why)
    r.buf = ""
    put(streamOpen(domain))
    f = features()
    let b = iq("<iq type='set' id='bind1'><bind xmlns='urn:ietf:params:xml:ns:xmpp-bind'><resource>" &
               esc(cfg.resource) & "</resource></bind></iq>", "bind1")
    var full = bareJid(cfg.jid) & "/" & cfg.resource
    if b.child("bind") != nil and b.child("bind").child("jid") != nil:
      full = b.child("bind").child("jid").innerText
    let sess = f.child("session")
    if sess != nil and sess.child("optional") == nil:
      discard iq("<iq type='set' id='sess1'><session xmlns='urn:ietf:params:xml:ns:xmpp-session'/></iq>", "sess1")
    put("<iq type='get' id='roster1'><query xmlns='jabber:iq:roster'/></iq>")
    put("<iq type='set' id='carbons1'><enable xmlns='urn:xmpp:carbons:2'/></iq>")
    put("<iq type='get' id='disco1' to='" & esc(domain) & "'><query xmlns='http://jabber.org/protocol/disco#items'/></iq>")
    # (the account's own features: the message archive is the account's)
    put("<iq type='get' id='info-" & esc(bareJid(full)) & "' to='" & esc(bareJid(full)) &
        "'><query xmlns='http://jabber.org/protocol/disco#info'/></iq>")
    var pres = "<presence>"
    if cfg.show.len > 0: pres &= "<show>" & esc(cfg.show) & "</show>"
    if cfg.status.len > 0: pres &= "<status>" & esc(cfg.status) & "</status>"
    pres &= "<priority>5</priority></presence>"
    put(pres)
    emit(XmppEvent(kind: xeOnline, jid: full))

    proc contactOf(item: XmlNode): Contact =
      result = Contact(jid: item.attr("jid"), name: item.attr("name"),
                       subscription: item.attr("subscription"), ask: item.attr("ask") == "subscribe")
      if result.subscription.len == 0: result.subscription = "none"
      for g in item.findAll("group"): result.groups.add g.innerText

    var discoLeft = 0
    proc handle(n: XmlNode) =
      case n.tag
      of "iq":
        let typ = n.attr("type")
        let id = n.attr("id")
        let q = n.child("query")
        if typ in ["get", "set"]:
          # (the server's questions: a ping, the list changed, what this client is)
          if n.child("ping") != nil or (q != nil and q.attr("xmlns") == "jabber:iq:roster" and typ == "set"):
            if q != nil:
              var cs: seq[Contact]
              var gone = false
              for it in q.findAll("item"):
                let c = contactOf(it)
                if c.subscription == "remove": gone = true
                cs.add c
              emit(XmppEvent(kind: xeRoster, contacts: cs, removed: gone))
            put("<iq type='result' id='" & esc(id) & "' to='" & esc(n.attr("from")) & "'/>")
          elif q != nil and q.attr("xmlns") == "http://jabber.org/protocol/disco#info":
            put("<iq type='result' id='" & esc(id) & "' to='" & esc(n.attr("from")) & "'>" &
                "<query xmlns='http://jabber.org/protocol/disco#info'><identity category='client' type='pc' name='Retro Communicator'/>" &
                "<feature var='http://jabber.org/protocol/chatstates'/><feature var='urn:xmpp:receipts'/>" &
                "<feature var='jabber:x:oob'/><feature var='urn:xmpp:ping'/>" &
                "<feature var='eu.siacs.conversations.axolotl.devicelist+notify'/></query></iq>")
          elif q != nil and q.attr("xmlns") == "jabber:iq:version":
            put("<iq type='result' id='" & esc(id) & "' to='" & esc(n.attr("from")) & "'>" &
                "<query xmlns='jabber:iq:version'><name>Retro Communicator</name><version>1</version></query></iq>")
          else:
            put("<iq type='error' id='" & esc(id) & "' to='" & esc(n.attr("from")) & "'><error type='cancel'>" &
                "<service-unavailable xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/></error></iq>")
          return
        if id.startsWith("q-"):
          # (asked with an id of its own: the answer, whole, to whoever asked)
          emit(XmppEvent(kind: xeStanza, id: id, text: $n))
          return
        if typ == "error":
          let e = n.child("error")
          var why = "the server refused it"
          if e != nil and e.child("text") != nil: why = e.child("text").innerText
          elif e != nil and e.len > 0: why = e[0].tag.replace("-", " ")
          emit(xeError, why, id = id)
          return
        let fin = n.child("fin")
        if fin != nil and fin.attr("xmlns") == "urn:xmpp:mam:2":
          # (the end of an archive's answer: where it stopped, for the next page)
          var ev = XmppEvent(kind: xeArchiveDone, id: id,
                             show: (if fin.attr("complete") == "true": "complete" else: ""))
          let st = fin.child("set")
          if st != nil:
            if st.child("last") != nil: ev.text = st.child("last").innerText
            if st.child("first") != nil: ev.fields.add ("first", st.child("first").innerText)
            if st.child("count") != nil: ev.fields.add ("count", st.child("count").innerText)
          emit(ev)
          return
        if id == "roster1" and q != nil:
          var cs: seq[Contact]
          for it in q.findAll("item"): cs.add contactOf(it)
          emit(XmppEvent(kind: xeRoster, contacts: cs))
        elif id == "disco1" and q != nil:
          # (the services: each asked what it is)
          for it in q.findAll("item"):
            inc discoLeft
            put("<iq type='get' id='info-" & esc(it.attr("jid")) & "' to='" & esc(it.attr("jid")) &
                "'><query xmlns='http://jabber.org/protocol/disco#info'/></iq>")
        elif id.startsWith("info-") and q != nil:
          let who = n.attr("from")
          var fs: seq[(string, string)]
          for ft in q.findAll("feature"):
            if ft.attr("var") == "urn:xmpp:http:upload:0": fs.add ("upload", who)
            if ft.attr("var") == "urn:xmpp:mam:2" and bareJid(who) == bareJid(full): fs.add ("archive", who)
          for idn in q.findAll("identity"):
            if idn.attr("category") == "conference" and idn.attr("type") == "text": fs.add ("rooms", who)
          if fs.len > 0: emit(XmppEvent(kind: xeServices, fields: fs))
        elif n.child("vCard") != nil:
          var fs: seq[(string, string)]
          let v = n.child("vCard")
          for k in ["FN", "NICKNAME", "DESC", "URL", "BDAY"]:
            if v.child(k) != nil: fs.add (k, v.child(k).innerText)
          let ph = v.child("PHOTO")
          if ph != nil:
            if ph.child("BINVAL") != nil: fs.add ("PHOTO", ph.child("BINVAL").innerText.multiReplace(("\n", ""), ("\r", ""), (" ", "")))
            if ph.child("TYPE") != nil: fs.add ("TYPE", ph.child("TYPE").innerText)
          let sender = n.attr("from")
          emit(XmppEvent(kind: xeVcard, jid: (if sender.len > 0: bareJid(sender) else: bareJid(full)), fields: fs))
        elif n.child("slot") != nil:
          let s = n.child("slot")
          var ev = XmppEvent(kind: xeSlot, id: id)
          if s.child("put") != nil:
            ev.putUrl = s.child("put").attr("url")
            for h in s.child("put").findAll("header"): ev.headers.add (h.attr("name"), h.innerText)
          if s.child("get") != nil: ev.url = s.child("get").attr("url")
          emit(ev)
      of "presence":
        let sender = n.attr("from")
        let typ = n.attr("type")
        let mucx = block:
          var m: XmlNode = nil
          for x in n.findAll("x"):
            if x.attr("xmlns") == "http://jabber.org/protocol/muc#user": m = x
          m
        if mucx != nil:
          emit(XmppEvent(kind: xeRoomPresence, jid: bareJid(sender), resource: resourceOf(sender),
                         show: (if typ == "unavailable": "unavailable" elif n.child("show") != nil: n.child("show").innerText else: "")))
          return
        case typ
        of "subscribe":
          var nick = ""
          for x in n.findAll("nick"): nick = x.innerText
          emit(XmppEvent(kind: xeAsk, jid: bareJid(sender), text: nick))
        of "subscribed", "unsubscribed":
          emit(XmppEvent(kind: xeAnswer, jid: bareJid(sender), show: typ))
        of "error":
          if n.child("error") != nil and resourceOf(sender).len > 0:
            emit(xeError, "could not join " & bareJid(sender), jid = bareJid(sender))
        else:
          var show = if typ == "unavailable": "unavailable" else: ""
          if show.len == 0 and n.child("show") != nil: show = n.child("show").innerText
          let st = if n.child("status") != nil: n.child("status").innerText else: ""
          emit(XmppEvent(kind: xePresence, jid: bareJid(sender), resource: resourceOf(sender), show: show, text: st))
      of "message":
        # a message from the archive, asked for with askArchive (only the
        # account's own server answers that: from nobody, or the account)
        let res = n.child("result")
        if res != nil and res.attr("xmlns") == "urn:xmpp:mam:2":
          if n.attr("from").len > 0 and bareJid(n.attr("from")) != bareJid(full): return
          let fw = res.child("forwarded")
          if fw == nil or fw.child("message") == nil: return
          let am = fw.child("message")
          let locked = am.child("encrypted") != nil
          if am.attr("type") == "groupchat" or am.attr("type") == "error" or (am.child("body") == nil and not locked): return
          var stamp = ""
          if fw.child("delay") != nil: stamp = fw.child("delay").attr("stamp")
          let mine = bareJid(am.attr("from")) == bareJid(full)
          var url = ""
          for x in am.findAll("x"):
            if x.attr("xmlns") == "jabber:x:oob" and x.child("url") != nil: url = x.child("url").innerText
          emit(XmppEvent(kind: xeArchived, jid: bareJid(if mine: am.attr("to") else: am.attr("from")),
                         text: (if am.child("body") != nil: am.child("body").innerText else: ""), id: am.attr("id"),
                         stamp: stamp, url: url, mine: mine, archiveId: res.attr("id"), resource: res.attr("queryid"),
                         raw: (if locked: $am else: "")))
          return
        var m = n
        var carbon = false
        # (a carbon: a message of this account, sent or received on another device)
        for tag in ["received", "sent"]:
          let c = n.child(tag)
          if c != nil and c.attr("xmlns") == "urn:xmpp:carbons:2" and bareJid(n.attr("from")) == bareJid(full):
            let fw = c.child("forwarded")
            if fw != nil and fw.child("message") != nil:
              m = fw.child("message")
              carbon = tag == "sent"
        # (a server's notice: what someone published changed)
        for ev in n.findAll("event"):
          if ev.attr("xmlns") == "http://jabber.org/protocol/pubsub#event":
            emit(XmppEvent(kind: xeStanza, text: $n))
            return
        let typ = m.attr("type")
        let sender = m.attr("from")
        var stamp = ""
        for d in m.findAll("delay"): stamp = d.attr("stamp")
        if typ == "error":
          emit(xeError, "a message to " & bareJid(sender) & " did not go", id = m.attr("id"))
          return
        if typ == "groupchat":
          if m.child("subject") != nil and m.child("body") == nil:
            emit(XmppEvent(kind: xeRoomSubject, jid: bareJid(sender), text: m.child("subject").innerText))
          elif m.child("body") != nil:
            emit(XmppEvent(kind: xeRoomMessage, jid: bareJid(sender), resource: resourceOf(sender),
                           text: m.child("body").innerText, stamp: stamp, id: m.attr("id")))
          return
        let other = if carbon: bareJid(m.attr("to")) else: bareJid(sender)
        for st in ["composing", "paused", "active", "inactive", "gone"]:
          let c = m.child(st)
          if c != nil and c.attr("xmlns") == "http://jabber.org/protocol/chatstates" and not carbon:
            emit(XmppEvent(kind: xeState, jid: other, show: st))
        let rc = m.child("received")
        if rc != nil and rc.attr("xmlns") == "urn:xmpp:receipts":
          emit(XmppEvent(kind: xeReceipt, jid: other, id: rc.attr("id")))
        let locked = m.child("encrypted") != nil
        if m.child("body") != nil or locked:
          var url = ""
          for x in m.findAll("x"):
            if x.attr("xmlns") == "jabber:x:oob" and x.child("url") != nil: url = x.child("url").innerText
          # (its id in the archive, given by the account's server)
          var aid = ""
          for sid in n.findAll("stanza-id"):
            if sid.attr("xmlns") == "urn:xmpp:sid:0" and sid.attr("by") == bareJid(full): aid = sid.attr("id")
          emit(XmppEvent(kind: xeMessage, jid: other, resource: resourceOf(sender),
                         text: (if m.child("body") != nil: m.child("body").innerText else: ""),
                         id: m.attr("id"), stamp: stamp, url: url, carbon: carbon, archiveId: aid,
                         raw: (if locked: $m else: "")))
          # (a receipt asked for: given)
          let rq = m.child("request")
          if rq != nil and rq.attr("xmlns") == "urn:xmpp:receipts" and not carbon and m.attr("id").len > 0:
            put("<message to='" & esc(sender) & "'><received xmlns='urn:xmpp:receipts' id='" & esc(m.attr("id")) & "'/></message>")
      else: discard

    # the session: what comes, what is sent, a space now and then to keep it open
    while true:
      while true:
        let (k, n) = r.next()
        if k == pNone: break
        if k == pEnd: raise newException(IOError, "the server ended the session")
        if k == pElement: handle(n)
      var quit = false
      for msg in takeOut():
        if msg == "\0quit":
          quit = true
          break
        put(msg)
      if quit:
        put("<presence type='unavailable'/>")
        put(streamClose)
        closeSock()
        emit(xeOffline)
        return
      # (a space now and then keeps it open; a WebSocket takes whole stanzas only: a ping)
      if epochTime() - lastSend > 50:
        put(when defined(wasm): "<iq type='get' id='keepalive'><ping xmlns='urn:xmpp:ping'/></iq>" else: " ")
      if not pump(200): raise newException(IOError, "the connection was lost")
  except CatchableError as e:
    try: closeSock()
    except CatchableError: discard
    emit(xeError, e.msg)
    emit(xeOffline, e.msg)

# ---- the app's side --------------------------------------------------------------------------------

proc xmppRunning*(): bool = running
  ## A connection is open (or being made).

proc xmppStart*(jid, password: string; host = ""; port = 0; insecure = false;
                resource = "Retro"; show = ""; status = ""; register = false) =
  ## Signs on as `jid` (`register`: makes that account first, then ends --
  ## xeRegistered or xeError says how it went). `show`, `status`: the first
  ## presence ("" available, "away", "dnd", "xa").
  if running: return
  randomize()
  initLock(lock)
  withLock lock:
    outbox = @[]
    inbox = @[]
  running = true
  myJid = ""
  when defined(wasm) and not compileOption("threads"):
    withLock lock:
      inbox.add XmppEvent(kind: xeError, text: "chat in a web page needs threads (retrokit web --threads)")
      inbox.add XmppEvent(kind: xeOffline, text: "no threads")
  else:
    createThread(worker, runWorker, Config(jid: jid, password: password, host: host, port: port,
                 insecure: insecure, register: register, resource: resource, show: show, status: status))

proc xmppEvents*(): seq[XmppEvent] =
  ## What came since the last call (call it every frame).
  if not running: return
  var got: seq[XmppEvent]
  withLock lock:
    got = move inbox
    inbox = @[]
  for e in got:
    if e.kind == xeOnline: myJid = e.jid
    result.add e
    if e.kind == xeOffline:
      running = false
      when not defined(wasm) or compileOption("threads"): joinThread(worker)
      return

proc xmppSend*(xml: string) =
  ## A stanza as it is (for what the procs below do not cover).
  if running:
    withLock lock: outbox.add xml

proc xmppStop*() =
  ## Signs off.
  if running:
    withLock lock: outbox.add "\0quit"

proc newId*(): string =
  ## An id for a message or a request.
  for _ in 0 ..< 12: result.add "abcdefghijklmnopqrstuvwxyz0123456789"[rand(35)]

proc sendChat*(to, body: string; url = ""): string =
  ## A message to `to`; its id (a receipt names it when it arrives).
  result = newId()
  var x = "<message to='" & esc(to) & "' type='chat' id='" & result & "'><body>" & esc(body) & "</body>" &
          "<active xmlns='http://jabber.org/protocol/chatstates'/><request xmlns='urn:xmpp:receipts'/>"
  if url.len > 0: x &= "<x xmlns='jabber:x:oob'><url>" & esc(url) & "</url></x>"
  xmppSend(x & "</message>")

proc sendState*(to, state: string) =
  ## Typing: "composing", "paused", "active", "inactive", "gone".
  xmppSend("<message to='" & esc(to) & "' type='chat'><" & state &
           " xmlns='http://jabber.org/protocol/chatstates'/></message>")

proc setPresence*(show, status: string) =
  ## "" available, "away", "dnd" busy, "xa" away for long; `status` the words.
  var x = "<presence>"
  if show.len > 0: x &= "<show>" & esc(show) & "</show>"
  if status.len > 0: x &= "<status>" & esc(status) & "</status>"
  xmppSend(x & "<priority>5</priority></presence>")

proc goInvisible*() =
  ## Seen as signed off by everyone (the contacts' presence still comes).
  xmppSend("<presence type='unavailable'/>")

proc addContact*(jid, name: string; groups: seq[string] = @[]) =
  ## `jid` on the list, and asked to let you see them.
  var x = "<iq type='set' id='" & newId() & "'><query xmlns='jabber:iq:roster'><item jid='" & esc(jid) & "'"
  if name.len > 0: x &= " name='" & esc(name) & "'"
  x &= ">"
  for g in groups: x &= "<group>" & esc(g) & "</group>"
  xmppSend(x & "</item></query></iq>")
  xmppSend("<presence to='" & esc(jid) & "' type='subscribe'/>")

proc changeContact*(jid, name: string; groups: seq[string]) =
  ## A contact renamed, or put in other groups.
  var x = "<iq type='set' id='" & newId() & "'><query xmlns='jabber:iq:roster'><item jid='" & esc(jid) & "'"
  if name.len > 0: x &= " name='" & esc(name) & "'"
  x &= ">"
  for g in groups: x &= "<group>" & esc(g) & "</group>"
  xmppSend(x & "</item></query></iq>")

proc removeContact*(jid: string) =
  ## Takes someone off your contact list (and ends seeing each other's presence).
  xmppSend("<iq type='set' id='" & newId() & "'><query xmlns='jabber:iq:roster'><item jid='" & esc(jid) &
           "' subscription='remove'/></query></iq>")

proc answerAsk*(jid: string; yes: bool) =
  ## Someone asked to add you: let them see your presence (and ask to see
  ## theirs), or not.
  if yes:
    xmppSend("<presence to='" & esc(jid) & "' type='subscribed'/>")
    xmppSend("<presence to='" & esc(jid) & "' type='subscribe'/>")
  else:
    xmppSend("<presence to='" & esc(jid) & "' type='unsubscribed'/>")

proc askVcard*(jid: string) =
  ## Someone's profile (`jid` "": yours); it comes as xeVcard.
  let to = if jid.len > 0: " to='" & esc(jid) & "'" else: ""
  xmppSend("<iq type='get' id='" & newId() & "'" & to & "><vCard xmlns='vcard-temp'/></iq>")

proc setVcard*(fields: openArray[(string, string)]) =
  ## Your profile: FN, NICKNAME, DESC, URL; PHOTO (base64) with TYPE.
  var x = "<iq type='set' id='" & newId() & "'><vCard xmlns='vcard-temp'>"
  var photo, kind = ""
  for (k, v) in fields:
    if k == "PHOTO": photo = v
    elif k == "TYPE": kind = v
    elif v.len > 0: x &= "<" & k & ">" & esc(v) & "</" & k & ">"
  if photo.len > 0: x &= "<PHOTO><TYPE>" & esc(kind) & "</TYPE><BINVAL>" & photo & "</BINVAL></PHOTO>"
  xmppSend(x & "</vCard></iq>")

proc joinRoom*(room, nick: string; history = 20) =
  ## A chat room (room@conference.server), with your nickname there.
  xmppSend("<presence to='" & esc(room & "/" & nick) & "'><x xmlns='http://jabber.org/protocol/muc'>" &
           "<history maxstanzas='" & $history & "'/></x></presence>")

proc leaveRoom*(room, nick: string) =
  ## Leaves a room joined with `joinRoom`.
  xmppSend("<presence to='" & esc(room & "/" & nick) & "' type='unavailable'/>")

proc sendRoom*(room, body: string; url = "") =
  ## A message to everyone in a room (`url`: a file sent with it, as `sendChat`).
  var x = "<message to='" & esc(room) & "' type='groupchat' id='" & newId() & "'><body>" & esc(body) & "</body>"
  if url.len > 0: x &= "<x xmlns='jabber:x:oob'><url>" & esc(url) & "</url></x>"
  xmppSend(x & "</message>")

proc askUpload*(service, filename: string; size: int64; mime: string): string =
  ## A place to put a file (HTTP upload, XEP-0363): its id; the slot comes
  ## as xeSlot with that id (PUT the file there, send its `url`).
  result = newId()
  xmppSend("<iq type='get' id='" & result & "' to='" & esc(service) & "'><request xmlns='urn:xmpp:http:upload:0' " &
           "filename='" & esc(filename) & "' size='" & $size & "' content-type='" & esc(mime) & "'/></iq>")

proc askArchive*(with = ""; after = ""; before = ""; latest = false; start = ""; max = 50): string =
  ## The server's archive of your messages (XEP-0313; xeServices says
  ## "archive" when it keeps one): those with `with` ("" everyone's), after
  ## the one whose archiveId is `after`, or before `before`, or the
  ## `latest`, or since `start` (ISO 8601), `max` at most. They come as
  ## xeArchived in the order they were said, then xeArchiveDone (with the
  ## last one's id: ask `after` it for the next page). Its id.
  result = newId()
  var x = "<iq type='set' id='" & result & "'><query xmlns='urn:xmpp:mam:2' queryid='" & result & "'>" &
          "<x xmlns='jabber:x:data' type='submit'><field var='FORM_TYPE' type='hidden'>" &
          "<value>urn:xmpp:mam:2</value></field>"
  if with.len > 0: x &= "<field var='with'><value>" & esc(with) & "</value></field>"
  if start.len > 0: x &= "<field var='start'><value>" & esc(start) & "</value></field>"
  x &= "</x><set xmlns='http://jabber.org/protocol/rsm'><max>" & $max & "</max>"
  if after.len > 0: x &= "<after>" & esc(after) & "</after>"
  elif before.len > 0: x &= "<before>" & esc(before) & "</before>"
  elif latest: x &= "<before/>"
  xmppSend(x & "</set></query></iq>")
