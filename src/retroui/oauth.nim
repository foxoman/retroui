## Signing in with OAuth 2.0 -- Microsoft 365 (Entra ID), Google -- the
## way RFC 8252 asks of apps: the sign-in page opens in the user's own
## browser (no browser inside the app, so the password, the passkey and
## the company's sign-in rules stay the browser's), the request carries a
## PKCE challenge (S256), and the answer comes back to a small server of
## the app's on 127.0.0.1, on a free port, for the time of the sign-in.
##
## .. code-block:: nim
##   let ms = microsoftProvider(clientId,
##              scopes = ["https://graph.microsoft.com/Mail.ReadWrite"])
##   var flow = beginSignIn(ms, loginHint = "sultan@example.com")
##   # every frame:
##   case flow.state
##   of osWaiting: label "Finish signing in in your browser"
##   of osDone: tokens = flow.tokens          # keep them: retroui/secrets
##   of osFailed: label flow.error
##   of osCancelled: discard
##   # before requests, on any thread:
##   let err = ms.ensureFresh(tokens)
##   if err.len == 0: headers.add ("Authorization", "Bearer " & tokens.accessToken)
##
## The waiting happens on a thread of its own: `state` only looks. A
## sign-in ends after 10 minutes without an answer; the port is let go
## when it ends or is cancelled. The page the browser shows at the end is
## plain HTML (no script) saying it worked, or what failed.
##
## Microsoft: register the app in Entra ("Mobile and desktop
## applications", redirect address `http://localhost`); it has no secret.
## Google: a "Desktop app" client; its secret is not secret, and it is
## needed. Both providers ask for `openid`, `email` and `profile` too
## (`claims` then has the name and address), and Microsoft for
## `offline_access` (a refresh token).

import std/[json, strutils, times, locks, net, nativesockets, selectors, sysrand, base64, typedthreads]
import http, sha2, core
from codec import unbase64
import uirelays/services

type
  OAuthProvider* = object
    ## A service that signs users in, and what it needs to know of the app.
    name*, authUrl*, tokenUrl*: string  ## the sign-in page, and where codes become tokens
    clientId*, clientSecret*: string    ## Google's desktop clients have a "secret" that is needed (not secret); Microsoft: ""
    scopes*: seq[string]                ## what the app asks to do
    authParams*: seq[(string, string)]  ## more parameters for the sign-in page
    redirectHost*: string               ## "localhost" or "127.0.0.1" (the default) in the redirect address
    scopeOnRefresh*: bool               ## send the scopes when refreshing (Microsoft wants them)

  OAuthTokens* = object
    ## What a sign-in brings: keep it (`%`, `toTokens`, `retroui/secrets`).
    accessToken*, refreshToken*, idToken*, scope*: string
      ## the token the API takes, the one that gets a new one (`refresh`),
      ## the OpenID token (who signed in), and the scopes granted
    expiresAt*: float                   ## epochTime() when the access token ends

  OAuthState* = enum
    ## Where a sign-in is.
    osWaiting,                          ## for the user, in the browser
    osDone,                             ## signed in: `tokens`
    osFailed,                           ## `error` says why
    osCancelled                         ## `cancel` was called

  Link = object
    slot: int                           # the flow's slot while its thread may still write it; -1 after

  FlowObj = object
    link: Link
    st: OAuthState
    toks: OAuthTokens
    err, address: string

  OAuthFlow* = ref FlowObj
    ## A sign-in in progress.

const
  signInSeconds = 600.0                 # how long the user has
  maxSlots = 8                          # sign-ins at once

type
  Job = object
    slot: int
    provider: OAuthProvider
    verifier, expected, redirect: string
    listeners: seq[(SocketHandle, Domain)]

  Slot = object
    inUse, attached, finished, cancel: bool
    state: OAuthState
    tokens: OAuthTokens
    error: string
    thread: Thread[Job]

var
  signInLock: Lock
  slots: array[maxSlots, Slot]          # guarded by signInLock

initLock(signInLock)

# ---- small parts ----------------------------------------------------------------------------

proc b64url(data: string): string =
  ## base64url without padding (RFC 4648, section 5).
  encode(data, safe = true).strip(leading = false, chars = {'='})

proc unb64url(s: string): string =
  var t = s.multiReplace(("-", "+"), ("_", "/"))
  while t.len mod 4 != 0: t.add '='
  try: unbase64(t) except ValueError: ""

proc randomText(bytes: int): string =
  var b = newString(bytes)
  if not urandom(b.toOpenArrayByte(0, bytes - 1)):
    raise newException(OSError, "no random numbers")
  b64url(b)

proc withBasics(scopes: openArray[string]; basics: openArray[string]): seq[string] =
  for s in scopes:
    if s notin result: result.add s
  for s in basics:
    if s notin result: result.add s

proc microsoftProvider*(clientId: string; tenant = "organizations";
                        scopes: openArray[string]): OAuthProvider =
  ## Microsoft's sign-in (Entra ID, Microsoft 365): `tenant` is
  ## "organizations" (work and school accounts), "common" (personal ones
  ## too), "consumers" or the organization's own id or domain.
  ## Scopes such as "https://graph.microsoft.com/Mail.ReadWrite".
  let base = "https://login.microsoftonline.com/" & tenant & "/oauth2/v2.0/"
  OAuthProvider(name: "Microsoft", authUrl: base & "authorize", tokenUrl: base & "token",
                clientId: clientId,
                scopes: withBasics(scopes, ["openid", "profile", "email", "offline_access"]),
                redirectHost: "localhost", scopeOnRefresh: true)

proc googleProvider*(clientId, clientSecret: string; scopes: openArray[string]): OAuthProvider =
  ## Google's sign-in, for a "Desktop app" client (`clientSecret` is the
  ## one Google gives it). Asks for a refresh token every time
  ## (`access_type=offline`, `prompt=consent`). Scopes such as
  ## "https://mail.google.com/".
  OAuthProvider(name: "Google", authUrl: "https://accounts.google.com/o/oauth2/v2/auth",
                tokenUrl: "https://oauth2.googleapis.com/token",
                clientId: clientId, clientSecret: clientSecret,
                scopes: withBasics(scopes, ["openid", "email", "profile"]),
                authParams: @[("access_type", "offline"), ("prompt", "consent")],
                redirectHost: "127.0.0.1")

proc `%`*(t: OAuthTokens): JsonNode =
  ## The tokens as JSON, to keep (`$(%tokens)` into `saveSecret`).
  %*{"accessToken": t.accessToken, "refreshToken": t.refreshToken, "idToken": t.idToken,
     "scope": t.scope, "expiresAt": t.expiresAt}

proc toTokens*(j: JsonNode): OAuthTokens =
  ## Tokens from what `%` made (what is missing stays empty).
  if j.isNil or j.kind != JObject: return
  result.accessToken = j{"accessToken"}.getStr
  result.refreshToken = j{"refreshToken"}.getStr
  result.idToken = j{"idToken"}.getStr
  result.scope = j{"scope"}.getStr
  result.expiresAt = j{"expiresAt"}.getFloat

proc claims*(t: OAuthTokens): JsonNode =
  ## The id token's payload ("email", "name", "preferred_username"...), for
  ## showing who signed in. Its signature is not checked: not for deciding
  ## anything. An empty object when there is none.
  let parts = t.idToken.split('.')
  if parts.len >= 2:
    try:
      result = parseJson(unb64url(parts[1]))
      if result.kind == JObject: return
    except CatchableError: discard
  newJObject()

# ---- the token endpoint ---------------------------------------------------------------------

proc readable(code, description: string): string =
  ## A token endpoint's error in words, with its own after.
  let said = block:
    var d = description.splitLines()[0].strip
    let trace = d.find(" Trace ID:")
    if trace > 0: d.setLen(trace)
    d
  let words = case code
    of "invalid_grant": "the sign-in is no longer valid (it ran out, was revoked, or the password changed): sign in again"
    of "invalid_client", "unauthorized_client": "the app's client id or secret was refused"
    of "invalid_scope": "a permission the app asks for was refused"
    of "access_denied": "the sign-in was refused or cancelled"
    of "consent_required", "interaction_required": "the account must sign in again in the browser"
    of "invalid_request": "the sign-in request was refused"
    of "temporarily_unavailable", "server_error": "the sign-in service has a problem; try again later"
    else: "the sign-in failed"
  result = words & " (" & code
  if said.len > 0: result.add ": " & said
  result.add ")"

proc tokenRequest(p: OAuthProvider; fields: seq[(string, string)]; got: var OAuthTokens): string {.gcsafe.} =
  ## Posts `fields` to the token endpoint; "" when tokens came back.
  var all = fields
  all.add ("client_id", p.clientId)
  if p.clientSecret.len > 0: all.add ("client_secret", p.clientSecret)
  let r = httpRequest("POST", p.tokenUrl, {"Content-Type": "application/x-www-form-urlencoded",
                                           "Accept": "application/json"}, body = formEncode(all))
  if r.status == 0: return "could not reach " & p.name & ": " & r.error
  var j: JsonNode
  try: j = parseJson(r.body)
  except CatchableError: j = nil
  if j.isNil or j.kind != JObject:
    return p.name & " answered " & $r.status & " without tokens"
  if j.hasKey("error"):
    return readable(j{"error"}.getStr, j{"error_description"}.getStr)
  if not r.ok or j{"access_token"}.getStr.len == 0:
    return p.name & " answered " & $r.status & " without tokens"
  got.accessToken = j{"access_token"}.getStr
  got.refreshToken = j{"refresh_token"}.getStr
  got.idToken = j{"id_token"}.getStr
  got.scope = j{"scope"}.getStr
  let e = j{"expires_in"}
  let seconds = if e.isNil: 3600.0
                elif e.kind == JString: (try: parseFloat(e.getStr) except ValueError: 3600.0)
                else: e.getFloat
  got.expiresAt = epochTime() + seconds
  ""

proc refresh*(p: OAuthProvider; t: var OAuthTokens): string {.gcsafe.} =
  ## New tokens for `t` with its refresh token: "" when it worked (`t` has
  ## them), else why not. Keeps the old refresh token (and id token) when
  ## no new one comes back.
  if t.refreshToken.len == 0: return "there is no refresh token: sign in again"
  var fields = @[("grant_type", "refresh_token"), ("refresh_token", t.refreshToken)]
  if p.scopeOnRefresh and p.scopes.len > 0: fields.add ("scope", p.scopes.join(" "))
  var got: OAuthTokens
  result = tokenRequest(p, fields, got)
  if result.len > 0: return
  if got.refreshToken.len == 0: got.refreshToken = t.refreshToken
  if got.idToken.len == 0: got.idToken = t.idToken
  if got.scope.len == 0: got.scope = t.scope
  t = got

proc ensureFresh*(p: OAuthProvider; t: var OAuthTokens; margin = 120.0): string {.gcsafe.} =
  ## Refreshes `t` when its access token ends within `margin` seconds: ""
  ## when it is good to use (a refresh that failed while the old token
  ## still has time is tried again next call). Threads that share tokens
  ## should take turns.
  let left = t.expiresAt - epochTime()
  if t.accessToken.len > 0 and left > margin: return ""
  result = refresh(p, t)
  if result.len > 0 and t.accessToken.len > 0 and left > 10: result = ""

# ---- the loopback server (on its own thread) ------------------------------------------------

proc page(title, text: string): string =
  ## The small page the browser shows.
  proc esc(s: string): string =
    s.multiReplace(("&", "&amp;"), ("<", "&lt;"), (">", "&gt;"), ("\"", "&quot;"))
  "<!DOCTYPE html>\n<html><head><meta charset=\"utf-8\"><title>" & esc(title) &
    "</title>\n<style>body{font:16px/1.5 system-ui,sans-serif;margin:4em auto;max-width:34em;" &
    "padding:0 1em;color:#222}h1{font-size:1.4em}</style></head>\n<body><h1>" & esc(title) &
    "</h1><p>" & esc(text) & "</p></body></html>\n"

proc reply(c: Socket; status: int; html: string) =
  let reason = case status
               of 200: "OK"
               of 400: "Bad Request"
               of 404: "Not Found"
               else: "Error"
  try:
    c.send("HTTP/1.1 " & $status & " " & reason & "\r\nContent-Type: text/html; charset=utf-8\r\n" &
           "Content-Length: " & $html.len & "\r\nCache-Control: no-store\r\n" &
           "Referrer-Policy: no-referrer\r\nConnection: close\r\n\r\n" & html)
  except OSError, IOError: discard

proc finish(slot: int; state: OAuthState; tokens: OAuthTokens; error: string) =
  withLock signInLock:
    let s = addr slots[slot]
    if s.state == osWaiting:
      s.state = state
      s.tokens = tokens
      s.error = error

proc cancelled(slot: int): bool =
  withLock signInLock:
    result = slots[slot].cancel

proc listen(job: Job) {.thread.} =
  {.cast(gcsafe).}:
    let p = job.provider
    let deadline = epochTime() + signInSeconds
    var sel = newSelector[int]()
    var listeners: seq[Socket]
    for (fd, domain) in job.listeners:
      let l = newSocket(fd, domain, SOCK_STREAM, IPPROTO_TCP, buffered = false)
      listeners.add l
      sel.registerHandle(fd, {Event.Read}, -1)
    var clients: seq[tuple[sock: Socket; data: string; since: float]]

    proc drop(i: int) =
      try: sel.unregister(clients[i].sock.getFd)
      except CatchableError: discard
      clients[i].sock.close()
      clients.delete(i)

    var outcome = osWaiting
    var tokens: OAuthTokens
    var error = ""
    while outcome == osWaiting:
      if cancelled(job.slot):
        outcome = osCancelled
        break
      if epochTime() > deadline:
        outcome = osFailed
        error = "the sign-in took too long (10 minutes); sign in again"
        break
      var ready: seq[ReadyKey]
      try: ready = sel.select(200)
      except CatchableError: ready = @[]
      for k in ready:
        if outcome != osWaiting: break
        let fd = SocketHandle(k.fd)
        var listener = false
        for l in listeners:
          if l.getFd == fd:                             # a new client
            listener = true
            var c: Socket
            try:
              l.accept(c)
              clients.add (c, "", epochTime())
              sel.registerHandle(c.getFd, {Event.Read}, 0)
            except CatchableError: discard
        if listener: continue
        var at = -1
        for i, c in clients:
          if c.sock.getFd == fd: at = i
        if at < 0: continue
        var buf: array[4096, char]
        let n = try: clients[at].sock.recv(addr buf[0], buf.len) except CatchableError: -1
        if n <= 0:
          drop(at)
          continue
        for i in 0 ..< n: clients[at].data.add buf[i]
        if clients[at].data.len > 16384:
          reply(clients[at].sock, 400, page("Too long", "This request is too long."))
          drop(at)
          continue
        if "\r\n\r\n" notin clients[at].data and "\n\n" notin clients[at].data: continue
        # a whole request: GET /?code=...&state=... HTTP/1.1
        let c = clients[at].sock
        let first = clients[at].data.splitLines()[0].splitWhitespace()
        let target = if first.len >= 2: first[1] else: ""
        let q = target.find('?')
        let path = if q < 0: target else: target[0 ..< q]
        let query = formDecode(if q < 0: "" else: target[q + 1 .. ^1])
        proc get(name: string): string =
          for (k, v) in query:
            if k == name: return v
        if first.len < 2 or first[0] notin ["GET", "HEAD"] or path != "/":
          reply(c, 404, page("Not here", "There is nothing here."))
        elif get("state").len == 0:
          reply(c, 400, page("Not signed in", "This page waits for the answer of a sign-in."))
        elif get("state") != job.expected:
          reply(c, 400, page("Not this sign-in",
                "This answer belongs to another sign-in (an older window?). " &
                "Go back to the app and sign in from there."))
        elif get("error").len > 0:
          outcome = osFailed
          error = readable(get("error"), get("error_description"))
          reply(c, 200, page("Not signed in", "The sign-in did not work: " & error &
                ". You can close this window and go back to the app."))
        elif get("code").len == 0:
          reply(c, 400, page("Not signed in", "The answer has no code."))
        else:
          # the code: no more listening, then tokens for it
          for l in listeners:
            try: sel.unregister(l.getFd) except CatchableError: discard
            l.close()
          listeners.setLen(0)
          error = tokenRequest(p, @[("grant_type", "authorization_code"), ("code", get("code")),
                                    ("redirect_uri", job.redirect),
                                    ("code_verifier", job.verifier)], tokens)
          if cancelled(job.slot):
            outcome = osCancelled
            reply(c, 200, page("Cancelled", "The sign-in was cancelled in the app."))
          elif error.len == 0:
            outcome = osDone
            reply(c, 200, page("Signed in", "You are signed in with " & p.name &
                  ". You can close this window and go back to the app."))
          else:
            outcome = osFailed
            reply(c, 200, page("Not signed in", "The sign-in did not work: " & error &
                  ". You can close this window and go back to the app."))
        drop(at)
      # clients that say nothing (a browser's spare connection)
      var i = 0
      while i < clients.len:
        if epochTime() - clients[i].since > 20: drop(i) else: inc i
    while clients.len > 0: drop(0)
    for l in listeners: l.close()
    sel.close()
    finish(job.slot, outcome, tokens, error)
    withLock signInLock:
      slots[job.slot].finished = true

# ---- the flow, on the UI thread -------------------------------------------------------------

proc dropLink(slot: int) =
  ## A flow no one keeps: its sign-in stops, its slot is free once its
  ## thread ends.
  if slot >= 0:
    {.cast(gcsafe).}:
      withLock signInLock:
        slots[slot].cancel = true
        slots[slot].attached = false

when defined(gcDestructors):
  proc `=destroy`(l: Link) = dropLink(l.slot)
else:      # (--mm:refc, an editor's check among them: its hooks take `var`)
  proc `=destroy`(l: var Link) = dropLink(l.slot)

proc `=copy`(a: var Link; b: Link) {.error.}

proc reap() =
  ## Joins the threads of sign-ins that ended and no flow looks at.
  withLock signInLock:
    for s in slots.mitems:
      if s.inUse and s.finished and not s.attached:
        joinThread(s.thread)
        s.inUse = false
        s.tokens = OAuthTokens()
        s.error = ""

proc failedFlow(msg: string): OAuthFlow =
  OAuthFlow(link: Link(slot: -1), st: osFailed, err: msg)

proc beginSignIn*(p: OAuthProvider; loginHint = "";
                  openBrowser: proc (url: string) {.gcsafe.} = nil): OAuthFlow =
  ## Starts signing in with `p`: listens on 127.0.0.1 (a free port) and
  ## opens the sign-in page in the browser (`openUrl`), or hands its
  ## address to `openBrowser`. `loginHint` fills in the account. Look at
  ## `state` every frame; it never waits.
  reap()
  var verifier, expected: string
  try:
    verifier = randomText(32)
    expected = randomText(16)
  except OSError:
    return failedFlow("no random numbers")
  # the port: free on 127.0.0.1 (and the same on ::1 for "localhost")
  var listeners: seq[(SocketHandle, Domain)]
  var port: Port
  try:
    let s4 = newSocket(AF_INET, SOCK_STREAM, IPPROTO_TCP, buffered = false)
    s4.bindAddr(Port(0), "127.0.0.1")
    s4.listen()
    port = s4.getLocalAddr()[1]
    listeners.add (s4.getFd, AF_INET)
  except OSError as e:
    return failedFlow("cannot listen on 127.0.0.1: " & e.msg)
  let host = if p.redirectHost.len > 0: p.redirectHost else: "127.0.0.1"
  if host == "localhost":
    try:
      let s6 = newSocket(AF_INET6, SOCK_STREAM, IPPROTO_TCP, buffered = false)
      try:
        s6.bindAddr(port, "::1")
        s6.listen()
        listeners.add (s6.getFd, AF_INET6)
      except OSError:
        s6.close()
    except OSError: discard
  let redirect = "http://" & host & ":" & $int(port) & "/"
  var fields = @[("client_id", p.clientId), ("response_type", "code"),
                 ("redirect_uri", redirect), ("scope", p.scopes.join(" ")),
                 ("state", expected), ("code_challenge", b64url(sha256(verifier).toBinary)),
                 ("code_challenge_method", "S256")]
  if loginHint.len > 0: fields.add ("login_hint", loginHint)
  for f in p.authParams: fields.add f
  let address = p.authUrl & (if '?' in p.authUrl: "&" else: "?") & formEncode(fields)
  var slot = -1
  withLock signInLock:
    for i in 0 ..< maxSlots:
      if not slots[i].inUse:
        slot = i
        slots[i] = Slot(inUse: true, attached: true, state: osWaiting)
        break
  if slot < 0:
    for (fd, _) in listeners: fd.close()
    return failedFlow("too many sign-ins at once")
  result = OAuthFlow(link: Link(slot: slot), st: osWaiting, address: address)
  createThread(slots[slot].thread, listen,
               Job(slot: slot, provider: p, verifier: verifier, expected: expected,
                   redirect: redirect, listeners: listeners))
  if openBrowser != nil: openBrowser(address)
  else: discard openUrl(address)

proc state*(f: OAuthFlow): OAuthState =
  ## Where the sign-in is; never waits (call it every frame).
  if f.link.slot >= 0:
    withLock signInLock:
      let s = addr slots[f.link.slot]
      if s.state != osWaiting:
        f.st = s.state
        f.toks = s.tokens
        f.err = s.error
        s.attached = false
    if f.st != osWaiting: f.link.slot = -1
    else: wakeIn(250)                  # (frames keep coming to see the end)
  f.st

proc tokens*(f: OAuthFlow): OAuthTokens =
  ## The tokens, once `state` is `osDone`.
  discard f.state
  f.toks

proc error*(f: OAuthFlow): string =
  ## Why it failed, once `state` is `osFailed`.
  discard f.state
  f.err

proc url*(f: OAuthFlow): string =
  ## The sign-in page's address (to show, or copy into a browser).
  f.address

proc cancel*(f: OAuthFlow) =
  ## Stops waiting: the state becomes `osCancelled` (unless it ended
  ## already) and the port is let go.
  if f.link.slot >= 0:
    withLock signInLock:
      slots[f.link.slot].cancel = true
      slots[f.link.slot].attached = false
    f.link.slot = -1
    f.st = osCancelled
