## The app the fake Android (mock_android.c) drives. Build with run.sh.

{.compile: "mock_android.c".}

import retroui
import retroui/uirelays/drivers/android_driver

# The fake Android's relays, in place of the desktop driver's.
initAndroidDriver()
echo "the app starts"     # (twice in one process: started again in a new activity)

var
  clicks = 0
  name = "abc"
  wasPaused = false
  composed = false
  keyed = false

app "mock", 300, 200:
  if button("Press me"):
    inc clicks
    echo "clicked ", clicks
  edit name
  if name.len == 0 and clicks > 0: echo "typed hi"
  if name == "سلام":
    echo "arabic ok"
    name = "done"
  if ui.composing == "كت" and not composed:
    echo "composing ok"
    composed = true
  if name == "don" and not keyed:
    echo "key ok"
    keyed = true
  label "Arabic: مرحبا"
  if ui.paused and not wasPaused: echo "paused"
  wasPaused = ui.paused
