## A message's HTML made safe to read, and what in a message is there to
## fool: tracking pictures (the invisible ones that tell a sender when the
## message was opened) taken out, tracking codes (utm_source, fbclid,
## gclid...) taken off links, links whose words name one site but go to
## another, links that hide where they go (an address before an "@", an IP
## address, letters from another alphabet), and senders whose name says
## one company while the mail comes from another, or whose domain looks
## like a well-known one ("paypa1.com") or like one of the user's own
## contacts'.
##
## .. code-block:: nim
##   let r = cleanMail(html)
##   echo r.trackers, " tracking pictures taken out"
##   for l in r.links: echo l.shown, " -> ", l.real, ": ", l.why
##   show(r.html)
##   for w in senderWarnings("PayPal Service", "help@paypa1-secure.com"): echo w
##   let why = linkWarning(href, linkText)  # before opening a link
##
## None of it needs the network; none of it raises.
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[strutils, uri]
import domains
from htmldom import decodeEntities

type
  LinkProblem* = object
    ## A link that is not what it looks like.
    href*: string       ## where it goes
    text*: string       ## its words
    shown*, real*: string  ## the site its words name ("" none) and the one it goes to
    why*: string        ## in words
    deceptive*: bool    ## made to fool (a look-alike, a hidden address), not just a link through a mailer
  MailSafety* = object
    html*: string            ## the HTML, tracking pictures out and tracking codes off its links
    trackers*: int           ## tracking pictures taken out
    codes*: int              ## links that had tracking codes
    links*: seq[LinkProblem] ## links whose words name another site, or that hide where they go

  Brand = tuple[name: string; domains: seq[string]]

const
  trackingParams = ["fbclid", "gclid", "gclsrc", "dclid", "gbraid", "wbraid", "msclkid", "mc_cid",
    "mc_eid", "_hsenc", "_hsmi", "__hssc", "__hstc", "__hsfp", "hsctatracking", "mkt_tok", "igshid",
    "yclid", "_openstat", "oly_anon_id", "oly_enc_id", "vero_conv", "vero_id", "rb_clickid",
    "s_cid", "ml_subscriber", "ml_subscriber_hash", "ss_source", "ss_campaign_id", "ss_email_id",
    "trk_contact", "trk_msg", "trk_module", "trk_sid", "sc_cid", "et_rid", "et_cid", "ef_id",
    "cmpid", "_bta_tid", "_bta_c", "wickedid", "twclid", "ttclid", "li_fat_id", "epik", "_kx",
    "obem", "spm", "scm", "xtor", "elqtrackid", "elqtrack", "elq", "elqcampaignid", "assetid",
    "assettype", "recipientid", "campaignid", "siteid", "redirect_log_mongo_id",
    "redirect_mongo_id", "sb_referer_host", "mbid", "pk_campaign", "pk_kwd", "piwik_campaign",
    "piwik_kwd", "matomo_campaign", "mtm_campaign", "mtm_source", "mtm_medium", "mtm_content"]
  trackerPaths = ["/track/open", "/wf/open", "/e2t/o", "/open.gif", "/open.php", "/o.gif",
    "/beacon", "/pixel", "/trk/open", "/t/open", "/open.aspx", "/emimp/", "/view.gif",
    "/email/open", "/mailopen", "/openpixel", "/tr/op/", "/ss/o/", "/q/open", "/o.php?",
    "/track/o", "/e/o/", "/imp?", "/impression", "/tracking/open", "/v/open", "/emailopen"]
  trackerHosts = ["mailtrack.io", "mixmax.com", "yesware.com", "bananatag.com", "getnotify.com",
    "mailstat.us", "sidekickopen", "t.yesware.com", "pixel.wp.com", "pixel.mathtag.com",
    "mltrk.io", "trk.klclick.com", "ct.sendgrid.net", "open.convertkit-mail.com", "trace.mailpace",
    "mandrillapp.com", "emltrk.com", "pstmrk.it", "track.customer.io", "email.mg.",
    "go.pardot.com/e", "ablink.", "clicks.aweber.com/y/ct"]

let brands: seq[Brand] = @[
  ("PayPal", @["paypal.com", "paypal.me", "paypal-communication.com", "paypalobjects.com", "paypal.co.uk",
              "paypal.de", "paypal.fr", "paypal.it", "paypal.es", "paypal.nl", "paypal.com.au", "paypal.ca"]),
  ("Apple", @["apple.com", "icloud.com", "me.com", "mac.com", "itunes.com", "apple.news"]),
  ("iCloud", @["icloud.com", "apple.com", "me.com"]),
  ("Microsoft", @["microsoft.com", "outlook.com", "office.com", "live.com", "microsoftonline.com",
                  "office365.com", "hotmail.com", "msn.com", "sharepoint.com", "onmicrosoft.com",
                  "microsoftstore.com", "xbox.com", "skype.com", "bing.com", "azure.com", "teams.microsoft.com"]),
  ("Outlook", @["outlook.com", "microsoft.com", "office.com", "live.com", "hotmail.com"]),
  ("Office 365", @["microsoft.com", "office.com", "office365.com", "microsoftonline.com", "outlook.com"]),
  ("OneDrive", @["microsoft.com", "onedrive.com", "live.com", "sharepoint.com"]),
  ("Google", @["google.com", "gmail.com", "googlemail.com", "youtube.com", "accounts.google.com", "google.org"]),
  ("Gmail", @["google.com", "gmail.com", "googlemail.com"]),
  ("YouTube", @["youtube.com", "google.com"]),
  ("Amazon", @["amazon.com", "amazonses.com", "amazon.co.uk", "amazon.de", "amazon.fr", "amazon.ae",
               "amazon.sa", "amazon.in", "amazon.co.jp", "amazon.ca", "amazon.it", "amazon.es",
               "amazon.com.au", "amazon.nl", "amazon.eg", "amazon.com.tr", "aws.amazon.com", "primevideo.com"]),
  ("Netflix", @["netflix.com", "mailer.netflix.com"]),
  ("Facebook", @["facebook.com", "facebookmail.com", "meta.com", "fb.com"]),
  ("Meta", @["meta.com", "facebook.com", "facebookmail.com", "instagram.com", "whatsapp.com"]),
  ("Instagram", @["instagram.com", "facebookmail.com", "mail.instagram.com", "meta.com"]),
  ("WhatsApp", @["whatsapp.com", "facebookmail.com", "meta.com"]),
  ("LinkedIn", @["linkedin.com"]),
  ("DHL", @["dhl.com", "dhl.de", "dhl.co.uk", "dhl.fr", "dpdhl.com", "dhl-news.com"]),
  ("FedEx", @["fedex.com"]),
  ("UPS", @["ups.com"]),
  ("Aramex", @["aramex.com"]),
  ("DocuSign", @["docusign.com", "docusign.net"]),
  ("Dropbox", @["dropbox.com", "dropboxmail.com"]),
  ("Coinbase", @["coinbase.com"]),
  ("Binance", @["binance.com"]),
  ("eBay", @["ebay.com", "ebay.co.uk", "ebay.de", "ebay.fr"]),
  ("Spotify", @["spotify.com"]),
  ("Steam", @["steampowered.com", "steamcommunity.com", "valvesoftware.com"]),
  ("Zoom", @["zoom.us", "zoom.com"]),
  ("Chase", @["chase.com", "jpmorgan.com", "jpmchase.com"]),
  ("Wells Fargo", @["wellsfargo.com"]),
  ("Bank of America", @["bankofamerica.com", "bofa.com", "ealerts.bankofamerica.com"]),
  ("Citibank", @["citi.com", "citibank.com"]),
  ("HSBC", @["hsbc.com", "hsbc.co.uk", "hsbc.ae", "hsbc.com.hk"]),
  ("American Express", @["americanexpress.com", "aexp.com"]),
  ("Visa", @["visa.com"]),
  ("Mastercard", @["mastercard.com"]),
  ("Adyen", @["adyen.com"]),
  ("Stripe", @["stripe.com"]),
  ("GitHub", @["github.com", "githubusercontent.com"]),
  ("Yahoo", @["yahoo.com", "yahoo-inc.com", "yahoomail.com"]),
  ("Twitter", @["twitter.com", "x.com"]),
  ("TikTok", @["tiktok.com", "tiktokv.com"]),
  ("Telegram", @["telegram.org"]),
  ("Booking.com", @["booking.com"]),
  ("Airbnb", @["airbnb.com"]),
  ("Uber", @["uber.com"]),
  ("Careem", @["careem.com"]),
  ("Emirates", @["emirates.com", "emirates.email"]),
  ("Qatar Airways", @["qatarairways.com"]),
  ("Oman Air", @["omanair.com"]),
  ("Omantel", @["omantel.om"]),
  ("Ooredoo", @["ooredoo.om", "ooredoo.qa", "ooredoo.com"]),
  ("Bank Muscat", @["bankmuscat.com"]),
  ("Al Rajhi", @["alrajhibank.com.sa"]),
  ("Etisalat", @["etisalat.ae", "eand.com"]),
  ("STC", @["stc.com.sa"])]

# ---- links -------------------------------------------------------------------------

proc hostOf(url: string): string =
  ## (the host a link goes to, lower case, letters as letters; "" none)
  var u = url.strip
  let low = u.toLowerAscii
  var k = low.find("://")
  if k < 0:
    if low.startsWith("www."): k = -3
    else: return ""
  u = u[k + 3 .. ^1]
  var e = 0
  while e < u.len and u[e] notin {'/', '?', '#', '\\'}: inc e
  var auth = u[0 ..< e]
  let at = auth.rfind('@')
  if at >= 0: auth = auth[at + 1 .. ^1]
  if auth.startsWith("["):
    let b = auth.find(']')
    return (if b > 0: auth[0 .. b] else: auth)
  let colon = auth.rfind(':')
  if colon >= 0: auth = auth[0 ..< colon]
  toUnicodeHost(decodeUrl(auth))

proc stripTracking*(url: string): string =
  ## `url` without its tracking codes (utm_*, fbclid, gclid, mc_eid...): the
  ## page is the same, the sender learns nothing from the visit.
  let q = url.find('?')
  if q < 0: return url
  var hash = url.find('#', q)
  let tail = if hash >= 0: url[hash .. ^1] else: ""
  let query = url[q + 1 ..< (if hash >= 0: hash else: url.len)]
  var kept: seq[string]
  for part in query.split('&'):
    if part.len == 0: continue
    let e = part.find('=')
    let name = decodeUrl(if e >= 0: part[0 ..< e] else: part).toLowerAscii
    if name.startsWith("utm_") or name in trackingParams: continue
    kept.add part
  url[0 ..< q] & (if kept.len > 0: "?" & kept.join("&") else: "") & tail

proc looksLikeLink(t: string): string =
  ## (the host a link's words name, when they are an address: "www.paypal.com",
  ## "https://example.com/x", "paypal.com/login"; "" when they are words)
  var s = t.strip(chars = Whitespace + {'<', '>', '(', ')', '[', ']', '"', '\''})
  if s.len < 4 or ' ' in s: return ""
  let low = s.toLowerAscii
  if low.startsWith("mailto:"): return ""
  if not (low.startsWith("http://") or low.startsWith("https://")):
    if '@' in s: return ""
    s = "https://" & s
  let h = hostOf(s)
  if '.' notin h or h.endsWith("."): return ""
  let tld = h[h.rfind('.') + 1 .. ^1]
  if tld.len < 2: return ""
  for c in tld:
    if c in {'0'..'9'}:
      return (if isIpHost(h): h else: "")
  h

proc brandOfDomain(host: string): string =
  ## (the brand whose domain this one looks like without being it -- the
  ## same look, "paypa1.com", or its name with words added, "paypal-secure.com"
  ## -- "" none)
  let reg = registrableDomain(host)
  if reg.len == 0: return ""
  for b in brands:
    for d in b.domains:
      if reg == registrableDomain(d): return ""
  let label = reg[0 ..< max(0, reg.find('.'))]
  let words = skeleton(label).split('-')
  for b in brands:
    for d in b.domains:
      if looksLike(reg, d): return b.name
      let theirs = registrableDomain(d)
      let tl = theirs[0 ..< max(0, theirs.find('.'))]
      if tl.len >= 5 and words.len > 1 and skeleton(tl) in words: return b.name

proc brandSite(host: string): string =
  ## (the brand whose own site this is: "" none)
  let reg = registrableDomain(host)
  if reg.len == 0: return ""
  for b in brands:
    for d in b.domains:
      if reg == registrableDomain(d): return b.name

proc hidden(href: string): string =
  ## (why a link's address itself is made to fool; "" it is not)
  let low = href.toLowerAscii.strip
  let k = low.find("://")
  if k > 0:
    var e = k + 3
    while e < low.len and low[e] notin {'/', '?', '#'}: inc e
    if '@' in low[k + 3 ..< e]:
      return "the address hides where it goes (a name before an @)"
  let h = hostOf(href)
  if h.len == 0: return ""
  if isIpHost(h): return "it goes to a bare IP address, not a named site"
  if mixedScripts(h): return "its address mixes letters of two alphabets"
  let b = brandOfDomain(h)
  if b.len > 0: return "it goes to " & h & ", which looks like " & b & "'s site but is not"

proc linkProblem(href, text: string): LinkProblem =
  result.href = href
  result.text = text
  let real = hostOf(href)
  result.real = real
  let why = hidden(href)
  if why.len > 0:
    result.why = why
    result.deceptive = true
    return
  let shown = looksLikeLink(text)
  result.shown = shown
  if shown.len == 0 or real.len == 0: return
  let a = registrableDomain(shown)
  let b = registrableDomain(real)
  if (a.len > 0 and a == b) or shown == real: return
  result.why = "its words say " & shown & " but it goes to " & real
  # (a look-alike of the site named, or of a known brand's: made to fool)
  result.deceptive = looksLike(real, shown) or brandSite(shown).len > 0

proc linkWarning*(href, text: string): string =
  ## Why a link should not be opened without a second look ("" it is fine):
  ## its words name another site, it hides where it goes, it looks like a
  ## well-known site's but is not, or it runs a script.
  let low = href.strip.toLowerAscii
  if low.startsWith("javascript:") or low.startsWith("vbscript:") or low.startsWith("data:"):
    return "it runs something rather than opening a page"
  linkProblem(href, text).why

# ---- the HTML ---------------------------------------------------------------------

proc attrs(tag: string): seq[(string, string)] =
  ## (a tag's attributes: names lower case, values with their entities read)
  var i = 1
  while i < tag.len and tag[i] notin Whitespace + {'>', '/'}: inc i
  while i < tag.len:
    while i < tag.len and tag[i] in Whitespace + {'/'}: inc i
    if i >= tag.len or tag[i] == '>': break
    let ns = i
    while i < tag.len and tag[i] notin Whitespace + {'=', '>', '/'}: inc i
    let name = tag[ns ..< i].toLowerAscii
    while i < tag.len and tag[i] in Whitespace: inc i
    var value = ""
    if i < tag.len and tag[i] == '=':
      inc i
      while i < tag.len and tag[i] in Whitespace: inc i
      if i < tag.len and tag[i] in {'"', '\''}:
        let q = tag[i]
        let e = tag.find(q, i + 1)
        let stop = if e < 0: tag.len else: e
        value = tag[i + 1 ..< stop]
        i = stop + 1
      else:
        let vs = i
        while i < tag.len and tag[i] notin Whitespace + {'>'}: inc i
        value = tag[vs ..< i]
    if name.len > 0: result.add (name, decodeEntities(value, inAttr = true))
    if result.len > 100: break

proc attrOf(a: seq[(string, string)]; name: string): string =
  for (k, v) in a:
    if k == name: return v

proc smallSize(v: string): bool =
  let t = v.strip.toLowerAscii.replace("px", "")
  if t.len == 0: return false
  try: parseFloat(t) <= 3.0 except ValueError: false

proc styleSays(style, prop: string): string =
  let s = style.toLowerAscii
  var i = 0
  while true:
    let k = s.find(prop, i)
    if k < 0: return ""
    if k == 0 or s[k - 1] in {';', ' ', '\t', '"', '\n'}:
      var j = k + prop.len
      while j < s.len and s[j] == ' ': inc j
      if j < s.len and s[j] == ':':
        let e = s.find(';', j)
        return s[j + 1 ..< (if e < 0: s.len else: e)].strip
    i = k + 1

proc isTracker*(src: string; width = ""; height = ""; style = ""): bool =
  ## An <img> that is there only to tell the sender the message was read: a
  ## picture of a pixel or two, or hidden, or from a tracking service.
  let low = src.toLowerAscii
  if not (low.startsWith("http://") or low.startsWith("https://") or low.startsWith("//")): return false
  let w = if width.len > 0: width else: styleSays(style, "width")
  let h = if height.len > 0: height else: styleSays(style, "height")
  if (smallSize(w) and (h.len == 0 or smallSize(h))) or (smallSize(h) and w.len == 0): return true
  if styleSays(style, "display") == "none" or styleSays(style, "visibility") == "hidden" or
     styleSays(style, "opacity") in ["0", "0.0"]: return true
  for p in trackerPaths:
    if p in low: return true
  let host = hostOf(if low.startsWith("//"): "https:" & low else: low)
  for t in trackerHosts:
    if host.startsWith(t) or ("." & t) in ("." & host) or (t.endsWith(".") and t in host):
      return true

proc innerText(html: string): string =
  var inTag = false
  for c in html:
    if c == '<': inTag = true
    elif c == '>': inTag = false
    elif not inTag: result.add c
  decodeEntities(result).strip

proc cleanMail*(html: string): MailSafety =
  ## `html` without its tracking pictures, its links without tracking
  ## codes, and the links that are not what they look like.
  result.html = newStringOfCap(html.len)
  var i = 0
  let low = html.toLowerAscii
  while i < html.len:
    let k = html.find('<', i)
    if k < 0:
      result.html.add html[i .. ^1]
      break
    result.html.add html[i ..< k]
    if low.continuesWith("<!--", k):
      let e = html.find("-->", k + 4)
      let stop = if e < 0: html.len else: e + 3
      result.html.add html[k ..< stop]
      i = stop
      continue
    let e = html.find('>', k)
    if e < 0:
      result.html.add html[k .. ^1]
      break
    let tag = html[k .. e]
    let name = block:
      var j = k + 1
      while j < e and low[j] notin Whitespace + {'>', '/'}: inc j
      low[k + 1 ..< j]
    case name
    of "img":
      let a = attrs(tag)
      if isTracker(a.attrOf("src"), a.attrOf("width"), a.attrOf("height"), a.attrOf("style")):
        inc result.trackers
      else: result.html.add tag
    of "a", "area":
      let a = attrs(tag)
      let href = a.attrOf("href")
      var outTag = tag
      if href.len > 0:
        let clean = stripTracking(href)
        if clean != href:
          inc result.codes
          # (the tag again, its href the clean one)
          var rebuilt = "<" & name
          for (n, v) in a:
            rebuilt.add " " & n & "=\"" & (if n == "href": clean else: v).multiReplace(
              ("&", "&amp;"), ("\"", "&quot;"), ("<", "&lt;"), (">", "&gt;")) & "\""
          rebuilt.add ">"
          outTag = rebuilt
        if name == "a":
          let close = low.find("</a", e)
          let words = innerText(html[e + 1 ..< (if close < 0: html.len else: close)])
          let p = linkProblem(href, words)
          if p.why.len > 0 and result.links.len < 50: result.links.add p
        else:
          let p = linkProblem(href, a.attrOf("alt"))
          if p.why.len > 0 and result.links.len < 50: result.links.add p
      result.html.add outTag
    else: result.html.add tag
    i = e + 1

# ---- the sender -------------------------------------------------------------------

proc wordIn(hay, word: string): bool =
  ## (`word` in `hay` as a word of its own, case aside: "PayPal" in "PayPal
  ## Service", not in "PayPalooza")
  let h = hay.toLowerAscii
  let w = word.toLowerAscii
  var i = 0
  while true:
    let k = h.find(w, i)
    if k < 0: return false
    let before = k == 0 or not h[k - 1].isAlphaNumeric
    let after = k + w.len >= h.len or not h[k + w.len].isAlphaNumeric
    if before and after: return true
    i = k + 1

const plainWords = ["Chase", "Visa", "Steam", "Zoom", "Uber", "Meta", "Emirates", "Stripe", "Telegram",
                    "Outlook", "STC", "Careem", "Booking.com", "Twitter", "Adyen", "Ooredoo", "UPS"]
  ## (brands whose names are also words or names people have: "Chase Smith"
  ## is not the bank -- their names in a sender's name are not taken as theirs)

proc brandDomain(b: Brand; domain: string): bool =
  let reg = registrableDomain(domain)
  for d in b.domains:
    if reg == registrableDomain(d) or domain == d or domain.endsWith("." & d): return true

proc senderWarnings*(fromName, fromEmail: string; known: openArray[string] = []): seq[string] =
  ## What about a sender is there to fool: a name that says a company
  ## ("PayPal Service") on mail from another one's domain, an address in
  ## the name that is not the sender's, a domain that looks like a
  ## well-known one or like one of `known` (the domains the user writes to)
  ## without being it, letters of two alphabets in the domain.
  let at = fromEmail.rfind('@')
  if at < 0: return
  let domain = toUnicodeHost(fromEmail[at + 1 .. ^1].strip(chars = {'>', ' '}))
  let reg = registrableDomain(domain)
  let name = fromName.strip
  # an address in the name that is not the sender's own
  for w0 in name.multiReplace(("<", " "), (">", " "), ("\"", " "), ("'", " "), ("(", " "), (")", " ")).splitWhitespace:
    let w = w0.strip(chars = {',', ';', ':', '.', '[', ']'})
    if '@' in w and '.' in w and w.toLowerAscii != fromEmail.toLowerAscii.strip:
      result.add "its name shows the address " & w & ", but it is from " & fromEmail
      break
  # a company's name on another company's mail
  for b in brands:
    if b.name notin plainWords and wordIn(name, b.name) and not brandDomain(b, domain):
      # (the name of the user's own correspondent's company -- "Sam at Acme" -- is not a brand)
      result.add "its name says " & b.name & ", but it is from " & (if reg.len > 0: reg else: domain) &
                 ", not " & b.name
      break
  if mixedScripts(domain):
    result.add "its address mixes letters of two alphabets (" & domain & ")"
  if reg.len > 0:
    let b = brandOfDomain(reg)
    if b.len > 0:
      result.add "its domain " & reg & " looks like " & b & "'s, but is not"
    else:
      for k in known:
        if looksLike(reg, k):
          result.add "its domain " & reg & " looks like " & registrableDomain(k) &
                     " (whom you write to), but is not"
          break
