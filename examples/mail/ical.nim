## Retro Mail: iCalendar (RFC 5545) as meeting invitations carry it.
## Reading: content lines unfolded, parameters (quoted, several values,
## RFC 6868's ^ escapes), escaped text, and times -- in UTC (Z), with a TZID
## (the invitation's own VTIMEZONE, else a well-known zone name, IANA or
## Windows, else the device's zone), floating, or whole days. Writing: text
## escaped, lines folded at 75 octets.
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[strutils, times, algorithm, math]

type
  IcalProp* = object
    ## One content line: NAME;PARAM=value:value.
    name*: string                       ## upper case ("DTSTART")
    params*: seq[(string, string)]      ## names upper case, values unquoted (several: joined by ",")
    value*: string                      ## as written (TEXT still escaped)
  IcalComp* = ref object
    ## A component (VCALENDAR, VEVENT, VTIMEZONE, STANDARD...) and those in it.
    name*: string                       ## upper case; "" for the root `parseIcal` gives
    props*: seq[IcalProp]
    comps*: seq[IcalComp]

const
  MaxDepth = 12
  MaxProps = 5000

# ---- reading -----------------------------------------------------------------------------

proc contentLines*(text: string): seq[string] =
  ## The content lines of `text`, unfolded: a line break (CRLF or LF)
  ## followed by a space or a tab goes on with the line before.
  var cur = ""
  var i = if text.startsWith("\xEF\xBB\xBF"): 3 else: 0
  let n = text.len
  while i < n:
    let c = text[i]
    if c == '\r' or c == '\n':
      var j = i + 1
      if c == '\r' and j < n and text[j] == '\n': inc j
      if j < n and text[j] in {' ', '\t'}:
        i = j + 1                       # (folded: the line goes on)
        continue
      if cur.len > 0: result.add cur
      cur.setLen(0)
      i = j
    else:
      cur.add c
      inc i
  if cur.len > 0: result.add cur

proc caretDecode(s: string): string =
  ## RFC 6868: ^n a line break, ^' a double quote, ^^ a caret.
  var i = 0
  while i < s.len:
    if s[i] == '^' and i + 1 < s.len and s[i + 1] in {'n', 'N', '\'', '^'}:
      result.add(case s[i + 1]
                 of 'n', 'N': '\n'
                 of '\'': '"'
                 else: '^')
      i += 2
    else:
      result.add s[i]
      inc i

proc parseLine*(line: string): IcalProp =
  ## One unfolded content line. The value starts after the first ":" that
  ## is not inside a quoted parameter value.
  var i = 0
  while i < line.len and line[i] notin {';', ':'}: inc i
  result.name = line[0 ..< i].strip.toUpperAscii
  while i < line.len and line[i] == ';':
    inc i
    let ns = i
    while i < line.len and line[i] notin {'=', ';', ':'}: inc i
    let pname = line[ns ..< i].strip.toUpperAscii
    var vals: seq[string]
    if i < line.len and line[i] == '=':
      inc i
      while true:
        var v = ""
        if i < line.len and line[i] == '"':
          inc i
          while i < line.len and line[i] != '"':
            v.add line[i]
            inc i
          if i < line.len: inc i
          while i < line.len and line[i] notin {',', ';', ':'}: inc i   # (anything after the quotes)
        else:
          while i < line.len and line[i] notin {',', ';', ':'}:
            v.add line[i]
            inc i
        vals.add caretDecode(v)
        if i < line.len and line[i] == ',': inc i
        else: break
    if pname.len > 0: result.params.add (pname, vals.join(","))
  if i < line.len and line[i] == ':': inc i
  result.value = line[i .. ^1]

proc param*(p: IcalProp; name: string): string =
  ## The value of parameter `name` (any case); "" when it has none.
  for (k, v) in p.params:
    if cmpIgnoreCase(k, name) == 0: return v

proc parseIcal*(text: string): IcalComp =
  ## The components of `text` (VCALENDARs, under a root without a name).
  ## Never raises: what cannot be read is left out; a missing END closes
  ## with its parent's.
  result = IcalComp()
  var stack = @[result]
  var count = 0
  for line in contentLines(text):
    let p = parseLine(line)
    if p.name == "BEGIN":
      let c = IcalComp(name: p.value.strip.toUpperAscii)
      if stack.len > MaxDepth: continue
      stack[^1].comps.add c
      stack.add c
    elif p.name == "END":
      let nm = p.value.strip.toUpperAscii
      var k = stack.high
      while k > 0 and stack[k].name != nm: dec k
      if k > 0: stack.setLen(k)
    elif p.name.len > 0 and count < MaxProps:
      inc count
      stack[^1].props.add p

proc child*(c: IcalComp; name: string): IcalComp =
  ## The first component `name` right inside `c`; nil when none.
  if c.isNil: return nil
  for x in c.comps:
    if x.name == name: return x

proc children*(c: IcalComp; name: string): seq[IcalComp] =
  if c.isNil: return
  for x in c.comps:
    if x.name == name: result.add x

proc prop*(c: IcalComp; name: string): IcalProp =
  ## The first property `name` of `c` (its name "" when it has none).
  if c.isNil: return
  for p in c.props:
    if p.name == name: return p

proc props*(c: IcalComp; name: string): seq[IcalProp] =
  if c.isNil: return
  for p in c.props:
    if p.name == name: result.add p

proc unescapeText*(s: string): string =
  ## A TEXT value as it reads: \n a line break, \, \; \\ the character.
  var i = 0
  while i < s.len:
    if s[i] == '\\' and i + 1 < s.len:
      if s[i + 1] in {'n', 'N'}: result.add '\n'
      else: result.add s[i + 1]
      i += 2
    else:
      result.add s[i]
      inc i

proc text*(c: IcalComp; name: string): string =
  ## Property `name`'s TEXT value, unescaped.
  unescapeText(c.prop(name).value)

proc mailto*(value: string): string =
  ## The address of a CAL-ADDRESS ("mailto:a@b" -> "a@b").
  result = value.strip
  if result.toLowerAscii.startsWith("mailto:"): result = result[7 .. ^1].strip

# ---- times -------------------------------------------------------------------------------

type
  Stamp* = object
    ## A DATE or DATE-TIME as written.
    ok*, date*, utc*: bool
    y*, mo*, d*, h*, mi*, s*: int
  Observance = object
    offFrom, offTo: int                 # seconds east of UTC
    start: int64                        # its DTSTART, wall-clock seconds (in offFrom)
    rule: bool                          # a yearly rule: BYMONTH with BYDAY or BYMONTHDAY
    month, nth, wday, mday: int         # (wday 0 Sunday; nth < 0 from the month's end)
    until: int64                        # UTC seconds; 0 none
    rdates: seq[int64]                  # wall-clock seconds
    std: bool

proc daysFromCivil(y, m, d: int): int64 =
  let y2 = if m <= 2: y - 1 else: y
  let era = (if y2 >= 0: y2 else: y2 - 399) div 400
  let yoe = y2 - era * 400
  let mp = (m + 9) mod 12
  let doy = (153 * mp + 2) div 5 + d - 1
  let doe = yoe * 365 + yoe div 4 - yoe div 100 + doy
  int64(era) * 146097 + int64(doe) - 719468

proc yearOf(secs: int64): int =
  let z = floorDiv(secs, 86400) + 719468
  let era = floorDiv(z, 146097)
  let doe = z - era * 146097
  let yoe = (doe - doe div 1460 + doe div 36524 - doe div 146096) div 365
  let doy = doe - (365 * yoe + yoe div 4 - yoe div 100)
  let mp = (5 * doy + 2) div 153
  let m = if mp < 10: mp + 3 else: mp - 9
  int(yoe + era * 400) + (if m <= 2: 1 else: 0)

proc parseStamp*(v: string): Stamp =
  ## "20261110", "20261110T100000", "20261110T100000Z" (or ISO 8601's
  ## "2026-11-10T10:00:00.0000000", as Graph writes them).
  var s = ""
  for c in v.strip:
    if c in {'0'..'9', 'T', 't', 'Z', 'z'}: s.add c
    elif c == '.': break               # (fractions of a second)
  if s.len < 8: return
  try:
    result.y = parseInt(s[0 .. 3])
    result.mo = parseInt(s[4 .. 5])
    result.d = parseInt(s[6 .. 7])
    if s.len == 8:
      result.date = true
    elif s.len >= 15 and s[8] in {'T', 't'}:
      result.h = parseInt(s[9 .. 10])
      result.mi = parseInt(s[11 .. 12])
      result.s = parseInt(s[13 .. 14])
      result.utc = s.len >= 16 and s[15] in {'Z', 'z'}
    else: return
  except ValueError: return
  if result.y < 1 or result.mo notin 1 .. 12 or result.h notin 0 .. 23 or
     result.mi notin 0 .. 59 or result.s notin 0 .. 60: return
  if result.d < 1 or result.d > getDaysInMonth(Month(result.mo), result.y): return
  result.ok = true

proc wall(st: Stamp): int64 =
  ## The wall-clock time as seconds, as if it were UTC.
  daysFromCivil(st.y, st.mo, st.d) * 86400 + int64(st.h * 3600 + st.mi * 60 + min(st.s, 59))

proc localWall(st: Stamp): float =
  ## The wall-clock time in the device's zone.
  try:
    dateTime(st.y, Month(st.mo), MonthdayRange(st.d), HourRange(st.h), MinuteRange(st.mi),
             SecondRange(min(st.s, 59)), 0, local()).toTime.toUnixFloat
  except CatchableError: float(wall(st))

proc offsetSecs(s: string): int =
  ## "+0400", "-0530", "+043000" as seconds east of UTC.
  let t = s.strip
  if t.len < 5 or t[0] notin {'+', '-'}: return 0
  try:
    result = parseInt(t[1 .. 2]) * 3600 + parseInt(t[3 .. 4]) * 60
    if t.len >= 7: result += parseInt(t[5 .. 6])
  except ValueError: return 0
  if t[0] == '-': result = -result

proc nthWeekday(y, m, nth, wday: int): int =
  ## The day of month of the `nth` `wday` (0 Sunday) of the month; nth < 0
  ## counts from its end.
  let last = getDaysInMonth(Month(m), y)
  if nth >= 0:
    let w0 = int(floorMod(daysFromCivil(y, m, 1) + 4, 7))
    result = 1 + (wday - w0 + 7) mod 7 + (max(nth, 1) - 1) * 7
    while result > last: result -= 7
  else:
    let wl = int(floorMod(daysFromCivil(y, m, last) + 4, 7))
    result = last - (wl - wday + 7) mod 7 + (nth + 1) * 7
    while result < 1: result += 7

proc onsets(obs: seq[Observance]; year: int): seq[tuple[at: int64; off: int]] =
  ## When the observances begin (UTC seconds) around `year`.
  for o in obs:
    if o.rule:
      let tod = floorMod(o.start, 86400)
      let first = yearOf(o.start)
      for y in year - 1 .. year + 1:
        if y < first: continue
        let d = if o.mday != 0:
                  (if o.mday > 0: min(o.mday, getDaysInMonth(Month(o.month), y))
                   else: getDaysInMonth(Month(o.month), y) + o.mday + 1)
                else: nthWeekday(y, o.month, o.nth, o.wday)
        let at = daysFromCivil(y, o.month, d) * 86400 + tod - o.offFrom
        if at < o.start - o.offFrom or (o.until != 0 and at > o.until): continue
        result.add (at, o.offTo)
    else:
      result.add (o.start - o.offFrom, o.offTo)
    for r in o.rdates: result.add (r - o.offFrom, o.offTo)

proc offsetAt(obs: seq[Observance]; t: int64): int =
  ## The zone's offset at UTC second `t`.
  var best = int64.low
  var found = false
  for (at, off) in onsets(obs, yearOf(t)):
    if at <= t and (not found or at > best):
      best = at
      result = off
      found = true
  if not found:
    for o in obs:
      if o.std: return o.offTo
    if obs.len > 0: result = obs[0].offFrom

proc wallToUtc(w: int64; obs: seq[Observance]): int64 =
  ## A wall-clock time of the zone in UTC: of two (the hour repeated in
  ## autumn) the first; in the hour skipped in spring, as the offset before.
  var cands: seq[int]
  for o in obs:
    for x in [o.offTo, o.offFrom]:
      if x notin cands: cands.add x
  if cands.len == 0: return w
  cands.sort(proc (a, b: int): int = cmp(b, a))
  for c in cands:
    if offsetAt(obs, w - c) == c: return w - c
  w - offsetAt(obs, w - cands[0])

proc ruleParts(rr: string): seq[(string, string)] =
  for part in rr.split(';'):
    let eq = part.find('=')
    if eq > 0: result.add (part[0 ..< eq].strip.toUpperAscii, part[eq + 1 .. ^1].strip.toUpperAscii)

const dayCodes = ["SU", "MO", "TU", "WE", "TH", "FR", "SA"]

proc observancesOf(tz: IcalComp): seq[Observance] =
  ## The observances of a VTIMEZONE.
  for c in tz.comps:
    if c.name notin ["STANDARD", "DAYLIGHT"]: continue
    var o = Observance(offFrom: offsetSecs(c.prop("TZOFFSETFROM").value),
                       offTo: offsetSecs(c.prop("TZOFFSETTO").value), std: c.name == "STANDARD")
    let st = parseStamp(c.prop("DTSTART").value)
    o.start = if st.ok: wall(st) else: 0
    let rr = c.prop("RRULE").value
    if rr.len > 0:
      var freq = ""
      for (k, v) in ruleParts(rr):
        case k
        of "FREQ": freq = v
        of "BYMONTH": o.month = (try: parseInt(v.split(',')[0]) except ValueError: 0)
        of "BYMONTHDAY": o.mday = (try: parseInt(v.split(',')[0]) except ValueError: 0)
        of "BYDAY":
          let b = v.split(',')[0]
          if b.len >= 2:
            o.wday = dayCodes.find(b[^2 .. ^1])
            let n = b[0 ..< b.len - 2]
            o.nth = if n.len == 0: 1 else: (try: parseInt(n.strip(chars = {'+'})) except ValueError: 1)
        of "UNTIL":
          let u = parseStamp(v)
          if u.ok: o.until = if u.utc: wall(u) else: wall(u) - o.offFrom
        else: discard
      o.rule = freq == "YEARLY" and o.month in 1 .. 12 and (o.mday != 0 or o.wday >= 0 and o.nth != 0)
    for p in c.props("RDATE"):
      for v in p.value.split(','):
        let r = parseStamp(v)
        if r.ok: o.rdates.add wall(r)
    result.add o

# well-known zones, for a TZID without a VTIMEZONE: (name, minutes east of
# UTC, rule: 0 none, 1 the European Union's, 2 the United States')
const zoneTable = [
  ("utc", 0, 0), ("gmt", 0, 0), ("etc/utc", 0, 0), ("etc/gmt", 0, 0), ("z", 0, 0),
  ("coordinated universal time", 0, 0), ("greenwich standard time", 0, 0),
  ("asia/muscat", 240, 0), ("asia/dubai", 240, 0), ("arabian standard time", 240, 0),
  ("asia/riyadh", 180, 0), ("asia/kuwait", 180, 0), ("asia/bahrain", 180, 0), ("asia/qatar", 180, 0),
  ("asia/aden", 180, 0), ("asia/baghdad", 180, 0), ("arab standard time", 180, 0),
  ("arabic standard time", 180, 0), ("europe/istanbul", 180, 0), ("turkey standard time", 180, 0),
  ("europe/moscow", 180, 0), ("russian standard time", 180, 0), ("africa/nairobi", 180, 0),
  ("e. africa standard time", 180, 0), ("asia/tehran", 210, 0), ("iran standard time", 210, 0),
  ("asia/karachi", 300, 0), ("pakistan standard time", 300, 0), ("asia/tashkent", 300, 0),
  ("asia/kolkata", 330, 0), ("asia/calcutta", 330, 0), ("india standard time", 330, 0),
  ("asia/kathmandu", 345, 0), ("asia/dhaka", 360, 0), ("bangladesh standard time", 360, 0),
  ("asia/bangkok", 420, 0), ("asia/jakarta", 420, 0), ("se asia standard time", 420, 0),
  ("asia/singapore", 480, 0), ("asia/kuala_lumpur", 480, 0), ("singapore standard time", 480, 0),
  ("asia/shanghai", 480, 0), ("asia/hong_kong", 480, 0), ("china standard time", 480, 0),
  ("asia/manila", 480, 0), ("australia/perth", 480, 0), ("w. australia standard time", 480, 0),
  ("asia/tokyo", 540, 0), ("tokyo standard time", 540, 0), ("asia/seoul", 540, 0),
  ("korea standard time", 540, 0), ("africa/johannesburg", 120, 0),
  ("south africa standard time", 120, 0), ("africa/lagos", 60, 0),
  ("w. central africa standard time", 60, 0), ("america/phoenix", -420, 0),
  ("us mountain standard time", -420, 0), ("america/sao_paulo", -180, 0),
  ("e. south america standard time", -180, 0), ("pacific/honolulu", -600, 0),
  ("hawaiian standard time", -600, 0),
  ("europe/london", 0, 1), ("europe/dublin", 0, 1), ("europe/lisbon", 0, 1), ("gmt standard time", 0, 1),
  ("europe/paris", 60, 1), ("europe/berlin", 60, 1), ("europe/madrid", 60, 1), ("europe/rome", 60, 1),
  ("europe/amsterdam", 60, 1), ("europe/brussels", 60, 1), ("europe/vienna", 60, 1),
  ("europe/zurich", 60, 1), ("europe/stockholm", 60, 1), ("europe/oslo", 60, 1),
  ("europe/copenhagen", 60, 1), ("europe/warsaw", 60, 1), ("europe/prague", 60, 1),
  ("europe/budapest", 60, 1), ("w. europe standard time", 60, 1), ("romance standard time", 60, 1),
  ("central europe standard time", 60, 1), ("central european standard time", 60, 1),
  ("europe/athens", 120, 1), ("europe/helsinki", 120, 1), ("europe/kiev", 120, 1),
  ("europe/kyiv", 120, 1), ("europe/bucharest", 120, 1), ("europe/sofia", 120, 1),
  ("gtb standard time", 120, 1), ("fle standard time", 120, 1),
  ("america/new_york", -300, 2), ("america/toronto", -300, 2), ("america/detroit", -300, 2),
  ("eastern standard time", -300, 2), ("us/eastern", -300, 2), ("america/chicago", -360, 2),
  ("central standard time", -360, 2), ("us/central", -360, 2), ("america/denver", -420, 2),
  ("mountain standard time", -420, 2), ("us/mountain", -420, 2), ("america/los_angeles", -480, 2),
  ("america/vancouver", -480, 2), ("pacific standard time", -480, 2), ("us/pacific", -480, 2)]

proc ruleZone(std, rule: int): seq[Observance] =
  let s = std * 60
  case rule
  of 1:    # the last Sundays of March and October, 01:00 UTC (since 1996)
    let base = daysFromCivil(1996, 1, 1) * 86400
    @[Observance(offFrom: s, offTo: s + 3600, start: base + floorMod(3600 + s, 86400), rule: true,
                 month: 3, nth: -1, wday: 0),
      Observance(offFrom: s + 3600, offTo: s, start: base + floorMod(7200 + s, 86400), rule: true,
                 month: 10, nth: -1, wday: 0, std: true)]
  of 2:    # the second Sunday of March, the first of November, 02:00 there (since 2007)
    let base = daysFromCivil(2007, 1, 1) * 86400 + 7200
    @[Observance(offFrom: s, offTo: s + 3600, start: base, rule: true, month: 3, nth: 2, wday: 0),
      Observance(offFrom: s + 3600, offTo: s, start: base, rule: true, month: 11, nth: 1, wday: 0,
                 std: true)]
  else: @[Observance(offFrom: s, offTo: s, std: true)]

proc knownZone(tzid: string): seq[Observance] =
  let n = tzid.strip.toLowerAscii
  for (name, std, rule) in zoneTable:
    if n == name or n.endsWith("/" & name): return ruleZone(std, rule)
  # "Etc/GMT-4" (the sign the other way), "(UTC+04:00) Abu Dhabi, Muscat"
  if n.startsWith("etc/gmt") and n.len > 8 and n[7] in {'+', '-'}:
    let h = try: parseInt(n[8 .. ^1]) except ValueError: 99
    if h <= 14: return ruleZone((if n[7] == '+': -h else: h) * 60, 0)
  for p in ["utc", "gmt"]:
    let k = n.find(p)
    if k >= 0 and k + 4 < n.len and n[k + 3] in {'+', '-'}:
      var digits = ""
      var j = k + 4
      while j < n.len and n[j] in {'0'..'9', ':'}:
        if n[j] != ':': digits.add n[j]
        inc j
      if digits.len in [1, 2, 3, 4]:
        let hm = if digits.len <= 2: parseInt(digits) * 60
                 else: parseInt(digits[0 ..< digits.len - 2]) * 60 + parseInt(digits[^2 .. ^1])
        if hm <= 14 * 60: return ruleZone((if n[k + 3] == '-': -hm else: hm), 0)

proc zoneOf(tzid: string; cal: IcalComp): seq[Observance] =
  ## A TZID's observances: the calendar's VTIMEZONE, else a known zone;
  ## none when it is not known.
  result = @[]         # (a value at once: see tools/writecheck.py)
  if not cal.isNil:
    for vcal in (if cal.name == "VCALENDAR": @[cal] else: cal.children("VCALENDAR") & @[cal]):
      for tz in vcal.children("VTIMEZONE"):
        if tz.prop("TZID").value.strip == tzid.strip:
          result = observancesOf(tz)
          if result.len > 0: return
  result = knownZone(tzid)

proc stampToUtc*(st: Stamp; tzid: string; cal: IcalComp = nil): float =
  ## A DATE-TIME as epoch seconds: Z as UTC, a TZID through the calendar's
  ## VTIMEZONE or a known zone, else (floating, a zone not known) the
  ## device's zone.
  if not st.ok: return 0
  if st.utc: return float(wall(st))
  if tzid.len > 0:
    let obs = zoneOf(tzid, cal)
    if obs.len > 0: return float(wallToUtc(wall(st), obs))
  localWall(st)

proc zoneOffset*(tzid: string; t: float): tuple[secs: int; known: bool] =
  ## How far east of UTC zone `tzid` (a well-known name, IANA's or
  ## Windows') is at instant `t`, in seconds; not `known` for another zone.
  let obs = knownZone(tzid)
  if obs.len == 0: return (0, false)
  (offsetAt(obs, int64(floor(t))), true)

proc zoneToUtc*(dateTime, timeZone: string): float =
  ## Graph's {dateTime, timeZone} ("2026-11-20T08:00:00.0000000", "UTC" or
  ## a zone name, Windows' or IANA's) as epoch seconds.
  let tz = if timeZone.strip.len == 0: "UTC" else: timeZone
  stampToUtc(parseStamp(dateTime), tz)

proc localMidnight*(st: Stamp): float =
  ## The start of a whole day in the device's zone.
  if not st.ok: return 0
  var s = st
  (s.h, s.mi, s.s) = (0, 0, 0)
  localWall(s)

proc timeOf*(cal: IcalComp; p: IcalProp): tuple[t: float; allDay: bool] =
  ## A DTSTART / DTEND / RECURRENCE-ID as epoch seconds; whole days (a DATE)
  ## as the device's local midnight.
  let st = parseStamp(p.value)
  if not st.ok: return (0.0, false)
  if st.date or p.param("VALUE").toUpperAscii == "DATE": return (localMidnight(st), true)
  (stampToUtc(st, p.param("TZID"), cal), false)

proc durationSecs*(s: string): float =
  ## A DURATION ("PT1H30M", "P1D", "-PT15M", "P2W") in seconds.
  var t = s.strip.toUpperAscii
  var sign = 1.0
  if t.startsWith("-"): (sign = -1.0; t = t[1 .. ^1])
  elif t.startsWith("+"): t = t[1 .. ^1]
  if not t.startsWith("P"): return 0
  var n = 0
  var timePart = false
  for c in t[1 .. ^1]:
    case c
    of '0'..'9': n = n * 10 + (ord(c) - ord('0'))
    of 'T': timePart = true
    of 'W': (result += float(n) * 604800; n = 0)
    of 'D': (result += float(n) * 86400; n = 0)
    of 'H': (result += float(n) * 3600; n = 0)
    of 'M': (result += float(n) * (if timePart: 60.0 else: 2592000.0); n = 0)
    of 'S': (result += float(n); n = 0)
    else: return 0
  result *= sign

# ---- writing -----------------------------------------------------------------------------

proc escapeText*(s: string): string =
  ## A TEXT value as written: \\ \; \, and \n for a line break.
  for c in s:
    case c
    of '\\': result.add "\\\\"
    of ';': result.add "\\;"
    of ',': result.add "\\,"
    of '\n': result.add "\\n"
    of '\r': discard
    else: result.add c

proc paramValue*(s: string): string =
  ## A parameter value as written: quoted when it holds : ; or , (double
  ## quotes and line breaks cannot be in one: left out).
  result = ""         # (a value at once: see tools/writecheck.py)
  for c in s:
    if c != '"' and ord(c) >= 32 and c != '\x7F': result.add c
  if result.contains({':', ';', ','}): result = "\"" & result & "\""

proc foldLine*(line: string): string =
  ## A content line as written: CRLF-ended, folded so no line is longer
  ## than 75 octets (never inside a UTF-8 character).
  var i = 0
  var width = 75
  while line.len - i > width:
    var e = i + width
    while e > i + 1 and (ord(line[e]) and 0xC0) == 0x80: dec e
    result.add line[i ..< e]
    result.add "\r\n "
    i = e
    width = 74
  result.add line[i .. ^1]
  result.add "\r\n"

proc utcStamp*(t: float): string =
  ## Epoch seconds as a UTC DATE-TIME: 20261110T060000Z.
  fromUnixFloat(t).utc.format("yyyyMMdd'T'HHmmss'Z'")

proc dateStamp*(t: float): string =
  ## Epoch seconds as the DATE it is in the device's zone: 20261110.
  fromUnixFloat(t).local.format("yyyyMMdd")
