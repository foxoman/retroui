## A message's HTML made safe to read (retroui/mailsafety): tracking
## pictures taken out (tiny, hidden, from tracking services), tracking codes
## taken off links, links whose words name another site or that hide where
## they go, and senders who say they are a company they are not, or whose
## domain looks like a well-known one or like a contact's.
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/strutils
import retroui/mailsafety

var failures = 0
template check(cond: bool; what: string) =
  if cond: echo "  ok   ", what
  else:
    echo "  FAIL ", what
    inc failures

block codes:
  echo "tracking codes"
  check stripTracking("https://shop.example/p?id=4&utm_source=news&utm_medium=email&fbclid=xyz#top") ==
        "https://shop.example/p?id=4#top", "utm_* and fbclid off, the rest kept"
  check stripTracking("https://a.example/?gclid=1&mc_eid=2") == "https://a.example/", "nothing left: no ?"
  check stripTracking("https://a.example/x?q=utm_source") == "https://a.example/x?q=utm_source",
        "a value that only names one stays"
  check stripTracking("https://a.example/x") == "https://a.example/x", "no query"

block pictures:
  echo "tracking pictures"
  check isTracker("https://t.example/x.gif", "1", "1"), "1 x 1"
  check isTracker("https://t.example/x.gif", style = "width:1px;height:1px"), "1 x 1 by its style"
  check isTracker("https://t.example/x.png", style = "display: none"), "hidden"
  check isTracker("https://mailtrack.io/trace/mail/abc.png"), "a tracking service"
  check isTracker("https://news.example/wf/open?upn=abc", "600", "300"), "an open-tracking address, whatever its size"
  check not isTracker("https://cdn.example/logo.png", "200", "80"), "a logo is not"
  check not isTracker("cid:logo1", "1", "1"), "a picture in the message itself is not (it tells no one)"

block html:
  echo "the HTML"
  let r = cleanMail("""<p>Hi <a href="https://evil.example/login?utm_campaign=x">www.paypal.com</a>
<img src="https://t.example/open.gif?u=1" width="1" height="1"><img src="https://cdn.example/logo.png" width=200>
<a href="http://paypal.com@evil.example/">PayPal</a> <a href="https://xn--pypal-4ve.com">here</a>
<a href='https://news.example.com/a'>example.com</a> <a href="https://click.mailer.example/c/1">www.shop.example</a>
<!-- <img src="https://x.example/a.png" width=1 height=1> -->
<img src="https://mailtrack.io/trace/mail/abc.png"><img style="display:none" src="http://x.example/a.png"></p>""")
  check r.trackers == 3, "three tracking pictures out (" & $r.trackers & ")"
  check "logo.png" in r.html and "open.gif" notin r.html and "mailtrack" notin r.html, "the logo kept, the trackers gone"
  check r.codes == 1 and "utm_campaign" notin r.html and "https://evil.example/login\"" in r.html,
        "the tracking code off the link"
  check "<!-- <img" in r.html, "a comment left as it is"
  check r.links.len == 4, "four links not what they look like (" & $r.links.len & ")"
  var deceptive = 0
  for l in r.links:
    if l.deceptive: inc deceptive
  check deceptive == 3, "three of them made to fool"
  check r.links[0].shown == "www.paypal.com" and r.links[0].real == "evil.example" and r.links[0].deceptive,
        "words naming PayPal, going elsewhere"
  check "@" in r.links[1].why, "an address hidden before an @"
  check "two alphabets" in r.links[2].why, "letters of two alphabets"
  check not r.links[3].deceptive and r.links[3].real == "click.mailer.example",
        "through a mailer's click counter: worth a look, not made to fool"
  check linkWarning("javascript:alert(1)", "x").len > 0, "a script is not opened"
  check linkWarning("https://example.com/a", "example.com") == "", "a plain link is fine"
  check "IP" in linkWarning("https://1.2.3.4/x", "bank"), "a bare IP address"
  check "looks like" in linkWarning("https://paypa1.com/login", "Log in"), "a look-alike of PayPal's"
  check linkWarning("https://www.paypal.com/x", "paypal.com") == "", "PayPal's own"

block senders:
  echo "senders"
  let w1 = senderWarnings("PayPal Service", "help@paypa1-secure.com")
  check w1.len == 2 and "says PayPal" in w1[0] and "looks like PayPal" in w1[1], "PayPal's name and a look-alike domain"
  check senderWarnings("PayPal", "service@paypal.com").len == 0, "PayPal itself"
  check senderWarnings("PayPal", "service@mail.paypal.com").len == 0, "PayPal from a subdomain"
  check senderWarnings("Chase Smith", "chase@example.com").len == 0, "a name that is also a bank's"
  check "shows the address" in senderWarnings("support@paypal.com", "x@evil.example")[0], "an address in the name"
  check senderWarnings("Ali", "ali@exarnple.com", ["example.com"]).len == 1, "a contact's domain, rn for m"
  check senderWarnings("Ali", "ali@example.com", ["example.com"]).len == 0, "the contact's own"
  check senderWarnings("Apple", "no-reply@apple-id-verify.com").len == 2, "Apple's name, words added to its domain"
  check senderWarnings("Maryam", "m@pаypal.com").len >= 1, "Cyrillic letters in the domain"
  check senderWarnings("Amazon", "orders@amazon.co.uk").len == 0, "Amazon's country sites"

if failures > 0:
  echo failures, " failed"
  quit 1
echo "test_mailsafety: all passed"
