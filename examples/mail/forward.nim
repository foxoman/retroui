## Retro Mail: forwarding a message as an attachment -- the message whole,
## as the server keeps it (RFC 5322 bytes), attached to a new one as
## message/rfc822 (an .eml file to the one who gets it).
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[json, strutils, os, times, hashes]
import retroui/[http, mime]
import api, store, imapsync

proc rawMessage*(acc: Account; token, remoteId: string): string =
  ## The message's whole MIME source. Graph: its $value; Gmail: format=raw.
  case acc.kind
  of akGraph:
    let r = call("GET", graphBase() & "/me/messages/" & remoteId & "/$value", token, timeout = 300)
    if not r.ok: fail(r, "the message")
    r.body
  of akGmail:
    let j = callJson("GET", gmailBase() & "/gmail/v1/users/me/messages/" & remoteId & "?format=raw",
                     token, what = "the message")
    base64UrlDecode(j{"raw"}.getStr)
  of akImap:
    imapRaw(acc, token, remoteId)

const reservedNames = ["CON", "PRN", "AUX", "NUL", "COM1", "COM2", "COM3", "COM4", "COM5", "COM6",
                       "COM7", "COM8", "COM9", "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6",
                       "LPT7", "LPT8", "LPT9"]

proc attachmentName*(subject: string; maxLen = 80): string =
  ## The file name of a message forwarded as an attachment: its subject
  ## with what file systems refuse as "_", spaces run together, at most
  ## `maxLen` bytes (never inside a character), then ".eml"; "message.eml"
  ## for a message without a subject.
  var s = ""
  var space = false
  for c in subject:
    if c in {' ', '\t', '\r', '\n'}:
      if not space: s.add ' '
      space = true
      continue
    space = false
    if ord(c) < 32 or c in {'<', '>', ':', '"', '/', '\\', '|', '?', '*', '\x7F'}: s.add '_'
    else: s.add c
  s = s.strip(chars = {' ', '.'})
  if s.len > maxLen:
    var n = maxLen
    while n > 0 and (ord(s[n]) and 0xC0) == 0x80: dec n
    s = s[0 ..< n].strip(chars = {' ', '.'})
  if s.len == 0: s = "message"
  if s.toUpperAscii in reservedNames: s = "_" & s
  s & ".eml"

proc forwardAttachment*(acc: Account; token: string; m: Msg; dir: string): JsonNode =
  ## Message `m` saved in `dir` for sending as an attachment: the entry a
  ## send's "attachments" take ({path, name, mime, copy}: the file goes
  ## once the mail is sent).
  let data = rawMessage(acc, token, m.remoteId)
  createDir(dir)
  let path = dir / ("fwd-" & $(hash(m.remoteId) and 0xFFFFFF) & "-" & $int(epochTime() * 1000) & ".eml")
  writeFile(path, data)
  %*{"path": path, "name": attachmentName(m.subject), "mime": "message/rfc822", "copy": true}
