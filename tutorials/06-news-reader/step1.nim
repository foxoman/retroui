#> clickMark(0)
#> for i in 0 ..< 200:
#>   frames(1)
#>   os.sleep(5)
#> shot("06-news-reader--step1")
import retroui
import retroui/[jobs, feeds]

const sample = """<rss><channel><title>Nim News</title>
<item><title>Version 2.2.6 released</title><pubDate>Mon, 02 Nov 2026 08:00:00 GMT</pubDate></item>
<item><title>A new tutorial series</title><pubDate>Sun, 01 Nov 2026 08:00:00 GMT</pubDate></item>
</channel></rss>"""

var reading: Job[Feed] = nil         # (a job while it runs)
var news: Feed

app "News", 340, 150:
  if button("&Read the news"):
    # on a worker thread: here a feed in the program; fetch(url) brings one from the web
    reading = job(proc (): Feed = parseFeed(sample))
  mark "read"
  if reading != nil and reading.done:          # read between frames, like a click
    news = reading.value
    reading = nil
  label news.title, bold = true
  for item in news.episodes: label "- " & item.title
