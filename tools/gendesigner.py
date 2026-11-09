#!/usr/bin/env python3
"""Makes src/retrodesigner/registry.nim: what Retro Designer knows of the
controls -- for each control its parameters (names, types, defaults) and a
call that draws it with the values the designer read from the file; the
layout templates with a body (row, group, tabs, menu...) as their begin and
end; the enums' values and the string constants by name (pxOpen, nfSave);
and the Widget Box: every example of the guide (tools/shots.nim), by its
part, with the code it inserts.

    python3 tools/gendesigner.py          (from the repository's root)

It reads the API with `nim jsondoc`, writes the registry, and has the
compiler check it: a call that does not compile (a parameter's type the
designer cannot give, an overload two calls cannot tell apart) is left out,
and the registry written again, until it compiles. Run it after a control
is added or changed; tests/test_designer.nim checks the result.
"""

import glob
import json
import os
import re
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)
import controlscheck as cc  # noqa: E402

OUT = os.path.join(ROOT, "src", "retrodesigner", "registry.nim")
EXTRA = ["textwidgets", "richedit", "qrcode", "pdfview",    # not in `import retroui`
         "tilemap", "gltf", "capture", "mediasession"]
# Layout from core that the designer offers (the rest of core is the frame
# loop, input, ids).
CORE = {"row", "col", "rowPx", "spring", "space", "withId", "adaptive"}
# Controls the designer never calls: they open windows of the system, wait,
# or end the app (they are drawn as boxes when a file has them).
NEVER = {"quitApp", "openApp", "beginFrame", "endFrame", "appFrameDone", "closeApp",
         "messageBox", "msgBox", "inputBox", "fileDialog", "openFileDialog",
         "saveFileDialog", "folderDialog", "printDialog", "colorDialog", "fontDialog",
         "alert", "confirm", "ask", "askText", "toast", "notify", "beep", "openUrl",
         "share", "startDrag", "requestClose", "cancelClose",
         # (a web view's commands: what they do is the page's, not drawing)
         "webGoBack", "webGoForward", "webReload", "webStop", "webClose", "webRun",
         "webPost", "webAllow", "webZoom"}
# Parts of the guide that are not controls to drop.
SKIP_PARTS = {"Getting started", "Looks", "Screen readers and input methods"}
# Names only the screenshot tool has: an example using one is not offered.
SHOT_ONLY = {"ledgerIcon", "samplePicture", "sampleHome", "sampleRoot", "samplePlaces", "makeSampleHome",
             "target", "aimed", "sampleUi", "themeLook", "kindCols", "settle", "run(",
             "look(", "opts(", "carScene"}

# The standard modules an example may call (as tools/shots.nim imports
# them): an example using one of these names gets the module imported.
STD = {
    "std/os": {"getHomeDir", "getTempDir", "getCurrentDir", "fileExists", "dirExists",
               "extractFilename", "splitFile", "changeFileExt", "parentDir", "walkDir",
               "createDir", "removeFile", "getAppDir"},
    "std/math": {"PI", "TAU", "sin", "cos", "tan", "sqrt", "pow", "floor", "ceil",
                 "arctan2", "exp", "ln", "log10", "hypot", "degToRad", "radToDeg"},
    "std/strutils": {"formatFloat", "ffDecimal", "repeat", "strip", "startsWith", "endsWith",
                     "toUpperAscii", "toLowerAscii", "parseInt", "parseFloat", "align",
                     "alignLeft", "splitLines", "insertSep", "replace", "split", "join"},
    "std/sequtils": {"filterIt", "mapIt", "toSeq", "anyIt", "allIt", "countIt", "keepItIf"},
    "std/times": {"now", "epochTime", "fromUnix", "getTime"},
    "std/json": {"parseJson", "newJObject", "newJArray"},
    "std/algorithm": {"sort", "sorted", "reversed"},
    "std/tables": {"initTable", "toTable", "initOrderedTable"},
}

# Examples of the guide that are about showing a window, not a control to drop.
NOT_IN_BOX = {"windowbox"}

# The names templates give their bodies (besides `body`): two bodies side by side.
BODY_NAMES = {"left", "right", "top", "bottom", "upper", "lower", "main", "pane", "first", "second", "header", "footer"}

# The toolkit's measures (templates): a default that is one of them is an int.
METRICS = {"Gap", "Pad", "CtrlH", "EditH", "ItemH", "FontH", "MenuH", "ToolH", "TitleH"}

INT_TYPES = {"int", "Natural", "Positive", "int32", "int16", "int8", "int64", "uint8",
             "uint16", "uint32", "uint", "Id"}
FLOAT_TYPES = {"float", "float32", "float64"}


# ---- the API --------------------------------------------------------------------------------------

def jsondocs(tmp):
    out = os.path.join(tmp, "jd")
    src = os.path.join(ROOT, "src")
    def doc(args):
        subprocess.run(["nim", "jsondoc", "--hints:off", "--warnings:off", "--path:" + src,
                        "--outdir:" + out] + args,
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    doc(["--project", os.path.join(src, "retroui.nim")])
    for m in EXTRA:
        doc([os.path.join(src, "retroui", m + ".nim")])
    mods = {}
    for p in glob.glob(os.path.join(out, "**", "*.json"), recursive=True):
        name = os.path.splitext(os.path.basename(p))[0]
        if name in ("theindex", "retroui"):
            continue
        with open(p, "rb") as f:
            d = json.loads(f.read().decode("utf-8", "replace"))
        if "entries" in d:
            mods[name] = d["entries"]
    return mods


def strip_html(s):
    s = re.sub(r"<[^>]+>", "", s or "")
    for a, b in (("&lt;", "<"), ("&gt;", ">"), ("&amp;", "&"), ("&quot;", '"'), ("&#39;", "'")):
        s = s.replace(a, b)
    return " ".join(s.split())


def enum_members(code):
    """The values of an enum type from its code (`E = enum a = "A", b ## ...`)."""
    m = re.match(r"\s*([A-Za-z_]\w*)\*?\s*(\{[^}]*\})?\s*=\s*enum\b(.*)", code, re.S)
    if not m:
        return None, []
    pure = "pure" in (m.group(2) or "")
    body = m.group(3)
    body = re.sub(r"##[^\n]*", "", body)
    out = []
    for part in re.split(r"[,\n]", body):
        part = part.strip()
        if not part:
            continue
        nm = re.match(r"([A-Za-z_]\w*)", part)
        if nm:
            out.append(nm.group(1))
    return pure, out


def collect(mods):
    enums, strconsts, intconsts = {}, {}, {}
    for mod, entries in mods.items():
        for e in entries:
            if e["type"] == "skType":
                pure, mem = enum_members(e["code"])
                if mem:
                    enums[e["name"]] = mem
            elif e["type"] == "skConst":
                code = e["code"]
                m = re.match(r"\s*([A-Za-z_]\w*)\s*(?::\s*\w+\s*)?=\s*(.*)", code, re.S)
                if not m:
                    continue
                v = m.group(2).strip()
                if re.match(r'^"(?:[^"\\]|\\.)*"$', v):
                    strconsts[e["name"]] = mod
                elif re.match(r"^-?\d+$", v):
                    intconsts[e["name"]] = mod
    return enums, strconsts, intconsts


# ---- parameter types ------------------------------------------------------------------------------

def infer(default, enums):
    d = (default or "").strip()
    if d in ("true", "false"):
        return "bool"
    if re.match(r"^-?\d+$", d):
        return "int"
    if re.match(r"^-?\d+\.\d*([eE][-+]?\d+)?$", d):
        return "float"
    if re.match(r'^"(?:[^"\\]|\\.)*"$', d):
        return "string"
    if d.startswith("Color(") or d.startswith("color("):
        return "Color"
    if d in METRICS or re.match(r"^dp\(\d+\)$", d):
        return "int"
    for en, mem in enums.items():
        if d in mem:
            return en
    return ""


def kind_of(typ, default, enums):
    """(kind, element) for a parameter: how the designer gives it."""
    t = typ.strip()
    if not t:
        t = infer(default, enums)
    var = t.startswith("var ")
    if var:
        t = t[4:].strip()
    base = t
    if base in ("string", "cstring"):
        k = "str"
    elif base in INT_TYPES:
        k = "int"
    elif base in FLOAT_TYPES:
        k = "float"
    elif base == "bool":
        k = "bool"
    elif base in ("openArray[string]", "seq[string]", "varargs[string]"):
        k = "strs"
    elif base in ("openArray[int]", "seq[int]", "varargs[int]"):
        k = "ints"
    elif base in ("openArray[float]", "seq[float]"):
        k = "floats"
    elif base == "Color":
        k = "color"
    elif base == "Rect":
        k = "rect"
    elif base in enums:
        k = "enum"
    elif re.match(r"^set\[(\w+)\]$", base) and re.match(r"^set\[(\w+)\]$", base).group(1) in enums:
        k = "set"
    else:
        return ("", base, var)
    if var:
        if k in ("str", "int", "float", "bool", "strs", "ints"):
            if base not in ("string", "int", "float", "bool", "seq[string]", "seq[int]",
                            "openArray[string]", "openArray[int]"):
                return ("", base, var)          # (var int32, var Natural...: not given)
            return ("v" + k, base, True)
        return ("", base, var)
    return (k, base, False)


def zero(k, base):
    return {"str": '""', "int": "0", "float": "0.0", "bool": "false", "strs": "@[]",
            "ints": "@[]", "floats": "@[]", "color": "Color()", "rect": "Rect()"}.get(k, "")


def seqdefault(d):
    d = d.strip()
    if d.startswith("@["):
        return d
    if d.startswith("["):
        return "@" + d
    return "@(" + d + ")"


def accessor(i, p, enums):
    """The Nim expression that gives parameter `p` (number `i`) its value."""
    k, base, var = p["kind"], p["base"], p["var"]
    d = p.get("default", "")
    if k.startswith("v"):
        return "a.%s(%d)" % (k, i)
    if k in ("strs", "ints", "floats"):
        dd = seqdefault(d) if d else "@[]"
        fn = {"strs": "argStrs", "ints": "argInts", "floats": "argFloats"}[k]
        return "a.%s(%d, %s)" % (fn, i, dd)
    if k == "enum":
        dd = d if d else "%s.low" % base
        if d in enums.get(base, []):
            dd = "%s.%s" % (base, d)
        return "enum_%s(a.argIdent(%d), %s)" % (base, i, dd)
    if k == "set":
        en = re.match(r"^set\[(\w+)\]$", base).group(1)
        return "set_%s(a.argNames(%d), %s)" % (en, i, d if d else "{}")
    dd = d if d else zero(k, base)
    fn = {"str": "argStr", "int": "argInt", "float": "argFloat", "bool": "argBool",
          "color": "argColor", "rect": "argRect"}[k]
    expr = "a.%s(%d, %s)" % (fn, i, dd)
    if k == "int" and base != "int":
        expr = "%s(%s)" % (base, expr)
    if k == "float" and base != "float":
        expr = "%s(%s)" % (base, expr)
    return expr


# ---- templates with a body: their begin and end ---------------------------------------------------

def template_source(path, line):
    with open(path, encoding="utf-8") as f:
        lines = f.read().split("\n")
    out = [lines[line - 1]]
    k = line
    while k < len(lines):
        l = lines[k]
        if l.strip() and not l.startswith(" "):
            break
        out.append(l)
        k += 1
    while out and not out[-1].strip():
        out.pop()
    return out


def split_template(src, pnames):
    """(begin lines, end lines, conditional) around `body`, or None."""
    lines = [l for l in src[1:] if not l.strip().startswith("##")]
    idx = [i for i, l in enumerate(lines) if l.strip() == "body"]
    if len(idx) != 1:
        return None
    b = idx[0]
    ind = len(lines[b]) - len(lines[b].lstrip())
    before = [l for l in lines[:b] if l.strip()]
    after = [l for l in lines[b + 1:] if l.strip()]
    base = min((len(l) - len(l.lstrip()) for l in before + after + [lines[b]]), default=2)
    cond = None
    if ind > base:
        # `if beginX(...):` then body (and the end) under it
        if not before or not re.match(r"\s*if\s+(.*):\s*$", before[-1]):
            return None
        if len(before[-1]) - len(before[-1].lstrip()) != base:
            return None
        cond = re.match(r"\s*if\s+(.*):\s*$", before[-1]).group(1)
        before = before[:-1]
        inner = [l for l in after if len(l) - len(l.lstrip()) >= ind]
        rest = [l for l in after if len(l) - len(l.lstrip()) < ind]
        if rest:
            return None
        after = inner
    for l in before + after:
        s = l.strip()
        if s.startswith(("let ", "var ", "const ", "defer", "try", "finally", "for ", "while ",
                         "block", "when ", "return", "except")):
            return None
        if "body" in re.findall(r"\b\w+\b", s):
            return None
    deind = lambda ls: [l[min(len(l) - len(l.lstrip()), ind if cond else base):] for l in ls]
    return deind(before), deind(after), cond


def subst(line, mapping):
    out, i = [], 0
    # (names outside strings only)
    for m in re.finditer(r'"(?:[^"\\]|\\.)*"|\b[A-Za-z_]\w*\b', line):
        out.append(line[i:m.start()])
        tok = m.group(0)
        out.append(mapping.get(tok, tok) if not tok.startswith('"') else tok)
        i = m.end()
    out.append(line[i:])
    return "".join(out)


# ---- the guide's examples (the Widget Box) --------------------------------------------------------

def nim_string(s):
    """A Nim "..." literal's value (enough for the guide's texts)."""
    out, i = [], 0
    while i < len(s):
        c = s[i]
        if c == "\\" and i + 1 < len(s):
            n = s[i + 1]
            out.append({"n": "\n", "t": "\t", '"': '"', "\\": "\\", "'": "'"}.get(n, n))
            i += 2
        else:
            out.append(c)
            i += 1
    return "".join(out)


def clean_code(code):
    lines = []
    for l in code.split("\n"):
        st = l.strip()
        if st in ("aim()", "aimed = true") or st.startswith("target = ") or st.startswith("aimAt("):
            continue
        l = l.replace(", enabled = shotEnabled", "").replace("enabled = shotEnabled", "")
        l = l.replace("(, ", "(")
        lines.append(l)
    return "\n".join(lines).strip("\n")


def dedent(lines):
    ind = min((len(l) - len(l.lstrip()) for l in lines if l.strip()), default=0)
    return [l[ind:] for l in lines]


def shot_globals(lines):
    """tools/shots.nim's variables and constants at the top (some examples
    share them): each one's declaration, by name."""
    out, i = {}, 0
    while i < len(lines):
        m = re.match(r"^(var|let|const)\b\s*(.*)$", lines[i])
        if not m:
            i += 1
            continue
        kw, rest = m.group(1), m.group(2).strip()
        if rest:
            j = i + 1
            if rest.count('"""') % 2 == 1:
                # (a long string: to its end)
                while j < len(lines) and '"""' not in lines[j]:
                    j += 1
                j += 1
            while j < len(lines) and lines[j].startswith(" ") and lines[j].strip():
                j += 1
            nm = re.match(r"^(\w+)", rest)
            if nm:
                out[nm.group(1)] = "\n".join(lines[i:j])
            i = j
            continue
        j = i + 1
        while j < len(lines) and lines[j].startswith("  "):
            em = re.match(r"^  (\w+)\b", lines[j])
            k = j + 1
            while k < len(lines) and lines[k].startswith("    "):
                k += 1
            if em:
                out[em.group(1)] = kw + "\n" + "\n".join(lines[j:k])
            j = k
        i = j
    return out


def examples():
    with open(os.path.join(ROOT, "tools", "shots.nim"), encoding="utf-8") as f:
        lines = f.read().split("\n")
    shared = shot_globals(lines)
    part, out, i = "", [], 0
    start = re.compile(r'^example\("([^"]+)",\s*"((?:[^"\\]|\\.)*)",\s*$')
    while i < len(lines):
        l = lines[i]
        pm = re.match(r'^part\("([^"]+)"', l)
        if pm:
            part = pm.group(1)
        m = re.match(r'^example\(', l)
        if m:
            # the call's arguments run to the line ending in ':' at depth 0
            head = l
            j = i
            while not re.search(r"\):\s*$", head.rstrip()):
                j += 1
                head += "\n" + lines[j]
            args = re.match(r'^example\(\s*"([^"]+)",\s*"((?:[^"\\]|\\.)*)",\s*"((?:[^"\\]|\\.)*)",\s*(\d+),\s*(\d+),', head, re.S)
            if not args:
                i = j + 1
                continue
            name, title, about, w, h = args.group(1), nim_string(args.group(2)), \
                nim_string(args.group(3)), int(args.group(4)), int(args.group(5))
            k = j + 1
            first = []
            while k < len(lines) and (lines[k].startswith(" ") or not lines[k].strip()):
                first.append(lines[k])
                k += 1
            decls, body = [], first
            if k < len(lines) and lines[k].startswith("do:"):
                decls = first
                body = []
                k += 1
                while k < len(lines) and (lines[k].startswith(" ") or not lines[k].strip()):
                    body.append(lines[k])
                    k += 1
            while body and not body[-1].strip():
                body.pop()
            while decls and not decls[-1].strip():
                decls.pop()
            code = clean_code("\n".join(dedent(body)))
            dcode = clean_code("\n".join(dedent(decls)))
            # (the shared variables it uses, declared with it: each example
            #  stands on its own in your file)
            def declared(t):
                return set(re.findall(r"^\s*(?:(?:var|let|const)\s+)?([A-Za-z_]\w*)\s*\*?\s*[:=]",
                                      t, re.M))
            for _ in range(3):
                # (names used as names: not a field `.name`, not `name:` or
                #  `name =` labelling an argument)
                used = set(re.findall(r"(?<![.\w])([A-Za-z_]\w*)\b(?!\s*:)(?!\s*=[^=])",
                                      code + "\n" + dcode))
                need = [shared[n] for n in sorted(used - declared(dcode)) if n in shared]
                if not need:
                    break
                dcode = "\n".join(need + ([dcode] if dcode else []))
            if part not in SKIP_PARTS and name not in NOT_IN_BOX and \
               not any(x in code + dcode for x in SHOT_ONLY):
                out.append(dict(name=name, title=title, about=about, w=w, h=h, part=part,
                                code=code, decls=dcode))
            i = k
            continue
        i += 1
    return out


# ---- the registry --------------------------------------------------------------------------------

def nimlit(s):
    o = ['"']
    for ch in s:
        if ch == "\\":
            o.append("\\\\")
        elif ch == '"':
            o.append('\\"')
        elif ch == "\n":
            o.append("\\n")
        elif ord(ch) < 32:
            o.append("\\x%02x" % ord(ch))
        else:
            o.append(ch)
    o.append('"')
    return "".join(o)


def build(mods, enums, strconsts, intconsts, drop, exs):
    """The registry's text and, for each line, which call it belongs to."""
    lines, owner = [], []

    def emit(s, who=None):
        for l in s.split("\n"):
            lines.append(l)
            owner.append(who)

    emit("""## Retro Designer's registry: every control, its parameters and a call that
## draws it; the layout templates' begin and end; the enums' values, the
## string constants; the Widget Box (the guide's examples).
##
## MADE BY tools/gendesigner.py -- DO NOT EDIT: run it again instead.
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/tables
import retroui
import retroui/[%s]
import values

{.push warning[Deprecated]: off, warning[UnusedImport]: off, hint[XDeclaredButNotUsed]: off.}

type
  ParamKind* = enum
    kNone = "", kStr = "str", kInt = "int", kFloat = "float", kBool = "bool",
    kStrs = "strs", kInts = "ints", kFloats = "floats", kColor = "color", kRect = "rect",
    kEnum = "enum", kSet = "set", kVStr = "vstr", kVInt = "vint", kVFloat = "vfloat",
    kVBool = "vbool", kVStrs = "vstrs", kVInts = "vints"
  Param* = object
    name*, typ*, default*: string   ## its type and default as the source has them
    kind*: ParamKind                ## how the designer gives it (kNone: it cannot)
  Overload* = object
    params*: seq[Param]
    returns*: string
    call*: proc (a: var Args): Value {.nimcall.}   ## nil: the designer cannot call it
  Control* = object
    name*, module*, doc*: string
    overloads*: seq[Overload]
  Block* = object
    ## A template with a body (row, group, tabs, menu...): `run` uses the
    ## template itself, its body (or bodies: a split's two sides) the
    ## designer's own drawing of what the file has there.
    name*, module*, doc*: string
    params*: seq[Param]
    bodies*: int
    run*: proc (a: var Args; bodies: seq[proc () {.closure.}]) {.nimcall.}
  Example* = object
    ## One of the guide's examples: what the Widget Box offers.
    name*, title*, about*, part*: string
    w*, h*: int
    code*, decls*: string           ## what it inserts: the controls, and the variables
    imports*: seq[string]           ## the modules it needs besides `retroui`

var
  controls*: Table[string, Control]
  blocks*: Table[string, seq[Block]]
  enumValues*: Table[string, seq[string]]  ## an enum's values, by the enum's name
  stringConsts*: Table[string, string]     ## pxOpen, nfSave...: their text
  intConsts*: Table[string, int]
  widgetBox*: seq[Example]
""" % ", ".join(EXTRA))

    used_enums = set()
    calls = []          # (name, module, doc, overloads)
    blks = []
    seen_ctl = set()
    for mod in cc.MODULES + ["core"] + EXTRA:
        if mod not in mods:
            continue
        for e in mods[mod]:
            name = e["name"]
            if e["type"] not in ("skProc", "skTemplate", "skFunc"):
                continue
            if mod == "core":
                if name not in CORE:
                    continue
            elif mod in cc.WHOLE_MODULE_NOT_CONTROLS or name in cc.NOT_CONTROLS.get(mod, ()):
                continue
            if name in NEVER or name.startswith(("begin", "end")) and name not in ("endsWith",):
                if name.startswith(("begin", "end")):
                    continue
                continue
            sig = e.get("signature") or {}
            args = sig.get("arguments", [])
            ps = []
            bodies = []
            for a in args:
                t = a.get("type", "")
                if t == "untyped" and (a["name"] == "body" or a["name"] in BODY_NAMES):
                    bodies.append(a["name"])
                    continue
                if t == "untyped":
                    # (a name the template declares for its body: `ctx`)
                    ps.append(dict(name=a["name"], typ=t, base=t, default="", kind="",
                                   var=False, own=True))
                    continue
                if t == "typed":
                    t = "string"
                k, base, var = kind_of(t, a.get("default", ""), enums)
                ps.append(dict(name=a["name"], typ=a.get("type", "") or base, base=base,
                               default=a.get("default", ""), kind=k, var=var))
            body = len(bodies) > 0
            doc = strip_html(e.get("description", ""))
            if body:
                blks.append(dict(name=name, mod=mod, doc=doc, params=ps, line=e["line"],
                                 bodies=bodies, ret=sig.get("return", "")))
            else:
                calls.append(dict(name=name, mod=mod, doc=doc, params=ps,
                                  ret=sig.get("return", ""), line=e["line"]))

    # enums and sets the calls need
    for c in calls + blks:
        for p in c["params"]:
            if p["kind"] == "enum":
                used_enums.add(p["base"])
            if p["kind"] == "set":
                used_enums.add(re.match(r"^set\[(\w+)\]$", p["base"]).group(1))
    used_enums = {e for e in used_enums if ("enum:" + e) not in drop}
    emit("\n# ---- enums ----\n")
    for en in sorted(used_enums):
        who = "enum:" + en
        emit("proc enum_%s(name: string; d: %s): %s =" % (en, en, en), who)
        emit("  case name", who)
        for m in enums[en]:
            emit('  of "%s": %s.%s' % (m, en, m), who)
        emit("  else: d", who)
        emit("proc set_%s(names: seq[string]; d: set[%s]): set[%s] =" % (en, en, en), who)
        emit("  if names.len == 0: return d", who)
        emit("  for n in names: result.incl enum_%s(n, %s.low)" % (en, en), who)
        emit("")

    emit("# ---- the calls ----\n")
    reg = []
    for idx, c in enumerate(calls):
        who = "call:%s:%d" % (c["name"], c["line"])
        params = c["params"]
        if who in drop:
            reg.append((c, None))
            continue
        callable_ = all(p["kind"] or p["default"] or p.get("own") for p in params)
        if not callable_:
            reg.append((c, None))
            continue
        fn = "c%d_%s" % (idx, c["name"])
        argl = []
        for i, p in enumerate(params):
            if p.get("own"):
                argl.append("%s = %s" % (p["name"], p["name"]))
                continue
            if not p["kind"]:
                continue        # (its default)
            argl.append("%s = %s" % (p["name"], accessor(i, p, enums)))
        callx = "%s(%s)" % (c["name"], ", ".join(argl))
        emit("proc %s(a: var Args): Value =" % fn, who)
        if c["ret"] and c["ret"] != "void":
            emit("  toValue(%s)" % callx, who)
        else:
            emit("  %s" % callx, who)
            emit("  Value()", who)
        reg.append((c, fn))

    emit("\n# ---- the blocks ----\n")
    breg = []
    for idx, b in enumerate(blks):
        who = "block:%s:%d" % (b["name"], b["line"])
        if who in drop:
            continue
        if not all(p["kind"] or p["default"] or p.get("own") for p in b["params"]):
            continue
        fn = "b%d_%s" % (idx, b["name"])
        argl = []
        for i, p in enumerate(b["params"]):
            if p.get("own"):
                argl.append("%s = %s" % (p["name"], p["name"]))
            elif p["kind"]:
                argl.append("%s = %s" % (p["name"], accessor(i, p, enums)))
        emit("proc %s(a: var Args; bodies: seq[proc () {.closure.}]) =" % fn, who)
        dis = "discard " if b["ret"] and b["ret"] != "void" else ""
        if len(b["bodies"]) == 1:
            emit("  %s%s(%s):" % (dis, b["name"], ", ".join(argl)), who)
            emit("    bodies[0]()", who)
        else:
            for k, bn in enumerate(b["bodies"]):
                argl.append("%s = (bodies[%d]())" % (bn, k))
            emit("  %s%s(%s)" % (dis, b["name"], ", ".join(argl)), who)
        breg.append((b, fn))

    def kname(k):
        if not k:
            return "kNone"
        if k.startswith("v"):
            return "kV" + k[1].upper() + k[2:]
        return "k" + k[0].upper() + k[1:]

    def plist(params):
        return "@[" + ", ".join(
            "Param(name: %s, typ: %s, default: %s, kind: %s)" % (
                nimlit(p["name"]), nimlit(p["typ"]), nimlit(p["default"]), kname(p["kind"]))
            for p in params) + "]"

    emit("\nproc initRegistry*() =")
    emit("  ## Fills the tables (once, when the designer starts).")
    emit("  if controls.len > 0: return")
    for c, fn in reg:
        who = "call:%s:%d" % (c["name"], c["line"])
        emit("  controls.mgetOrPut(%s, Control(name: %s, module: %s, doc: %s)).overloads.add Overload(params: %s, returns: %s, call: %s)" % (
            nimlit(c["name"]), nimlit(c["name"]), nimlit(c["mod"]), nimlit(c["doc"][:400]),
            plist(c["params"]), nimlit(c["ret"]), fn or "nil"), who)
    for b, fn in breg:
        who = "block:%s:%d" % (b["name"], b["line"])
        emit("  blocks.mgetOrPut(%s, @[]).add Block(name: %s, module: %s, doc: %s, params: %s, bodies: %d, run: %s)" % (
            nimlit(b["name"]), nimlit(b["name"]), nimlit(b["mod"]), nimlit(b["doc"][:400]),
            plist(b["params"]), len(b["bodies"]), fn), who)
    for en in sorted(used_enums):
        emit("  enumValues[%s] = @[%s]" % (nimlit(en), ", ".join(nimlit(m) for m in enums[en])),
             "enum:" + en)
    for nm in sorted(strconsts):
        if "sconst:" + nm in drop:
            continue
        emit("  stringConsts[%s] = %s" % (nimlit(nm), nm), "sconst:" + nm)
    for nm in sorted(intconsts):
        if "iconst:" + nm in drop:
            continue
        emit("  intConsts[%s] = int(%s)" % (nimlit(nm), nm), "iconst:" + nm)
    for x in exs:
        emit("  widgetBox.add Example(name: %s, title: %s, about: %s, part: %s, w: %d, h: %d, code: %s, decls: %s, imports: @[%s])" % (
            nimlit(x["name"]), nimlit(x["title"]), nimlit(x["about"]), nimlit(x["part"]),
            x["w"], x["h"], nimlit(x["code"]), nimlit(x["decls"]),
            ", ".join(nimlit(m) for m in x.get("imports", []))))
    emit("\n{.pop.}")
    return lines, owner


def check(path):
    p = subprocess.run(["nim", "check", "--hints:off", "--warnings:off", "--errorMax:200",
                        "--path:" + os.path.join(ROOT, "src"), path],
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    errs = []
    base = os.path.basename(path)
    for l in p.stdout.split("\n"):
        if "Error:" not in l:
            continue
        for m in re.finditer(re.escape(base) + r"\((\d+), (\d+)\)", l):
            errs.append((int(m.group(1)), l))
    return p.returncode, errs, p.stdout


def main():
    with tempfile.TemporaryDirectory() as tmp:
        print("gendesigner: reading the API (nim jsondoc)...")
        mods = jsondocs(tmp)
    enums, strconsts, intconsts = collect(mods)
    exs = examples()
    # (an example calling a control of a module `import retroui` does not
    #  bring: that module imported with it)
    common = set()
    for m, es in mods.items():
        if m not in EXTRA:
            common |= {e["name"] for e in es}
    for x in exs:
        words = set(re.findall(r"\b[A-Za-z_]\w*\b", x["code"] + "\n" + x["decls"]))
        x["imports"] = ["retroui/" + m for m in EXTRA if m in mods and
                        any(e["name"] in words and e["name"] not in common for e in mods[m])]
        x["imports"] += [m for m, names in STD.items()
                         if names & words or (m == "std/json" and "%*" in x["code"] + x["decls"])]
    drop = set()
    for rnd in range(40):
        lines, owner = build(mods, enums, strconsts, intconsts, drop, exs)
        with open(OUT, "w", encoding="utf-8") as f:
            f.write("\n".join(lines) + "\n")
        code, errs, text = check(OUT)
        if code == 0:
            break
        new = set()
        for ln, msg in errs:
            if 1 <= ln <= len(owner) and owner[ln - 1]:
                new.add(owner[ln - 1])
        if not new:
            print(text[-3000:])
            sys.exit("gendesigner: the registry does not compile and the errors are not in a call")
        print("gendesigner: round %d: %d left out" % (rnd + 1, len(new)))
        drop |= new
    else:
        sys.exit("gendesigner: gave up")
    ncalls = sum(1 for l in lines if l.startswith("  controls.mgetOrPut") and "call: nil" not in l)
    nall = sum(1 for l in lines if l.startswith("  controls.mgetOrPut"))
    nblocks = sum(1 for l in lines if l.startswith("  blocks.mgetOrPut"))
    print("gendesigner: %d control overloads (%d drawn by the designer), %d blocks, %d enums, "
          "%d examples in the Widget Box -> %s" % (nall, ncalls, nblocks,
                                                  sum(1 for l in lines if l.startswith("  enumValues")),
                                                  len(exs), os.path.relpath(OUT, ROOT)))
    left = sorted(d for d in drop if d.startswith(("call:", "block:")))
    if left:
        print("gendesigner: left out (drawn as boxes):", ", ".join(x.split(":")[1] for x in left))


if __name__ == "__main__":
    main()
