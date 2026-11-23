#!/usr/bin/env python3
"""Finds the texts Retro Atelier shows that have no Arabic.

Every text a label, a button, a menu item, a group, a tooltip or the
status line shows is looked up in the Arabic tables
(examples/photo/lang_ar.nim, src/retroui/lang_ar.nim) when the interface
is in Arabic: what is not there is shown in English. This check reads the
calls in examples/photo.nim and examples/photo/ and lists each text with
no entry -- the first text of the call (texts joined with `&` taken as
one), and for one glued to a value (`"Could not open " & name`) the fixed
parts `tr` translates: the one it starts with, the one it ends with (" pages
left"), and those between two values (" of "). It ends with 1 when it
found one.

    python3 tools/arabiccheck.py         (from the repository's root)
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TABLES = ["examples/photo/lang_ar.nim", "src/retroui/lang_ar.nim"]
CALLS = {"label", "tr", "button", "num", "ci", "checkbox", "group", "ti", "item", "menuItem",
         "defFilter", "paragraph", "radio", "optSlider", "field", "psSub", "submenu", "toolButton",
         "optCombo", "barCheck", "dvSlider", "wideSlider", "nfSlider", "dynSlider", "tooltip",
         "fxSlider", "optNumber", "quickAction", "scrubLabel", "beginStep", "groupBox", "menu", "tab",
         "dialog", "beginDialog", "msgBox", "heading", "caption", "help", "status", "setTabs",
         "twoButtons", "askNumber"}
# (texts that are the same in Arabic: names of formats and services, letters, code; a part of a
# name made -- "X Pattern")
SAME = {"JPEG", "PNG-24", "BMP", "JPEG XL", "WebP", "TIFF", "Targa", "Pixabay", "Pexels",
        "Unsplash", "RGB", "ppi", "V:", "/1000 em", "u2261", " Pattern", " (index.html)"}
CODE = re.compile(r"^(Values: |x y |src\(|sin |min |c2d |rad |p0|noise |mix |app, app|\\frac)")
IDENT = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")


def literal(s, i):
    """(the Nim string literal at s[i], its opening quote; and where it ends)"""
    out = []
    i += 1
    while i < len(s) and s[i] != '"':
        if s[i] == "\\" and i + 1 < len(s):
            i += 1
            out.append({"n": "\n", "t": "\t", '"': '"', "\\": "\\", "'": "'"}.get(s[i], "\\" + s[i]))
        elif s[i] == "\n":
            return None, i
        else:
            out.append(s[i])
        i += 1
    return "".join(out), i + 1


def plain(s):
    """(as `tr` looks it up: a mnemonic's & left out, && one &; & before a space kept)"""
    out = []
    i = 0
    while i < len(s):
        if s[i] == "&" and not (i + 1 < len(s) and s[i + 1] == " "):
            if i + 1 < len(s) and s[i + 1] == "&":
                out.append("&")
                i += 1
        else:
            out.append(s[i])
        i += 1
    return "".join(out)


def keys():
    found = set()
    pair = re.compile(r'^\s*\(\s*"((?:[^"\\\n]|\\.)*)"\s*,', re.M)
    for t in TABLES:
        for m in pair.finditer(open(os.path.join(ROOT, t), encoding="utf-8").read()):
            v, _ = literal('"' + m.group(1) + '"', 0)
            found.add(v)
    return found


def skip(s, i):
    while i < len(s) and s[i] in " \n":
        i += 1
    return i


def texts(code):
    """(each call's texts: (call, parts) -- parts the literals glued, None for a value)"""
    i = 0
    n = len(code)
    while i < n:
        c = code[i]
        if c == "#":
            while i < n and code[i] != "\n":
                i += 1
            continue
        if c == '"':
            if code.startswith('"""', i):
                e = code.find('"""', i + 3)
                i = n if e < 0 else e + 3
            else:
                _, i = literal(code, i)
            continue
        m = IDENT.match(code, i)
        if m and (i == 0 or not (code[i - 1].isalnum() or code[i - 1] in "_.")):
            word = m.group(0)
            i = m.end()
            if word not in CALLS:
                continue
            k = i
            while k < n and code[k] in " (=":
                k += 1
            if k >= n or code[k] != '"' or code.startswith('"""', k):
                continue
            first, k = literal(code, k)
            if first is None:
                continue
            parts = [first]
            # (the rest of the expression: literals and values glued with &, to its end)
            while True:
                m2 = skip(code, k)
                if m2 < n and code[m2] == "&" and code[m2 + 1:m2 + 2] in (" ", "\n"):
                    m2 = skip(code, m2 + 1)
                    if m2 < n and code[m2] == '"' and not code.startswith('"""', m2):
                        t, k = literal(code, m2)
                        if t is None:
                            break
                        if parts[-1] is not None:
                            parts[-1] += t
                        else:
                            parts.append(t)
                        continue
                    # a value: to the next & at the same depth, or the end
                    depth = 0
                    j = m2
                    while j < n:
                        ch = code[j]
                        if ch == '"':
                            if code.startswith('"""', j):
                                break
                            _, j = literal(code, j)
                            continue
                        if ch in "([{":
                            depth += 1
                        elif ch in ")]}":
                            if depth == 0:
                                break
                            depth -= 1
                        elif ch == "," and depth == 0:
                            break
                        elif ch == "\n" and depth == 0 and not code[:j].rstrip().endswith("&"):
                            break
                        elif ch == "&" and depth == 0 and code[j + 1:j + 2] in (" ", "\n"):
                            break
                        j += 1
                    parts.append(None)
                    k = j
                    continue
                break
            i = k
            yield word, parts
            continue
        i += 1


def wanted(word, parts):
    """(the texts `tr` looks up for this call)"""
    if len(parts) == 1 or word == "tr":
        yield parts[0]
        return
    if parts[0] is not None:
        yield parts[0]
    if parts[-1] is not None and parts[-1].startswith(" "):
        yield parts[-1]
    for p in parts[1:-1]:
        if p is not None and p.startswith(" ") and p.endswith(" ") and p.strip():
            yield p


def main():
    have = keys()
    files = [os.path.join(ROOT, "examples/photo.nim")]
    d = os.path.join(ROOT, "examples/photo")
    files += sorted(os.path.join(d, f) for f in os.listdir(d) if f.endswith(".nim") and f != "lang_ar.nim")
    missing = {}
    for f in files:
        for word, parts in texts(open(f, encoding="utf-8").read()):
            for t in wanted(word, parts):
                k = plain(t)
                if (not k.strip() or k in have or k in SAME or CODE.match(k) or len(k.strip()) <= 1
                        or not re.search(r"[A-Za-z]{2}", k) or k.strip() in ("--", "/", ">", "x")):
                    continue
                missing.setdefault(k, (os.path.relpath(f, ROOT), word))
    for k, (f, word) in missing.items():
        print("%s: %s %r has no Arabic" % (f, word, k))
    print("%d texts with no Arabic" % len(missing))
    return 1 if missing else 0


if __name__ == "__main__":
    sys.exit(main())
