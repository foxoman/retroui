#> shot("06-news-reader--step2")
#> phone(300, 300)
#> shot("06-news-reader--step2-phone")
import retroui
import retroui/feeds

let news = parseFeed("""<rss><channel><title>Nim News</title>
<item><title>Version 2.2.6 released</title><description>Bug fixes and speed.</description></item>
<item><title>A new tutorial series</title><description>From Hello to your own controls.</description></item>
</channel></rss>""")
var titles: seq[string]
for e in news.episodes: titles.add e.title
var sel = 0
var open = false

app "News", 520, 220:
  listDetail(open, 220):             # side by side when there is room, one at a time on a phone
    if listbox(titles, sel, rows = 6): open = true
  do:
    label news.episodes[sel].title, bold = true
    paragraph plainText(news.episodes[sel].notes)
