## Forms and grids made from your own Nim types: `formOf(person)` draws a
## field for each field of the object -- a text box for a string, a check
## box for a bool, a number field, a list of an enum's values, a date
## picker, a color -- with its caption, checks what you asked of it, and
## says what is wrong under the field. `gridOf(people, sel)` shows a seq
## of them, a column for each field. Pragmas on the fields say the rest:
##
## .. code-block:: nim
##   type
##     Shift = enum Morning, Evening, Night
##     Person = object
##       name {.caption: "Full name", required, maxLen: 40.}: string
##       age {.limits: (16, 70).}: int
##       shift: Shift
##       startDate: Date
##       notes {.multiline: 3, help: "Anything the manager should know".}: string
##       internalId {.noForm.}: int
##
##   var p = Person(name: "Maryam", age: 29)
##   var people: seq[Person]
##   var sel = 0
##   app "Staff", 420, 420:
##     formOf(p)                                   # captions from the names
##     if button("&Add", enabled = formValid(p)): people.add p
##     gridOf(people, sel, height = 6)
##
## Captions come from the field's name ("startDate": Start date) unless
## `caption` gives one. The form is `form`'s: captions in a column, above
## the fields on a phone.
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[macros, strutils, algorithm]
from std/unicode import runeLen
import gfx, core, widgets, business, extras

template caption*(text: string) {.pragma.}
  ## The field's caption, instead of one made from its name.
template help*(text: string) {.pragma.}
  ## A line under the field saying what goes in it.
template required*() {.pragma.}
  ## The field must not be empty (a string, a seq) or 0 (a number).
template limits*(range: (int, int)) {.pragma.}
  ## The lowest and the highest a number may be: `{.limits: (0, 120).}`.
template maxLen*(n: int) {.pragma.}
  ## The most letters a string may have.
template multiline*(lines: int) {.pragma.}
  ## A string in a box of `lines` lines.
template readonly*() {.pragma.}
  ## Shown, not changed.
template noForm*() {.pragma.}
  ## Left out of forms and grids.
template decimals*(n: int) {.pragma.}
  ## A float shown with `n` places (2 when not said).

proc niceCaption*(name: string): string =
  ## A field's name as a caption: "startDate" and "start_date" become
  ## "Start date".
  for i, c in name:
    if c == '_':
      result.add ' '
    elif c.isUpperAscii and i > 0 and not name[i - 1].isUpperAscii:
      result.add ' '
      result.add c.toLowerAscii
    else:
      result.add c
  if result.len > 0: result[0] = result[0].toUpperAscii

template fieldCaption(f, name: untyped): string =
  when f.hasCustomPragma(caption): f.getCustomPragmaVal(caption) else: niceCaption(name)

proc fieldError*[F](f: F; isRequired: bool; lo, hi: float; most: int): string =
  ## (what is wrong with a field's value, "" when nothing)
  when F is string:
    if isRequired and f.strip.len == 0: return tr("Needed")
    if most > 0 and f.runeLen > most: return tr("At most") & " " & $most & " " & tr("letters")
  elif F is SomeNumber:
    if isRequired and f == F(0): return tr("Needed")
    if lo > NegInf and f.float < lo or hi < Inf and f.float > hi:
      return tr("From") & " " & $lo.int & " " & tr("to") & " " & $hi.int
  elif F is seq:
    if isRequired and f.len == 0: return tr("Needed")
  ""

template fieldLimits(f: untyped): (float, float) =
  when f.hasCustomPragma(limits):
    let lim = f.getCustomPragmaVal(limits)
    (lim[0].float, lim[1].float)
  else: (NegInf, Inf)

template fieldMost(f: untyped): int =
  when f.hasCustomPragma(maxLen): f.getCustomPragmaVal(maxLen) else: 0

proc formErrors*[T: object](v: T): seq[tuple[field, error: string]] =
  ## What is wrong in `v` by its fields' pragmas: their captions and why
  ## (empty when all is right).
  for name, f in v.fieldPairs:
    when not f.hasCustomPragma(noForm):
      let (lo, hi) = fieldLimits(f)
      let e = fieldError(f, f.hasCustomPragma(required), lo, hi, fieldMost(f))
      if e.len > 0: result.add (fieldCaption(f, name), e)

proc formValid*[T: object](v: T): bool =
  ## Nothing is wrong in `v` (`formErrors` is empty).
  formErrors(v).len == 0

proc enumNames[E: enum](e: typedesc[E]): seq[string] =
  for x in E: result.add niceCaption($x)

proc formOf*[T: object](v: var T; labelW = 110; showErrors = true): bool {.discardable.} =
  ## A form of `v`'s fields (see the module's notes); true when one changed.
  ## `showErrors` false: what is wrong is not said (a form not filled in
  ## yet), the fields' red too.
  form(labelW):
    for name, f in v.fieldPairs:
      when not f.hasCustomPragma(noForm):
        let (lo, hi) = fieldLimits(f)
        let err = if showErrors: fieldError(f, f.hasCustomPragma(required), lo, hi,
                                            fieldMost(f))
                  else: ""
        let ro = f.hasCustomPragma(readonly)
        field(tr(fieldCaption(f, name)) & ":"):
          when f is string:
            when f.hasCustomPragma(multiline):
              if editArea(f, lines = f.getCustomPragmaVal(multiline), readOnly = ro): result = true
            else:
              if edit(f, readOnly = ro, invalid = err.len > 0): result = true
          elif f is bool:
            if checkbox("", f, enabled = not ro): result = true
          elif f is enum:
            var i = ord(f) - ord(low(typeof(f)))
            if combo(enumNames(typeof(f)), i, enabled = not ro):
              f = typeof(f)(i + ord(low(typeof(f))))
              result = true
          elif f is SomeInteger:
            var n = int(f)
            if intEdit(n, lo = (if lo > NegInf: lo.int else: low(int)),
                       hi = (if hi < Inf: hi.int else: high(int)), enabled = not ro):
              f = typeof(f)(n)
              result = true
          elif f is SomeFloat:
            var x = float(f)
            let places = when f.hasCustomPragma(decimals): f.getCustomPragmaVal(decimals) else: 2
            if numberEdit(x, decimals = places, lo = lo, hi = hi, enabled = not ro):
              f = typeof(f)(x)
              result = true
          elif f is Date:
            if datePicker(f, enabled = not ro): result = true
          elif f is Color:
            if colorPicker(f, enabled = not ro): result = true
          else:
            label $f
        when f.hasCustomPragma(help):
          field(""):
            label tr(f.getCustomPragmaVal(help)), color = ui.theme.gray
        if err.len > 0:
          field(""):
            label err, color = color(192, 0, 0)

proc cellText[F](f: F): string =
  ## (a field's value as a grid cell)
  when F is bool: (if f: "Yes" else: "No")
  elif F is enum: niceCaption($f)
  elif F is SomeFloat: formatFloat(f.float, ffDecimal, 2)
  elif F is string: f
  else: $f

proc columnsOf*[T: object](t: typedesc[T]): seq[Column] =
  ## The columns `gridOf` shows for `T`: a field each (but `noForm`), its
  ## caption the title, its width by its kind.
  var v: T
  for name, f in v.fieldPairs:
    when not f.hasCustomPragma(noForm):
      let w = when f is bool: 50
              elif f is SomeNumber: 80
              elif f is enum: 90
              else: 140
      result.add Column(title: tr(fieldCaption(f, name)), width: w)

proc cellOf*[T: object](v: T; col: int): string =
  ## The text of column `col` of `v` in `gridOf`.
  var i = 0
  for name, f in v.fieldPairs:
    when not f.hasCustomPragma(noForm):
      if i == col: return cellText(f)
      inc i
  ""

proc cmpAt[T: object](a, b: T; col: int): int =
  ## (rows compared by column `col`'s field: numbers as numbers, dates by date)
  var i = 0
  for fa, fb in fields(a, b):
    when not fa.hasCustomPragma(noForm):
      if i == col:
        when compiles(cmp(fa, fb)): return cmp(fa, fb)
        else: return cmp(cellText(fa), cellText(fb))
      inc i
  0

proc gridOf*[T: object](rows: var seq[T]; sel: var int; height = 10;
                        cols: ptr seq[Column] = nil): GridEvent {.discardable.} =
  ## A grid of `rows`, a column for each field of `T` (`columnsOf`); a
  ## header click sorts them by that column. `cols`: columns of your own
  ## (to keep the widths the user dragged).
  var own {.global.}: seq[Column]
  if own.len == 0: own = columnsOf(T)
  let cp = if cols != nil: cols else: addr own
  let rp = addr rows
  result = grid(cp[], rows.len, proc (row, col: int): string = cellOf(rp[][row], col),
                sel, height = height)
  if result.sorted:
    let c = result.sortColumn
    let desc = result.sortDescending
    rows.sort(proc (a, b: T): int = cmpAt(a, b, c), if desc: Descending else: Ascending)
