#> clickMark(0)
#> frames(20)
#> shot("f-pages")
import retroui

var nav = initPages("inbox")
var mails = ["Lunch on Thursday?", "The quarterly report", "Photos from Sur"]
var picked = 0

app "Mail", 320, 150:
  pageView(nav):                             # the page on top, sliding in
    case nav.page
    of "inbox":
      pageHeader(nav, "Inbox")
      for i, m in mails:
        if button(m):
          picked = i
          nav.push("mail")                   # a page over this one
        mark "mail"
    of "mail":
      pageHeader(nav, mails[picked])         # with Back (and Esc, the phone's Back)
      label "From: Aisha"
      label "The new place by the harbour, at one?"
