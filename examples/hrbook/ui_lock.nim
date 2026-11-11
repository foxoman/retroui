# (included by hrbook.nim) The first start (hotels, a PIN) and the lock.
#
# Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

var
  restoreFirstOpen = false
  restoreFirstPath = ""
  restoreFirstPin = ""
  restoreFirstMsg = ""
  restorePinOpen = false

proc desktopFill() =
  fill(rect(0, ui.barY, ui.w, ui.h - ui.barY), color(0, 128, 128))     # the 3.1 desktop

proc pinDots(n: int) =
  let r = canvas(0, dp(34))
  # (a screen reader hears how many digits are in, not which)
  accessNode(arLabel, $n & " digits typed", id = 0, r = r)
  let shown = max(4, n)
  for i in 0 ..< shown:
    let cx = float(r.x + r.w div 2 + (i * 2 - shown + 1) * dp(14))
    let cy = float(r.y + r.h div 2)
    if i < n: disc(cx, cy, float(dp(6)), color(0, 0, 128))
    else: ring(cx, cy, float(dp(6)), 1.5, black)

proc keypad(s: var string; okLabel: string): bool =
  ## The number pad; true when OK is pressed (or Enter).
  # the keyboard too -- read first, so that Enter is OK and not a press of
  # the key that has the focus (which would add its digit to the PIN)
  if canInput():
    for c in ui.typed:
      if c in {'0'..'9'} and s.len < 12: s.add c
    if keyHit(KeyBackspace) and s.len > 0: s.setLen(s.len - 1)
    if keyHit(KeyEnter): result = true
  for line in [["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"], ["Clear", "0", okLabel]]:
    row([-1, -1, -1]):
      for k in line:
        if button(k, isDefault = k == okLabel):
          if k == okLabel: result = true
          elif k == "Clear": s = ""
          elif s.len < 12: s.add k

proc startBook() =
  var names: seq[string] = @[]
  for n in setupNames:
    if n.strip.len > 0: names.add n.strip
  if names.len == 0: names = @["Hotel 1"]
  book = newBook(names)
  book.templates = starterTemplates()
  st = create(dir, pin, book)
  locked = false
  setupMode = false
  pin = ""
  pin2 = ""
  section = "Settings/Hotels"
  status = "Welcome! Fill in your hotels' details, then import your Excel sheets."

proc setupScreen() =
  desktopFill()
  var open = true
  dialog(open, "Welcome to HR Book", 420):
    if setupStep == 0:
      row:
        icon(pxDocuments, size = 2.0)
        col:
          label("Every employee of your hotels, in one private book.", bold = true)
          label("First, your hotels (you can change them later):", color = ui.theme.gray)
      for i in 0 ..< setupNames.len:
        row([-1, 90]):
          edit(setupNames[i])
          if button("Remove", enabled = setupNames.len > 1):
            setupNames.delete(i)
            break
      row:
        if button("&Add a hotel"): setupNames.add "Hotel " & $(setupNames.len + 1)
        spring()
        if button("&Next >", isDefault = true): setupStep = 1
      separator()
      row:
        label("Moving from another tablet?", color = ui.theme.gray)
        if link("Restore a backup instead") and filesOk():
          if restoreFirstPath.len == 0: restoreFirstPath = downloadsDir()
          restoreFirstOpen = true
    else:
      row:
        icon(pxLock, size = 2.0)
        col:
          label("Choose a PIN.", bold = true)
          paragraph("It opens HR Book and seals its data (6 digits or more is safer). " &
                    "Without it nobody, not even you, can read the data or its backups: keep it safe.",
                    color = ui.theme.gray)
      form 0:
        field "PIN:": edit(pin, password = true)
        field "Again:": edit(pin2, password = true)
      if pinMsg.len > 0: label(pinMsg, color = color(200, 0, 0))
      row:
        if button("< &Back"): setupStep = 0
        spring()
        if button("&Start", isDefault = true):
          if pin.len < 4 or not pin.allCharsInSet({'0'..'9'}): pinMsg = "The PIN is 4 digits or more."
          elif pin != pin2: pinMsg = "The two PINs are not the same."
          else:
            pinMsg = ""
            try: startBook()
            except IOError, OSError, VaultError: pinMsg = "Could not create the data: " & getCurrentExceptionMsg()
  if filePicker(restoreFirstOpen, restoreFirstPath, fmOpen, ["*.hrbook", "*"], "Open a backup"):
    restoreFirstMsg = ""
    restoreFirstPin = ""
    restorePinOpen = true
    focusFirstText()
  dialog(restorePinOpen, "Open the backup", 360):
    label(restoreFirstPath.extractFilename, bold = true)
    label("The PIN it was made with:")
    edit(restoreFirstPin, password = true)
    if restoreFirstMsg.len > 0: label(restoreFirstMsg, color = color(200, 0, 0))
    row:
      spring()
      if button("&Open", isDefault = true, enabled = restoreFirstPin.len > 0):
        try:
          book = readBackup(restoreFirstPath, restoreFirstPin)
          st = create(dir, restoreFirstPin, book)
          locked = false
          setupMode = false
          restorePinOpen = false
          status = "Restored " & restoreFirstPath.extractFilename & ". Your PIN is the backup's."
        except VaultError:
          restoreFirstMsg = "Wrong PIN, or not an HR Book backup."
        except IOError, OSError:
          restoreFirstMsg = "Could not read it."
      if button("Cancel"): restorePinOpen = false

proc lockScreen() =
  if setupMode:
    setupScreen()
    return
  desktopFill()
  dialog(lockOpen, AppTitle, 330):
    row:
      icon(pxLock, size = 2.0)
      col:
        label("Enter your PIN to open the records.")
        label(if pinMsg.len > 0: pinMsg else: "Locked", color = if pinMsg.len > 0: color(200, 0, 0) else: ui.theme.gray)
    pinDots(pin.len)
    let waiting = nowT() < pinWaitUntil
    if waiting:
      label("Too many wrong PINs: wait " & $int(pinWaitUntil - nowT() + 1) & " s.", color = color(200, 0, 0))
      wakeIn(1000)
    if keypad(pin, "OK") and not waiting and pin.len > 0:
      try:
        (st, book) = open(dir, pin)
        locked = false
        pin = ""
        pinMsg = ""
        pinTries = 0
        lastInput = nowT()
      except VaultError:
        inc pinTries
        pinMsg = "Wrong PIN."
        pin = ""
        if pinTries >= 5:
          pinWaitUntil = nowT() + 30
          pinTries = 0
      except IOError, OSError:
        pinMsg = "Could not read the data."
  lockOpen = true                       # (it cannot be closed)
