#!/usr/bin/env python3
"""The kit measured (Linux): tools/bench.nim built for release, stripped, each
scene run 5 times (taking turns), the medians written to docs/benchmarks.md.

    python3 tools/bench.py            (from the repository's root)
    python3 tools/bench.py --runs 3   (fewer runs)
    python3 tools/bench.py --profile  (where each frame's time goes too: the
                                       frame profiler, retroui/frameprof)

What the page has after its busy scenes (the apps' table of
tools/appbench.sh) is kept.

On the screen there is ($DISPLAY), else on Xvfb (software drawing: what a
machine with no graphics card does). Developed by Sultan Al Isaiee @foxoman
-- www.foxoman.net -- sultan@foxoman.net
"""
import json, os, platform, statistics, subprocess, sys, time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "build", "bench")
SCENES = ["rest", "list", "dashboard", "document", "type", "phone"]


def main():
    runs = 5
    profile = "--profile" in sys.argv
    if "--runs" in sys.argv:
        runs = int(sys.argv[sys.argv.index("--runs") + 1])
    os.makedirs(OUT, exist_ok=True)
    exe = os.path.join(OUT, "bench")
    subprocess.run(["nim", "c", "--hints:off", "-d:release", "-d:useMalloc", "-d:strip",
                    "-o:" + exe, "tools/bench.nim"], cwd=ROOT, check=True)
    env = dict(os.environ)
    xvfb = None
    if not env.get("DISPLAY"):
        env["DISPLAY"] = ":93"
        xvfb = subprocess.Popen(["Xvfb", ":93", "-screen", "0", "1280x800x24"],
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        time.sleep(1.5)
    results = {s: [] for s in SCENES}
    try:
        for _ in range(runs):
            for s in SCENES:
                e = dict(env, RETRO_BENCH=s, RETRO_BENCH_OUT="")
                if profile:
                    e["RETRO_BENCH_PROFILE"] = "1"
                p = subprocess.run([exe], env=e, capture_output=True, text=True, timeout=90)
                line = [l for l in p.stdout.splitlines() if l.startswith("{")]
                if line:
                    results[s].append(json.loads(line[-1]))
    finally:
        if xvfb:
            xvfb.terminate()

    def med(scene, key, scale=1.0):
        v = [r[key] for r in results[scene] if key in r]
        return statistics.median(v) * scale if v else float("nan")

    size = os.path.getsize(exe) / 1e6
    cpu = "?"
    try:
        for l in open("/proc/cpuinfo"):
            if l.startswith("model name"):
                cpu = l.split(":", 1)[1].strip()
                break
    except OSError:
        pass
    nim = subprocess.run(["nim", "-v"], capture_output=True, text=True).stdout.splitlines()[0]
    shown = "the screen ($DISPLAY)" if not xvfb else "Xvfb (no graphics card: drawn by the processor)"
    rest = "rest"
    lines = [
        "# Benchmarks",
        "",
        "What an app made with Retro Nim UI costs, measured by `tools/bench.py`",
        "(its scenes are in `tools/bench.nim`). Medians of %d runs, the scenes" % runs,
        "taking turns. Run it on your own machine for your own numbers.",
        "",
        "| | |",
        "|---|---|",
        "| Machine | %s, %d cores |" % (cpu, os.cpu_count()),
        "| System | %s %s |" % (platform.system(), platform.release()),
        "| Compiler | %s, `-d:release -d:useMalloc -d:strip` |" % nim,
        "| Drawn on | %s |" % shown,
        "",
        "## At rest",
        "",
        "A number and three buttons, 5 seconds after its first frame, nothing happening.",
        "",
        "| | |",
        "|---|---|",
        "| The program (stripped) | %.1f MB |" % size,
        "| Start to the first frame on screen | %.0f ms |" % med(rest, "startupMs"),
        "| Memory at rest (resident) | %.1f MB |" % med(rest, "restKb", 1 / 1024),
        "| Processor at rest | %.2f%% of a core |" % med(rest, "restCpuPct"),
        "",
        "## Busy",
        "",
        "600 frames, each asked for 16 ms after the last, as a 60 Hz screen would.",
        "",
        "| Scene | Processor a frame | Frames a second | Slowest frames (99th percentile) | Most memory |",
        "|---|---|---|---|---|",
    ]
    names = {"list": "A list: 100,000 rows of three texts, scrolled 8 pixels a frame",
             "dashboard": "A dashboard: 600 cells, each its own color and a number changing every frame",
             "document": "A document: 40 paragraphs (20,000 letters) wrapped to a new width every frame",
             "type": "Type: 24 lines, each in another of 48 sizes and four faces every frame",
             "phone": "A phone: a settings page in the Gloss look, a pixel lower every frame"}
    for s in ["list", "dashboard", "document", "type", "phone"]:
        lines.append("| %s | %.2f ms | %.1f | %.1f ms | %.1f MB |" % (
            names[s], med(s, "cpuMsPerFrame"), med(s, "fps"), med(s, "p99Ms"),
            med(s, "peakKb", 1 / 1024)))
    lines += ["",
              "The processor's time is the whole process's (every thread). The frame rate",
              "stops at the 62 frames a second the scenes ask for (one each 16 ms); the",
              "slowest frames are the time between frames as each starts.",
              ""]
    if profile:
        lines += profile_lines(results, names)
    path = os.path.join(ROOT, "docs", "benchmarks.md")
    kept = ""
    try:
        old = open(path).read()
        if "\n## The apps" in old:
            kept = old[old.index("\n## The apps") + 1:]
    except OSError:
        pass
    open(path, "w").write("\n".join(lines) + ("\n" + kept if kept else ""))
    print("\n".join(lines))
    print("written:", path)


SPANS = [("app", "The app's code"), ("finish", "Finishing the frame"), ("present", "On the screen"),
         ("CPU: draw", "of it, the CPU drawing"), ("CPU: send", "the CPU sending"),
         ("GPU: draw", "the GPU drawing"), ("GPU: swap", "the GPU's swap")]


def profile_lines(results, names):
    """(the frame profiler's spans: each scene's medians of the spans' averages, ms)"""
    def span(scene, name):
        v = [r["profile"]["spans"][name]["avgMs"] for r in results[scene]
             if "profile" in r and name in r["profile"]["spans"]]
        return statistics.median(v) if v else None
    scenes = ["list", "dashboard", "document", "type", "phone"]
    cols = [(k, t) for k, t in SPANS if any(span(s, k) is not None for s in scenes)]
    out = ["## Where a frame's time goes",
           "",
           "The same scenes with the frame profiler on (`--profile`, `retroui/frameprof`):",
           "a frame's time in its parts, averages of the last 120 frames, ms.",
           "",
           "| Scene | A frame | " + " | ".join(t for _, t in cols) + " |",
           "|---" * (len(cols) + 2) + "|"]
    for s in scenes:
        f = span(s, "frame")
        cells = ["%.3f" % v if v is not None else "" for v in (span(s, k) for k, _ in cols)]
        out.append("| %s | %s | %s |" % (names[s].split(":")[0], "%.3f" % f if f is not None else "",
                                        " | ".join(cells)))
    out.append("")
    return out


if __name__ == "__main__":
    main()
