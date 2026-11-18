## Where an e-mail address's mail is: its IMAP and SMTP servers, found as
## mail programs find them -- the provider's own autoconfig file, the
## Thunderbird list of providers (ISPDB), the domain's DNS (its SRV
## records, RFC 6186 and 8314; its MX records, then the list again for
## the mail host's provider), and last the usual names (imap.example.com,
## mail.example.com). A user types an address and a password; the rest is
## found. With them, where the provider has them: its POP3 server, its
## JMAP session (Fastmail; any domain's by DNS, RFC 8620), and what to do
## where it wants an app password rather than the account's own (Gmail,
## Yahoo, iCloud...).
##
## .. code-block:: nim
##   import retroui/mailsetup
##   let s = findMailServers("me@example.com")
##   if s.found:
##     echo s.imap.host, ":", s.imap.port, " ", s.imap.security   # imap.example.com:993 tls
##     echo s.smtp.host, ":", s.smtp.port, " ", s.smtp.security
##     echo "user name: ", s.imap.user, " (", s.source, ")"
##   if s.pop3.host.len > 0: echo "POP3: ", s.pop3.host
##   if s.jmap.len > 0: echo "JMAP: ", s.jmap
##   if s.appPassword.len > 0: echo s.appPassword     # (where to make one)
##
## Blocking (a few web requests and DNS questions, each waiting at most
## `timeoutSec`): call it from a thread of its own. The addresses it asks
## are changeable for tests: $RETRO_MAIL_ISPDB, $RETRO_MAIL_DOH (DNS over
## HTTPS instead of the system's resolver).
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[strutils, json, xmlparser, xmltree, os, uri]
import http, netconn, dnsquery
export netconn.Security

type
  MailServer* = object
    host*: string
    port*: int
    security*: Security
    user*: string               ## the name to sign in with (the address itself, mostly)
  MailServers* = object
    imap*, smtp*: MailServer
    found*: bool                ## both found (else a guess, to check)
    source*: string             ## where they came from ("the provider", "ISPDB", "DNS", "a guess")
    oauthOnly*: bool            ## the provider takes no password (it wants its own sign-in)
    pop3*: MailServer           ## its POP3 server (host "": none known)
    jmap*: string               ## its JMAP session's address ("": none known)
    appPassword*: string        ## where it wants an app password, how to make one ("": its own password)

proc ispdbBase(): string = getEnv("RETRO_MAIL_ISPDB", "https://autoconfig.thunderbird.net/v1.1/")
proc dohBase(): string = getEnv("RETRO_MAIL_DOH", "https://dns.google/resolve")

proc fill(s, email: string): string =
  let at = email.find('@')
  let local = if at > 0: email[0 ..< at] else: email
  let domain = if at > 0: email[at + 1 .. ^1] else: ""
  s.multiReplace(("%EMAILADDRESS%", email), ("%EMAILLOCALPART%", local),
                 ("%EMAILDOMAIN%", domain))

proc parseAutoconfig*(xml, email: string): MailServers =
  ## Thunderbird's autoconfig file (config-v1.1.xml): its first IMAP and
  ## SMTP servers (TLS ones first).
  var doc: XmlNode
  try: doc = parseXml(xml)
  except CatchableError: return
  proc serverOf(n: XmlNode): MailServer =
    template field(name: string): string =
      (let c = n.child(name); if c == nil: "" else: c.innerText.strip)
    result.host = field("hostname").fill(email)
    result.port = try: parseInt(field("port")) except ValueError: 0
    result.security = case field("socketType").toUpperAscii
                      of "SSL", "TLS": secTls
                      of "STARTTLS": secStartTls
                      else: secNone
    result.user = field("username").fill(email)
    if result.user.len == 0: result.user = email
  var best: array[2, (int, MailServer)]          # (a score: TLS first, a password taken)
  var sawPassword = false
  var sawAny = false
  for p in doc.findAll("emailProvider"):
    for kind in 0 .. 1:
      for n in p.findAll(if kind == 0: "incomingServer" else: "outgoingServer"):
        let want = if kind == 0: "imap" else: "smtp"
        if kind == 0 and n.attr("type").toLowerAscii == "pop3" and result.pop3.host.len == 0:
          let ps = serverOf(n)
          if ps.host.len > 0 and ps.port > 0: result.pop3 = ps
        if n.attr("type").toLowerAscii != want: continue
        sawAny = true
        var auths: seq[string]
        for a in n.findAll("authentication"): auths.add a.innerText.strip.toLowerAscii
        let takesPassword = auths.len == 0 or "password-cleartext" in auths or
                            "plain" in auths or "password-encrypted" in auths
        if takesPassword: sawPassword = true
        let s = serverOf(n)
        if s.host.len == 0 or s.port == 0: continue
        let score = (if s.security == secTls: 3 elif s.security == secStartTls: 2 else: 0) +
                    (if takesPassword: 10 else: 0)
        if best[kind][1].host.len == 0 or score > best[kind][0]:
          best[kind] = (score, s)
  result.imap = best[0][1]
  result.smtp = best[1][1]
  result.found = result.imap.host.len > 0 and result.smtp.host.len > 0
  result.oauthOnly = sawAny and not sawPassword

proc fetchConfig(url, email: string; timeoutSec: int): MailServers =
  let r = httpRequest("GET", url, timeoutSec = timeoutSec)
  if r.status == 200 and "<clientConfig" in r.body:
    result = parseAutoconfig(r.body, email)

proc dns(name, kind: string; timeoutSec: int): seq[string] =
  ## (answers of a DNS question: the system's resolver, `retroui/dnsquery`
  ## -- or, when $RETRO_MAIL_DOH names one, that DNS-over-HTTPS service)
  if getEnv("RETRO_MAIL_DOH").len == 0:
    return dnsLookup(name, kind, timeoutSec)
  let r = httpRequest("GET", dohBase() & "?name=" & encodeUrl(name) & "&type=" & kind,
                      [("Accept", "application/dns-json")], timeoutSec = timeoutSec)
  if not r.ok: return
  try:
    for a in parseJson(r.body){"Answer"}.getElems:
      result.add a{"data"}.getStr
  except CatchableError: discard

proc srv(name: string; timeoutSec: int): tuple[host: string; port: int] =
  ## (the best target of an SRV record: "0 1 993 imap.example.com.")
  var best = int.high
  for d in dns(name, "SRV", timeoutSec):
    let f = d.splitWhitespace
    if f.len == 4 and f[3] != ".":
      let pri = try: parseInt(f[0]) except ValueError: 99
      if pri < best:
        best = pri
        result = (f[3].strip(chars = {'.'}), (try: parseInt(f[2]) except ValueError: 0))

proc baseDomain(host: string): string =
  ## "aspmx.l.google.com" -> "google.com" (two labels; three after a short
  ## second one: "mx.example.co.uk" -> "example.co.uk")
  let p = host.strip(chars = {'.'}).split('.')
  if p.len <= 2: return p.join(".")
  if p[^2].len <= 3 and p[^1].len == 2: p[^3 .. ^1].join(".") else: p[^2 .. ^1].join(".")

proc knownServers(domain, email: string): MailServers =
  ## (the biggest providers, known here: no request needed)
  template both(ih: string; ip: int; isec: Security; sh: string; sp: int; ssec: Security) =
    result = MailServers(imap: MailServer(host: ih, port: ip, security: isec, user: email),
                         smtp: MailServer(host: sh, port: sp, security: ssec, user: email),
                         found: true, source: "the provider")
  template pop(h: string; p = 995; sec = secTls) =
    result.pop3 = MailServer(host: h, port: p, security: sec, user: email)
  case domain
  of "gmail.com", "googlemail.com":
    both("imap.gmail.com", 993, secTls, "smtp.gmail.com", 465, secTls)
    pop("pop.gmail.com")
    result.appPassword = "Gmail wants an app password here: turn on 2-Step Verification, then " &
      "make one at myaccount.google.com/apppasswords (or sign in with Google instead)."
  of "outlook.com", "hotmail.com", "live.com", "msn.com":
    both("outlook.office365.com", 993, secTls, "smtp-mail.outlook.com", 587, secStartTls)
    pop("outlook.office365.com")
  of "yahoo.com", "ymail.com", "rocketmail.com":
    both("imap.mail.yahoo.com", 993, secTls, "smtp.mail.yahoo.com", 465, secTls)
    pop("pop.mail.yahoo.com")
    result.appPassword = "Yahoo wants an app password here: Account Info, Account Security, " &
      "Generate app password (login.yahoo.com/account/security)."
  of "icloud.com", "me.com", "mac.com":
    both("imap.mail.me.com", 993, secTls, "smtp.mail.me.com", 587, secStartTls)
    result.appPassword = "iCloud wants an app-specific password here: appleid.apple.com, " &
      "Sign-In and Security, App-Specific Passwords. Your user name is the part before the @."
    result.imap.user = email.split('@')[0]
  of "aol.com":
    both("imap.aol.com", 993, secTls, "smtp.aol.com", 465, secTls)
    pop("pop.aol.com")
    result.appPassword = "AOL wants an app password here: Account Info, Account Security, " &
      "Generate app password."
  of "fastmail.com", "fastmail.fm":
    both("imap.fastmail.com", 993, secTls, "smtp.fastmail.com", 465, secTls)
    pop("pop.fastmail.com")
    result.jmap = "https://api.fastmail.com/jmap/session"
    result.appPassword = "Fastmail wants an app password (IMAP, POP3) or an API token (JMAP): " &
      "Settings, Privacy & Security, Manage app passwords and access."
  of "gmx.com", "gmx.net", "gmx.de":
    both("imap.gmx.net", 993, secTls, "mail.gmx.net", 465, secTls)
    pop("pop.gmx.net")
    result.appPassword = "GMX: turn on POP3 and IMAP first, in its settings (E-mail, POP3 & IMAP)."
  of "web.de":
    both("imap.web.de", 993, secTls, "smtp.web.de", 587, secStartTls)
    pop("pop3.web.de")
    result.appPassword = "WEB.DE: turn on POP3 and IMAP first, in its settings (E-Mail, POP3/IMAP)."
  of "mailbox.org":
    both("imap.mailbox.org", 993, secTls, "smtp.mailbox.org", 465, secTls)
    pop("pop3.mailbox.org")
  of "posteo.de", "posteo.net":
    both("posteo.de", 993, secTls, "posteo.de", 465, secTls)
    pop("posteo.de")
  of "zoho.com", "zohomail.com":
    both("imap.zoho.com", 993, secTls, "smtp.zoho.com", 465, secTls)
    pop("pop.zoho.com")
    result.appPassword = "Zoho: turn on IMAP or POP access in Mail Settings; with two-factor " &
      "sign-in, make an app password (accounts.zoho.com, Security, App Passwords)."
  of "yandex.com", "yandex.ru", "ya.ru":
    both("imap.yandex.com", 993, secTls, "smtp.yandex.com", 465, secTls)
    pop("pop.yandex.com")
    result.appPassword = "Yandex wants an app password here: id.yandex.com, Security, App passwords."
  of "mail.ru", "inbox.ru", "list.ru", "bk.ru":
    both("imap.mail.ru", 993, secTls, "smtp.mail.ru", 465, secTls)
    pop("pop.mail.ru")
    result.appPassword = "Mail.ru wants an app password here: its settings, Security, Passwords for " &
      "external applications."
  of "proton.me", "protonmail.com", "pm.me":
    # (Proton's mail is read through its Bridge, on this computer)
    both("127.0.0.1", 1143, secStartTls, "127.0.0.1", 1025, secStartTls)
    result.source = "Proton Mail Bridge, on this computer"
    result.appPassword = "Proton: run Proton Mail Bridge on this computer and use the password it " &
      "shows (not your Proton password)."
  else: discard

proc findMailServers*(email: string; timeoutSec = 8): MailServers =
  ## The IMAP and SMTP servers of `email`'s mail (`found` false: a guess
  ## by the usual names, for the user to check).
  let e = email.strip
  let at = e.rfind('@')
  if at <= 0 or at == e.high: return
  let domain = e[at + 1 .. ^1].toLowerAscii
  result = knownServers(domain, e)
  if result.found: return
  # (a JMAP server of the domain's own, by DNS: RFC 8620's SRV record)
  let j = srv("_jmap._tcp." & domain, timeoutSec)
  let jmapUrl = if j.host.len > 0: "https://" & j.host & (if j.port in [0, 443]: "" else: ":" & $j.port) &
                                   "/.well-known/jmap" else: ""
  defer:
    if result.jmap.len == 0: result.jmap = jmapUrl
  # the provider's own file, then the Thunderbird list
  for (url, src) in [("https://autoconfig." & domain & "/mail/config-v1.1.xml?emailaddress=" &
                      encodeUrl(e), "the provider"),
                     ("https://" & domain & "/.well-known/autoconfig/mail/config-v1.1.xml", "the provider"),
                     (ispdbBase() & domain, "ISPDB")]:
    let s = fetchConfig(url, e, timeoutSec)
    if s.found:
      result = s
      result.source = src
      return
  # DNS: SRV records (RFC 6186, 8314)
  var imapS = srv("_imaps._tcp." & domain, timeoutSec)
  var imapSec = secTls
  if imapS.host.len == 0:
    imapS = srv("_imap._tcp." & domain, timeoutSec)
    imapSec = secStartTls
  var smtpS = srv("_submissions._tcp." & domain, timeoutSec)
  var smtpSec = secTls
  if smtpS.host.len == 0:
    smtpS = srv("_submission._tcp." & domain, timeoutSec)
    smtpSec = secStartTls
  if imapS.host.len > 0 and smtpS.host.len > 0:
    result = MailServers(imap: MailServer(host: imapS.host, port: imapS.port, security: imapSec, user: e),
                         smtp: MailServer(host: smtpS.host, port: smtpS.port, security: smtpSec, user: e),
                         found: true, source: "DNS")
    return
  # the mail host's provider (a domain whose mail Google or Microsoft keeps)
  var mx = ""
  var bestPri = int.high
  for d in dns(domain, "MX", timeoutSec):
    let f = d.splitWhitespace
    if f.len == 2:
      let pri = try: parseInt(f[0]) except ValueError: 99
      if pri < bestPri:
        bestPri = pri
        mx = f[1].strip(chars = {'.'}).toLowerAscii
  if mx.len > 0:
    let base = baseDomain(mx)
    if base in ["google.com", "googlemail.com"]:
      result = knownServers("gmail.com", e)
      result.source = "DNS (Google keeps its mail)"
      return
    if base in ["outlook.com", "office365.us"] or mx.endsWith(".protection.outlook.com"):
      result = MailServers(imap: MailServer(host: "outlook.office365.com", port: 993, security: secTls, user: e),
                           smtp: MailServer(host: "smtp.office365.com", port: 587, security: secStartTls, user: e),
                           found: true, source: "DNS (Microsoft 365 keeps its mail)")
      return
    if base != domain:
      let s = fetchConfig(ispdbBase() & base, e, timeoutSec)
      if s.found:
        result = s
        result.source = "ISPDB (the mail host's provider)"
        return
  # a guess: the usual names
  result = MailServers(imap: MailServer(host: "imap." & domain, port: 993, security: secTls, user: e),
                       smtp: MailServer(host: "smtp." & domain, port: 465, security: secTls, user: e),
                       found: false, source: "a guess")
  if mx.len > 0 and baseDomain(mx) == domain:
    # (the domain's own mail host: often its IMAP and SMTP too)
    result.imap.host = mx
    result.smtp.host = mx

proc securityName*(s: Security): string =
  ## For a form: "SSL/TLS", "STARTTLS", "None".
  case s
  of secTls: "SSL/TLS"
  of secStartTls: "STARTTLS"
  of secNone: "None"

proc defaultPort*(imap: bool; s: Security): int =
  ## The usual port: IMAP 993 / 143, SMTP 465 / 587.
  if imap: (if s == secTls: 993 else: 143)
  else: (if s == secTls: 465 else: 587)
