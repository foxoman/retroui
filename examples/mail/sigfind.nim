## Retro Mail: the signature the user already has on the web, so that
## mail written here ends the same way. Gmail keeps it in its settings
## (the send-as address's signature); Microsoft 365 and Outlook.com have no
## API for it, so it is read from the user's own sent mail, where Outlook on
## the web, the new Outlook, Outlook for Windows and Outlook mobile mark it.
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[json, strutils]
import api

const replyMarks = ["id=\"divrplyfwdmsg\"", "id=divrplyfwdmsg", "id=\"appendonsend\"",
                    "id=\"mail-editor-reference-message-container\"", "class=\"gmail_quote",
                    "border-top:solid #e1e1e1", "border-top:solid #b5c4df",
                    "-----original message-----", "----- original message -----"]

proc firstMark(lower: string; start = 0): int =
  ## Where the quoted message of a reply begins (the text's length if none).
  result = lower.len
  for m in replyMarks:
    let k = lower.find(m, start)
    if k >= 0 and k < result: result = k
  if result < lower.len:
    let d = lower.rfind("<div", last = result)         # (the element that holds the mark)
    if d >= start: result = d

proc elementAt(html, lower: string; at: int): string =
  ## The whole element (`<div ...>...</div>`, nested divs counted) whose
  ## start tag holds position `at`.
  let s = lower.rfind('<', last = at)
  if s < 0: return ""
  var tagEnd = s + 1
  while tagEnd < lower.len and lower[tagEnd] in {'a'..'z', '0'..'9'}: inc tagEnd
  let tag = lower[s + 1 ..< tagEnd]
  if tag.len == 0: return ""
  var depth = 0
  var i = s
  while i < lower.len:
    if lower.continuesWith("<" & tag, i) and i + tag.len + 1 < lower.len and
       lower[i + tag.len + 1] in {' ', '>', '/', '\t', '\n', '\r'}:
      inc depth
      i += tag.len + 1
    elif lower.continuesWith("</" & tag, i):
      dec depth
      let e = lower.find('>', i)
      if e < 0: return html[s .. ^1]
      if depth == 0: return html[s .. e]
      i = e + 1
    else: inc i
  html[s .. ^1]

proc cleanSignature(html: string): string =
  ## Without what cannot travel (pictures kept inside the sent message,
  ## scripts) and blank around.
  result = html
  var i = 0
  while true:
    let lower = result.toLowerAscii
    let k = lower.find("<img", i)
    if k < 0: break
    let e = lower.find('>', k)
    if e < 0: break
    if "src=\"cid:" in lower[k .. e] or "src='cid:" in lower[k .. e] or "src=cid:" in lower[k .. e]:
      result.delete(k .. e)
      i = k
    else: i = e + 1
  result = result.strip

proc textOf(html: string): string =
  result = ""         # (a value at once: see tools/writecheck.py)
  var inTag = false
  for c in html:
    if c == '<': inTag = true
    elif c == '>': inTag = false
    elif not inTag: result.add c
  result = result.multiReplace(("&nbsp;", " "), ("&amp;", "&")).strip

proc signatureIn*(html: string): string =
  ## The signature a mail program marked in a message it sent (the part the
  ## writer wrote, before any quoted message); "" when none is marked.
  let lower = html.toLowerAscii
  let stop = firstMark(lower)
  # Outlook on the web and the new Outlook; Thunderbird; Apple Mail; Gmail
  for mark in ["id=\"signature\"", "id=signature", "id='signature'", "class=\"moz-signature\"",
               "id=\"applemailsignature\"", "class=\"gmail_signature\""]:
    let k = lower.find(mark)
    if k >= 0 and k < stop:
      let el = elementAt(html, lower, k)
      if textOf(el).len > 0: return cleanSignature(el)
  # Outlook for Windows: a bookmark where the signature starts
  let k = lower.find("_mailautosig")
  if k >= 0 and k < stop:
    var s = lower.rfind("<p", last = k)
    let d = lower.rfind("<div", last = k)
    if d > s: s = d
    if s >= 0:
      var e = stop
      let b = lower.rfind("</body", last = e)
      if b > s: e = b
      let part = html[s ..< e]
      if textOf(part).len > 0: return cleanSignature(part)
  # Outlook on phones (not its "Get Outlook for ..." line)
  let mk = lower.find("id=\"ms-outlook-mobile-signature\"")
  if mk >= 0 and mk < stop:
    let el = elementAt(html, lower, mk)
    let t = textOf(el)
    if t.len > 0 and not t.toLowerAscii.startsWith("get outlook for"): return cleanSignature(el)
  ""

proc isReply*(subject, html: string): bool =
  ## A reply or a forward (by its subject or a quoted message in it).
  let s = subject.strip.toLowerAscii
  for p in ["re:", "fw:", "fwd:", "aw:", "wg:", "sv:", "vs:", "tr:", "rv:", "رد:", "إعادة توجيه:", "ر:"]:
    if s.startsWith(p): return true
  firstMark(html.toLowerAscii) < html.len

proc graphSignatures*(token: string; fromAddress = ""): tuple[newHtml, replyHtml: string] =
  ## The signatures of the newest mail sent from Microsoft 365 / Outlook.com:
  ## the one under new messages and the one under replies.
  let j = callJson("GET", graphBase() & "/me/mailFolders/sentitems/messages?$top=40&" &
                   "$select=subject,body,sentDateTime,from&$orderby=sentDateTime%20desc", token,
                   what = "the sent mail")
  for m in j{"value"}.getElems:
    if fromAddress.len > 0:
      let f = m{"from"}{"emailAddress"}{"address"}.getStr
      if f.len > 0 and cmpIgnoreCase(f, fromAddress) != 0: continue
    let html = m{"body"}{"content"}.getStr
    let sig = signatureIn(html)
    if sig.len == 0: continue
    if isReply(m{"subject"}.getStr, html):
      if result.replyHtml.len == 0: result.replyHtml = sig
    elif result.newHtml.len == 0: result.newHtml = sig
    if result.newHtml.len > 0 and result.replyHtml.len > 0: break
  if result.newHtml.len == 0: result.newHtml = result.replyHtml
  if result.replyHtml.len == 0: result.replyHtml = result.newHtml

proc gmailSignature*(token, email: string): string =
  ## The signature Gmail's settings keep for the account's address.
  let j = callJson("GET", gmailBase() & "/gmail/v1/users/me/settings/sendAs", token,
                   what = "the Gmail settings")
  var first = ""
  for s in j{"sendAs"}.getElems:
    let sig = s{"signature"}.getStr.strip
    if sig.len == 0: continue
    if cmpIgnoreCase(s{"sendAsEmail"}.getStr, email) == 0: return sig
    if s{"isPrimary"}.getBool or s{"isDefault"}.getBool or first.len == 0: first = sig
  first
