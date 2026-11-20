## Tests of an app run from the command line by a script (retroui/drive): RETRO_SCRIPT's steps
## (a click -- on a control, or at a point --, typing, a key, a wait for a control) done in order, RETRO_SNAPSHOT's picture of the
## window kept in memory written once they are done and the app ended; a step that fails says
## which and ends the app with 1; a script that is not one, with 2. This program is the app
## too: started with the variables, it is the app; without, it starts itself with them.

import std/[os, osproc, strutils, strtabs, streams]
import retroui

if getEnv("RETRO_SCRIPT").len > 0 or getEnv("RETRO_SNAPSHOT").len > 0:
  # ---- the app the script drives ----
  var name = ""
  var count = 0
  var saved = false
  var taps = 0
  app "Script Test", 360, 240:
    # (a place with no name -- a canvas's: a click at a point lands there)
    if ui.pressed and rect(300, 200, 50, 30).contains(point(ui.mx, ui.my)): inc taps
    if taps > 0: label("Tapped " & $taps)
    row:
      label "&Name:"
      edit(name, w = dp(160))
    if button("&Add"): inc count
    label("Added " & $count)
    if CtrlPressed in ui.mods and keyHit(KeyS): saved = true
    if saved: label("Saved " & name)
  quit 0

let me = getAppFilename()
let dir = getTempDir() / "retro-script-test"
removeDir(dir)
createDir(dir)

proc runWith(script, shot: string): tuple[output: string; code: int] =
  var env = newStringTable(modeCaseSensitive)
  for k, v in envPairs(): env[k] = v
  env["RETRO_SCRIPT"] = script
  env["RETRO_SNAPSHOT"] = shot
  env["RETRO_SIZE"] = "360x240"
  let p = startProcess(me, env = env, options = {poStdErrToStdOut})
  result.output = p.outputStream.readAll()
  result.code = p.waitForExit()
  p.close()

block stepsAndPicture:
  let r = runWith("click:Add;click:Add;click:Name;type:Retro;key:ctrl+s;wait:Saved Retro;wait:0.2",
                  dir / "app.png")
  doAssert r.code == 0, r.output
  doAssert fileExists(dir / "app.png") and readFile(dir / "app.png").startsWith("\x89PNG")

block aClickAtAPoint:
  let r = runWith("click:@320,210;wait:Tapped 1;click:@10,10;click:@320,215;wait:Tapped 2", dir / "point.png")
  doAssert r.code == 0, r.output

block aPictureOnly:
  let r = runWith("", dir / "first.png")
  doAssert r.code == 0 and fileExists(dir / "first.png"), r.output

block aStepThatFails:
  let r = runWith("click:Add;click:Nothing Here;click:Add", dir / "no.png")
  doAssert r.code == 1, $r.code
  doAssert "step 2 (click:Nothing Here) failed" in r.output, r.output
  doAssert not fileExists(dir / "no.png")

block notAScript:
  let r = runWith("jump:high", dir / "x.png")
  doAssert r.code == 2 and "no step \"jump\"" in r.output, r.output

removeDir(dir)
echo "test_script: ok"
