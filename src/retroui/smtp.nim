## SMTP (RFC 5321) to send mail through an account's server: TLS at once
## (port 465) or STARTTLS (587), signed in with a password (PLAIN or
## LOGIN) or an OAuth token (XOAUTH2), then the message as `retroui/mime`
## makes it. Blocking: send from a thread of its own.
##
## .. code-block:: nim
##   import retroui/[smtp, mime]
##   let raw = buildMail(OutMail(fromAddr: MailAddress(email: "me@example.com"),
##                               to: @[MailAddress(email: "you@example.com")],
##                               subject: "Hello", text: "Hi."))
##   let err = smtpSend("smtp.example.com", 465, secTls, "me@example.com", "my password",
##                      "me@example.com", ["you@example.com"], raw)
##   if err.len > 0: echo "not sent: ", err
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[strutils, base64]
import netconn
export netconn.Security

type
  SmtpError* = object of IOError
    ## The server refused (`code`: its number, 5xx for good, 4xx for now).
    code*: int
  SmtpClient* = ref object
    conn: NetConn
    host: string
    exts*: seq[string]          ## what EHLO said it can do, in capitals ("AUTH PLAIN LOGIN", "SIZE 35882577")
    log*: proc (line: string) {.closure, gcsafe.}

proc smtpFail(code: int; msg: string) {.noreturn.} =
  var e = newException(SmtpError, msg)
  e.code = code
  raise e

proc sendLine(c: SmtpClient; s: string; secret = false) =
  if c.log != nil: c.log("> " & (if secret: "(hidden)" else: s))
  c.conn.write(s & "\r\n")

proc reply(c: SmtpClient): tuple[code: int; lines: seq[string]] =
  ## One reply: "250-..." lines, then "250 ...".
  while true:
    let l = c.conn.readLine()
    if c.log != nil: c.log("< " & l)
    if l.len < 3: smtpFail(0, "a strange answer: " & l)
    result.code = try: parseInt(l[0 ..< 3]) except ValueError: 0
    result.lines.add (if l.len > 4: l[4 .. ^1] else: "")
    if l.len == 3 or l[3] == ' ': break

proc expect(c: SmtpClient; codes: openArray[int]; what: string): seq[string] =
  let r = c.reply()
  if r.code notin codes:
    smtpFail(r.code, what & ": " & r.lines.join(" ").strip & " (" & $r.code & ")")
  r.lines

proc has*(c: SmtpClient; ext: string): bool =
  ## EHLO said it can (`"STARTTLS"`, `"SMTPUTF8"`, `"AUTH"`...).
  for e in c.exts:
    if e == ext.toUpperAscii or e.startsWith(ext.toUpperAscii & " "): return true

proc authKinds(c: SmtpClient): seq[string] =
  for e in c.exts:
    if e.startsWith("AUTH ") or e.startsWith("AUTH="):
      for w in e[5 .. ^1].splitWhitespace: result.add w

proc hello(c: SmtpClient; name: string) =
  c.sendLine("EHLO " & name)
  let r = c.reply()
  if r.code == 250:
    c.exts.setLen(0)
    for l in r.lines[1 .. ^1]: c.exts.add l.toUpperAscii.strip
  else:
    c.sendLine("HELO " & name)
    discard c.expect([250], "the server did not greet")
    c.exts.setLen(0)

proc smtpConnect*(host: string; port = 465; security = secTls; timeoutSec = 60;
                  insecure = false; helloName = "localhost";
                  log: proc (line: string) {.closure, gcsafe.} = nil): SmtpClient =
  ## Connects, greets (EHLO), and encrypts (STARTTLS) with `secStartTls`.
  result = SmtpClient(host: host, log: log)
  result.conn = openSecured(host, port, security, timeoutSec, insecure)
  try:
    discard result.expect([220], host & " did not greet")
    result.hello(helloName)
    if security == secStartTls:
      if not result.has("STARTTLS"):
        smtpFail(0, host & " does not offer STARTTLS (try TLS, port 465)")
      result.sendLine("STARTTLS")
      discard result.expect([220], "STARTTLS")
      result.conn.startTls()
      result.hello(helloName)
  except CatchableError:
    result.conn.close()           # (no socket or TLS state left behind)
    raise

proc login*(c: SmtpClient; user, password: string) =
  ## Signs in (AUTH PLAIN, else LOGIN). Raises `SmtpError` when refused.
  let kinds = c.authKinds()
  if "PLAIN" in kinds or kinds.len == 0:
    c.sendLine("AUTH PLAIN " & encode("\0" & user & "\0" & password), secret = true)
    discard c.expect([235], "signing in")
  elif "LOGIN" in kinds:
    c.sendLine("AUTH LOGIN")
    discard c.expect([334], "signing in")
    c.sendLine(encode(user), secret = true)
    discard c.expect([334], "signing in")
    c.sendLine(encode(password), secret = true)
    discard c.expect([235], "signing in")
  else:
    smtpFail(0, "the server signs in only by " & kinds.join(", "))

proc loginOAuth*(c: SmtpClient; user, token: string) =
  ## Signs in with an OAuth access token (XOAUTH2).
  c.sendLine("AUTH XOAUTH2 " & encode("user=" & user & "\x01auth=Bearer " & token & "\x01\x01"),
             secret = true)
  let r = c.reply()
  if r.code == 334:                      # (the error's details: end the exchange)
    c.sendLine("")
    discard c.expect([235], "signing in")
  elif r.code != 235:
    smtpFail(r.code, "signing in: " & r.lines.join(" "))

proc sendMail*(c: SmtpClient; fromAddr: string; rcpts: openArray[string]; message: string) =
  ## Sends one message (its RFC 5322 bytes) to `rcpts` (the To, Cc and
  ## Bcc addresses). Raises `SmtpError` with the server's words.
  var ascii = true
  for ch in fromAddr & rcpts.join(""):
    if ord(ch) >= 0x80: ascii = false
  var mail = "MAIL FROM:<" & fromAddr & ">"
  if c.has("SIZE"): mail.add " SIZE=" & $message.len
  if not ascii and c.has("SMTPUTF8"): mail.add " SMTPUTF8"
  if c.has("8BITMIME"): mail.add " BODY=8BITMIME"
  c.sendLine(mail)
  discard c.expect([250], "the sender")
  var ok = 0
  var refused: seq[string]
  for r in rcpts:
    c.sendLine("RCPT TO:<" & r & ">")
    let a = c.reply()
    if a.code in [250, 251]: inc ok
    else: refused.add r & " (" & a.lines.join(" ").strip & ")"
  if ok == 0:
    c.sendLine("RSET")
    discard c.reply()
    smtpFail(550, "no recipient was taken: " & refused.join("; "))
  c.sendLine("DATA")
  discard c.expect([354], "the message")
  # the message, its lines' first dots doubled, CR LF everywhere, ended by "."
  var body = newStringOfCap(message.len + 1024)
  var lineStart = true
  var i = 0
  while i < message.len:
    let ch = message[i]
    if lineStart and ch == '.': body.add '.'
    if ch == '\n' and (i == 0 or message[i - 1] != '\r'): body.add '\r'
    body.add ch
    lineStart = ch == '\n'
    inc i
  if not body.endsWith("\r\n"): body.add "\r\n"
  body.add ".\r\n"
  if c.log != nil: c.log("> (" & $message.len & " bytes)")
  c.conn.write(body)
  discard c.expect([250], "the message")
  if refused.len > 0:
    smtpFail(250, "sent, but not to " & refused.join("; "))

proc quit*(c: SmtpClient) =
  ## Says goodbye and closes the connection.
  if c == nil or c.conn == nil: return
  try:
    c.sendLine("QUIT")
    discard c.reply()
  except CatchableError: discard
  c.conn.close()

proc smtpSend*(host: string; port: int; security: Security; user, password: string;
               fromAddr: string; rcpts: openArray[string]; message: string;
               timeoutSec = 120; insecure = false; oauthToken = ""): string =
  ## Connects, signs in (when `user` is given), sends, says goodbye: "" when
  ## the message went to everyone, else why not ("sent, but not to ...":
  ## it went to the others).
  var c: SmtpClient
  try:
    c = smtpConnect(host, port, security, timeoutSec, insecure)
    if oauthToken.len > 0: c.loginOAuth(user, oauthToken)
    elif user.len > 0: c.login(user, password)
    c.sendMail(fromAddr, rcpts, message)
    c.quit()
    ""
  except SmtpError as e:
    if c != nil: c.quit()
    e.msg
  except CatchableError as e:
    if c != nil: c.conn.close()
    e.msg
