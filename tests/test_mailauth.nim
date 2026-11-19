## Who a message is from (retroui/mailauth, retroui/dnsquery,
## retroui/domains): DKIM signatures verified here -- RFC 8463's own
## example (Ed25519 and RSA) and messages dkimpy signed (another program),
## in each canonicalization, changed after signing, with keys withdrawn or
## testing; providers' Authentication-Results, trusted from their own
## servers only and only the topmost; DMARC policies; the Public Suffix
## List, IDN and look-alike names; DNS over UDP and TCP against a server of
## the test's own (tests/dnsmock.py).
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[os, osproc, strutils, tables, exitprocs, times, streams]
import retroui/[mailauth, dnsquery, domains]

var failures = 0
template check(cond: bool; what: string) =
  if cond: echo "  ok   ", what
  else:
    echo "  FAIL ", what
    inc failures

let data = currentSourcePath().parentDir / "data" / "dkim"
var zone = initTable[string, seq[string]]()
for line in lines(data / "zone.txt"):
  if line.len == 0 or line[0] == '#': continue
  let sp = line.find(' ')
  zone.mgetOrPut(line[0 ..< sp].toLowerAscii, @[]).add line[sp + 1 .. ^1]
zone["_dmarc.paypal.example"] = @["v=DMARC1; p=reject; rua=mailto:d@paypal.example"]
zone["_dmarc.example.org"] = @["v=DMARC1; p=none"]
zone["_dmarc.strict.example"] = @["v=DMARC1; p=quarantine; sp=reject"]

proc stub(name: string): DnsResult {.gcsafe.} =
  {.cast(gcsafe).}:
    let n = name.toLowerAscii
    if n in zone: DnsResult(status: dnsOk, answers: zone[n])
    else: DnsResult(status: dnsNoName)

proc offline(name: string): DnsResult {.gcsafe.} = DnsResult(status: dnsFailed, error: "offline")

proc only(raw: string; lookup: TxtLookup = stub): DkimResult =
  let r = verifyDkim(raw, lookup)
  if r.len > 0: r[0] else: DkimResult(state: dkimFail, detail: "no signature")

block rfc8463:
  echo "RFC 8463's example message (LF line ends, as a file has them)"
  let raw = readFile(data / "rfc8463.eml")
  let r = verifyDkim(raw, stub)
  check r.len == 2, "two signatures"
  check r.len == 2 and r[0].state == dkimPass and r[0].selector == "brisbane", "the Ed25519 one verifies"
  check r.len == 2 and r[1].state == dkimPass and r[1].selector == "test", "the RSA one verifies"
  let c = checkSender(raw, lookup = stub)
  check c.state == senderVerified and c.domain == "football.example.com" and c.by == "this device",
        "the sender is proven: " & c.detail
  let changed = raw.replace("We lost the game.", "We won the game.")
  let r2 = verifyDkim(changed, stub)
  check r2.len == 2 and r2[0].state == dkimFail and r2[1].state == dkimFail and
        "body" in r2[0].detail, "a changed body does not verify"
  let changed2 = raw.replace("Subject: Is dinner ready?", "Subject: Is lunch ready?")
  let r3 = verifyDkim(changed2, stub)
  check r3.len == 2 and r3[0].state == dkimFail and r3[1].state == dkimFail, "a changed Subject does not verify"
  let r4 = verifyDkim(raw.replace("\n", "\r\n"), stub)
  check r4.len == 2 and r4[0].state == dkimPass and r4[1].state == dkimPass, "the same with CRLF line ends"
  check only(raw, offline).state == dkimTempError, "no network: asked again later, not failed"

block otherSigner:
  echo "messages dkimpy signed"
  for name in ["rsa-relaxed-relaxed", "rsa-simple-simple", "rsa-relaxed-simple", "rsa-simple-relaxed",
               "ed-relaxed-relaxed", "ed-simple-simple", "ed-relaxed-simple", "ed-simple-relaxed",
               "rsa-empty-body", "rsa-empty-body-simple"]:
    let r = only(readFile(data / name & ".eml"))
    check r.state == dkimPass and r.domain == "example.org", name & " verifies (" & r.detail & ")"
  let base = readFile(data / "rsa-relaxed-relaxed.eml")
  check only(base.replace("Subject:   A   report", "Subject: A report")).state == dkimPass,
        "relaxed: spaces in a header line may change"
  check only(base.replace("Subject:   A   report", "Subject:   A   rep0rt")).state == dkimFail,
        "relaxed: letters may not"
  check only(base.replace("Last line.\r\n", "Last line.\r\n\r\n\r\n\r\n")).state == dkimPass,
        "empty lines added at the end are nothing"
  check only(base.replace("Last line.", "Last line. ")).state == dkimPass,
        "relaxed body: a space at a line's end is nothing"
  let simple = readFile(data / "rsa-simple-simple.eml")
  check only(simple.replace("Last line.", "Last line. ")).state == dkimFail,
        "simple body: it is a change"
  check only(base.replace("From: =?UTF-8?B?2LPZhNi32KfZhg==?= <sultan@mail.example.org>",
                          "From: =?UTF-8?B?2LPZhNi32KfZhg==?= <sultan@mail.example.org>\r\nFrom: boss@example.com")).state == dkimFail,
        "a second From added (signed once more: oversigned) does not verify"
  let t = only(readFile(data / "rsa-testing.eml"))
  check t.state == dkimNeutral and "testing" in t.detail, "a testing key proves nothing"
  check only(readFile(data / "rsa-revoked.eml")).state == dkimFail, "a withdrawn key fails"
  let l = only(readFile(data / "rsa-length.eml"))
  check l.state == dkimNeutral and "part" in l.detail, "l= with text added after: proves nothing"
  let c = checkSender(base, lookup = stub)
  check c.state == senderVerified and c.domain == "mail.example.org",
        "mail.example.org signed by example.org: the same organization"

block authResults:
  echo "providers' Authentication-Results"
  let g = parseAuthResults("mx.google.com;\r\n       dkim=pass header.i=@example.com header.s=s1 header.b=AbC;\r\n" &
    "       spf=pass (google.com: domain of a@example.com designates 1.2.3.4 as permitted sender) smtp.mailfrom=a@example.com;\r\n" &
    "       dmarc=pass (p=REJECT sp=REJECT dis=NONE) header.from=example.com")
  check g.authserv == "mx.google.com" and g.results.len == 3 and g.results[2].meth == "dmarc" and
        g.results[2].result == "pass" and g.results[2].prop("header.from") == "example.com",
        "Gmail's header read"
  let ms = parseAuthResults("spf=pass (sender IP is 209.85.1.2) smtp.mailfrom=gmail.com; dkim=pass " &
    "(signature was verified) header.d=gmail.com;dmarc=pass action=none header.from=gmail.com;compauth=pass reason=100")
  check ms.authserv == "" and ms.results.len == 4 and ms.results[3].meth == "compauth",
        "Microsoft's (no server named) read"
  let semi = parseAuthResults("mx.example.net 1; dkim=pass header.d=\"a;b.example\"")
  check semi.authserv == "mx.example.net" and semi.results.len == 1 and
        semi.results[0].prop("header.d") == "a;b.example", "a version and a quoted ';'"
  proc hdrs(arTop, arDeep, frm: string): seq[(string, string)] =
    if arTop.len > 0: result.add ("Authentication-Results", arTop)
    result.add ("Received", "from mx.attacker.example")
    if arDeep.len > 0: result.add ("Authentication-Results", arDeep)
    result.add ("From", frm)
  let gm = providerAuthservs("imap.gmail.com")
  var c = checkHeaders(hdrs("mx.google.com; dmarc=pass header.from=paypal.example", "", "PayPal <service@paypal.example>"), gm)
  check c.state == senderVerified and c.by == "mx.google.com", "Gmail: DMARC passed"
  c = checkHeaders(hdrs("mx.google.com; dmarc=fail (p=REJECT) header.from=paypal.example", "", "PayPal <service@paypal.example>"), gm)
  check c.state == senderFailed, "Gmail: DMARC failed"
  c = checkHeaders(hdrs("mx.google.com; spf=neutral", "mx.google.com; dmarc=pass header.from=paypal.example",
                        "PayPal <service@paypal.example>"), gm)
  check c.state == senderUnknown, "a second one, written lower down by the sender, is not believed"
  c = checkHeaders(hdrs("", "mx.google.com; dmarc=pass header.from=paypal.example", "PayPal <service@paypal.example>"),
                   providerAuthservs("imap.example.net"))
  check c.state == senderUnknown, "nor one of a provider the account is not with"
  c = checkHeaders(hdrs("mx.google.com; dmarc=pass header.from=other.example", "", "PayPal <service@paypal.example>"), gm)
  check c.state == senderUnknown, "a pass for another domain is not this sender's"
  c = checkHeaders(hdrs("mx.google.com; dkim=pass header.d=news.paypal.example; spf=fail", "",
                        "PayPal <service@paypal.example>"), gm)
  check c.state == senderVerified and "news.paypal.example" in c.detail, "an aligned DKIM pass the provider saw"
  c = checkHeaders(hdrs("mx.google.com; dkim=pass header.d=mailer.example", "", "PayPal <service@paypal.example>"), gm)
  check c.state == senderUnknown, "a pass of an unaligned domain proves nothing"
  let msHeaders = hdrs("spf=fail (sender IP is 1.2.3.4) smtp.mailfrom=paypal.example; dkim=none " &
                       "(message not signed) header.d=none;dmarc=none action=none header.from=paypal.example;compauth=fail reason=001",
                       "", "service@paypal.example")
  c = checkHeaders(msHeaders, providerAuthservs("outlook.office365.com"))
  check c.state == senderFailed, "Microsoft: compauth failed"
  c = checkHeaders(@[("From", "a@x.example"), ("From", "b@y.example")], gm)
  check c.state == senderFailed and "more than one" in c.detail, "two From lines"
  c = checkHeaders(@[("From", "a@x.example, b@y.example")], gm)
  check c.state == senderFailed, "two senders in one From"
  var icloud = @[("Authentication-Results", "dmarc.icloud.com; dmarc=pass header.from=example.com"),
                 ("Authentication-Results", "dkim-verifier.icloud.com; dkim=pass header.d=example.com"),
                 ("From", "a@example.com")]
  c = checkHeaders(icloud, providerAuthservs("imap.mail.me.com"))
  check c.state == senderVerified, "iCloud's results, one header per check"

block policy:
  echo "DMARC policies, when nothing proves the sender"
  let unsigned = "From: PayPal <service@paypal.example>\r\nSubject: Your account\r\n\r\nClick here.\r\n"
  var c = checkSender(unsigned, lookup = stub)
  check c.state == senderUnverified and "paypal.example" in c.detail, "p=reject and not signed: unproven"
  c = checkSender(unsigned.replace("paypal.example", "example.org"), lookup = stub)
  check c.state == senderUnknown, "p=none: nothing said"
  c = checkSender(unsigned.replace("paypal.example", "a.strict.example"), lookup = stub)
  check c.state == senderUnverified, "a subdomain: its organization's sp="
  check dmarcPolicy("a.strict.example", stub).policy == "reject", "sp= read for a subdomain"
  check dmarcPolicy("strict.example", stub).policy == "quarantine", "p= for the domain itself"
  c = checkSender(unsigned, lookup = offline)
  check c.state == senderUnknown, "no network: nothing said"

block names:
  echo "domain names"
  check registrableDomain("news.bbc.co.uk") == "bbc.co.uk", "co.uk"
  check registrableDomain("me.foo.github.io") == "foo.github.io", "a private suffix (github.io)"
  check registrableDomain("www.city.kawasaki.jp") == "city.kawasaki.jp", "an exception rule"
  check registrableDomain("x.y.kawasaki.jp") == "x.y.kawasaki.jp", "a wildcard rule"
  check registrableDomain("co.uk") == "" and registrableDomain("1.2.3.4") == "", "a suffix, an address"
  check registrableDomain("mail.example.unknowntld") == "example.unknowntld", "a suffix not listed"
  check toAsciiHost("münchen.de") == "xn--mnchen-3ya.de" and toUnicodeHost("XN--MNCHEN-3YA.de") == "münchen.de",
        "IDN both ways"
  check toUnicodeHost(toAsciiHost("مثال.إختبار")) == "مثال.إختبار", "Arabic IDN both ways"
  check registrableDomain("xn--mgbh0fb.xn--kgbechtv") == "مثال.إختبار", "an IDN suffix (إختبار)"
  check skeleton("pаypa1.com") == skeleton("paypal.com"), "Cyrillic а and 1 for l"
  check skeleton("rnicrosoft.com") == skeleton("microsoft.com"), "rn for m"
  check looksLike("xn--pypal-4ve.com", "paypal.com"), "a look-alike written as xn--"
  check not looksLike("www.paypal.com", "paypal.com") and not looksLike("example.com", "paypal.com"),
        "the same organization, or another name, is not a look-alike"
  check mixedScripts("pаypal") and not mixedScripts("paypal") and not mixedScripts("яндекс") and
        not mixedScripts("東京abc"), "letters of two alphabets in one name"

proc stopAtExit(p: Process) =
  # (the exit proc keeps its own reference: what the block holds is freed
  # before the exit procs run)
  addExitProc(proc () = p.terminate())

block wire:
  echo "DNS over UDP and TCP (a server of the test's own)"
  let python = if findExe("python3").len > 0: "python3" else: "python"
  let p = startProcess(python, args = [currentSourcePath().parentDir / "dnsmock.py", data / "zone.txt"],
                       options = {poUsePath})
  stopAtExit(p)
  let port = p.outputStream.readLine.strip
  putEnv("RETRO_DNS", "127.0.0.1:" & port)
  let ed = dnsQuery("brisbane._domainkey.football.example.com", "TXT")
  check ed.status == dnsOk and ed.answers == @["v=DKIM1; k=ed25519; p=11qYAYKxCrfVS/7TyWQHOg7hcvPapiMlrwIaaPcHURo="],
        "a TXT record over UDP"
  let big = dnsQuery("k2048._domainkey.example.org", "TXT")
  check big.status == dnsOk and big.answers.len == 1 and big.answers[0].len > 380 and
        big.answers[0] == zone["k2048._domainkey.example.org"][0],
        "a long one (cut short over UDP, asked again over TCP), its strings joined"
  check dnsQuery("nothing.example", "TXT").status == dnsNoName, "NXDOMAIN"
  let t0 = epochTime()
  let r = verifyDkim(readFile(data / "rfc8463.eml"))
  check r.len == 2 and r[0].state == dkimPass and r[1].state == dkimPass,
        "RFC 8463's message verified with keys asked of DNS (" & $int((epochTime() - t0) * 1000) & " ms)"
  let again = epochTime()
  discard verifyDkim(readFile(data / "rfc8463.eml"))
  check epochTime() - again < 0.05, "asked again: the answers kept"
  p.terminate()

if failures > 0:
  echo failures, " failed"
  quit 1
echo "test_mailauth: all passed"
