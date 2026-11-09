## Free fonts from Google Fonts, fetched into an app's own folder: a list
## of well-liked families to pick from (Arabic ones too), or any family by
## its name. Each style there is (regular, bold, their italics) is saved as
## a TrueType file; `addFontDir` (textengine) then offers them.
##
## .. code-block:: nim
##   let r = installGoogleFont("Cairo", dataDir("MyApp") / "Fonts")
##   if r.error.len == 0: scanFonts(force = true)

import std/[os, strutils, json]
import fetch, ttf

type GoogleFont* = tuple[family, category: string; arabic: bool]
  ## A family of `googleFontList`: its name, its kind ("Arabic", "Sans
  ## Serif", "Serif", "Display", "Handwriting", "Monospace") and whether it
  ## has Arabic letters.

const googleFontList*: seq[GoogleFont] = @[
  # Arabic (and Latin)
  ("Cairo", "Arabic", true), ("Tajawal", "Arabic", true), ("Almarai", "Arabic", true),
  ("Amiri", "Arabic", true), ("Noto Naskh Arabic", "Arabic", true), ("Noto Kufi Arabic", "Arabic", true),
  ("Noto Sans Arabic", "Arabic", true), ("IBM Plex Sans Arabic", "Arabic", true), ("Readex Pro", "Arabic", true),
  ("El Messiri", "Arabic", true), ("Changa", "Arabic", true), ("Lalezar", "Arabic", true),
  ("Reem Kufi", "Arabic", true), ("Harmattan", "Arabic", true), ("Mada", "Arabic", true),
  ("Lateef", "Arabic", true), ("Scheherazade New", "Arabic", true), ("Markazi Text", "Arabic", true),
  ("Aref Ruqaa", "Arabic", true), ("Rakkas", "Arabic", true), ("Mirza", "Arabic", true),
  ("Katibeh", "Arabic", true), ("Jomhuria", "Arabic", true), ("Lemonada", "Arabic", true),
  ("Baloo Bhaijaan 2", "Arabic", true), ("Vibes", "Arabic", true), ("Marhey", "Arabic", true),
  ("Alexandria", "Arabic", true), ("Rubik", "Sans Serif", false), ("Zain", "Arabic", true),
  # sans serif
  ("Roboto", "Sans Serif", false), ("Open Sans", "Sans Serif", false), ("Montserrat", "Sans Serif", false),
  ("Lato", "Sans Serif", false), ("Poppins", "Sans Serif", false), ("Inter", "Sans Serif", false),
  ("Raleway", "Sans Serif", false), ("Nunito", "Sans Serif", false), ("Work Sans", "Sans Serif", false),
  ("Noto Sans", "Sans Serif", false), ("PT Sans", "Sans Serif", false), ("Ubuntu", "Sans Serif", false),
  ("Barlow", "Sans Serif", false), ("Kanit", "Sans Serif", false), ("Titillium Web", "Sans Serif", false),
  ("Fira Sans", "Sans Serif", false), ("Manrope", "Sans Serif", false), ("Sora", "Sans Serif", false),
  ("Outfit", "Sans Serif", false), ("Lexend", "Sans Serif", false), ("Plus Jakarta Sans", "Sans Serif", false),
  ("Urbanist", "Sans Serif", false), ("Archivo", "Sans Serif", false), ("Space Grotesk", "Sans Serif", false),
  ("Josefin Sans", "Sans Serif", false), ("Quicksand", "Sans Serif", false), ("Comfortaa", "Sans Serif", false),
  ("Libre Franklin", "Sans Serif", false), ("Exo 2", "Sans Serif", false), ("IBM Plex Sans", "Sans Serif", false),
  # serif
  ("Playfair Display", "Serif", false), ("Merriweather", "Serif", false), ("Lora", "Serif", false),
  ("PT Serif", "Serif", false), ("EB Garamond", "Serif", false), ("Libre Baskerville", "Serif", false),
  ("Cormorant Garamond", "Serif", false), ("Crimson Text", "Serif", false), ("Noto Serif", "Serif", false),
  ("Source Serif 4", "Serif", false), ("DM Serif Display", "Serif", false), ("Bitter", "Serif", false),
  ("Roboto Slab", "Serif", false), ("Zilla Slab", "Serif", false), ("Arvo", "Serif", false),
  ("Abril Fatface", "Serif", false), ("Alfa Slab One", "Serif", false), ("IBM Plex Serif", "Serif", false),
  # display
  ("Bebas Neue", "Display", false), ("Anton", "Display", false), ("Oswald", "Display", false),
  ("Archivo Black", "Display", false), ("Righteous", "Display", false), ("Bungee", "Display", false),
  ("Monoton", "Display", false), ("Audiowide", "Display", false), ("Orbitron", "Display", false),
  ("Black Ops One", "Display", false), ("Bangers", "Display", false), ("Creepster", "Display", false),
  ("Fredoka", "Display", false), ("Teko", "Display", false), ("Unbounded", "Display", false),
  ("Syne", "Display", false), ("Big Shoulders Display", "Display", false), ("Lobster", "Display", false),
  # handwriting
  ("Pacifico", "Handwriting", false), ("Dancing Script", "Handwriting", false), ("Caveat", "Handwriting", false),
  ("Satisfy", "Handwriting", false), ("Great Vibes", "Handwriting", false), ("Permanent Marker", "Handwriting", false),
  ("Shadows Into Light", "Handwriting", false), ("Kaushan Script", "Handwriting", false),
  ("Sacramento", "Handwriting", false), ("Indie Flower", "Handwriting", false),
  # monospace and retro
  ("Press Start 2P", "Monospace", false), ("VT323", "Monospace", false), ("Silkscreen", "Monospace", false),
  ("Fira Code", "Monospace", false), ("JetBrains Mono", "Monospace", false), ("IBM Plex Mono", "Monospace", false),
  ("Source Code Pro", "Monospace", false), ("Space Mono", "Monospace", false), ("Courier Prime", "Monospace", false),
  ("Special Elite", "Monospace", false)]
  ## Families worth having, by kind.

proc familyDir*(dir, family: string): string = dir / family.replace(" ", "")
  ## Where a family's files go in `dir`.

proc isInstalled*(dir, family: string): bool =
  ## Whether a family was fetched into `dir` already.
  let d = familyDir(dir, family)
  if not dirExists(d): return false
  for kind, f in walkDir(d):
    if kind == pcFile and f.endsWith(".ttf"): return true

proc fontFaces*(css: string): seq[tuple[style, weight, url: string]] =
  ## The @font-face rules of Google Fonts' CSS: their style, weight and file.
  var p = 0
  while true:
    let a = css.find("@font-face", p)
    if a < 0: break
    let b = css.find('}', a)
    if b < 0: break
    let blk = css[a .. b]
    proc prop(name: string): string =
      let i = blk.find(name & ":")
      if i < 0: return ""
      let e = blk.find(';', i)
      blk[i + name.len + 1 ..< (if e < 0: blk.len else: e)].strip
    let src = prop("src")
    let u0 = src.find("url(")
    if u0 >= 0:
      let u1 = src.find(')', u0)
      if u1 > u0:
        result.add (prop("font-style"), prop("font-weight"), src[u0 + 4 ..< u1].strip(chars = {'\'', '"', ' '}))
    p = b + 1

const
  githubContents* = "https://api.github.com/repos/google/fonts/contents/"
    ## Where the families' full files are listed (Google's own repository)

proc slugOf*(family: string): string =
  ## A family's folder in Google's repository ("Noto Kufi Arabic" -> notokufiarabic).
  for c in family.toLowerAscii:
    if c in {'a'..'z', '0'..'9'}: result.add c

proc fontCheck*(path: string; needArabic = false): string =
  ## "" when `path` is a font file the program draws with (and, with
  ## `needArabic`, one that has the Arabic letters); else why it is not.
  let data = try: readFile(path) except IOError: return "it cannot be read"
  if data.len < 12: return "it is empty"
  case data[0 .. 3]
  of "wOF2", "wOFF": return "it is a web font (WOFF), not a TrueType file"
  of "OTTO": return "its outlines are PostScript (CFF), which are not drawn here"
  of "\x00\x01\x00\x00", "true", "ttcf": discard
  else: return "it is not a font file"
  try:
    let f = parseFace(data)
    if f.glyphOf(ord('a')) == 0 and f.glyphOf(0x0627) == 0 and f.glyphOf(ord('A')) == 0:
      return "it has no letters"
    if needArabic and f.glyphOf(0x0628) == 0:
      return "it has no Arabic letters (only a part of the family came)"
  except CatchableError, Defect:
    return "it cannot be read (" & getCurrentExceptionMsg() & ")"
  ""

proc listing(url, tmp: string): seq[tuple[name, kind, url: string]] =
  ## (a folder of Google's repository, as GitHub lists it)
  if downloadFile(url, tmp).len > 0: return
  try:
    let j = parseJson(readFile(tmp))
    if j.kind == JArray:
      for e in j:
        # (a file: where it downloads from; a folder: where it is listed)
        let kind = e{"type"}.getStr
        result.add (e{"name"}.getStr, kind, if kind == "dir": e{"url"}.getStr else: e{"download_url"}.getStr)
  except CatchableError: discard
  try: removeFile(tmp) except OSError: discard

proc styleOfFile(name: string): string =
  ## "Regular", "Bold", "Italic", "BoldItalic" from a file's name ("" another).
  let n = name.toLowerAscii.splitFile.name
  for (suffix, st) in [("-bolditalic", "BoldItalic"), ("-italic", "Italic"), ("-bold", "Bold"),
                       ("-regular", "Regular")]:
    if n.endsWith(suffix): return st
  ""

proc fromGithub(fam, d, base: string; needArabic: bool; why: var string): int =
  ## The family's files from Google's repository: its static styles
  ## (regular, bold, their italics) when it has them, else its variable
  ## files. How many were saved and draw.
  let slug = slugOf(fam)
  let tmp = d / "listing.json"
  var files: seq[tuple[name, kind, url: string]]
  for lic in ["ofl", "apache", "ufl"]:
    files = listing(base & lic & "/" & slug, tmp)
    if files.len > 0: break
  if files.len == 0:
    why = "not in Google's font repository"
    return 0
  var picked: seq[tuple[url, name: string]]
  proc pick(list: seq[tuple[name, kind, url: string]]) =
    for f in list:
      if f.kind == "file" and f.name.toLowerAscii.endsWith(".ttf"):
        let st = styleOfFile(f.name)
        if st.len > 0: picked.add (f.url, fam.replace(" ", "") & "-" & st & ".ttf")
  for f in files:
    if f.kind == "dir" and f.name == "static":
      pick(listing(f.url, tmp))
  if picked.len == 0: pick(files)
  if picked.len == 0:
    # (variable files only: "Cairo[slnt,wght].ttf", an italic one beside it)
    for f in files:
      if f.kind == "file" and f.name.toLowerAscii.endsWith(".ttf") and picked.len < 2:
        let it = "italic" in f.name.toLowerAscii
        picked.add (f.url, fam.replace(" ", "") & (if it: "-Italic.ttf" else: "-Regular.ttf"))
  for (url, name) in picked:
    let dest = d / name
    let e = downloadFile(url, dest)
    if e.len > 0:
      if why.len == 0: why = e
      continue
    let bad = fontCheck(dest, needArabic)
    if bad.len > 0:
      if why.len == 0: why = name & ": " & bad
      try: removeFile(dest) except OSError: discard
    else: inc result

proc installFromCss(fam, d: string; needArabic: bool): tuple[files: int; error: string] =
  ## (the files Google's web CSS names: regular, bold and their italics)
  let tmp = d / "styles.css"
  let q = fam.replace(" ", "+")
  # (the older CSS API gives the styles there are, leaving out those that are not)
  var err = downloadFile("https://fonts.googleapis.com/css?family=" & q & ":400,400italic,700,700italic", tmp)
  if err.len > 0:
    err = downloadFile("https://fonts.googleapis.com/css2?family=" & q, tmp)
  if err.len > 0:
    return (0, if "404" in err or "400" in err: "Google Fonts has no family \"" & fam & "\"" else: err)
  let css = try: readFile(tmp) except IOError: ""
  try: removeFile(tmp) except OSError: discard
  let faces = fontFaces(css)
  if faces.len == 0: return (0, "Google Fonts gave no files for \"" & fam & "\"")
  var seen: seq[string]
  for f in faces:
    if not f.url.endsWith(".ttf"):
      continue                                          # (WOFF2 for browsers: not for us)
    let style = (if f.style == "italic": "Italic" else: "") 
    let w = if f.weight.len > 0: f.weight else: "400"
    let name = fam.replace(" ", "") & "-" & (case w
                                             of "400": (if style.len > 0: "" else: "Regular")
                                             of "700": "Bold"
                                             else: w) & style & ".ttf"
    if name in seen: continue
    seen.add name
    let e = downloadFile(f.url, d / name)
    if e.len == 0:
      let bad = fontCheck(d / name, needArabic)
      if bad.len == 0: inc result.files
      else:
        if result.error.len == 0: result.error = fam & ": " & bad
        try: removeFile(d / name) except OSError: discard
    elif result.error.len == 0: result.error = e
  if result.files > 0: result.error = ""
  elif result.error.len == 0: result.error = "Google Fonts gave web fonts only (WOFF2) for \"" & fam & "\""

proc installGoogleFont*(family, dir: string; needArabic = false;
                        github = githubContents): tuple[files: int; error: string] =
  ## Fetches `family` from Google Fonts into `dir` (a folder of its own in
  ## it): the whole font files from Google's repository (every letter of
  ## every script the family has), else the files its web CSS names. Each
  ## file is checked -- that it is a TrueType font that draws, with the
  ## Arabic letters when `needArabic` -- and taken out when it is not. The
  ## files that came, or why none did.
  let fam = family.strip
  if fam.len == 0: return (0, "no family named")
  let d = familyDir(dir, fam)
  try: createDir(d) except OSError: discard
  var why = ""
  result.files = fromGithub(fam, d, github, needArabic, why)
  if result.files > 0: return
  let viaCss = installFromCss(fam, d, needArabic)
  if viaCss.files > 0: result = (viaCss.files, ""); return
  # (why the repository's files were not taken says more than a web error)
  let notThere = why.len == 0 or why == "not in Google's font repository"
  result.error = if not notThere: why elif viaCss.error.len > 0: viaCss.error
                 else: "Google Fonts gave no file for \"" & fam & "\""
