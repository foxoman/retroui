## Base types for the UI layer: rectangles and points in the window's
## coordinates (x to the right, y down). No SDL or platform dependencies.
##
## ```nim
## let r = rect(10, 10, 100, 40)
## assert point(20, 20) in r
## ```

type
  Rect* = object
    ## A rectangle: its top-left corner and its size.
    x*, y*: int    ## the top-left corner
    w*, h*: int    ## the width and height (0 or less: empty)

  Point* = object
    ## A point in the window.
    x*, y*: int

  GlobalPos* = object
    ## A position in a document or a scene: `x`, `y`, `z` and a time `t`
    ## (a layout cell's place, a frame of an animation).
    x*, y*, z*: int
    t*: int

proc rect*(x, y, w, h: int): Rect =
  ## A rectangle at `x`, `y`, `w` x `h`.
  Rect(x: x, y: y, w: w, h: h)

proc point*(x, y: int): Point =
  ## A point at `x`, `y`.
  Point(x: x, y: y)

proc contains*(r: Rect; p: Point): bool =
  ## Whether `p` is inside `r` (the right and bottom edges are outside).
  p.x >= r.x and p.x < r.x + r.w and p.y >= r.y and p.y < r.y + r.h
