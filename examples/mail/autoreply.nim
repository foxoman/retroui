## Retro Mail: automatic replies (out of office). Microsoft 365 and
## Outlook.com keep them in the mailbox settings (automaticRepliesSetting:
## a message for the organization, one for outside it), Gmail in its
## vacation responder settings (one message, to everyone or only to
## contacts or to the domain).
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[json, strutils, times]
import api, store, ical

type
  AutoReply* = object
    enabled*: bool             ## replies go out
    scheduled*: bool           ## only between `start` and `finish`
    start*, finish*: float     ## epoch seconds
    subject*: string           ## Gmail: the replies' subject ("" for "Re: " and the message's)
    internalHtml*: string      ## to people in the organization (Gmail: the one message)
    externalHtml*: string      ## to people outside it (Microsoft 365, Outlook.com)
    externalAudience*: string  ## who outside gets a reply: "none", "contactsOnly" or "all"

proc audience(s: string): string =
  if s in ["none", "contactsOnly", "all"]: s else: "all"

proc checked(r: AutoReply): AutoReply =
  result = r
  result.externalAudience = audience(r.externalAudience)
  if r.enabled and r.scheduled and not (r.finish > r.start and r.start > 0):
    raise newException(ValueError, "the automatic replies' end must come after their start")

proc plainToHtml(t: string): string =
  t.multiReplace(("&", "&amp;"), ("<", "&lt;"), (">", "&gt;")).replace("\r\n", "\n").replace("\n", "<br>")

# ---- Microsoft Graph -----------------------------------------------------------------------

proc graphUtc(t: float): JsonNode =
  %*{"dateTime": fromUnixFloat(t).utc.format("yyyy-MM-dd'T'HH:mm:ss"), "timeZone": "UTC"}

proc graphAutoReply*(j: JsonNode): AutoReply =
  ## An automaticRepliesSetting as an AutoReply.
  let status = j{"status"}.getStr("disabled")
  result.enabled = status in ["alwaysEnabled", "scheduled"]
  result.scheduled = status == "scheduled"
  for (key, field) in [("scheduledStartDateTime", addr result.start),
                       ("scheduledEndDateTime", addr result.finish)]:
    let d = j{key}
    if d != nil and d.kind == JObject and d{"dateTime"}.getStr.len > 0:
      field[] = zoneToUtc(d{"dateTime"}.getStr, d{"timeZone"}.getStr("UTC"))
  result.internalHtml = j{"internalReplyMessage"}.getStr
  result.externalHtml = j{"externalReplyMessage"}.getStr
  result.externalAudience = audience(j{"externalAudience"}.getStr("all"))

proc graphAutoReplyJson*(r: AutoReply): JsonNode =
  ## An AutoReply as Graph's automaticRepliesSetting (times in UTC).
  let r = checked(r)
  result = %*{"status": (if not r.enabled: "disabled" elif r.scheduled: "scheduled" else: "alwaysEnabled"),
              "externalAudience": r.externalAudience, "internalReplyMessage": r.internalHtml,
              "externalReplyMessage": r.externalHtml}
  if r.scheduled and r.start > 0 and r.finish > r.start:
    result["scheduledStartDateTime"] = graphUtc(r.start)
    result["scheduledEndDateTime"] = graphUtc(r.finish)

# ---- Gmail ---------------------------------------------------------------------------------

proc msOf(j: JsonNode): float =
  ## Gmail's int64 milliseconds (a string in JSON, or a number) as seconds.
  if j == nil: return 0
  case j.kind
  of JString: (try: parseFloat(j.getStr) / 1000 except ValueError: 0.0)
  of JInt: float(j.getBiggestInt) / 1000
  of JFloat: j.getFloat / 1000
  else: 0.0

proc gmailAutoReply*(j: JsonNode): AutoReply =
  ## Gmail's vacation settings as an AutoReply.
  result.enabled = j{"enableAutoReply"}.getBool
  result.subject = j{"responseSubject"}.getStr
  var html = j{"responseBodyHtml"}.getStr
  if html.len == 0: html = plainToHtml(j{"responseBodyPlainText"}.getStr)
  result.internalHtml = html
  result.externalHtml = html
  result.start = msOf(j{"startTime"})
  result.finish = msOf(j{"endTime"})
  result.scheduled = result.start > 0 or result.finish > 0
  result.externalAudience = if j{"restrictToDomain"}.getBool: "none"
                            elif j{"restrictToContacts"}.getBool: "contactsOnly"
                            else: "all"

proc consumerGmail(email: string): bool =
  let d = email.toLowerAscii
  d.endsWith("@gmail.com") or d.endsWith("@googlemail.com")

proc gmailAutoReplyJson*(r: AutoReply; email: string): JsonNode =
  ## An AutoReply as Gmail's vacation settings. Gmail has one message:
  ## `internalHtml` (else `externalHtml`). "none" keeps replies inside the
  ## domain (Google Workspace); a gmail.com address has no domain of its
  ## own, so there it means contacts only.
  let r = checked(r)
  let html = if r.internalHtml.len > 0: r.internalHtml else: r.externalHtml
  result = %*{"enableAutoReply": r.enabled, "responseSubject": r.subject, "responseBodyHtml": html,
              "restrictToContacts": r.externalAudience == "contactsOnly" or
                                    (r.externalAudience == "none" and consumerGmail(email)),
              "restrictToDomain": r.externalAudience == "none" and not consumerGmail(email)}
  if r.scheduled:
    if r.start > 0: result["startTime"] = %($int64(r.start * 1000))
    if r.finish > 0: result["endTime"] = %($int64(r.finish * 1000))

# ---- the calls ---------------------------------------------------------------------------

proc noAutoReply(): ref ApiError =
  ## (IMAP has none of its own: the provider's web mail sets them)
  result = newException(ApiError, "an IMAP account's automatic replies are set in its " &
                                  "provider's web mail (IMAP has none of its own)")
  result.status = 400

proc getAutoReply*(acc: Account; token: string): AutoReply =
  ## The account's automatic replies as the service keeps them.
  case acc.kind
  of akGraph:
    graphAutoReply(callJson("GET", graphBase() & "/me/mailboxSettings/automaticRepliesSetting", token,
                            what = "the automatic replies"))
  of akGmail:
    gmailAutoReply(callJson("GET", gmailBase() & "/gmail/v1/users/me/settings/vacation", token,
                            what = "the vacation responder"))
  of akImap:
    raise noAutoReply()

proc setAutoReply*(acc: Account; token: string; r: AutoReply) =
  ## Turns the account's automatic replies on or off, with their messages.
  ## Raises ValueError for a schedule that ends before it starts.
  case acc.kind
  of akGraph:
    discard callJson("PATCH", graphBase() & "/me/mailboxSettings", token,
                     %*{"automaticRepliesSetting": graphAutoReplyJson(r)}, what = "the automatic replies")
  of akGmail:
    discard callJson("PUT", gmailBase() & "/gmail/v1/users/me/settings/vacation", token,
                     gmailAutoReplyJson(r, acc.email), what = "the vacation responder")
  of akImap:
    raise noAutoReply()
