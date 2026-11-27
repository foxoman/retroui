## BMI Studio -- a body mass index calculator made with Retro Nim UI, and
## the example of a window with a look of its own: what the kit's controls
## take to look different, and where an app draws for itself.
##
## - the kit's controls, changed by their options: the title bar with the
##   app's icon and a large title at the left (`captionIcon`,
##   `captionAlign`, `captionStyle`), panels with a title strip
##   (`group ..., glCaption`), option buttons (`radio(boxed = true)`),
##   number boxes with large digits (`spin(style = ...)`), the button that
##   matters in the accent colour with a large label (`button(accent =
##   true, style = ...)`), a dial in bands (`gauge`), a bar of ranges
##   (`rangeBar`), a tag with an icon (`pill`);
## - a colour scheme of the app's own (`StudioTheme`), and the kit's
##   schemes from the View menu -- the bands, the tag and the panels follow
##   whichever is on (`goodColor`, `warnColor`...);
## - a control made here: the banner, drawn on a `canvas` (`heartShape`,
##   `pulse`, `miniBars`).
##
## docs/customizing.md goes through each.
##
##   nimble bmi                                  (or: nim c -r -d:release examples/bmi.nim)
##   RETRO_APP=bmi nimble appapk                 (build/BMIStudio.apk)
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[math, strutils]
import retroui
import retroui/charts
import retroui/uirelays/input       # putClipboardText

const
  AppIcon = staticRead("assets/bmi-icon.png")
  BmiVersion* = "1.0.0"

# ---- the app's own colours ------------------------------------------------------------------------

const
  StudioTheme* = Theme(
    window: color(214, 214, 214), text: color(0, 0, 0),
    face: color(206, 206, 206), light: color(255, 255, 255),
    shadow: color(122, 122, 122), frame: color(0, 0, 0),
    select: color(0, 0, 128), selectText: color(255, 255, 255),
    gray: color(128, 128, 128), field: color(255, 255, 255),
    fieldText: color(0, 0, 0), scroll: color(200, 200, 200),
    tip: color(255, 255, 225), tipText: color(0, 0, 0),
    line: color(150, 150, 150), edge: color(0, 0, 0),
    link: color(0, 0, 160), face2: color(232, 232, 232),
    accent: color(22, 40, 140), accentText: color(255, 255, 255))
    ## The window: 3.1's gray dialogs, a little lighter; the accent, the
    ## navy of "Calculate BMI".

# ---- the classes (WHO, adults) --------------------------------------------------------------------

const
  GaugeLo = 16.0
  GaugeHi = 40.0
  Classes* = [
    # (their colours: the scheme's blue, green, amber and red by turn; the
    # healthy band wide on the dial, the obese one -- 16 points of BMI,
    # mostly far off -- narrow)
    Band(upTo: 18.5, label: "Underweight", range: "< 18.5", sweep: 40),
    Band(upTo: 25.0, label: "Healthy", range: "18.5 – 24.9", sweep: 70),
    Band(upTo: 30.0, label: "Overweight", range: "25.0 – 29.9", sweep: 40),
    Band(upTo: GaugeHi, label: "Obese", range: "≥ 30.0", sweep: 30)]
  Status = ["Underweight", "Healthy range", "Overweight", "Obese"]

proc fmt1(x: float): string = formatFloat(x, ffDecimal, 1)

# ---- the app's state ------------------------------------------------------------------------------

var
  units* = 0                 # 0 metric, 1 imperial
  shownUnits = 0             # the units the numbers are in now
  heightCm* = 175
  weightKg* = 75
  heightIn* = 69
  weightLb* = 165
  bmi* = NaN                 # the last result (NaN: none)
  dirty = false              # the numbers changed since it was worked out
  showAbout = false
  scheme = -1                # the kit's scheme chosen in View (-1: the app's own)

proc computeBmi*(): float =
  let v =
    if units == 0: float(weightKg) / pow(float(heightCm) / 100, 2)
    else: 703.0 * float(weightLb) / pow(float(heightIn), 2)
  round(v * 10) / 10          # as shown: the class follows the number on screen

proc calculate*() =
  bmi = computeBmi()
  dirty = false

proc resetAll*() =
  units = 0
  shownUnits = 0
  heightCm = 175
  weightKg = 75
  heightIn = 69
  weightLb = 165
  bmi = NaN
  dirty = false

proc convertUnits() =
  ## The numbers follow the unit system when it changes.
  if units == shownUnits: return
  if units == 1:
    heightIn = int(round(float(heightCm) / 2.54))
    weightLb = int(round(float(weightKg) * 2.20462))
  else:
    heightCm = int(round(float(heightIn) * 2.54))
    weightKg = int(round(float(weightLb) / 2.20462))
  shownUnits = units
  dirty = true

proc resultText*(): string =
  if bmi.isNaN: return "Enter your height and weight, then press Calculate BMI."
  result = "Your BMI is " & fmt1(bmi) & ", which is " &
    (case bandOf(Classes, bmi)
     of 0: "below the healthy weight range for adults."
     of 1: "within the healthy weight range for adults."
     of 2: "above the healthy weight range (overweight) for adults."
     else: "in the obese range for adults.")
  if dirty: result.add " The numbers changed: press Calculate BMI again."

proc copyResult() =
  if not bmi.isNaN:
    putClipboardText("BMI " & fmt1(bmi) & " (" & Status[bandOf(Classes, bmi)] & ")")

# ---- a control of the app's own: the banner -------------------------------------------------------
#
# `canvas` gives the room; what is drawn there is the app's. Its colours
# are mixed from the scheme's, so it follows a dark one.

proc heartShape(cx, cy, s: float; fill, edge: Color) =
  ## A heart `s` wide around (cx, cy), with an edge.
  for (k, c) in [(1.0, edge), (0.86, fill)]:
    let r = s * 0.27 * k
    disc(cx - s * 0.22, cy - s * 0.12, r, c)
    disc(cx + s * 0.22, cy - s * 0.12, r, c)
    polygon([(cx - s * 0.48 * k, cy - s * 0.04), (cx + s * 0.48 * k, cy - s * 0.04),
             (cx, cy + s * 0.46 * k)], c)

proc pulse(cx, cy, s: float; c: Color) =
  ## The heartbeat line across the heart.
  let pts = [(-0.40, 0.02), (-0.16, 0.02), (-0.08, -0.16), (0.02, 0.22),
             (0.12, -0.06), (0.18, 0.02), (0.40, 0.02)]
  for i in 0 ..< pts.high:
    thickLine(cx + pts[i][0] * s, cy + pts[i][1] * s,
              cx + pts[i + 1][0] * s, cy + pts[i + 1][1] * s, max(2.0, s * 0.055), c)

proc miniBars(x, y, h: int; c: Color; n = 4) =
  ## A small rising bar chart, `h` high, its bottom left at (x, y + h).
  let bw = max(3, h div 4)
  for i in 0 ..< n:
    let bh = h * (i + 1) div n
    fill(x + i * (bw + max(2, bw div 3)), y + h - bh, bw, bh, c)

proc banner() =
  let r = canvas(0, dp(74))
  let bg = mixColor(ui.theme.window, infoColor(), 0.28)
  let hi = mixColor(bg, ui.theme.light, 0.55)
  let edge = mixColor(bg, infoColor(), 0.6)
  let ink = contrastInk(bg, ui.theme.text, ui.theme.selectText)
  fill(r, bg)
  fill(rect(r.x, r.y, r.w, r.h div 3), mixColor(bg, hi, 0.5))
  box(r, edge, 2)
  hline(r.x + 2, r.y + 2, r.w - 4, hi)
  # the heart, a line, the title, the bars
  let hs = float(dp(58))
  let hx = float(r.x + dp(56))
  let hy = float(r.y + r.h div 2 + dp(2))
  heartShape(hx, hy, hs, color(232, 62, 82), color(150, 24, 44))
  pulse(hx, hy - hs * 0.05, hs, color(255, 255, 255))
  vline(r.x + dp(104), r.y + dp(12), r.h - dp(24), edge)
  let tst = style(bold = true, italic = true, serif = true, size = 2.5)
  let sst = style(serif = true, size = 1.3)
  let tx = r.x + dp(120)
  let th = lineHeight(tst)
  let ty = r.y + (r.h - th - lineHeight(sst) + dp(6)) div 2
  text(tx, ty, "BMI Calculator", ink, tst)
  text(tx + dp(2), ty + th - dp(6), "Your health, at a glance.", ink, sst)
  let bh = dp(44)
  if r.w > dp(420): miniBars(r.x + r.w - dp(70), r.y + (r.h - bh) div 2, bh, edge)
  if accessOn: accessNode(arImage, "BMI Calculator. Your health, at a glance.", r = r)

# ---- the window -----------------------------------------------------------------------------------

proc measurements() =
  group "Your Measurements", glCaption:
    label "Unit System:"
    row([-1, -1]):
      radio("&Metric (cm, kg)", units, 0, boxed = true)
      radio("&Imperial (in, lb)", units, 1, boxed = true)
    convertUnits()
    space(dp(8))
    let big = style(bold = true, size = 1.5)
    row([66, 110, -1]):
      label "&Height:"
      if units == 0:
        if spin(heightCm, 50, 250, w = dp(110), style = big): dirty = true
        label "cm"
      else:
        if spin(heightIn, 20, 100, w = dp(110), style = big): dirty = true
        label "in"
    row([66, 110, -1]):
      label "&Weight:"
      if units == 0:
        if spin(weightKg, 10, 300, w = dp(110), style = big): dirty = true
        label "kg"
      else:
        if spin(weightLb, 22, 660, w = dp(110), style = big): dirty = true
        label "lb"

proc result() =
  group "BMI Classification (Adults)", glCaption:
    rangeBar(Classes, bmi, GaugeLo)
    separator()
    let at = bandOf(Classes, bmi)
    row:
      withTextStyle(style(size = 1.4)):
        if at < 0: pill("No result yet", ui.theme.gray)
        else:
          pill(Status[at] & ": " & Classes[at].range,
               (case at
                of 0: infoColor()
                of 1: goodColor()
                of 2: warnColor()
                else: badColor()),
               if at == 1: nfCheck else: "")
    label resultText()

proc buttons() =
  let big = style(bold = true, size = 1.3)
  row:
    if button("&Calculate BMI", nfCalculator, isDefault = true, accent = true, style = big,
              w = dp(210), h = dp(42)):
      calculate()
    if button("&Reset", nfRedo, style = big, w = dp(150), h = dp(42)):
      resetAll()
    spring()
    let fst = style(italic = true, serif = true, size = 1.1)
    let f = if units == 0: "BMI = weight (kg) ÷ height (m)²"
            else: "BMI = 703 × weight (lb) ÷ height (in)²"
    if available() > textWidth(f, fst) + dp(8):
      let fr = canvas(textWidth(f, fst) + dp(4), dp(42))
      text(fr.x, fr.y + (fr.h - lineHeight(fst)) div 2, f, ui.theme.text, fst)

proc bmiFrame*() =
  ## One frame of the window (the tests run it without one).
  if hotkeyPressed("F5"): calculate()
  if hotkeyPressed("Ctrl+R"): resetAll()
  if hotkeyPressed("Ctrl+Shift+C"): copyResult()
  menubar:
    menu "&File":
      if menuItem("&Calculate BMI", "F5"): calculate()
      if menuItem("&Reset", "Ctrl+R"): resetAll()
      menuSeparator()
      if menuItem("E&xit", "Alt+F4"): quitApp()
    menu "&Edit":
      if menuItem("&Copy Result", "Ctrl+Shift+C", enabled = not bmi.isNaN): copyResult()
    menu "&View":
      if menuItem("&Metric (cm, kg)", checked = units == 0): units = 0
      if menuItem("&Imperial (in, lb)", checked = units == 1): units = 1
      menuSeparator()
      submenu "&Colours":
        if menuItem("BMI &Studio", checked = scheme < 0):
          scheme = -1
          ui.theme = StudioTheme
        menuSeparator()
        for i, t in builtinThemes:
          if menuItem(t.name, checked = scheme == i):
            scheme = i
            ui.theme = t.theme
    menu "&Help":
      if menuItem("&About BMI Studio"): showAbout = true

  convertUnits()
  banner()
  if isCompact():
    # a phone: one column, the dial under the numbers
    measurements()
    group "", glCaption:
      gauge("BMI", bmi, GaugeLo, GaugeHi, Classes,
            valueStyle = style(bold = true, serif = true, size = 3.0), height = dp(210))
    result()
  else:
    row([270, -1]):
      measurements()
      group "", glCaption:
        gauge("BMI", bmi, GaugeLo, GaugeHi, Classes,
              valueStyle = style(bold = true, serif = true, size = 3.0), height = dp(214))
    result()
  buttons()
  aboutBox(showAbout, "BMI Studio", BmiVersion,
           tagline = "Your health, at a glance.",
           lines = ["Body mass index from your height and weight, with the WHO classes for adults.",
                    "BMI is a screening number, not a diagnosis: ask a doctor about your own health."],
           iconPng = AppIcon)

when isMainModule and not declared(bmiUnderTest):
  calculate()
  uiLook = lookClassic          # (a look of its own, on a phone too: its title strips, its digits)
  app "BMI Studio", 680, 610, theme = StudioTheme, frame = wfClassic, icon = AppIcon,
      id = "bmistudio", version = BmiVersion, captionIcon = true, captionAlign = caLeft,
      captionStyle = style(bold = true, serif = true, size = 1.35):
    bmiFrame()
