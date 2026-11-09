## The classic cursors as drawings: rows of `X` (black), `.` (white) and
## ` ` (none) with a hot spot, for a driver that draws its pointer itself
## (X11 on a dense screen without a cursor theme, Wayland without the
## compositor's cursor shapes, a framebuffer).

import ../screen

proc shapeArt(fill: seq[string]; ink: bool): seq[string] =
  ## A shape (`#`) with a 1-pixel edge all round: white inside and black
  ## edge, or (`ink`) black inside and a white edge, so it shows on any
  ## background. (`X` black, `.` white, ` ` none.)
  let h = fill.len + 2
  var w = 0
  for r in fill: w = max(w, r.len)
  w += 2
  template at(r, c: int): bool =
    (let rr = r - 1; let cc = c - 1;
     rr >= 0 and rr < fill.len and cc >= 0 and cc < fill[rr].len and fill[rr][cc] == '#')
  for r in 0 ..< h:
    var line = newString(w)
    for c in 0 ..< w:
      if at(r, c): line[c] = (if ink: 'X' else: '.')
      else:
        var edge = false
        for dr in -1 .. 1:
          for dc in -1 .. 1:
            if at(r + dr, c + dc): edge = true
        line[c] = (if edge: (if ink: '.' else: 'X') else: ' ')
    result.add line

proc grid(w, h: int; inside: proc (r, c: int): bool): seq[string] =
  for r in 0 ..< h:
    var line = newString(w)
    for c in 0 ..< w: line[c] = (if inside(r, c): '#' else: ' ')
    result.add line

proc classicCursorArt*(c: CursorKind): tuple[rows: seq[string]; hx, hy: int] =
  ## The classic drawing of cursor `c`: rows of `X` (black), `.` (white) and
  ## ` ` (none), and its hot spot.
  case c
  of curDefault, curArrow:
    (@["X           ", "XX          ", "X.X         ", "X..X        ", "X...X       ",
       "X....X      ", "X.....X     ", "X......X    ", "X.......X   ", "X........X  ",
       "X.....XXXXX ", "X..X..X     ", "X.X X..X    ", "XX  X..X    ", "X    X..X   ",
       "     X..X   ", "      X..X  ", "      X..X  ", "       XX   "], 0, 0)
  of curIbeam:
    var core = @["### ###"]
    for _ in 0 ..< 14: core.add "   #   "
    core.add "### ###"
    (shapeArt(core, true), 4, 8)
  of curWait:
    (@["XXXXXXXXXXXXX", "X...........X", "XXXXXXXXXXXXX", " X.........X ", " X.........X ",
       "  X.......X  ", "   X.....X   ", "    X...X    ", "     X.X     ", "     X.X     ",
       "    X...X    ", "   X..X..X   ", "  X..XXX..X  ", " X..XXXXX..X ", " X.XXXXXXX.X ",
       "XXXXXXXXXXXXX", "X...........X", "XXXXXXXXXXXXX"], 6, 9)
  of curHand:
    (@["     XX         ", "    X..X        ", "    X..X        ", "    X..X        ",
       "    X..X        ", "    X..XXX      ", "    X..X..XXX   ", "    X..X..X..XX ",
       " XX X..X..X..X.X", "X..XX........X.X", "X...X..........X", " X.............X",
       "  X............X", "  X...........X ", "   X..........X ", "   X.........X  ",
       "    X........X  ", "    X........X  ", "    XXXXXXXXXX  "], 5, 0)
  of curCrosshair:
    (shapeArt(grid(15, 15, proc (r, c: int): bool = r == 7 or c == 7), true), 8, 8)
  of curSizeWE:
    (shapeArt(grid(21, 7, proc (r, c: int): bool =
      (c <= 3 and abs(r - 3) <= c) or (c >= 17 and abs(r - 3) <= 20 - c) or
      (r == 3)), false), 11, 4)
  of curSizeNS:
    (shapeArt(grid(7, 21, proc (r, c: int): bool =
      (r <= 3 and abs(c - 3) <= r) or (r >= 17 and abs(c - 3) <= 20 - r) or
      (c == 3)), false), 4, 11)
  of curSizeNWSE:
    (shapeArt(grid(13, 13, proc (r, c: int): bool =
      (r + c <= 4) or ((12 - r) + (12 - c) <= 4) or (r == c)), false), 7, 7)
  of curSizeNESW:
    (shapeArt(grid(13, 13, proc (r, c: int): bool =
      (r + (12 - c) <= 4) or ((12 - r) + c <= 4) or (r == 12 - c)), false), 7, 7)
  of curMove:
    (shapeArt(grid(19, 19, proc (r, c: int): bool =
      (r <= 3 and abs(c - 9) <= r) or (r >= 15 and abs(c - 9) <= 18 - r) or
      (c <= 3 and abs(r - 9) <= c) or (c >= 15 and abs(r - 9) <= 18 - c) or
      (r == 9 and c >= 3 and c <= 15) or (c == 9 and r >= 3 and r <= 15)), false), 10, 10)
