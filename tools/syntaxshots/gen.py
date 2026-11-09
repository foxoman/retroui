"""Builds build/study.nim from ex/*.nim (each program in a proc, its `app`
the one of core.nim) and writes build/code/<name>.nim: the code the study
shows, without the script lines (`#>`) and the `mark` lines.

  python3 gen.py              build/study.nim and build/code/
  python3 gen.py NAME...      only the programs whose names hold NAME
  python3 gen.py --check DOC  every program's code is in DOC, as it is here
"""
import os, re, sys

here = os.path.dirname(os.path.abspath(__file__))
exdir = os.path.join(here, "ex")
build = os.path.join(here, "build")
codedir = os.path.join(build, "code")


def shown(lines):
    """The code the study shows."""
    code = [l for l in lines if not l.startswith("#>") and not l.strip().startswith("mark ")]
    while code and not code[0].strip():
        code.pop(0)
    return "\n".join(code) + "\n"


def programs():
    for fn in sorted(os.listdir(exdir)):
        if fn.endswith(".nim"):
            yield fn[:-4], open(os.path.join(exdir, fn)).read().rstrip("\n").split("\n")


if sys.argv[1:2] == ["--check"]:
    doc = open(sys.argv[2]).read()
    missing = [name for name, lines in programs() if "```nim\n" + shown(lines) + "```" not in doc]
    for name in missing:
        print("not in", sys.argv[2], "as in ex/:", name)
    sys.exit(1 if missing else 0)

only = sys.argv[1:]
imports = {"import std/[os, json]", "import retroui except app",
           "import retroui/uirelays/[coords, screen, input, services]"}
procs, calls = [], []
os.makedirs(codedir, exist_ok=True)
for name, lines in programs():
    open(os.path.join(codedir, name + ".nim"), "w").write(shown(lines))
    if only and not any(o in name for o in only):
        continue
    script = [l[3:] if l.startswith("#> ") else l[2:] for l in lines if l.startswith("#>")]
    run = []
    for l in lines:
        if l.startswith("#>") or l.strip() == "import retroui":
            continue
        if l.startswith("import ") or l.startswith("from "):
            imports.add(l)
            continue
        run.append(l)
    ident = "ex_" + re.sub(r"[^A-Za-z0-9]", "_", name)
    procs.append("\n".join([
        f"proc {ident}() =",
        f'  echo "{name}"',
        "  script = proc () =",
        *("    " + s for s in (script or ["discard"])),
        *("  " + l if l.strip() else "" for l in run)]))
    calls.append(f"{ident}()")

out = "\n".join(sorted(imports)) + '\n\ninclude "../core.nim"\n\n'
out += "\n\n".join(procs) + "\n\n"
out += 'fakeDriver()\nstartApp("study", W, H)\n' + "\n".join(calls) + "\n"
open(os.path.join(build, "study.nim"), "w").write(out)
print(len(procs), "programs")
