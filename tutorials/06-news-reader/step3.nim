#> clickMark(0)
#> for i in 0 ..< 200:
#>   frames(1)
#>   os.sleep(5)
#> shot("06-news-reader--step3")
import retroui
import retroui/[jobs, feeds]

var reading: Job[Feed] = nil
var news: Feed
var problem = ""

app "News", 360, 120:
  row:
    if button("&Refresh", enabled = reading == nil):
      problem = ""
      reading = job(proc (): Feed = parseFeed("<html>not a feed</html>"))   # raises
    mark "refresh"
    if reading != nil: spinner()     # turning while it works
  if reading != nil and reading.ended:
    if reading.done: news = reading.value
    else: problem = reading.error    # what went wrong, in words
    reading = nil
  if problem.len > 0:
    label "Could not read the news: " & problem, color = color(160, 0, 0)
  label news.title
