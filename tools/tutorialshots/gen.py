"""Builds build/study.nim from the tutorials' steps (tutorials/*/step*.nim:
each in a proc, its `app` the one of core.nim), and build/buildonly.txt:
the steps marked `#> build-only` (their own loop, another system's API, a
test), which make.sh checks with `nim check` instead.

  python3 gen.py              build/study.nim, build/buildonly.txt
  python3 gen.py --check      every step's code is in its lesson's README.md, as it is
"""
import glob, os, re, sys

here = os.path.dirname(os.path.abspath(__file__))
root = os.path.dirname(os.path.dirname(here))
tut = os.path.join(root, "tutorials")
build = os.path.join(here, "build")


def shown(lines):
    """The code the lesson shows."""
    code = [l for l in lines if not l.startswith("#>") and not l.strip().startswith("mark ")]
    while code and not code[0].strip():
        code.pop(0)
    return "\n".join(code) + "\n"


def steps():
    for path in sorted(glob.glob(os.path.join(tut, "*", "step*.nim"))):
        lesson = os.path.basename(os.path.dirname(path))
        yield lesson, path, open(path).read().rstrip("\n").split("\n")


if sys.argv[1:2] == ["--check"]:
    bad = 0
    for lesson, path, lines in steps():
        readme = os.path.join(tut, lesson, "README.md")
        doc = open(readme).read() if os.path.exists(readme) else ""
        if "```nim\n" + shown(lines) + "```" not in doc:
            print("not in", os.path.relpath(readme, root), "as in", os.path.relpath(path, root))
            bad += 1
    sys.exit(1 if bad else 0)

os.makedirs(build, exist_ok=True)
imports = {"import std/[os, json]", "import retroui except app",
           "import retroui/uirelays/[coords, screen, input, services]"}
procs, calls, only = [], [], []
for lesson, path, lines in steps():
    if any(l.strip() == "#> build-only" for l in lines):
        only.append(path)
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
    name = lesson + "/" + os.path.basename(path)
    ident = "t_" + re.sub(r"[^A-Za-z0-9]", "_", name)
    procs.append("\n".join([
        f"proc {ident}() =",
        f'  echo "{name}"',
        "  script = proc () =",
        *("    " + s for s in (script or ["discard"])),
        *("  " + l if l.strip() else "" for l in run)]))
    calls.append(f"{ident}()")

out = "\n".join(sorted(imports)) + '\n\ninclude "../core.nim"\n\n'
out += "\n\n".join(procs) + "\n\n"
out += 'fakeDriver()\nstartApp("tutorials", W, H)\n' + "\n".join(calls) + "\n"
open(os.path.join(build, "study.nim"), "w").write(out)
open(os.path.join(build, "buildonly.txt"), "w").write("\n".join(only) + "\n")
print(len(procs), "steps with pictures,", len(only), "built only")
