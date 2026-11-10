#!/usr/bin/env python3
"""The docs against the code: what the pages name must be there.

  python3 tools/docscheck.py        (from the repository's root)

Checks, in README.md, BUILDING.md, AGENTS.md, CHANGELOG.md's newest
release, llms.txt, skills/retroui/SKILL.md, examples/README.md and docs/*.md:

  * every RETRO_ setting they name is read somewhere in the code, and every
    one the kit reads is named in a page;
  * every `nimble TASK` is a task of retroui.nimble;
  * every `retrokit COMMAND` is a command of retrokit;
  * every file or folder they name (src/..., tests/..., tools/...,
    examples/..., docs/...) is there;
  * every call they show -- `name(` in code and in backticks -- is a proc,
    template, macro, iterator or type the kit exports (or Nim's, or the
    examples' own);
  * every test in README's table is a test there is.

Ends with 1 and a list when something is wrong.
"""
import glob
import os
import re
import sys

ROOT = os.getcwd()
PAGES = (["README.md", "BUILDING.md", "AGENTS.md", "llms.txt", "SECURITY.md",
          "skills/retroui/SKILL.md", "examples/README.md"] +
         [p for p in sorted(glob.glob("docs/*.md"))
          if p not in ("docs/uirelays-pr.md",)])   # (the pull request's page: uirelays' own files)
problems = []


def read(p):
    with open(p, encoding="utf-8", errors="replace") as f:
        return f.read()


def newest_changes():
    # (the newest release's notes: the older ones tell of their own time)
    t = read("CHANGELOG.md")
    parts = re.split(r"\n## ", t)
    return "## " + parts[1] if len(parts) > 1 else t


texts = {p: read(p) for p in PAGES if os.path.exists(p)}
texts["CHANGELOG.md (newest)"] = newest_changes()

code_files = (glob.glob("src/**/*.nim", recursive=True) + glob.glob("tools/**/*.nim", recursive=True) +
              glob.glob("examples/**/*.nim", recursive=True) + glob.glob("tests/**/*.nim", recursive=True) +
              glob.glob("src/**/*.c", recursive=True) + glob.glob("src/**/*.m", recursive=True) +
              glob.glob("tools/**/*.java", recursive=True) + glob.glob("tools/**/*.sh", recursive=True) +
              glob.glob("tests/**/*.sh", recursive=True) + glob.glob("tools/**/*.py", recursive=True) +
              glob.glob(".github/workflows/*.yml") + ["retroui.nimble"])
code = {p: read(p) for p in code_files if os.path.isfile(p)}
allcode = "\n".join(code.values())
kitcode = "\n".join(v for p, v in code.items() if p.startswith("src/"))

# ---- RETRO_ settings ------------------------------------------------------------------------
used = set(re.findall(r'getEnv\(\s*"(RETRO_[A-Z0-9_]+)"', kitcode))
used |= set(re.findall(r'"(RETRO_[A-Z0-9_]+)"', kitcode))
alltext = "\n".join(texts.values())
named = set(re.findall(r"\b(RETRO_[A-Z0-9_]+)\b", alltext))
for v in sorted(named):
    if v not in allcode and not v.endswith("_"):
        problems.append(f"{v}: named in the docs, read nowhere in the code")
for v in sorted(used):
    if v not in alltext:
        problems.append(f"{v}: read by the kit, named in no page")

# ---- nimble tasks ---------------------------------------------------------------------------
tasks = set(re.findall(r"^task (\w+),", read("retroui.nimble"), re.M))
tasks |= {"install", "test", "build", "develop", "c", "cpp", "js", "refresh", "search", "list",
          "uninstall", "dump", "init", "publish", "check", "path", "setup", "doc", "run"}
for page, t in texts.items():
    for m in re.finditer(r"\bnimble (\w+)\b", t):
        w = m.group(1)
        if w not in tasks and not w[0].isupper() and w not in {"dependency", "package", "packages"}:
            problems.append(f"{page}: `nimble {w}` is no task")

# ---- retrokit commands ----------------------------------------------------------------------
rk = read("src/retrokit.nim")
main = rk[rk.index("proc main()"):]
cmds = set()
for line in re.findall(r'^\s*of ("[^\n]*):', main, re.M):
    cmds |= set(re.findall(r'"([a-z0-9-]+)"', line))
for page, t in texts.items():
    for m in re.finditer(r"\bretrokit ([a-z][a-z0-9-]*)\b", t):
        w = m.group(1)
        if w not in cmds and w not in {"is", "and", "or", "the", "a", "builds", "takes", "makes",
                                       "runs", "signs", "does", "speaks", "can", "has", "itself",
                                       "starts", "web's", "drive's", "also", "needs", "knows"}:
            problems.append(f"{page}: `retrokit {w}` is no command")

# ---- files and folders ----------------------------------------------------------------------
for page, t in texts.items():
    for m in re.finditer(r"(?<![\w/.-])((?:src|tests|tools|examples|docs|skills|\.github)/[\w./*-]+)", t):
        p = m.group(1).rstrip(".,:;)")
        if "*" in p or p.endswith("/"):
            base = p.split("*")[0].rstrip("/")
            if base and not os.path.exists(base) and not glob.glob(base + "*"):
                problems.append(f"{page}: {p}: no such files")
            continue
        if "NAME" in p or "APP" in p or "XXX" in p or p.endswith("_"):
            continue
        if not os.path.exists(p) and not os.path.exists(p.rsplit("#", 1)[0]):
            problems.append(f"{page}: {p}: no such file")

# ---- calls ----------------------------------------------------------------------------------
exported = set()
for p, t in code.items():
    if not p.endswith(".nim") and not p.endswith(".nimble"):
        continue
    for m in re.finditer(r"^\s*(?:proc|func|template|macro|iterator|method|converter)\s+`?([A-Za-z_]\w*)`?\*?", t, re.M):
        exported.add(m.group(1))
    for m in re.finditer(r"^\s*([A-Za-z_]\w*)\*?\s*(?:\[[^\]]*\])?\s*=\s*(?:ref |ptr |distinct )?(?:object|enum|tuple|proc|concept|\w)", t, re.M):
        exported.add(m.group(1))
    for m in re.finditer(r"^\s*(?:let|var|const)?\s*([A-Za-z_]\w*)\*", t, re.M):
        exported.add(m.group(1))
# Nim's own (std) and words that are not calls
NIM = set("""echo len add del delete insert high low inc dec ord chr new newSeq newString newStringOfCap
toLowerAscii toUpperAscii strip split join contains startsWith endsWith find replace parseInt parseFloat
parseHexInt formatFloat repeat align alignLeft toHex fromHex readFile writeFile fileExists dirExists
createDir removeDir removeFile copyFile moveFile getEnv putEnv existsEnv paramStr paramCount commandLineParams
getHomeDir getTempDir getCurrentDir setCurrentDir joinPath splitFile extractFilename changeFileExt
sleep quit assert doAssert min max abs clamp sqrt sin cos tan arctan2 floor ceil round trunc pow exp ln log
toFloat toInt int float string seq array set open close readLine write writeLine items pairs mitems
countup countdown sum sorted sort reversed reverse map filter mapIt filterIt anyIt allIt toSeq zip
isNil isNaN isAlphaAscii isDigit isSpaceAscii parseJson to newJObject newJArray getStr getInt getFloat
getBool hasKey keys values now format today initTable toTable getOrDefault mgetOrPut withValue
initHashSet toHashSet incl excl card spawn sync createThread joinThread initLock acquire release
cast addr unsafeAddr sizeof typeof defined declared compiles when if case for while proc func
template macro iterator block try except finally raise return result discard yield static
getTicks getMonoTime inMilliseconds epochTime cpuTime fmt formatValue runes toUTF8 runeLen
newSocket connect send recv bindAddr listen accept setLen copyMem zeroMem moveMem alloc dealloc
free malloc printf puts main exec execProcess startProcess waitForExit cmd nim nimble
""".split())
code_ids = set(re.findall(r"\b([A-Za-z_]\w*)\s*\(", allcode))
# (the app's own procs in the pages' examples: what an app of yours does)
APPS_OWN = set("""addCustomer deleteIt drawSales isLate lanes openIt openOrder saveCustomer saveIt
saveToTemp showCountry showRegion editPerson showOnMap""".split())
skip_pages = {"CHANGELOG.md (newest)", "docs/nim-bugs.md", "SECURITY.md"}
for page, t in texts.items():
    if page in skip_pages:
        continue
    found = set()
    # code blocks of Nim, and calls in backticks
    for blk in re.findall(r"```nim\n(.*?)```", t, re.S):
        found |= set(re.findall(r"(?<![\w.$'\"])([a-z]\w*)\s*\(", blk))
    for tick in re.findall(r"`([^`\n]+)`", t):
        m = re.match(r"^([a-z]\w*)\(", tick)
        if m:
            found.add(m.group(1))
    for w in sorted(found):
        if w in exported or w in NIM or w in code_ids or w in APPS_OWN:
            continue
        problems.append(f"{page}: `{w}(...)` is in no code")

# ---- the README's tests -----------------------------------------------------------------------
readme = texts.get("README.md", "")
for m in re.finditer(r"^\| `(test_\w+)`(?:, `(test_\w+)`)?", readme, re.M):
    for t in m.groups():
        if t and not os.path.exists(f"tests/{t}.nim"):
            problems.append(f"README.md: the test {t} is not in tests/")

if problems:
    print(f"docscheck: {len(problems)} things in the docs that are not in the code:")
    for p in problems:
        print("  " + p)
    sys.exit(1)
print(f"docscheck: {len(texts)} pages, all they name is there")
