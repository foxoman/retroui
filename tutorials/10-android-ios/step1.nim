#> phone(300, 300)
#> shot("10-android-ios--step1")
import retroui

var leaving = false

app "Radio", 300, 300:
  if backPressed():                  # the phone's Back (a desktop's close box too)
    cancelClose()
    leaving = true
  label "Morning news", bold = true
  # a sound plays on with the app in the background: retroapk adds the
  # service it needs on Android, retroios the background mode on iOS
  audioView("https://example.com/news.mp3", height = dp(120), title = "Morning news")
  case msgBox(leaving, "Radio", "Stop playing and leave?", ["&Leave", "Stay"], miQuestion)
  of 1: quitApp()
  else: discard
