## POP3 (RFC 1939, with 2449's CAPA, 2595's STLS and 5034's SASL): the
## mail waiting in an account's Inbox on its server -- for the providers
## and the old servers that have no IMAP, or where mail is meant to be
## taken home. A client signs in (a password, or an OAuth token: XOAUTH2),
## lists the messages with their lasting ids (UIDL), reads one's header
## (TOP) or the whole of it (RETR), and deletes (DELE: done when it signs
## out with QUIT).
##
## .. code-block:: nim
##   import retroui/pop3
##   let c = pop3Connect("pop.example.com", 995, secTls)
##   c.login("me@example.com", "my password")
##   for (n, uid) in c.uidl(): echo n, " ", uid
##   echo c.top(1)            # its header fields
##   echo c.retr(1)           # the whole message (RFC 5322)
##   c.dele(1)
##   c.quit()                 # (only now is it deleted)
##
## The connection is `retroui/netconn`'s (TLS at once on 995, STLS on
## 110). Every call blocks: run them on a thread of their own.
## `Pop3Error` carries the server's words when it says -ERR.
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[strutils, base64]
import netconn
export netconn.Security, netconn.NetError

type
  Pop3Error* = object of IOError
    ## The server said -ERR (`msg`: its words), or answered strangely.
  Pop3Client* = ref object
    ## A connection to one account's server (`pop3Connect`).
    conn: NetConn
    caps*: seq[string]          ## what the server can do (CAPA), in capitals ("UIDL", "SASL PLAIN")
    greeting: string
    log*: proc (line: string) {.closure, gcsafe.}  ## (sees every line, for tests and debugging)

proc popFail(msg: string) {.noreturn.} = raise newException(Pop3Error, msg)

proc sendLine(c: Pop3Client; s: string) =
  if c.log != nil:
    c.log("> " & (if s.toUpperAscii.startsWith("PASS "): "PASS ..." else: s))
  c.conn.write(s & "\r\n")

proc readLine(c: Pop3Client): string =
  result = c.conn.readLine()
  if c.log != nil: c.log("< " & (if result.len > 300: result[0 ..< 300] & "..." else: result))

proc status(c: Pop3Client): string =
  ## (one +OK line's words; -ERR raises)
  let r = c.readLine()
  if r.startsWith("+OK"): return r[3 .. ^1].strip
  if r.startsWith("-ERR"): popFail(if r.len > 5: r[5 .. ^1].strip else: "the server refused")
  popFail("not a POP3 answer: " & r)

proc cmd(c: Pop3Client; line: string): string =
  c.sendLine(line)
  c.status()

proc multiline(c: Pop3Client): string =
  ## (the lines up to the "." alone, dots that started a line taken off)
  result = newStringOfCap(4096)
  while true:
    let l = c.conn.readLine()
    if l == ".": break
    if l.startsWith(".."): result.add l[1 .. ^1]
    else: result.add l
    result.add "\r\n"

proc has*(c: Pop3Client; cap: string): bool =
  ## The server can (`"UIDL"`, `"TOP"`, `"STLS"`, `"SASL PLAIN"`...).
  let want = cap.toUpperAscii
  for k in c.caps:
    if k == want or k.startsWith(want & " "): return true
    if want.startsWith("SASL ") and k.startsWith("SASL ") and want[5 .. ^1] in k[5 .. ^1].splitWhitespace:
      return true

proc capa(c: Pop3Client) =
  c.caps.setLen(0)
  try:
    discard c.cmd("CAPA")
    for l in c.multiline().splitLines:
      if l.strip.len > 0: c.caps.add l.strip.toUpperAscii
  except Pop3Error: discard              # (an old server: no CAPA)

proc pop3Connect*(host: string; port = 995; security = secTls; timeoutSec = 60;
                  insecure = false; log: proc (line: string) {.closure, gcsafe.} = nil): Pop3Client =
  ## Connects and reads the greeting (STLS first with `secStartTls`).
  ## Raises `NetError` (no connection) or `Pop3Error` (the server refused).
  result = Pop3Client(log: log)
  result.conn = openSecured(host, port, security, timeoutSec, insecure)
  try:
    result.greeting = result.status()
    result.capa()
    if security == secStartTls:
      if not result.has("STLS"): popFail(host & " does not offer STLS (try TLS, port 995)")
      discard result.cmd("STLS")
      result.conn.startTls()
      result.capa()
  except CatchableError:
    result.conn.close()
    raise

proc login*(c: Pop3Client; user, password: string) =
  ## Signs in with a password (USER and PASS, else SASL PLAIN). Raises
  ## `Pop3Error` with the server's words when refused.
  if c.caps.len > 0 and not c.has("USER") and c.has("SASL PLAIN"):
    c.sendLine("AUTH PLAIN " & encode("\0" & user & "\0" & password))
    discard c.status()
  else:
    discard c.cmd("USER " & user)
    discard c.cmd("PASS " & password)
  c.capa()

proc loginOAuth*(c: Pop3Client; user, token: string) =
  ## Signs in with an OAuth access token (XOAUTH2: Gmail, Outlook.com).
  c.sendLine("AUTH XOAUTH2 " & encode("user=" & user & "\x01auth=Bearer " & token & "\x01\x01"))
  var r = c.readLine()
  if r.startsWith("+ ") or r == "+":
    c.sendLine("")                     # (the error's details came: end it)
    r = c.readLine()
  if not r.startsWith("+OK"): popFail(if r.len > 5: r[5 .. ^1].strip else: "the token was refused")
  c.capa()

proc stat*(c: Pop3Client): tuple[count, size: int] =
  ## How many messages wait, and their bytes.
  let w = c.cmd("STAT").splitWhitespace
  if w.len >= 2:
    try: result = (parseInt(w[0]), parseInt(w[1]))
    except ValueError: discard

proc uidl*(c: Pop3Client): seq[tuple[num: int; uid: string]] =
  ## Each message's number (this session's) and its lasting id.
  discard c.cmd("UIDL")
  for l in c.multiline().splitLines:
    let w = l.splitWhitespace
    if w.len >= 2:
      try: result.add (parseInt(w[0]), w[1])
      except ValueError: discard

proc list*(c: Pop3Client): seq[tuple[num, size: int]] =
  ## Each message's number and size in bytes.
  discard c.cmd("LIST")
  for l in c.multiline().splitLines:
    let w = l.splitWhitespace
    if w.len >= 2:
      try: result.add (parseInt(w[0]), parseInt(w[1]))
      except ValueError: discard

proc top*(c: Pop3Client; num: int; lines = 0): string =
  ## Message `num`'s header fields (and its first `lines` lines of text).
  discard c.cmd("TOP " & $num & " " & $lines)
  c.multiline()

proc retr*(c: Pop3Client; num: int): string =
  ## The whole of message `num`, CRLF line ends.
  discard c.cmd("RETR " & $num)
  c.multiline()

proc dele*(c: Pop3Client; num: int) =
  ## Marks message `num` to delete (done at `quit`; `rset` takes it back).
  discard c.cmd("DELE " & $num)

proc rset*(c: Pop3Client) =
  ## Takes back this session's deletions.
  discard c.cmd("RSET")

proc noop*(c: Pop3Client) =
  discard c.cmd("NOOP")

proc quit*(c: Pop3Client) =
  ## Signs out: the messages marked are deleted now. The connection closes.
  if c == nil or c.conn == nil: return
  try: discard c.cmd("QUIT")
  finally: c.conn.close()

proc close*(c: Pop3Client) =
  ## Closes the connection without QUIT: nothing marked is deleted.
  if c != nil and c.conn != nil: c.conn.close()
