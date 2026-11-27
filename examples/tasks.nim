## Retro Tasks -- a whole phone app made with the kit: tasks in lists, ticked off with a round
## check, put in order, each with its day and time on wheels, a reminder (the phone's
## notification, also while the app is closed), a flag and a priority; lists made by themselves
## (Today, Upcoming, Flagged, Completed); notes beside them; a search through both; kept on the
## device. It starts in the Gloss look (Settings > Appearance changes it). tutorials/17-whole-app
## builds it step by step.
##
##   nim c -r -d:release examples/tasks.nim           (Windows, macOS, Linux)
##   nimble appapk with RETRO_APP=tasks               (Android)
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net

import retroui
import retroui/[notify, bgcheck]
import tasks/[model, screens]

const TasksIconPng = staticRead("assets/tasks-icon.png")

proc main() =
  # (while the app is closed: its reminders raised, its icon's count -- Android)
  onBackgroundCheck(backgroundCheck)
  loadStore()
  appNavBars = true
  uiLook = lookGloss
  ui.theme = GlossLight
  openApp("Retro Tasks", 420, 760, id = AppKey, icon = TasksIconPng, look = AppKey & "-1",
          version = TasksVersion)
  discard notifyAvailable()
  if store.reminders: discard scheduleBackgroundCheck(15)
  while beginFrame():
    if stoppedFrame():
      endFrame()
      continue
    captionBar()
    tasksView()
    if closeRequested(): saveStore()
    endFrame()
    appFrameDone()
  saveStore()
  closeApp()

main()
