#> shot("11-web--step1")
import retroui
import retroui/jobs

var notes = "Written in the browser, kept in its storage."
var page: Job[HttpResponse] = nil
var said = ""

app "Notes", 380, 200:
  editArea notes, lines = 4
  row:
    if button("&Load the news"):
      # in a page the site asked must allow it (CORS); your own site always does
      page = fetch("data/news.json")
    when defined(wasm):
      label "In the browser"
    else:
      label "On the desktop"
  if page != nil and page.ended:
    said = if page.done: $page.value.status & " " & $page.value.body.len & " bytes" else: page.error
    page = nil
  label said
