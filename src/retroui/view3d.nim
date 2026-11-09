## A 3D view: scenes of meshes and models drawn by the kit itself -- on
## the CPU with no library, or with OpenGL where the kit draws with the
## GPU -- for product viewers, car configurators, 3D bar charts and scenes
## that move. Models from Blender and other tools: `retroui/gltf`.
##
## - `Scene3`: meshes (`box`, `sphere`, `cylinder`, `cone`, `plane`, or
##   loaded with `loadObj` / `loadStl` / `loadModel`), lines (`addGrid`,
##   `addAxes`), labels; `bars3d` makes a 3D bar chart
## - `Camera3`: orbits a target; `fitView` frames the scene
## - `view3d`: the widget -- a drag turns the scene (Shift or Ctrl + drag,
##   or a finger held a moment, moves it), the wheel zooms, arrows, + / -
##   and Home work when it has the focus, the +, - and home buttons in its
##   corner do too; a click picks the mesh under it
## - `render3d`: the same picture into a `Bitmap` (to save as PNG)
##
## - parts (`Node3`: found by name, moved, turned, hidden, tinted), clips
##   (`play`, `animate`), bones and shapes, materials (`Material3`)
##
## Triangles are filled with a z-buffer at the screen's own resolution, lit
## (flat, or smooth with `Mesh3.smooth`; metal, paint and glass as their
## materials say) on all the cores, with outlines when asked; on the GPU
## the same picture is drawn by OpenGL (`view3dOnGpu`). A frame where nothing changed costs nothing: the picture is drawn
## again only when the scene, the camera or the size changed. After
## changing a mesh's points or triangles in place, call `sceneChanged`.
##
## .. code-block:: nim
##   var scene = Scene3()
##   discard scene.add box(1, 1, 1, color(0, 0, 160))
##   scene.addGrid()
##   var cam = camera3()
##   fitView(scene, cam)
##   app "3D", 800, 600:
##     let ev = view3d(scene, cam)
##     if ev.clicked and ev.picked >= 0: echo scene.meshes[ev.picked].name

import std/[math, tables, strutils, parseutils, os, algorithm]
import uirelays/input
import gfx, core, widgets, pixelicons, nerdicons, parallel

template th: untyped = ui.theme

type
  Vec3* = object
    ## A point or a direction in 3D (`vec3` makes one).
    x*, y*, z*: float32      ## y is up

  Quat* = object
    ## A turn in 3D (a unit quaternion; `quatAxis`, `quatEuler` make one).
    x*, y*, z*, w*: float32

  Mat4* = array[16, float32]
    ## A 4 x 4 matrix, column by column (as glTF has them).

  AlphaMode3* = enum
    amOpaque     ## solid
    amMask       ## solid where its alpha is past `alphaCutoff`, else not there
    amBlend      ## see-through as its alpha says (glass, lights)

  Material3* = object
    ## How a surface looks (glTF's metallic-roughness model): its color
    ## (and picture), how metallic and how rough it is, what light it gives.
    name*: string
    baseColor*: array[4, float32]   ## red, green, blue, alpha (0..1)
    texture*: Bitmap                ## the color's picture (nil: none)
    metallic*, roughness*: float32  ## 0 (plastic, paint) .. 1 (metal); 0 (mirror) .. 1 (chalk)
    mrTexture*: Bitmap              ## roughness (green) and metallic (blue) by place (nil: none)
    emissive*: array[3, float32]    ## the light it gives (0..1, and more with a strength)
    emissiveTexture*: Bitmap
    alphaMode*: AlphaMode3
    alphaCutoff*: float32
    doubleSided*: bool              ## both its sides drawn
    unlit*: bool                    ## its color as it is, no light on it

  Node3* = object
    ## A part of a model: it carries meshes, is placed in its parent
    ## (moved, turned, scaled), and can be shown or hidden, tinted, turned
    ## by the app or by an animation (`play`).
    name*: string
    parent*: int                    ## -1: none
    children*: seq[int]
    t*: Vec3                        ## where it is in its parent
    r*: Quat                        ## how it is turned
    s*: Vec3                        ## how it is scaled
    visible*: bool                  ## shown (with its children)
    tint*: Color                    ## its meshes in this color (alpha 0: their own)
    meshes*: seq[int]               ## indices into `Scene3.meshes`
    morphWeights*: seq[float32]     ## its meshes' shapes mixed so

  Skin3* = object
    ## Points that follow bones (`joints`, nodes), as a character's or a
    ## suspension's.
    joints*: seq[int]
    inverseBind*: seq[Mat4]

  AnimPath3* = enum apTranslation, apRotation, apScale, apWeights
  AnimInterp3* = enum aiLinear, aiStep, aiCubic

  AnimChannel3* = object
    node*: int
    path*: AnimPath3
    times*: seq[float32]
    values*: seq[float32]           ## (3 or 4 numbers a key, or one per shape; three
                                    ## times that for cubic: in, value, out)
    interp*: AnimInterp3

  Animation3* = object
    ## A clip made in Blender (or any glTF tool): what moves how, over time.
    name*: string
    channels*: seq[AnimChannel3]
    duration*: float32              ## seconds

  Playing3 = object
    anim: int
    time, speed: float32
    loop: bool

  Mesh3* = object
    ## Points and the triangles between them (counter-clockwise seen from
    ## outside), placed in the scene by `pos`, `rot` (degrees about x, y,
    ## then z) and `scale` -- or, in a model with nodes, by its `node`.
    name*: string            ## shown when it is picked or hovered ("" none)
    verts*: seq[Vec3]        ## its points
    tris*: seq[array[3, int32]]  ## its triangles: three indices of `verts` each
    color*: Color            ## of every triangle (when `colors` is empty)
    colors*: seq[Color]      ## one per triangle
    normals*: seq[Vec3]      ## one per point, for `smooth` (else worked out)
    smooth*: bool            ## shaded smoothly across the triangles
    twoSided*: bool          ## both sides drawn (planes, open surfaces)
    edges*: bool             ## its triangles outlined
    visible*: bool           ## drawn
    pos*, rot*, scale*: Vec3 ## where it is put, how it is turned, how it is scaled
    material*: int           ## its look in `Scene3.materials` (-1: `color`, lit simply)
    uvs*: seq[array[2, float32]]     ## where each point is in the material's pictures
    vcolors*: seq[array[4, float32]] ## a color for each point (multiplies the material's)
    node*: int               ## the node that places it (-1: `pos`, `rot`, `scale`)
    skin*: int               ## its skin in `Scene3.skins` (-1: none)
    joints*: seq[array[4, uint16]]   ## the bones each point follows
    weights*: seq[array[4, float32]] ## ... and how much
    targets*: seq[seq[Vec3]]         ## shapes it can take (each point's move)
    targetNormals*: seq[seq[Vec3]]
    morphWeights*: seq[float32]      ## how much of each shape (its node's when it has them)

  Line3* = object
    ## A line in the scene (an axis, a grid, a measure).
    a*, b*: Vec3             ## where it starts and ends
    color*: Color            ## its color

  Label3* = object
    ## Words at a point of the scene, always facing the viewer.
    at*: Vec3                ## where
    text*: string            ## what it says
    color*: Color            ## alpha 0: the theme's text color
    bold*: bool              ## in bold

  Scene3* = object
    ## What a `view3d` shows.
    meshes*: seq[Mesh3]      ## its meshes
    lines*: seq[Line3]       ## its lines
    labels*: seq[Label3]     ## its labels
    background*: Color       ## alpha 0: a soft gradient in the theme's colors
    ambient*: float32        ## 0..1, how light the side away from the light is
    wireframe*: bool         ## only the edges of the triangles
    materials*: seq[Material3]
    nodes*: seq[Node3]       ## a model's parts (`loadGltf`); empty: meshes placed by themselves
    roots*: seq[int]         ## the nodes without a parent
    skins*: seq[Skin3]
    animations*: seq[Animation3]
    exposure*: float32       ## how bright the lit materials are (0: 1)
    playing: seq[Playing3]
    version: int

  Camera3* = object
    ## Looks at `target` from `distance` away, turned `yaw` degrees about
    ## the vertical and `pitch` degrees up; `fov` is the vertical angle.
    target*: Vec3            ## the point looked at
    yaw*, pitch*, distance*, fov*: float32  ## degrees, degrees, scene units, degrees
    home: tuple[set: bool; target: Vec3; yaw, pitch, distance: float32]

  View3DEvent* = object
    ## What happened in a `view3d` this frame.
    clicked*: bool           ## a click or tap that did not turn the scene
    picked*: int             ## ... the mesh under it (-1: none)
    pickedTri*: int          ## ... and its triangle
    hovered*: int            ## the mesh under the mouse now (-1: none; not fingers)
    hoveredTri*: int         ## ... and its triangle (-1: none)
    activated*: bool         ## a double click on a mesh (`picked`)
    cameraChanged*: bool     ## turned, moved or zoomed this frame
    node*: int               ## the node of the mesh picked or hovered (-1: none)
    nodeName*: string        ## ... its name (the part: "Door_L", "Wheel_FR")

const
  MaxTriangles* = 2_000_000  ## the most a loaded model may have
  MaxPoints* = 6_000_000     ## the most points a loaded model may have
  MaxModelBytes* = 256 * 1024 * 1024  ## the largest model file read (bytes)

proc vec3*(x, y, z: float): Vec3 {.inline.} = Vec3(x: x.float32, y: y.float32, z: z.float32)
  ## A point (or direction) in 3D.

proc `+`(a, b: Vec3): Vec3 {.inline.} = Vec3(x: a.x + b.x, y: a.y + b.y, z: a.z + b.z)
proc `-`(a, b: Vec3): Vec3 {.inline.} = Vec3(x: a.x - b.x, y: a.y - b.y, z: a.z - b.z)
proc `*`(a: Vec3; k: float32): Vec3 {.inline.} = Vec3(x: a.x * k, y: a.y * k, z: a.z * k)
proc dot(a, b: Vec3): float32 {.inline.} = a.x * b.x + a.y * b.y + a.z * b.z
proc cross(a, b: Vec3): Vec3 {.inline.} =
  Vec3(x: a.y * b.z - a.z * b.y, y: a.z * b.x - a.x * b.z, z: a.x * b.y - a.y * b.x)
proc len(a: Vec3): float32 {.inline.} = sqrt(dot(a, a))
proc unit(a: Vec3): Vec3 {.inline.} =
  let l = len(a)
  if l > 1e-20: a * (1'f32 / l) else: Vec3(y: 1)
proc finite(v: float32): bool {.inline.} = v == v and abs(v) < 1e30
proc finite(v: Vec3): bool {.inline.} = finite(v.x) and finite(v.y) and finite(v.z)

# ---- turns and matrices --------------------------------------------------------------------

proc quat*(x, y, z, w: float): Quat {.inline.} = Quat(x: x.float32, y: y.float32, z: z.float32, w: w.float32)

proc quatAxis*(axis: Vec3; degrees: float): Quat =
  ## A turn of `degrees` about `axis` (a wheel turning: `quatAxis(vec3(1, 0, 0), angle)`).
  let a = unit(axis)
  let h = degrees * PI / 360
  let s = sin(h).float32
  Quat(x: a.x * s, y: a.y * s, z: a.z * s, w: cos(h).float32)

proc `*`*(a, b: Quat): Quat =
  ## `b`, then `a`.
  Quat(w: a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z,
       x: a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
       y: a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
       z: a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w)

proc quatEuler*(xDeg, yDeg, zDeg: float): Quat =
  ## Turns about x, then y, then z (degrees).
  quatAxis(Vec3(z: 1), zDeg) * quatAxis(Vec3(y: 1), yDeg) * quatAxis(Vec3(x: 1), xDeg)

proc normalized(q: Quat): Quat =
  let l = sqrt(q.x * q.x + q.y * q.y + q.z * q.z + q.w * q.w)
  if l < 1e-12: Quat(w: 1) else: Quat(x: q.x / l, y: q.y / l, z: q.z / l, w: q.w / l)

proc slerp*(a, b: Quat; t: float32): Quat =
  ## The turn `t` of the way from `a` to `b` (the short way).
  var b = b
  var d = a.x * b.x + a.y * b.y + a.z * b.z + a.w * b.w
  if d < 0:
    d = -d
    b = Quat(x: -b.x, y: -b.y, z: -b.z, w: -b.w)
  if d > 0.9995:
    return normalized(Quat(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t,
                           z: a.z + (b.z - a.z) * t, w: a.w + (b.w - a.w) * t))
  let th = arccos(clamp(d, -1, 1))
  let s = sin(th)
  let ka = sin((1 - t) * th) / s
  let kb = sin(t * th) / s
  Quat(x: a.x * ka + b.x * kb, y: a.y * ka + b.y * kb, z: a.z * ka + b.z * kb, w: a.w * ka + b.w * kb)

const Identity4*: Mat4 = [1'f32, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]

proc compose*(t: Vec3; r: Quat; s: Vec3): Mat4 =
  ## The matrix that scales by `s`, turns by `r`, then moves by `t`.
  let q = normalized(r)
  let (x, y, z, w) = (q.x, q.y, q.z, q.w)
  let (xx, yy, zz) = (x * x, y * y, z * z)
  let (xy, xz, yz) = (x * y, x * z, y * z)
  let (wx, wy, wz) = (w * x, w * y, w * z)
  [(1 - 2 * (yy + zz)) * s.x, (2 * (xy + wz)) * s.x, (2 * (xz - wy)) * s.x, 0,
   (2 * (xy - wz)) * s.y, (1 - 2 * (xx + zz)) * s.y, (2 * (yz + wx)) * s.y, 0,
   (2 * (xz + wy)) * s.z, (2 * (yz - wx)) * s.z, (1 - 2 * (xx + yy)) * s.z, 0,
   t.x, t.y, t.z, 1]

proc `*`*(a, b: Mat4): Mat4 =
  ## `b`, then `a`.
  for c in 0 .. 3:
    for r in 0 .. 3:
      result[c * 4 + r] = a[r] * b[c * 4] + a[4 + r] * b[c * 4 + 1] + a[8 + r] * b[c * 4 + 2] +
                          a[12 + r] * b[c * 4 + 3]

proc point(m: Mat4; v: Vec3): Vec3 {.inline.} =
  Vec3(x: m[0] * v.x + m[4] * v.y + m[8] * v.z + m[12],
       y: m[1] * v.x + m[5] * v.y + m[9] * v.z + m[13],
       z: m[2] * v.x + m[6] * v.y + m[10] * v.z + m[14])

proc direction(m: Mat4; v: Vec3): Vec3 {.inline.} =
  Vec3(x: m[0] * v.x + m[4] * v.y + m[8] * v.z,
       y: m[1] * v.x + m[5] * v.y + m[9] * v.z,
       z: m[2] * v.x + m[6] * v.y + m[10] * v.z)

proc decompose*(m: Mat4): tuple[t: Vec3; r: Quat; s: Vec3] =
  ## The move, turn and scale a matrix makes (one without shear).
  result.t = Vec3(x: m[12], y: m[13], z: m[14])
  var sx = len(Vec3(x: m[0], y: m[1], z: m[2]))
  let sy = len(Vec3(x: m[4], y: m[5], z: m[6]))
  let sz = len(Vec3(x: m[8], y: m[9], z: m[10]))
  # (a mirror: one scale negative)
  let det = m[0] * (m[5] * m[10] - m[6] * m[9]) - m[4] * (m[1] * m[10] - m[2] * m[9]) +
            m[8] * (m[1] * m[6] - m[2] * m[5])
  if det < 0: sx = -sx
  result.s = Vec3(x: sx, y: sy, z: sz)
  let ix = if abs(sx) > 1e-12: 1 / sx else: 0
  let iy = if sy > 1e-12: 1 / sy else: 0
  let iz = if sz > 1e-12: 1 / sz else: 0
  let r00 = m[0] * ix
  let r10 = m[1] * ix
  let r20 = m[2] * ix
  let r01 = m[4] * iy
  let r11 = m[5] * iy
  let r21 = m[6] * iy
  let r02 = m[8] * iz
  let r12 = m[9] * iz
  let r22 = m[10] * iz
  let tr = r00 + r11 + r22
  var q: Quat
  if tr > 0:
    let k = sqrt(tr + 1) * 2
    q = Quat(w: 0.25 * k, x: (r21 - r12) / k, y: (r02 - r20) / k, z: (r10 - r01) / k)
  elif r00 > r11 and r00 > r22:
    let k = sqrt(1 + r00 - r11 - r22) * 2
    q = Quat(w: (r21 - r12) / k, x: 0.25 * k, y: (r01 + r10) / k, z: (r02 + r20) / k)
  elif r11 > r22:
    let k = sqrt(1 + r11 - r00 - r22) * 2
    q = Quat(w: (r02 - r20) / k, x: (r01 + r10) / k, y: 0.25 * k, z: (r12 + r21) / k)
  else:
    let k = sqrt(1 + r22 - r00 - r11) * 2
    q = Quat(w: (r10 - r01) / k, x: (r02 + r20) / k, y: (r12 + r21) / k, z: 0.25 * k)
  result.r = normalized(q)

# ---- meshes --------------------------------------------------------------------------------------

proc newMesh*(name = ""; color = color(0, 0, 160)): Mesh3 =
  ## An empty mesh of one color (add its `verts` and `tris`).
  Mesh3(name: name, color: color, visible: true, scale: vec3(1, 1, 1), material: -1, node: -1, skin: -1)

proc triangleCount*(m: Mesh3): int = m.tris.len
  ## How many triangles the mesh has.

proc box*(w, h, d: float; color = color(0, 0, 160); name = "box"): Mesh3 =
  ## A box `w` wide (x), `h` high (y) and `d` deep (z), centered.
  result = newMesh(name, color)
  let (x, y, z) = (w.float32 / 2, h.float32 / 2, d.float32 / 2)
  result.verts = @[Vec3(x: -x, y: -y, z: -z), Vec3(x: x, y: -y, z: -z),
                   Vec3(x: x, y: y, z: -z), Vec3(x: -x, y: y, z: -z),
                   Vec3(x: -x, y: -y, z: z), Vec3(x: x, y: -y, z: z),
                   Vec3(x: x, y: y, z: z), Vec3(x: -x, y: y, z: z)]
  result.tris = @[[4'i32, 5, 6], [4'i32, 6, 7],      # front (+z)
                  [1'i32, 0, 3], [1'i32, 3, 2],      # back
                  [5'i32, 1, 2], [5'i32, 2, 6],      # right
                  [0'i32, 4, 7], [0'i32, 7, 3],      # left
                  [7'i32, 6, 2], [7'i32, 2, 3],      # top
                  [0'i32, 1, 5], [0'i32, 5, 4]]      # bottom

proc sphere*(radius: float; color = color(0, 0, 160); segments = 24; rings = 16;
             name = "sphere"): Mesh3 =
  ## A sphere, shaded smoothly.
  result = newMesh(name, color)
  result.smooth = true
  let seg = clamp(segments, 3, 512)
  let rg = clamp(rings, 2, 512)
  for j in 0 .. rg:
    let phi = PI * j.float / rg.float
    for i in 0 .. seg:
      let th2 = 2 * PI * i.float / seg.float
      let n = vec3(sin(phi) * sin(th2), cos(phi), sin(phi) * cos(th2))
      result.verts.add n * radius.float32
      result.normals.add n
  let row = seg + 1
  for j in 0 ..< rg:
    for i in 0 ..< seg:
      let a = int32(j * row + i)
      let b = int32((j + 1) * row + i)
      if j > 0: result.tris.add [a, b, a + 1]
      if j < rg - 1: result.tris.add [a + 1, b, b + 1]

proc lathe(name: string; color: Color; seg: int; bottomR, topR, h: float32;
           caps: bool): Mesh3 =
  ## A cylinder or cone about the y axis, from y = -h/2 to h/2.
  result = newMesh(name, color)
  result.smooth = true
  let seg = clamp(seg, 3, 1024)
  let y0 = -h / 2
  let y1 = h / 2
  let slope = (bottomR - topR) / max(1e-6'f32, h)
  for i in 0 .. seg:
    let a = 2 * PI * i.float / seg.float
    let (s, c) = (sin(a).float32, cos(a).float32)
    let n = unit(Vec3(x: s, y: slope, z: c))
    result.verts.add Vec3(x: s * bottomR, y: y0, z: c * bottomR)
    result.normals.add n
    result.verts.add Vec3(x: s * topR, y: y1, z: c * topR)
    result.normals.add n
  for i in 0 ..< seg:
    let a = int32(2 * i)
    result.tris.add [a, a + 2, a + 1]
    result.tris.add [a + 1, a + 2, a + 3]
  if caps:
    for (y, r, up) in [(y0, bottomR, false), (y1, topR, true)]:
      if r <= 0: continue
      let center = int32(result.verts.len)
      let n = Vec3(y: if up: 1 else: -1)
      result.verts.add Vec3(y: y)
      result.normals.add n
      for i in 0 .. seg:
        let a = 2 * PI * i.float / seg.float
        result.verts.add Vec3(x: sin(a).float32 * r, y: y, z: cos(a).float32 * r)
        result.normals.add n
      for i in 0 ..< seg:
        let a = center + 1 + int32(i)
        if up: result.tris.add [center, a, a + 1]
        else: result.tris.add [center, a + 1, a]

proc cylinder*(radius, height: float; color = color(0, 0, 160); segments = 24;
               name = "cylinder"): Mesh3 =
  ## A cylinder standing on the y axis, centered.
  lathe(name, color, segments, radius.float32, radius.float32, height.float32, true)

proc cone*(radius, height: float; color = color(0, 0, 160); segments = 24;
           name = "cone"): Mesh3 =
  ## A cone pointing up the y axis, centered.
  lathe(name, color, segments, radius.float32, 0, height.float32, true)

proc plane*(w, d: float; color = color(192, 192, 192); name = "plane"): Mesh3 =
  ## A flat rectangle in the x-z plane (seen from both sides).
  result = newMesh(name, color)
  result.twoSided = true
  let (x, z) = (w.float32 / 2, d.float32 / 2)
  result.verts = @[Vec3(x: -x, z: z), Vec3(x: x, z: z), Vec3(x: x, z: -z), Vec3(x: -x, z: -z)]
  result.tris = @[[0'i32, 1, 2], [0'i32, 2, 3]]

proc add*(scene: var Scene3; m: Mesh3): int {.discardable.} =
  ## Adds `m`; its index in `scene.meshes`.
  scene.meshes.add m
  inc scene.version
  scene.meshes.high

proc addLine*(scene: var Scene3; a, b: Vec3; color = color(128, 128, 128)) =
  ## Adds a line from `a` to `b`.
  scene.lines.add Line3(a: a, b: b, color: color)
  inc scene.version

proc addLabel*(scene: var Scene3; at: Vec3; text: string; color = Color(); bold = false) =
  ## Text shown at the point `at` (it keeps facing the screen).
  scene.labels.add Label3(at: at, text: text, color: color, bold: bold)
  inc scene.version

proc addGrid*(scene: var Scene3; size = 10.0; divisions = 10; y = 0.0;
              color = color(160, 160, 160)) =
  ## A square grid of lines in the x-z plane, `size` across.
  let n = clamp(divisions, 1, 1000)
  let h = size / 2
  for i in 0 .. n:
    let t = -h + size * i.float / n.float
    scene.lines.add Line3(a: vec3(t, y, -h), b: vec3(t, y, h), color: color)
    scene.lines.add Line3(a: vec3(-h, y, t), b: vec3(h, y, t), color: color)
  inc scene.version

proc addAxes*(scene: var Scene3; length = 1.0) =
  ## The x (red), y (green) and z (blue) axes from the origin.
  scene.addLine(vec3(0, 0, 0), vec3(length, 0, 0), color(220, 0, 0))
  scene.addLine(vec3(0, 0, 0), vec3(0, length, 0), color(0, 160, 0))
  scene.addLine(vec3(0, 0, 0), vec3(0, 0, length), color(0, 0, 220))

proc sceneChanged*(scene: var Scene3) =
  ## Call after changing points, triangles or colors in place: the view
  ## draws the scene again.
  inc scene.version

proc rotation(r: Vec3): array[9, float32] =
  ## The matrix turning by `r` degrees about x, then y, then z.
  let (sx, cx) = (sin(r.x.float * PI / 180).float32, cos(r.x.float * PI / 180).float32)
  let (sy, cy) = (sin(r.y.float * PI / 180).float32, cos(r.y.float * PI / 180).float32)
  let (sz, cz) = (sin(r.z.float * PI / 180).float32, cos(r.z.float * PI / 180).float32)
  # Rz * Ry * Rx
  [cz * cy, cz * sy * sx - sz * cx, cz * sy * cx + sz * sx,
   sz * cy, sz * sy * sx + cz * cx, sz * sy * cx - cz * sx,
   -sy, cy * sx, cy * cx]

proc apply(m: array[9, float32]; v: Vec3): Vec3 {.inline.} =
  Vec3(x: m[0] * v.x + m[1] * v.y + m[2] * v.z,
       y: m[3] * v.x + m[4] * v.y + m[5] * v.z,
       z: m[6] * v.x + m[7] * v.y + m[8] * v.z)

# ---- nodes: the parts of a model --------------------------------------------------------

proc newNode*(name = ""; parent = -1): Node3 =
  ## A part with nothing in it yet, in its place (add it with `addNode`).
  Node3(name: name, parent: parent, r: Quat(w: 1), s: vec3(1, 1, 1), visible: true)

proc addNode*(scene: var Scene3; n: Node3): int {.discardable.} =
  ## Puts `n` in the scene (under its `parent`); its index.
  result = scene.nodes.len
  scene.nodes.add n
  if n.parent >= 0 and n.parent < result: scene.nodes[n.parent].children.add result
  else:
    scene.nodes[result].parent = -1
    scene.roots.add result
  inc scene.version

proc findNode*(scene: Scene3; name: string): int =
  ## The node called `name` (-1: none); the first of that name.
  for i, n in scene.nodes:
    if n.name == name: return i
  -1

proc nodeNames*(scene: Scene3): seq[string] =
  ## The names of the model's parts (to find what to move: "Wheel_FL"...).
  for n in scene.nodes: result.add n.name

proc nodeWorlds(scene: Scene3): seq[Mat4] =
  ## Each node's place in the scene (its parents' placings and its own).
  result = newSeq[Mat4](scene.nodes.len)
  var done = newSeq[bool](scene.nodes.len)
  proc visit(scene: Scene3; i: int; parent: Mat4; result: var seq[Mat4]; done: var seq[bool]; depth: int) =
    if i < 0 or i >= scene.nodes.len or done[i] or depth > 256: return
    done[i] = true
    let n = scene.nodes[i]
    result[i] = parent * compose(n.t, n.r, n.s)
    for c in n.children: visit(scene, c, result[i], result, done, depth + 1)
  for i, n in scene.nodes:
    if n.parent < 0 or n.parent >= scene.nodes.len: visit(scene, i, Identity4, result, done, 0)
  for i in 0 ..< scene.nodes.len:
    if not done[i]: result[i] = compose(scene.nodes[i].t, scene.nodes[i].r, scene.nodes[i].s)

proc nodeShown(scene: Scene3; i: int): bool =
  ## The node and all above it are shown.
  var k = i
  var depth = 0
  while k >= 0 and k < scene.nodes.len and depth < 256:
    if not scene.nodes[k].visible: return false
    k = scene.nodes[k].parent
    inc depth
  true

proc nodeOf(scene: Scene3; nameOrIndex: string): int =
  result = scene.findNode(nameOrIndex)

proc setVisible*(scene: var Scene3; node: string; visible: bool) =
  ## Shows or hides a part (with what is in it: a door, the hood, a wheel).
  let i = scene.nodeOf(node)
  if i >= 0:
    scene.nodes[i].visible = visible
    inc scene.version

proc tint*(scene: var Scene3; node: string; c: Color) =
  ## A part (and what is in it) in color `c` (alpha 0: its own colors
  ## again) -- the body of the car in the customer's choice.
  let i = scene.nodeOf(node)
  if i < 0: return
  var stack = @[i]
  while stack.len > 0:
    let k = stack.pop()
    if k < 0 or k >= scene.nodes.len: continue
    scene.nodes[k].tint = c
    stack.add scene.nodes[k].children
  inc scene.version

proc turnNode*(scene: var Scene3; node: string; axis: Vec3; degrees: float) =
  ## Turns a part about `axis` (in its parent's directions) by `degrees`
  ## more (a wheel rolling, a door opening).
  let i = scene.nodeOf(node)
  if i >= 0:
    scene.nodes[i].r = normalized(scene.nodes[i].r * quatAxis(axis, degrees))
    inc scene.version

proc moveNode*(scene: var Scene3; node: string; by: Vec3) =
  ## Moves a part by `by` (in its parent's directions).
  let i = scene.nodeOf(node)
  if i >= 0:
    scene.nodes[i].t = scene.nodes[i].t + by
    inc scene.version

proc recolor*(scene: var Scene3; material: string; c: Color) =
  ## A material's color (by its name: "CarPaint") changed for every part
  ## that has it.
  for m in scene.materials.mitems:
    if m.name == material:
      m.baseColor = [c.r.float32 / 255, c.g.float32 / 255, c.b.float32 / 255, c.a.float32 / 255]
  inc scene.version

# ---- animations ------------------------------------------------------------------------------

proc animationNames*(scene: Scene3): seq[string] =
  ## The model's clips ("DoorOpen", "WheelsTurn"...).
  for a in scene.animations: result.add a.name

proc animationIndex(scene: Scene3; name: string): int =
  for i, a in scene.animations:
    if a.name == name: return i
  if name.len == 0 and scene.animations.len > 0: return 0
  -1

proc keyAt(times: seq[float32]; t: float32): (int, float32) =
  ## The key before `t` and how far toward the next it is.
  if times.len == 0: return (0, 0'f32)
  if t <= times[0]: return (0, 0'f32)
  if t >= times[^1]: return (times.high, 0'f32)
  var lo = 0
  var hi = times.high
  while hi - lo > 1:
    let m = (lo + hi) div 2
    if times[m] <= t: lo = m else: hi = m
  let span = times[hi] - times[lo]
  (lo, if span > 0: (t - times[lo]) / span else: 0'f32)

proc applyChannel(scene: var Scene3; c: AnimChannel3; t: float32) =
  if c.node < 0 or c.node >= scene.nodes.len or c.times.len == 0: return
  let n = c.times.len
  let width = case c.path
              of apTranslation, apScale: 3
              of apRotation: 4
              of apWeights: (if c.interp == aiCubic: c.values.len div (3 * n) else: c.values.len div n)
  if width <= 0: return
  let stride = if c.interp == aiCubic: 3 * width else: width
  if c.values.len < n * stride: return
  let (k, f) = keyAt(c.times, t)
  var o = newSeq[float32](width)
  proc v(key, i: int): float32 =
    # (cubic: in-tangent, value, out-tangent)
    if c.interp == aiCubic: c.values[key * stride + width + i] else: c.values[key * stride + i]
  let k1 = min(k + 1, n - 1)
  case c.interp
  of aiStep:
    for i in 0 ..< width: o[i] = v(k, i)
  of aiLinear:
    if c.path == apRotation:
      let q = slerp(Quat(x: v(k, 0), y: v(k, 1), z: v(k, 2), w: v(k, 3)),
                    Quat(x: v(k1, 0), y: v(k1, 1), z: v(k1, 2), w: v(k1, 3)), f)
      o = @[q.x, q.y, q.z, q.w]
    else:
      for i in 0 ..< width: o[i] = v(k, i) + (v(k1, i) - v(k, i)) * f
  of aiCubic:
    let dt = if k1 > k: c.times[k1] - c.times[k] else: 0'f32
    let t2 = f * f
    let t3 = t2 * f
    for i in 0 ..< width:
      let p0 = v(k, i)
      let m0 = c.values[k * stride + 2 * width + i] * dt       # (its out-tangent)
      let p1 = v(k1, i)
      let m1 = c.values[k1 * stride + i] * dt                  # (the next one's in-tangent)
      o[i] = (2 * t3 - 3 * t2 + 1) * p0 + (t3 - 2 * t2 + f) * m0 + (-2 * t3 + 3 * t2) * p1 + (t3 - t2) * m1
  case c.path
  of apTranslation: scene.nodes[c.node].t = Vec3(x: o[0], y: o[1], z: o[2])
  of apScale: scene.nodes[c.node].s = Vec3(x: o[0], y: o[1], z: o[2])
  of apRotation: scene.nodes[c.node].r = normalized(Quat(x: o[0], y: o[1], z: o[2], w: o[3]))
  of apWeights: scene.nodes[c.node].morphWeights = o

proc seekAnimation*(scene: var Scene3; name: string; seconds: float) =
  ## The model as clip `name` has it at `seconds` (a slider scrubbing it).
  let a = scene.animationIndex(name)
  if a < 0: return
  for c in scene.animations[a].channels: scene.applyChannel(c, seconds.float32)
  inc scene.version

proc play*(scene: var Scene3; name = ""; loop = true; speed = 1.0) =
  ## Plays clip `name` ("" the first) from its start, over and over with
  ## `loop`; `animate` moves it on each frame.
  let a = scene.animationIndex(name)
  if a < 0: return
  for p in scene.playing.mitems:
    if p.anim == a:
      p = Playing3(anim: a, time: if speed < 0: scene.animations[a].duration else: 0, speed: speed.float32, loop: loop)
      return
  scene.playing.add Playing3(anim: a, time: if speed < 0: scene.animations[a].duration else: 0,
                             speed: speed.float32, loop: loop)

proc stop*(scene: var Scene3; name = "") =
  ## Stops clip `name` (every clip: "") where it is.
  let a = if name.len == 0: -1 else: scene.animationIndex(name)
  var keep: seq[Playing3]
  for p in scene.playing:
    if a >= 0 and p.anim != a: keep.add p
  scene.playing = keep

proc isPlaying*(scene: Scene3; name = ""): bool =
  ## Clip `name` (any: "") is playing.
  let a = if name.len == 0: -1 else: scene.animationIndex(name)
  for p in scene.playing:
    if a < 0 or p.anim == a: return true

proc animate*(scene: var Scene3; seconds: float): bool {.discardable.} =
  ## Moves the clips playing on by `seconds` (the time since the last
  ## frame); true while one plays (keep the frames coming: `wakeIn`).
  var keep: seq[Playing3]
  for p in scene.playing.mitems:
    if p.anim < 0 or p.anim >= scene.animations.len: continue
    let a = scene.animations[p.anim]
    p.time += seconds.float32 * p.speed
    var ended = false
    if a.duration > 0:
      if p.loop:
        p.time = p.time mod a.duration
        if p.time < 0: p.time += a.duration
      elif p.time >= a.duration or p.time <= 0:
        p.time = clamp(p.time, 0, a.duration)
        ended = true
    for c in a.channels: scene.applyChannel(c, p.time)
    if not ended: keep.add p
  result = keep.len > 0
  if scene.playing.len > 0: inc scene.version
  scene.playing = keep

# ---- the posed meshes: where each point is now -------------------------------------------

proc poseMesh(scene: Scene3; worlds: seq[Mat4]; mi: int; verts, normals: var seq[Vec3]): bool =
  ## Mesh `mi`'s points (and normals, when it has them: true) where they
  ## are in the scene now: its shapes mixed, its bones followed, its node's
  ## placing (or its own `pos`, `rot`, `scale`).
  let m = scene.meshes[mi]
  let n = m.verts.len
  verts.setLen(n)
  let hasN = m.normals.len == n
  normals.setLen(if hasN: n else: 0)
  for k in 0 ..< n: verts[k] = m.verts[k]
  if hasN:
    for k in 0 ..< n: normals[k] = m.normals[k]
  # shapes (morph targets)
  var ws = m.morphWeights
  if m.node >= 0 and m.node < scene.nodes.len and scene.nodes[m.node].morphWeights.len > 0:
    ws = scene.nodes[m.node].morphWeights
  for ti in 0 ..< min(ws.len, m.targets.len):
    let w = ws[ti]
    if w == 0 or m.targets[ti].len != n: continue
    for k in 0 ..< n: verts[k] = verts[k] + m.targets[ti][k] * w
    if hasN and ti < m.targetNormals.len and m.targetNormals[ti].len == n:
      for k in 0 ..< n: normals[k] = normals[k] + m.targetNormals[ti][k] * w
  # bones
  if m.skin >= 0 and m.skin < scene.skins.len and m.joints.len == n and m.weights.len == n:
    let sk = scene.skins[m.skin]
    var mats = newSeq[Mat4](sk.joints.len)
    for j, nd in sk.joints:
      let wm = if nd >= 0 and nd < worlds.len: worlds[nd] else: Identity4
      mats[j] = if j < sk.inverseBind.len: wm * sk.inverseBind[j] else: wm
    for k in 0 ..< n:
      var p = Vec3()
      var q = Vec3()
      var total = 0'f32
      for c in 0 .. 3:
        let w = m.weights[k][c]
        let j = int(m.joints[k][c])
        if w == 0 or j >= mats.len: continue
        p = p + point(mats[j], verts[k]) * w
        if hasN: q = q + direction(mats[j], normals[k]) * w
        total += w
      if total > 0:
        verts[k] = p * (1 / total)
        if hasN: normals[k] = unit(q)
    return hasN
  # its place
  if m.node >= 0 and m.node < worlds.len:
    let wm = worlds[m.node]
    for k in 0 ..< n: verts[k] = point(wm, verts[k])
    if hasN:
      for k in 0 ..< n: normals[k] = unit(direction(wm, normals[k]))
  else:
    let rot = rotation(m.rot)
    for k in 0 ..< n:
      verts[k] = apply(rot, Vec3(x: verts[k].x * m.scale.x, y: verts[k].y * m.scale.y, z: verts[k].z * m.scale.z)) + m.pos
    if hasN:
      for k in 0 ..< n:
        normals[k] = unit(apply(rot, Vec3(x: normals[k].x / max(1e-6'f32, abs(m.scale.x)),
                                          y: normals[k].y / max(1e-6'f32, abs(m.scale.y)),
                                          z: normals[k].z / max(1e-6'f32, abs(m.scale.z)))))
  hasN

proc meshShown(scene: Scene3; m: Mesh3): bool =
  m.visible and (m.node < 0 or m.node >= scene.nodes.len or scene.nodeShown(m.node))

proc centerMesh*(m: var Mesh3; size = 0.0) =
  ## Moves the mesh's points so its middle is at the origin; with `size`,
  ## also scales them so its largest side is `size` long.
  if m.verts.len == 0: return
  var lo = m.verts[0]
  var hi = m.verts[0]
  for v in m.verts:
    lo = Vec3(x: min(lo.x, v.x), y: min(lo.y, v.y), z: min(lo.z, v.z))
    hi = Vec3(x: max(hi.x, v.x), y: max(hi.y, v.y), z: max(hi.z, v.z))
  let c = (lo + hi) * 0.5'f32
  let ext = max(hi.x - lo.x, max(hi.y - lo.y, hi.z - lo.z))
  let k = if size > 0 and ext > 0: size.float32 / ext else: 1'f32
  for v in m.verts.mitems: v = (v - c) * k

# ---- loading models -------------------------------------------------------------------------------

proc fail(msg: string) {.noreturn.} = raise newException(ValueError, msg)

proc skipSpace(s: string; i: var int; lineEnd: int) {.inline.} =
  while i < lineEnd and s[i] in {' ', '\t'}: inc i

proc readFloat(s: string; i: var int; lineEnd: int): float32 =
  skipSpace(s, i, lineEnd)
  var f: float
  if i > lineEnd: fail("a number was expected")
  let n = parseFloat(s.toOpenArray(i, lineEnd - 1), f)
  if n == 0: fail("a number was expected")
  i += n
  if not finite(f.float32) or abs(f) > 1e30: fail("a number that is not finite")
  f.float32

proc loadObj*(data: string; name = "model"): Mesh3 =
  ## A mesh from the text of a Wavefront OBJ file: its `v` points, `vn`
  ## normals and `f` faces (polygons are cut into triangles; negative
  ## indices count back; a point with different normals in different faces
  ## becomes one point per normal, so hard edges stay hard). Other lines
  ## (materials, groups, textures) are skipped. Raises `ValueError` for what
  ## is not a sound OBJ (or is too big: `MaxTriangles`, `MaxPoints`).
  if data.len > MaxModelBytes: fail("the model is too big")
  result = newMesh(name, color(160, 160, 176))
  var points, normals: seq[Vec3]
  var cornerV, cornerN: seq[int32]     # three corners to a triangle
  var allNormals = true
  var i = 0
  var face: seq[tuple[v, n: int32]]
  while i < data.len:
    var e = i
    while e < data.len and data[e] notin {'\n', '\r'}: inc e
    var p = i
    skipSpace(data, p, e)
    if p + 1 < e and data[p] == 'v' and data[p + 1] in {' ', '\t'}:
      p += 2
      let x = readFloat(data, p, e)
      let y = readFloat(data, p, e)
      let z = readFloat(data, p, e)
      if points.len >= MaxPoints: fail("too many points")
      points.add Vec3(x: x, y: y, z: z)
    elif p + 2 < e and data[p] == 'v' and data[p + 1] == 'n' and data[p + 2] in {' ', '\t'}:
      p += 3
      let x = readFloat(data, p, e)
      let y = readFloat(data, p, e)
      let z = readFloat(data, p, e)
      if normals.len >= MaxPoints: fail("too many normals")
      normals.add unit(Vec3(x: x, y: y, z: z))
    elif p + 1 < e and data[p] == 'f' and data[p + 1] in {' ', '\t'}:
      p += 2
      face.setLen(0)
      while true:
        skipSpace(data, p, e)
        if p >= e: break
        var idx: int
        let n = parseInt(data.toOpenArray(p, e - 1), idx)
        if n == 0: fail("a face index was expected")
        p += n
        let np = points.len
        let vi = if idx < 0: np + idx else: idx - 1
        if vi < 0 or vi >= np: fail("a face points to a point that is not there")
        # texture and normal indices: a/b, a/b/c, a//c
        var ni = -1
        if p < e and data[p] == '/':
          inc p
          if p < e and data[p] != '/':
            var t: int
            p += parseInt(data.toOpenArray(p, e - 1), t)
          if p < e and data[p] == '/':
            inc p
            var t: int
            let m = parseInt(data.toOpenArray(p, e - 1), t)
            if m == 0: fail("a normal index was expected")
            p += m
            ni = if t < 0: normals.len + t else: t - 1
            if ni < 0 or ni >= normals.len: fail("a face points to a normal that is not there")
        if ni < 0: allNormals = false
        if face.len >= 4096: fail("a face with too many corners")
        face.add (int32(vi), int32(ni))
        if p < e and data[p] notin {' ', '\t'}: fail("a face is not well formed")
      if face.len < 3: fail("a face with fewer than three corners")
      for k in 1 ..< face.len - 1:
        if cornerV.len >= MaxTriangles * 3: fail("too many triangles")
        for c in [face[0], face[k], face[k + 1]]:
          cornerV.add c.v
          cornerN.add c.n
    i = e
    while i < data.len and data[i] in {'\n', '\r'}: inc i
  if cornerV.len == 0: fail("there are no faces")
  if allNormals and normals.len > 0:
    # one point for each point-and-normal pair used
    var seen = initTable[int64, int32]()
    for k in 0 ..< cornerV.len:
      let key = (cornerV[k].int64 shl 32) or cornerN[k].int64
      var at = seen.getOrDefault(key, -1)
      if at < 0:
        at = int32(result.verts.len)
        seen[key] = at
        result.verts.add points[cornerV[k]]
        result.normals.add normals[cornerN[k]]
      cornerV[k] = at
    result.smooth = true
  else:
    result.verts = move points
  for k in countup(0, cornerV.len - 3, 3):
    result.tris.add [cornerV[k], cornerV[k + 1], cornerV[k + 2]]

proc loadStl*(data: string; name = "model"): Mesh3 =
  ## A mesh from an STL file, binary or text. Raises `ValueError` for what
  ## is not one (or has more than `MaxTriangles`).
  if data.len > MaxModelBytes: fail("the model is too big")
  result = newMesh(name, color(160, 160, 176))
  template addPoint(v: Vec3) =
    result.verts.add v
  var binary = false
  if data.len >= 84:
    let n = uint32(data[80].uint8) or (uint32(data[81].uint8) shl 8) or
            (uint32(data[82].uint8) shl 16) or (uint32(data[83].uint8) shl 24)
    if n.uint64 * 50 + 84 == data.len.uint64: binary = true
  if binary:
    let n = (data.len - 84) div 50
    if n > MaxTriangles: fail("too many triangles")
    if n == 0: fail("there are no triangles")
    result.verts = newSeqOfCap[Vec3](n * 3)
    result.tris = newSeqOfCap[array[3, int32]](n)
    proc f32(s: string; at: int): float32 =
      var u = uint32(s[at].uint8) or (uint32(s[at + 1].uint8) shl 8) or
              (uint32(s[at + 2].uint8) shl 16) or (uint32(s[at + 3].uint8) shl 24)
      cast[float32](u)
    for t in 0 ..< n:
      let base = 84 + t * 50 + 12            # (after the facet's normal)
      for k in 0 .. 2:
        let v = Vec3(x: f32(data, base + k * 12), y: f32(data, base + k * 12 + 4),
                     z: f32(data, base + k * 12 + 8))
        if not finite(v): fail("a point that is not finite")
        addPoint(v)
      let a = int32(t * 3)
      result.tris.add [a, a + 1, a + 2]
    return
  # text: "vertex x y z", three to a facet
  var i = 0
  var inFacet = 0
  while i < data.len:
    var e = i
    while e < data.len and data[e] notin {'\n', '\r'}: inc e
    var p = i
    skipSpace(data, p, e)
    if e - p >= 6 and data[p ..< p + 6] == "vertex":
      p += 6
      let x = readFloat(data, p, e)
      let y = readFloat(data, p, e)
      let z = readFloat(data, p, e)
      if result.verts.len >= MaxTriangles * 3: fail("too many triangles")
      addPoint(Vec3(x: x, y: y, z: z))
      inc inFacet
      if inFacet == 3:
        let a = int32(result.verts.len - 3)
        result.tris.add [a, a + 1, a + 2]
        inFacet = 0
    elif e - p >= 8 and data[p ..< p + 8] == "endfacet":
      if inFacet != 0: fail("a facet without three points")
    i = e
    while i < data.len and data[i] in {'\n', '\r'}: inc i
  if result.tris.len == 0: fail("not an STL model")

proc loadModel*(path: string): Mesh3 =
  ## An OBJ or STL file (by its extension), centered at the origin and
  ## scaled to 2 units across. Raises `ValueError` or `IOError`.
  if getFileSize(path) > MaxModelBytes: fail("the model is too big")
  let data = readFile(path)
  let name = path.extractFilename
  result = if path.toLowerAscii.endsWith(".obj"): loadObj(data, name)
           else: loadStl(data, name)
  centerMesh(result, 2.0)

# ---- 3D bar charts -------------------------------------------------------------------------------

const barColors = [color(0, 0, 192), color(192, 0, 0), color(0, 128, 0),
                   color(208, 144, 0), color(128, 0, 128), color(0, 128, 128),
                   color(96, 96, 96), color(0, 96, 192)]

proc niceNumber(v: float): string =
  if abs(v - round(v)) < 1e-9: $int(round(v))
  else: formatFloat(v, ffDecimal, 2).strip(leading = false, chars = {'0'}).strip(
          leading = false, chars = {'.'})

proc bars3d*(values: openArray[seq[float]]; rowLabels: openArray[string] = [];
             colLabels: openArray[string] = []; colors: openArray[Color] = [];
             showValues = false): Scene3 =
  ## A 3D bar chart: `values[row][col]` stand as bars on a floor, a row of
  ## bars per series (front to back), one color per row (`colors`, else the
  ## kit's), labels along the sides and, with `showValues`, on the bars.
  ## Negative values go down. Pair it with `fitView`.
  var rows = values.len
  var cols = 0
  var hi = 0.0
  for r in values:
    cols = max(cols, r.len)
    for v in r:
      if v == v and abs(v) < 1e300: hi = max(hi, abs(v))
  rows = min(rows, 200)
  cols = min(cols, 200)
  let unitH = if hi > 0: max(2.0, (rows + cols).float * 0.4) / hi else: 1.0
  let x0 = -(cols - 1).float / 2
  let z0 = -(rows - 1).float / 2
  for r in 0 ..< rows:
    let c = if r < colors.len: colors[r] else: barColors[r mod barColors.len]
    for k in 0 ..< min(cols, values[r].len):
      let v = values[r][k]
      if v != v or abs(v) >= 1e300: continue
      let h = max(0.001, abs(v) * unitH)
      var m = box(0.7, h, 0.7, c,
                  name = (if r < rowLabels.len: rowLabels[r] & ", " else: "") &
                         (if k < colLabels.len: colLabels[k] & ": " else: "") & niceNumber(v))
      m.pos = vec3(x0 + k.float, (if v >= 0: h / 2 else: -h / 2), z0 + r.float)
      m.edges = true
      result.add m
      if showValues:
        result.addLabel(vec3(x0 + k.float, (if v >= 0: h + 0.25 else: -h - 0.25), z0 + r.float),
                        niceNumber(v))
  var floor = plane(max(1, cols).float + 0.6, max(1, rows).float + 0.6, color(224, 224, 224), "floor")
  floor.pos = vec3(0, -0.002, 0)
  result.add floor
  for r in 0 ..< rows:
    if r < rowLabels.len:
      result.addLabel(vec3(x0 - 0.6 - 0.12 * rowLabels[r].len.float, 0, z0 + r.float),
                      rowLabels[r], bold = true)
  for k in 0 ..< cols:
    if k < colLabels.len:
      result.addLabel(vec3(x0 + k.float, 0, z0 + rows.float - 0.1), colLabels[k])
  result.ambient = 0.45

# ---- the camera ------------------------------------------------------------------------------------

proc camera3*(yaw = 35.0; pitch = 25.0; distance = 6.0; target = vec3(0, 0, 0);
              fov = 40.0): Camera3 =
  ## A camera looking at `target` (see `Camera3`); `resetView` comes back
  ## to it.
  result = Camera3(yaw: yaw.float32, pitch: pitch.float32, distance: distance.float32,
                   target: target, fov: fov.float32)
  result.home = (true, target, yaw.float32, pitch.float32, distance.float32)

proc resetView*(cam: var Camera3) =
  ## Back to where `camera3` or `fitView` put it.
  if cam.home.set:
    cam.target = cam.home.target
    cam.yaw = cam.home.yaw
    cam.pitch = cam.home.pitch
    cam.distance = cam.home.distance

proc worldPoint(m: Mesh3; rot: array[9, float32]; v: Vec3): Vec3 {.inline.} =
  apply(rot, Vec3(x: v.x * m.scale.x, y: v.y * m.scale.y, z: v.z * m.scale.z)) + m.pos

proc bounds*(scene: Scene3): tuple[lo, hi: Vec3; empty: bool] =
  ## The box around the visible meshes and the lines.
  result.empty = true
  template take(p: Vec3) =
    if finite(p):
      if result.empty:
        result.lo = p
        result.hi = p
        result.empty = false
      else:
        result.lo = Vec3(x: min(result.lo.x, p.x), y: min(result.lo.y, p.y), z: min(result.lo.z, p.z))
        result.hi = Vec3(x: max(result.hi.x, p.x), y: max(result.hi.y, p.y), z: max(result.hi.z, p.z))
  let worlds = nodeWorlds(scene)
  var vs, ns: seq[Vec3]
  for mi, m in scene.meshes:
    if not scene.meshShown(m): continue
    discard poseMesh(scene, worlds, mi, vs, ns)
    for v in vs: take(v)
  for l in scene.lines:
    take(l.a)
    take(l.b)

proc fitView*(scene: Scene3; cam: var Camera3) =
  ## Aims the camera at the middle of the scene, far enough to see all of
  ## it; Home (and the home button) come back to this view.
  let b = bounds(scene)
  if b.empty: return
  let c = (b.lo + b.hi) * 0.5'f32
  let radius = max(0.001'f32, len(b.hi - b.lo) * 0.5'f32)
  let half = max(5.0, cam.fov.float) * PI / 360
  cam.target = c
  cam.distance = float32(radius / sin(half) * 1.05)
  cam.home = (true, cam.target, cam.yaw, cam.pitch, cam.distance)

type Basis = object
  eye, right, up, fwd: Vec3

proc basis(cam: Camera3): Basis =
  let yaw = cam.yaw.float * PI / 180
  let pitch = clamp(cam.pitch.float, -89.9, 89.9) * PI / 180
  let dir = vec3(cos(pitch) * sin(yaw), sin(pitch), cos(pitch) * cos(yaw))
  result.eye = cam.target + dir * max(1e-4'f32, cam.distance)
  result.fwd = unit(cam.target - result.eye)
  result.right = unit(cross(result.fwd, Vec3(y: 1)))
  result.up = cross(result.right, result.fwd)

proc toView(b: Basis; p: Vec3): Vec3 {.inline.} =
  let d = p - b.eye
  Vec3(x: dot(d, b.right), y: dot(d, b.up), z: dot(d, b.fwd))

# ---- drawing ---------------------------------------------------------------------------------------

type
  SVert = object
    x, y, iz, shade: float32     # screen position, 1/depth, light (0..1)
  RenderCtx = object
    w, h: int
    px: ptr UncheckedArray[uint32]
    z: seq[float32]              # 1/depth of what is drawn (0: nothing)
    focal, near: float32
    view: seq[seq[Vec3]]         # the points of each mesh, seen from the eye
    spheres: seq[tuple[c: Vec3; r: float32]]   # the meshes' bounds, likewise
    labels: seq[tuple[x, y: float32; ok: bool]]

const LightDir = Vec3(x: -0.36, y: 0.55, z: -0.75)   # toward the light, eye space

proc pack(c: Color; k: float32): uint32 {.inline.} =
  let k = clamp(k, 0, 1.2)
  let r = min(255, int(c.r.float32 * k))
  let g = min(255, int(c.g.float32 * k))
  let b = min(255, int(c.b.float32 * k))
  0xFF000000'u32 or (r.uint32 shl 16) or (g.uint32 shl 8) or b.uint32

{.push boundChecks: off, overflowChecks: off, rangeChecks: off.}

proc project(ctx: RenderCtx; v: Vec3; shade: float32): SVert {.inline.} =
  let iz = 1'f32 / v.z
  SVert(x: ctx.w.float32 * 0.5'f32 + v.x * ctx.focal * iz,
        y: ctx.h.float32 * 0.5'f32 - v.y * ctx.focal * iz, iz: iz, shade: shade)

proc fillTri(ctx: var RenderCtx; a0, b0, c0: SVert; col: Color; smooth: bool) =
  var a = a0
  var b = b0
  var c = c0
  var area = (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
  if not (abs(area) > 1e-6'f32) or not (abs(area) < 1e14'f32): return
  if area < 0:
    swap(b, c)
    area = -area
  let fw = ctx.w.float32
  let fh = ctx.h.float32
  let minX = clamp(min(a.x, min(b.x, c.x)), 0, fw)
  let maxX = clamp(max(a.x, max(b.x, c.x)), 0, fw)
  let minY = clamp(min(a.y, min(b.y, c.y)), 0, fh)
  let maxY = clamp(max(a.y, max(b.y, c.y)), 0, fh)
  let x0 = int(minX)
  let x1 = min(ctx.w - 1, int(maxX))
  let y0 = int(minY)
  let y1 = min(ctx.h - 1, int(maxY))
  if x0 > x1 or y0 > y1: return
  let inv = 1'f32 / area
  # edge functions, stepped along x and y
  let e0dx = (b.y - c.y)
  let e1dx = (c.y - a.y)
  let e2dx = (a.y - b.y)
  let e0dy = (c.x - b.x)
  let e1dy = (a.x - c.x)
  let e2dy = (b.x - a.x)
  let px0 = x0.float32 + 0.5'f32
  var py = y0.float32 + 0.5'f32
  let flat = pack(col, a.shade)
  let zp = cast[ptr UncheckedArray[float32]](unsafeAddr ctx.z[0])
  for y in y0 .. y1:
    var w0 = (px0 - b.x) * e0dx + (py - b.y) * e0dy
    var w1 = (px0 - c.x) * e1dx + (py - c.y) * e1dy
    var w2 = (px0 - a.x) * e2dx + (py - a.y) * e2dy
    let row = y * ctx.w
    for x in x0 .. x1:
      if w0 >= 0 and w1 >= 0 and w2 >= 0:
        let l0 = w0 * inv
        let l1 = w1 * inv
        let l2 = 1'f32 - l0 - l1
        let iz = l0 * a.iz + l1 * b.iz + l2 * c.iz
        let i = row + x
        if iz > zp[i]:
          zp[i] = iz
          ctx.px[i] = if smooth: pack(col, l0 * a.shade + l1 * b.shade + l2 * c.shade)
                      else: flat
      w0 += e0dx
      w1 += e1dx
      w2 += e2dx
    py += 1

proc drawLine(ctx: var RenderCtx; a, b: SVert; c: uint32; bias: float32) =
  ## A line with the depth test (`bias`: how far in front it may win).
  if not (finite(a.x) and finite(a.y) and finite(b.x) and finite(b.y)): return
  let dx = b.x - a.x
  let dy = b.y - a.y
  let n = int(min(1e5'f32, max(abs(dx), abs(dy)))) + 1
  let zp = cast[ptr UncheckedArray[float32]](unsafeAddr ctx.z[0])
  for k in 0 .. n:
    let t = k.float32 / n.float32
    let x = a.x + dx * t
    let y = a.y + dy * t
    if x < 0 or y < 0 or x >= ctx.w.float32 or y >= ctx.h.float32: continue
    let i = int(y) * ctx.w + int(x)
    let iz = a.iz + (b.iz - a.iz) * t
    if iz * (1'f32 + bias) >= zp[i]:
      ctx.px[i] = c
      zp[i] = max(zp[i], iz)

{.pop.}

proc clipNear(ctx: RenderCtx; vs: openArray[tuple[p: Vec3; s: float32]];
              outv: var seq[SVert]) =
  ## The polygon `vs` cut at the near plane, projected.
  outv.setLen(0)
  for k in 0 ..< vs.len:
    let (p, s) = vs[k]
    let (q, t) = vs[(k + 1) mod vs.len]
    let pin = p.z >= ctx.near
    let qin = q.z >= ctx.near
    if pin: outv.add project(ctx, p, s)
    if pin != qin:
      let f = (ctx.near - p.z) / (q.z - p.z)
      outv.add project(ctx, p + (q - p) * f, s + (t - s) * f)

proc shadeOf(n: Vec3; ambient: float32; twoSided: bool): float32 {.inline.} =
  var d = dot(unit(n), LightDir)
  if twoSided: d = abs(d)
  ambient + (1 - ambient) * max(0'f32, d)

# ---- materials: pictures, light on metal and paint, see-through ----------------------------

type
  LitVert = object
    x, y, iz: float32              # on the screen, 1/depth
    px, py, pz: float32            # in eye space
    nx, ny, nz: float32            # its normal, eye space
    u, v: float32
    r, g, b, a: float32            # its color
  LitTri = object
    v: array[3, LitVert]
    mat: int32                     # in the scene's materials (-1: the mesh's color)
    col: array[4, float32]         # (the mesh's color, or its node's tint)
    tinted: bool
    flip: bool                     # (seen from its back: the normal turned)
    y0, y1: int32
    depth: float32                 # (see-through ones: drawn farthest first)

proc srgbToLinear(c: float32): float32 {.inline.} = c * c
proc linearToSrgb(c: float32): float32 {.inline.} = sqrt(max(0'f32, c))

{.push boundChecks: off, overflowChecks: off, rangeChecks: off.}

proc sample(b: Bitmap; u, v: float32): array[4, float32] {.inline.} =
  ## The picture at `u`, `v` (repeated past 0..1), read between its pixels.
  if b == nil or b.w <= 0 or b.h <= 0 or b.px.len < b.w * b.h: return [1'f32, 1, 1, 1]
  let fu = (u - floor(u)) * b.w.float32 - 0.5'f32
  let fv = (v - floor(v)) * b.h.float32 - 0.5'f32
  let x0 = int(floor(fu))
  let y0 = int(floor(fv))
  let tx = fu - x0.float32
  let ty = fv - y0.float32
  let p = cast[ptr UncheckedArray[uint32]](unsafeAddr b.px[0])
  template at(x, y: int): uint32 =
    p[(((y mod b.h) + b.h) mod b.h) * b.w + (((x mod b.w) + b.w) mod b.w)]
  let c00 = at(x0, y0)
  let c10 = at(x0 + 1, y0)
  let c01 = at(x0, y0 + 1)
  let c11 = at(x0 + 1, y0 + 1)
  for k in 0 .. 3:
    let sh = case k
             of 0: 16
             of 1: 8
             of 2: 0
             else: 24
    let a = ((c00 shr sh) and 255).float32
    let b2 = ((c10 shr sh) and 255).float32
    let c = ((c01 shr sh) and 255).float32
    let d = ((c11 shr sh) and 255).float32
    result[k] = ((a + (b2 - a) * tx) * (1 - ty) + (c + (d - c) * tx) * ty) * (1'f32 / 255)

type LightSet = object
  key, fill: Vec3                  # toward the lights, eye space
  up: Vec3                         # the world's up, eye space
  exposure, ambient: float32

proc shadePixel(L: LightSet; mat: ptr Material3; base: array[4, float32];
                p, n: Vec3; u, v: float32): array[4, float32] {.inline.} =
  ## The color of a lit point: diffuse light, a highlight sized by how
  ## rough it is, the sky reflected (metal, paint), the light it gives.
  var rough = 0.5'f32
  var metal = 0'f32
  var emis = [0'f32, 0, 0]
  var unlit = false
  if mat != nil:
    rough = mat.roughness
    metal = mat.metallic
    unlit = mat.unlit
    if mat.mrTexture != nil:
      let t = sample(mat.mrTexture, u, v)
      rough *= t[1]
      metal *= t[2]
    emis = mat.emissive
    if mat.emissiveTexture != nil:
      let t = sample(mat.emissiveTexture, u, v)
      for k in 0 .. 2: emis[k] *= srgbToLinear(t[k])
  if unlit: return base
  rough = clamp(rough, 0.03, 1)
  metal = clamp(metal, 0, 1)
  let vdir = unit(p * -1'f32)
  let ndotv = max(0'f32, dot(n, vdir))
  let shin = pow(2'f32, 1 + 11 * (1 - rough))
  let specNorm = (shin + 8) * (1'f32 / 25.13)
  let fres = pow(1 - ndotv, 5)
  # the sky and the ground as seen in it (no picture of the world: a soft one)
  let rdir = n * (2 * dot(n, vdir)) - vdir
  let upness = clamp(dot(rdir, L.up), -1, 1)
  let sky = if upness > 0: 0.55'f32 + 0.45'f32 * upness else: 0.18'f32 + 0.37'f32 * (1 + upness)
  let hemi = 0.6'f32 + 0.4'f32 * dot(n, L.up)
  var o: array[4, float32]
  for k in 0 .. 2:
    let albedo = srgbToLinear(base[k])
    let f0 = 0.04'f32 + (albedo - 0.04'f32) * metal
    let f = f0 + (1 - f0) * fres
    var c = albedo * (1 - metal) * L.ambient * hemi
    # the key light: diffuse and its highlight; the fill: diffuse only
    let ndotl = dot(n, L.key)
    if ndotl > 0:
      let h = unit(L.key + vdir)
      let spec = specNorm * pow(max(0'f32, dot(n, h)), shin) * f
      c += ndotl * (albedo * (1 - metal) + spec)
    let ndotf = dot(n, L.fill)
    if ndotf > 0: c += 0.3'f32 * ndotf * albedo * (1 - metal * 0.7'f32)
    c += f * sky * (1 - rough) * (1 - rough) * (0.35'f32 + 0.65'f32 * metal)
    c += emis[k]
    o[k] = linearToSrgb(c * L.exposure)
  o[3] = base[3]
  o

proc fillLitBand(tris: ptr UncheckedArray[LitTri]; n: int; scene: ptr Scene3; L: LightSet;
                 px: ptr UncheckedArray[uint32]; zb: ptr UncheckedArray[float32]; w, h, yA, yB: int;
                 blend: bool) =
  ## The triangles' rows `yA` ..< `yB` (a band of the picture: bands are
  ## drawn on all the cores at once).
  for ti in 0 ..< n:
    let t = addr tris[ti]
    if t.y1 < yA or t.y0 >= yB: continue
    var a = t.v[0]
    var b = t.v[1]
    var c = t.v[2]
    var area = (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
    if not (abs(area) > 1e-8'f32) or not (abs(area) < 1e14'f32): continue
    if area < 0:
      swap(b, c)
      area = -area
    let minX = clamp(min(a.x, min(b.x, c.x)), 0, w.float32)
    let maxX = clamp(max(a.x, max(b.x, c.x)), 0, w.float32)
    let x0 = int(minX)
    let x1 = min(w - 1, int(maxX))
    let y0 = max(yA, int(clamp(min(a.y, min(b.y, c.y)), 0, h.float32)))
    let y1 = min(yB - 1, min(h - 1, int(clamp(max(a.y, max(b.y, c.y)), 0, h.float32))))
    if x0 > x1 or y0 > y1: continue
    let inv = 1'f32 / area
    let e0dx = b.y - c.y
    let e1dx = c.y - a.y
    let e2dx = a.y - b.y
    let e0dy = c.x - b.x
    let e1dy = a.x - c.x
    let e2dy = b.x - a.x
    let mat = if t.mat >= 0 and t.mat < scene.materials.len: addr scene.materials[t.mat] else: nil
    let mode = if mat != nil: mat.alphaMode else: amOpaque
    let cutoff = if mat != nil: mat.alphaCutoff else: 0.5'f32
    let px0 = x0.float32 + 0.5'f32
    var py = y0.float32 + 0.5'f32
    for y in y0 .. y1:
      var w0 = (px0 - b.x) * e0dx + (py - b.y) * e0dy
      var w1 = (px0 - c.x) * e1dx + (py - c.y) * e1dy
      var w2 = (px0 - a.x) * e2dx + (py - a.y) * e2dy
      let row = y * w
      for x in x0 .. x1:
        if w0 >= 0 and w1 >= 0 and w2 >= 0:
          let l0 = w0 * inv
          let l1 = w1 * inv
          let l2 = 1'f32 - l0 - l1
          let iz = l0 * a.iz + l1 * b.iz + l2 * c.iz
          let i = row + x
          if iz > zb[i]:
            # (perspective right: what is between the corners as it is in 3D)
            let k0 = l0 * a.iz / iz
            let k1 = l1 * b.iz / iz
            let k2 = l2 * c.iz / iz
            template lerp(f: untyped): float32 = k0 * a.f + k1 * b.f + k2 * c.f
            let u = lerp(u)
            let v = lerp(v)
            var base = if t.tinted: t.col else:
                         (if mat != nil: mat.baseColor else: t.col)
            if mat != nil and mat.texture != nil and not t.tinted:
              let tc = sample(mat.texture, u, v)
              for q in 0 .. 3: base[q] *= tc[q]
            base[0] *= lerp(r)
            base[1] *= lerp(g)
            base[2] *= lerp(b)
            base[3] *= lerp(a)
            if mode == amMask and base[3] < cutoff:
              discard
            elif blend and base[3] <= 0.004:
              discard
            else:
              var nrm = unit(Vec3(x: lerp(nx), y: lerp(ny), z: lerp(nz)))
              if t.flip: nrm = nrm * -1'f32
              let pos = Vec3(x: lerp(px), y: lerp(py), z: lerp(pz))
              let o = shadePixel(L, mat, base, pos, nrm, u, v)
              let r8 = uint32(clamp(o[0], 0, 1) * 255 + 0.5'f32)
              let g8 = uint32(clamp(o[1], 0, 1) * 255 + 0.5'f32)
              let b8 = uint32(clamp(o[2], 0, 1) * 255 + 0.5'f32)
              if blend and mode == amBlend:
                let al = clamp(o[3], 0, 1)
                let d = px[i]
                let ia = 1 - al
                let rr = uint32(r8.float32 * al + ((d shr 16) and 255).float32 * ia)
                let gg = uint32(g8.float32 * al + ((d shr 8) and 255).float32 * ia)
                let bb = uint32(b8.float32 * al + (d and 255).float32 * ia)
                px[i] = 0xFF000000'u32 or (min(rr, 255) shl 16) or (min(gg, 255) shl 8) or min(bb, 255)
              else:
                px[i] = 0xFF000000'u32 or (r8 shl 16) or (g8 shl 8) or b8
                zb[i] = iz
        w0 += e0dx
        w1 += e1dx
        w2 += e2dx
      py += 1

{.pop.}

proc drawLit(ctx: var RenderCtx; scene: Scene3; tris: var seq[LitTri]; L: LightSet; blend: bool) =
  ## The triangles drawn in bands on all the cores (see-through ones
  ## farthest first, in one band at a time: they mix with what is behind).
  if tris.len == 0: return
  if blend:
    tris.sort(proc (a, b: LitTri): int = cmp(b.depth, a.depth))
  let tp = cast[ptr UncheckedArray[LitTri]](addr tris[0])
  let n = tris.len
  let sp = unsafeAddr scene
  let pxp = ctx.px
  let zp = cast[ptr UncheckedArray[float32]](addr ctx.z[0])
  let w = ctx.w
  let h = ctx.h
  const band = 32
  let bands = (h + band - 1) div band
  # (big enough to share among the cores; a small picture in one go)
  if w * h >= 160_000 and n > 64:
    parallelFor(bands, proc (lo, hi: int) =
      for bi in lo ..< hi:
        fillLitBand(tp, n, sp, L, pxp, zp, w, h, bi * band, min(h, (bi + 1) * band), blend),
      keepAlive = false)
  else:
    fillLitBand(tp, n, sp, L, pxp, zp, w, h, 0, h, blend)

proc renderInto(ctx: var RenderCtx; scene: Scene3; cam: Camera3; bg: Color) =
  let w = ctx.w
  let h = ctx.h
  # the background: a soft gradient, or the scene's color
  let top = if bg.a != 0: bg else: mixColor(th.field, th.face, 0.15)
  let bottom = if bg.a != 0: bg else: mixColor(th.field, th.face, 0.85)
  for y in 0 ..< h:
    let c = pack(mixColor(top, bottom, y / max(1, h - 1)), 1)
    let row = y * w
    for x in 0 ..< w: ctx.px[row + x] = c
  for z in ctx.z.mitems: z = 0
  let b = basis(cam)
  ctx.focal = (h.float32 * 0.5'f32) / tan(clamp(cam.fov, 5, 170) * PI.float32 / 360)
  ctx.near = max(1e-4'f32, cam.distance * 0.002'f32)
  let ambient = if scene.ambient > 0: clamp(scene.ambient, 0, 1) else: 0.35'f32
  ctx.view.setLen(scene.meshes.len)
  ctx.spheres.setLen(scene.meshes.len)
  var poly: seq[tuple[p: Vec3; s: float32]]
  var clipped: seq[SVert]
  var shades: seq[float32]
  var smoothN: seq[Vec3]
  let worlds = nodeWorlds(scene)
  var posedV, posedN: seq[Vec3]
  var litTris, blendTris: seq[LitTri]
  proc eyeDir(b: Basis; d: Vec3): Vec3 {.inline.} = Vec3(x: dot(d, b.right), y: dot(d, b.up), z: dot(d, b.fwd))
  for mi, m in scene.meshes:
    ctx.view[mi].setLen(0)
    ctx.spheres[mi] = (Vec3(), -1'f32)
    if not scene.meshShown(m) or m.verts.len == 0: continue
    let hasN = poseMesh(scene, worlds, mi, posedV, posedN)
    # the points seen from the eye, and a sphere around them
    var vv = move ctx.view[mi]
    vv.setLen(m.verts.len)
    var lo, hi: Vec3
    for k in 0 ..< posedV.len:
      let p = toView(b, posedV[k])
      vv[k] = p
      if k == 0:
        lo = p
        hi = p
      else:
        lo = Vec3(x: min(lo.x, p.x), y: min(lo.y, p.y), z: min(lo.z, p.z))
        hi = Vec3(x: max(hi.x, p.x), y: max(hi.y, p.y), z: max(hi.z, p.z))
    ctx.spheres[mi] = ((lo + hi) * 0.5'f32, len(hi - lo) * 0.5'f32)
    let tint = if m.node >= 0 and m.node < scene.nodes.len: scene.nodes[m.node].tint else: Color()
    let lit = not scene.wireframe and (m.material >= 0 and m.material < scene.materials.len or
                                       m.uvs.len > 0 or m.vcolors.len > 0)
    if lit:
      # a material (pictures, metal, paint, glass): drawn after, lit per pixel
      let mat = if m.material >= 0 and m.material < scene.materials.len: addr scene.materials[m.material] else: nil
      let twoSided = m.twoSided or (mat != nil and mat.doubleSided)
      var en: seq[Vec3]
      if hasN:
        en.setLen(posedN.len)
        for k in 0 ..< posedN.len: en[k] = eyeDir(b, posedN[k])
      else:
        en.setLen(vv.len)
        for nn in en.mitems: nn = Vec3()
        for t in m.tris:
          if t[0] < 0 or t[1] < 0 or t[2] < 0 or t[0] >= vv.len or t[1] >= vv.len or t[2] >= vv.len: continue
          let fnrm = cross(vv[t[2]] - vv[t[0]], vv[t[1]] - vv[t[0]])
          for k in 0 .. 2: en[t[k]] = en[t[k]] + fnrm
        for nn in en.mitems: nn = unit(nn)
      let col = if tint.a != 0: [tint.r.float32 / 255, tint.g.float32 / 255, tint.b.float32 / 255,
                                 (if mat != nil: mat.baseColor[3] else: 1'f32)]
                else: [m.color.r.float32 / 255, m.color.g.float32 / 255, m.color.b.float32 / 255, 1'f32]
      let blendMode = mat != nil and mat.alphaMode == amBlend
      for t in m.tris:
        if t[0] < 0 or t[1] < 0 or t[2] < 0 or t[0] >= vv.len or t[1] >= vv.len or t[2] >= vv.len: continue
        let p0 = vv[t[0]]
        let p1 = vv[t[1]]
        let p2 = vv[t[2]]
        if not (finite(p0) and finite(p1) and finite(p2)): continue
        if p0.z < ctx.near or p1.z < ctx.near or p2.z < ctx.near:
          # (crossing the near plane: left out -- a model is seen from outside)
          continue
        let n = cross(p1 - p0, p2 - p0)
        let facing = dot(n, p0)
        var flip = false
        if facing <= 0:
          if not twoSided: continue
          flip = true
        var lt = LitTri(mat: int32(if mat != nil: m.material else: -1), col: col, tinted: tint.a != 0,
                        flip: flip)
        var ymin = Inf.float32
        var ymax = -Inf.float32
        let faceN = if not hasN and not m.smooth: unit(n * -1'f32) else: Vec3()
        for k in 0 .. 2:
          let vi = t[k]
          let p = vv[vi]
          let sv = project(ctx, p, 1)
          let nn = if not hasN and not m.smooth: faceN else: en[vi]
          var lv = LitVert(x: sv.x, y: sv.y, iz: sv.iz, px: p.x, py: p.y, pz: p.z,
                           nx: nn.x, ny: nn.y, nz: nn.z, r: 1, g: 1, b: 1, a: 1)
          if vi < m.uvs.len: (lv.u, lv.v) = (m.uvs[vi][0], m.uvs[vi][1])
          if vi < m.vcolors.len:
            (lv.r, lv.g, lv.b, lv.a) = (m.vcolors[vi][0], m.vcolors[vi][1], m.vcolors[vi][2], m.vcolors[vi][3])
          lt.v[k] = lv
          ymin = min(ymin, sv.y)
          ymax = max(ymax, sv.y)
        if not (finite(ymin) and finite(ymax)): continue
        lt.y0 = int32(clamp(ymin, -1, ctx.h.float32 + 1))
        lt.y1 = int32(clamp(ymax, -1, ctx.h.float32 + 1)) + 1
        lt.depth = (p0.z + p1.z + p2.z) / 3
        if blendMode: blendTris.add lt else: litTris.add lt
      ctx.view[mi] = move vv
      continue
    # smooth: the light at each point, from its normal
    let smooth = m.smooth and not scene.wireframe
    if smooth:
      let given = hasN
      if not given:
        smoothN.setLen(m.verts.len)
        for n in smoothN.mitems: n = Vec3()
        for t in m.tris:
          if t[0] < 0 or t[1] < 0 or t[2] < 0 or t[0] >= vv.len or t[1] >= vv.len or
             t[2] >= vv.len: continue
          # (eye space turns the other way round: this points out of the face)
          let fnrm = cross(vv[t[2]] - vv[t[0]], vv[t[1]] - vv[t[0]])
          for k in 0 .. 2: smoothN[t[k]] = smoothN[t[k]] + fnrm
      shades.setLen(m.verts.len)
      for k in 0 ..< m.verts.len:
        let n = if given: eyeDir(b, posedN[k]) else: smoothN[k]
        # (eye space normals point at the eye with z < 0)
        shades[k] = shadeOf(n, ambient, m.twoSided)
    let edgeColor = pack(mixColor(m.color, color(0, 0, 0), 0.6), 1)
    # outlines: only where the surface folds (not the diagonals of flat faces)
    var fold: Table[int64, tuple[n: Vec3; count: int]]
    let outline = m.edges and not scene.wireframe
    if outline:
      for t in m.tris:
        if t[0] < 0 or t[1] < 0 or t[2] < 0 or t[0] >= vv.len or t[1] >= vv.len or
           t[2] >= vv.len: continue
        let fn = unit(cross(vv[t[1]] - vv[t[0]], vv[t[2]] - vv[t[0]]))
        for k in 0 .. 2:
          let a = t[k]
          let b2 = t[(k + 1) mod 3]
          let key = (min(a, b2).int64 shl 32) or max(a, b2).int64
          let e = fold.getOrDefault(key, (Vec3(), 0))
          let keep = if e.count == 0: fn
                     elif dot(e.n, fn) > 0.999: e.n      # (flat across: no edge)
                     else: Vec3()
          fold[key] = (keep, e.count + 1)
    for ti, t in m.tris:
      if t[0] < 0 or t[1] < 0 or t[2] < 0 or t[0] >= vv.len or t[1] >= vv.len or
         t[2] >= vv.len: continue
      let p0 = vv[t[0]]
      let p1 = vv[t[1]]
      let p2 = vv[t[2]]
      if not (finite(p0) and finite(p1) and finite(p2)): continue
      if p0.z < ctx.near and p1.z < ctx.near and p2.z < ctx.near: continue
      # (eye space is left-handed: a face turned to the eye has dot(n, p0) > 0;
      # the normal lit is the one pointing at the eye)
      var n = cross(p1 - p0, p2 - p0)
      let facing = dot(n, p0)
      if facing > 0: n = n * -1'f32
      elif not m.twoSided and not scene.wireframe: continue
      let col = if tint.a != 0: tint elif m.colors.len == m.tris.len: m.colors[ti] else: m.color
      let s = shadeOf(n, ambient, false)
      poly.setLen(0)
      for k in 0 .. 2:
        let sk = if smooth: shades[t[k]] else: s
        poly.add ([p0, p1, p2][k], sk)
      clipNear(ctx, poly, clipped)
      if clipped.len < 3: continue
      if not scene.wireframe:
        for k in 1 ..< clipped.len - 1:
          fillTri(ctx, clipped[0], clipped[k], clipped[k + 1], col, smooth)
      if scene.wireframe:
        for k in 0 ..< clipped.len:
          drawLine(ctx, clipped[k], clipped[(k + 1) mod clipped.len], pack(m.color, 1), 0.004)
      elif outline and clipped.len == 3 and p0.z >= ctx.near and p1.z >= ctx.near and
           p2.z >= ctx.near:
        for k in 0 .. 2:
          let a = t[k]
          let b2 = t[(k + 1) mod 3]
          let e = fold.getOrDefault((min(a, b2).int64 shl 32) or max(a, b2).int64, (Vec3(), 0))
          if e.count < 2 or (e.n.x == 0 and e.n.y == 0 and e.n.z == 0):
            drawLine(ctx, clipped[k], clipped[(k + 1) mod 3], edgeColor, 0.004)
    ctx.view[mi] = move vv
  # the materials' triangles: the solid ones, then the see-through ones
  if litTris.len > 0 or blendTris.len > 0:
    let up = Vec3(x: b.right.y, y: b.up.y, z: b.fwd.y)
    let L = LightSet(key: unit(LightDir), fill: unit(Vec3(x: 0.55, y: -0.15, z: -0.6)), up: up,
                     exposure: if scene.exposure > 0: scene.exposure else: 1'f32,
                     ambient: 0.3'f32 + ambient * 0.6'f32)
    drawLit(ctx, scene, litTris, L, false)
    drawLit(ctx, scene, blendTris, L, true)
  # lines
  for l in scene.lines:
    var a = toView(b, l.a)
    var c = toView(b, l.b)
    if not (finite(a) and finite(c)): continue
    if a.z < ctx.near and c.z < ctx.near: continue
    if a.z < ctx.near: a = a + (c - a) * ((ctx.near - a.z) / (c.z - a.z))
    elif c.z < ctx.near: c = c + (a - c) * ((ctx.near - c.z) / (a.z - c.z))
    drawLine(ctx, project(ctx, a, 1), project(ctx, c, 1), pack(l.color, 1), 0.002)
  # where the labels go
  ctx.labels.setLen(scene.labels.len)
  for k, lb in scene.labels:
    let p = toView(b, lb.at)
    if finite(p) and p.z >= ctx.near:
      let s = project(ctx, p, 1)
      ctx.labels[k] = (s.x, s.y, finite(s.x) and finite(s.y))
    else: ctx.labels[k] = (0'f32, 0'f32, false)

proc render3d*(scene: Scene3; cam: Camera3; w, h: int; background = Color()): Bitmap =
  ## The scene seen by `cam`, `w` x `h` pixels (to save with `encodePng`),
  ## on `background` (else the scene's). Labels are not in it.
  let w = clamp(w, 1, 16384)
  let h = clamp(h, 1, 16384)
  result = newBitmap(w, h)
  var ctx = RenderCtx(w: w, h: h)
  ctx.px = cast[ptr UncheckedArray[uint32]](addr result.px[0])
  ctx.z = newSeq[float32](w * h)
  renderInto(ctx, scene, cam, if background.a != 0: background else: scene.background)
  result.changed()

# ---- picking ----------------------------------------------------------------------------------------

proc pickAt(ctx: RenderCtx; scene: Scene3; sx, sy: float32): tuple[mesh, tri: int] =
  ## The mesh and triangle seen at the screen point `sx`, `sy` (device
  ## pixels) of the last picture; -1 for none.
  result = (-1, -1)
  if ctx.focal <= 0: return
  let dir = unit(Vec3(x: (sx - ctx.w.float32 * 0.5'f32) / ctx.focal,
                      y: -(sy - ctx.h.float32 * 0.5'f32) / ctx.focal, z: 1))
  var best = Inf.float32
  for mi, m in scene.meshes:
    if mi >= ctx.view.len or not scene.meshShown(m): continue
    let vv = ctx.view[mi]
    if vv.len != m.verts.len or vv.len == 0: continue
    let (c, r) = ctx.spheres[mi]
    if r < 0: continue
    # the ray misses the sphere around the mesh: not this one
    let tc = dot(c, dir)
    let d2 = dot(c, c) - tc * tc
    if d2 > r * r * 1.0001'f32 + 1e-6'f32 or tc + r < ctx.near: continue
    for ti, t in m.tris:
      if t[0] < 0 or t[1] < 0 or t[2] < 0 or t[0] >= vv.len or t[1] >= vv.len or
         t[2] >= vv.len: continue
      let v0 = vv[t[0]]
      let e1 = vv[t[1]] - v0
      let e2 = vv[t[2]] - v0
      let pv = cross(dir, e2)
      let det = dot(e1, pv)
      if abs(det) < 1e-12'f32: continue
      let inv = 1'f32 / det
      let tv = Vec3() - v0
      let u = dot(tv, pv) * inv
      if u < 0 or u > 1: continue
      let qv = cross(tv, e1)
      let v = dot(dir, qv) * inv
      if v < 0 or u + v > 1: continue
      let dist = dot(e2, qv) * inv
      if dist >= ctx.near and dist < best:
        best = dist
        result = (mi, ti)

# ---- on the GPU -----------------------------------------------------------------------------------

when not defined(wasm):
  include view3dgl

var view3dGpu* = getEnv("RETRO_3D_GPU") != "0"
  ## Scenes with materials drawn on the GPU when frames are (`drawnWithGpu`);
  ## false (or RETRO_3D_GPU=0): always on the CPU.

proc hasMaterials(scene: Scene3): bool =
  for m in scene.meshes:
    if m.material >= 0 and m.material < scene.materials.len: return true

# ---- the widget ----------------------------------------------------------------------------------

type ViewCache = ref object
  bmp: Bitmap
  ctx: RenderCtx
  hash: uint64
  usedAt: int
  hoverAt: tuple[x, y: int; hash: uint64]
  hover: tuple[mesh, tri: int]
  press: tuple[x, y: int; yaw, pitch: float32; target: Vec3; pan, moved: bool; at: int]
  onGpu: bool                    # (the last picture was drawn by the GPU)

var
  caches: Table[Id, ViewCache]
  renderCount = 0

proc view3dOnGpu*(key = ""): bool =
  ## The 3D view `key`'s last picture was drawn by the GPU.
  let c = caches.getOrDefault(peekId("view3d:" & key), nil)
  c != nil and c.onGpu

proc view3dPicture*(key = ""): Bitmap =
  ## The last picture the 3D view `key` showed (device pixels), drawn by the
  ## CPU or by the GPU (read back from it): a screenshot of the model.
  ## Nil before it was shown. Call it in a frame (after the view).
  let id = peekId("view3d:" & key)
  let c = caches.getOrDefault(id, nil)
  if c == nil: return nil
  when not defined(wasm):
    if c.onGpu:
      let gv = glViews.getOrDefault(id, nil)
      if gv == nil or gv.fb == 0 or gv.epoch != gpuEpoch() or not gpuFiltersReady():
        return nil
      let gl = gpuGl()
      let old = gpuBeginOffscreen()
      gl.bindFramebuffer(GL_FRAMEBUFFER, gv.fb)
      var raw = newSeq[uint32](gv.w * gv.h)
      gl.pixelStorei(GL_PACK_ALIGNMENT, 4)
      gl.readPixels(0, 0, GLsizei(gv.w), GLsizei(gv.h), GL_RGBA, GL_UNSIGNED_BYTE, addr raw[0])
      gpuEndOffscreen(old)
      # (its bytes are blue, green, red, alpha: 0xAARRGGBB as they are; its
      # rows from the top, as drawn)
      result = newBitmap(gv.w, gv.h)
      for i in 0 ..< raw.len: result.px[i] = raw[i] or 0xFF000000'u32
      result.opaque = true
      result.changed()
      return
  if c.bmp == nil: result = nil; return
  result = newBitmap(c.bmp.w, c.bmp.h)
  result.px = c.bmp.px
  result.opaque = true
  result.changed()

proc renders*(): int = renderCount
  ## How many pictures the 3D views drew so far (each is drawn only when
  ## something changed).

proc mixH(h: var uint64; x: uint64) {.inline.} =
  h = (h xor x) * 0x9E3779B97F4A7C15'u64
  h = h xor (h shr 29)
proc mixF(h: var uint64; f: float32) {.inline.} = mixH(h, uint64(cast[uint32](f)))
proc mixV(h: var uint64; v: Vec3) {.inline.} =
  mixF(h, v.x)
  mixF(h, v.y)
  mixF(h, v.z)
proc mixC(h: var uint64; c: Color) {.inline.} =
  mixH(h, uint64(c.r) or (uint64(c.g) shl 8) or (uint64(c.b) shl 16) or (uint64(c.a) shl 24))

proc sceneHash(scene: Scene3; cam: Camera3; w, h: int): uint64 =
  ## What the picture depends on (cheap: not the points themselves, which
  ## `sceneChanged` stands for).
  result = 0x51ED270B'u64
  mixH(result, uint64(scene.version))
  mixH(result, uint64(w) or (uint64(h) shl 32))
  mixH(result, uint64(scene.meshes.len))
  for m in scene.meshes:
    mixH(result, uint64(m.verts.len) or (uint64(m.tris.len) shl 32))
    mixH(result, if m.verts.len > 0: cast[uint64](unsafeAddr m.verts[0]) else: 0)
    mixH(result, if m.tris.len > 0: cast[uint64](unsafeAddr m.tris[0]) else: 0)
    mixH(result, uint64(m.colors.len))
    mixV(result, m.pos)
    mixV(result, m.rot)
    mixV(result, m.scale)
    mixC(result, m.color)
    mixH(result, uint64(ord(m.visible)) or uint64(ord(m.smooth)) shl 1 or
         uint64(ord(m.twoSided)) shl 2 or uint64(ord(m.edges)) shl 3)
  for m in scene.meshes:
    mixH(result, uint64(m.material + 1) or (uint64(m.node + 1) shl 32))
  for n in scene.nodes:
    mixV(result, n.t)
    mixF(result, n.r.x)
    mixF(result, n.r.y)
    mixF(result, n.r.z)
    mixF(result, n.r.w)
    mixV(result, n.s)
    mixC(result, n.tint)
    mixH(result, uint64(ord(n.visible)))
    for w in n.morphWeights: mixF(result, w)
  for m in scene.materials:
    for k in 0 .. 3: mixF(result, m.baseColor[k])
    mixF(result, m.metallic)
    mixF(result, m.roughness)
  mixF(result, scene.exposure)
  mixH(result, uint64(scene.lines.len))
  mixH(result, if scene.lines.len > 0: cast[uint64](unsafeAddr scene.lines[0]) else: 0)
  mixH(result, uint64(scene.labels.len))
  for l in scene.labels: mixV(result, l.at)
  mixC(result, scene.background)
  mixF(result, scene.ambient)
  mixH(result, uint64(ord(scene.wireframe)))
  mixV(result, cam.target)
  mixF(result, cam.yaw)
  mixF(result, cam.pitch)
  mixF(result, cam.distance)
  mixF(result, cam.fov)
  mixC(result, th.field)
  mixC(result, th.face)

proc cornerButton(hit: Hit; r: Rect; glyph: string; tip: string) =
  buttonFace(r, hit.down, rounded = false, bevel = 1, hot = hovered(r))
  let o = if hit.down: 1 else: 0
  if isPixelIcon(glyph):
    let k = max(16, min(r.w, r.h) - dp(4)) div 16 * 16
    pixelIconAt(rect(r.x + (r.w - k) div 2 + o, r.y + (r.h - k) div 2 + o, k, k), glyph)
  else:
    let tw = textWidth(glyph, true)
    text(r.x + (r.w - tw) div 2 + o, r.y + (r.h - FontH) div 2 + o, glyph, th.text, true)
  ui.lastRect = r
  tooltip(tip)

proc view3d*(scene: var Scene3; cam: var Camera3; height = -1; w = 0; key = "";
             controls = true): View3DEvent {.discardable.} =
  ## The scene seen by `cam`, `height` pixels high (-1: the room left).
  ## Drag to turn it, Shift or Ctrl + drag (or a finger held a moment,
  ## then moved) to move it, the wheel to zoom; with the focus: arrows turn,
  ## + / - zoom, Home goes back to the first view. `controls`: zoom and home
  ## buttons in the corner (handy for fingers). A click reports the mesh
  ## under it (`picked`), the mouse resting over one `hovered`.
  result.picked = -1
  result.pickedTri = -1
  result.hovered = -1
  result.hoveredTri = -1
  let r = place(if w > 0: w else: 0, if height < 0: remainingH() else: max(dp(40), height),
                fill = w <= 0)
  let id = idOf("view3d:" & key)
  var c = caches.getOrDefault(id, nil)
  if c == nil:
    c = ViewCache()
    caches[id] = c
  c.usedAt = ui.now
  let inner = inset(r, 2)
  # the corner buttons (they take their presses before the view does)
  let bs = if fingers(): CtrlH else: dp(20)
  var btns: array[3, Rect]
  var bhits: array[3, Hit]
  if controls and inner.w > bs * 4 and inner.h > bs * 2:
    for k in 0 .. 2:
      btns[k] = rect(inner.x + inner.w - (3 - k) * (bs + dp(2)), inner.y + dp(3), bs, bs)
      bhits[k] = interact(id + uint32(k + 1), btns[k], focusable = false)
  var hit = interact(id, inner)
  let before = (cam.target, cam.yaw, cam.pitch, cam.distance)
  # the mouse, fingers, the keyboard
  if canInput():
    if hit.down and ui.pressed:
      ui.dragsActive = true          # (a finger turns the scene, not the page)
      c.press = (ui.mx, ui.my, cam.yaw, cam.pitch, cam.target,
                 ShiftPressed in ui.mods or CtrlPressed in ui.mods, false, ui.now)
    if ui.active == id and ui.mouseDown:
      let dx = ui.mx - c.press.x
      let dy = ui.my - c.press.y
      if not c.press.moved and abs(dx) + abs(dy) > dp(4):
        c.press.moved = true
        # a finger held still for a moment, then moved: it moves the scene
        if finger() and ui.now - c.press.at > 450: c.press.pan = true
      if not c.press.moved and finger() and not c.press.pan:
        wakeIn(max(1, 460 - (ui.now - c.press.at)))
      if c.press.moved:
        if c.press.pan:
          let k = 2 * cam.distance * tan(clamp(cam.fov, 5, 170) * PI.float32 / 360) /
                  max(1, inner.h).float32
          let bs = basis(Camera3(target: c.press.target, yaw: cam.yaw, pitch: cam.pitch,
                                 distance: cam.distance, fov: cam.fov))
          cam.target = c.press.target - bs.right * (dx.float32 * k) + bs.up * (dy.float32 * k)
        else:
          cam.yaw = c.press.yaw - dx.float32 * 0.5'f32
          cam.pitch = clamp(c.press.pitch + dy.float32 * 0.5'f32, -89, 89)
    if ui.wheel != 0 and not ui.wheelUsed and mouseIn(inner):
      cam.distance = cam.distance * pow(0.88'f32, ui.wheel.float32)
      ui.wheelUsed = true
    if hit.focused:
      case ui.key
      of KeyLeft: cam.yaw += 7.5; ui.keyUsed = true
      of KeyRight: cam.yaw -= 7.5; ui.keyUsed = true
      of KeyUp: cam.pitch = min(89, cam.pitch + 7.5); ui.keyUsed = true
      of KeyDown: cam.pitch = max(-89, cam.pitch - 7.5); ui.keyUsed = true
      of KeyPlus, KeyEqual: cam.distance *= 0.8; ui.keyUsed = true
      of KeyMinus: cam.distance *= 1.25; ui.keyUsed = true
      of KeyHome: resetView(cam); ui.keyUsed = true
      else:
        if ui.typed == "+": cam.distance *= 0.8
        elif ui.typed == "-": cam.distance *= 1.25
  if btns[0].w > 0:
    if bhits[0].clicked: cam.distance *= 0.8
    if bhits[1].clicked: cam.distance *= 1.25
    if bhits[2].clicked: resetView(cam)
  if not (cam.distance == cam.distance): cam.distance = 1
  cam.distance = clamp(cam.distance, 1e-3, 1e7)
  if cam.yaw > 360 or cam.yaw < -360: cam.yaw = cam.yaw mod 360'f32
  # the picture: drawn again only when something changed
  let dw = max(1, inner.w * pxScale)
  let dh = max(1, inner.h * pxScale)
  let hsh = sceneHash(scene, cam, dw, dh)
  var gpuNow = false
  when not defined(wasm):
    if view3dGpu and not scene.wireframe and scene.hasMaterials() and glReady3D():
      var gv = glViews.getOrDefault(id, nil)
      if gv == nil:
        gv = GlView(key: 0x3D3D000000000000'u64 or uint64(id))
        glViews[id] = gv
      if gv.failed and getEnv("RETRO_3D_DEBUG").len > 0: echo "view3d: the GPU could not draw it"
      if not gv.failed:
        if not c.onGpu or c.hash != hsh or gv.w != dw or gv.h != dh or gv.epoch != gpuEpoch():
          c.ctx.w = dw
          c.ctx.h = dh
          if gv.renderGpu(c.ctx, scene, cam, scene.background):
            c.hash = hsh
            inc renderCount
            gpuNow = true
        else:
          gpuShowTexture(gv.key, gv.color, gv.w, gv.h)
          gpuNow = true
  if not gpuNow and (c.onGpu or c.bmp == nil or c.bmp.w != dw or c.bmp.h != dh or c.hash != hsh):
    if c.bmp == nil or c.bmp.w != dw or c.bmp.h != dh:
      c.bmp = newBitmap(dw, dh)
      c.ctx.z = newSeq[float32](dw * dh)
    c.ctx.w = dw
    c.ctx.h = dh
    c.ctx.px = cast[ptr UncheckedArray[uint32]](addr c.bmp.px[0])
    renderInto(c.ctx, scene, cam, scene.background)
    c.bmp.changed()
    c.hash = hsh
    inc renderCount
  c.onGpu = gpuNow
  # draw
  fill(r, th.face)
  sunken(r)
  box(inset(r, 1), th.edge)
  if gpuNow:
    when not defined(wasm):
      drawGpuImage(glViews[id].key, rect(inner.x * pxScale, inner.y * pxScale, dw, dh), int(hsh and 0x7FFFFFFF))
  else:
    drawBitmap(inner, c.bmp)
  pushClip(inner)
  for k, lb in scene.labels:
    if k < c.ctx.labels.len and c.ctx.labels[k].ok:
      let x = int(c.ctx.labels[k].x / pxScale.float32)
      let y = int(c.ctx.labels[k].y / pxScale.float32)
      let tw = textWidth(lb.text, lb.bold)
      let tx = inner.x + x - tw div 2
      let ty = inner.y + y - FontH div 2
      # a halo in the background's color keeps it legible over the bars
      for (ox, oy) in [(-1, 0), (1, 0), (0, -1), (0, 1)]:
        text(tx + ox, ty + oy, lb.text, th.field, lb.bold)
      text(tx, ty, lb.text, if lb.color.a != 0: lb.color else: th.text, lb.bold)
  popClip()
  if btns[0].w > 0:
    cornerButton(bhits[0], btns[0], "+", "Closer (+)")
    cornerButton(bhits[1], btns[1], "-", "Farther (-)")
    cornerButton(bhits[2], btns[2], retroOr(pxHome, nfHome), "The first view (Home)")
  if hit.focused: focusDots(inset(r, 3))
  # picking: a click that did not turn the scene; the mesh under the mouse
  let mx = (ui.mx - inner.x) * pxScale + pxScale div 2
  let my = (ui.my - inner.y) * pxScale + pxScale div 2
  if hit.clicked and not c.press.moved and canInput():
    let p = pickAt(c.ctx, scene, mx.float32, my.float32)
    result.clicked = true
    result.picked = p.mesh
    result.pickedTri = p.tri
    if ui.clicks >= 2 and p.mesh >= 0:
      result.activated = true
      markDouble(id)
  if canHover() and not ui.mouseDown and hover(inner):
    if c.hoverAt != (ui.mx, ui.my, c.hash):
      c.hoverAt = (ui.mx, ui.my, c.hash)
      c.hover = pickAt(c.ctx, scene, mx.float32, my.float32)
    result.hovered = c.hover.mesh
    result.hoveredTri = c.hover.tri
    if c.hover.mesh >= 0 and c.hover.mesh < scene.meshes.len and not ui.mouseDown:
      tooltip(scene.meshes[c.hover.mesh].name)
  result.cameraChanged = before != (cam.target, cam.yaw, cam.pitch, cam.distance)
  if result.cameraChanged: ui.redraw = true
  result.node = -1
  let shown = if result.picked >= 0: result.picked else: result.hovered
  if shown >= 0 and shown < scene.meshes.len:
    let nd = scene.meshes[shown].node
    if nd >= 0 and nd < scene.nodes.len:
      result.node = nd
      result.nodeName = scene.nodes[nd].name
  if scene.isPlaying(): wakeIn(15)
  # pictures of views not shown for a while are let go
  if caches.len > 1:
    var gone: seq[Id]
    for k, v in caches:
      if ui.now - v.usedAt > 30_000: gone.add k
    for k in gone: caches.del k
  if accessOn:
    accessNode(arImage, "3D view", id = id, r = r)
  ui.lastId = id
  ui.lastRect = r
