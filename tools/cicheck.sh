#!/bin/sh
# What GitHub's CI checks, run here before a release (or before you push):
# the return check, the warnings on every system, the tests, a short fuzz,
# the Android driver on a fake Android, the tests as WebAssembly under Node
# (when clang, wasm-ld and node are here), the tools built, the live check
# and the pixel compare compiled (they run on the systems workflow), the
# workflows' YAML read.
#
#   sh tools/cicheck.sh          (from the repository's root)
#   sh tools/cicheck.sh quick    (no fuzz, no WebAssembly, the warnings of the
#                                 modules and tools only)
#
# Ends with the number of steps that failed; the output of each is in
# build/cicheck/.
set -u
out=build/cicheck
mkdir -p "$out"
quick=${1:-}
failed=0
step() {
  # step NAME COMMAND...
  name=$1; shift
  printf '%-44s' "$name"
  start=$(date +%s)
  if "$@" > "$out/$name.log" 2>&1; then
    echo "ok   ($(( $(date +%s) - start )) s)"
  else
    echo "FAIL ($out/$name.log)"
    tail -15 "$out/$name.log" | sed 's/^/    /'
    failed=$((failed + 1))
  fi
}
step returncheck python3 tools/returncheck.py
step docscheck python3 tools/docscheck.py
step controlscheck python3 tools/controlscheck.py
if [ "$quick" = quick ]; then
  step warnings sh tools/warncheck.sh quick
else
  step warnings sh tools/warncheck.sh
fi
step workflows python3 -c "
import yaml, glob
for f in sorted(glob.glob('.github/workflows/*.yml')): yaml.safe_load(open(f))"
step tests nimble test -y
if [ "$quick" != quick ]; then
  step fuzz sh -c 'nim c -r -d:release --hints:off tests/fuzz/fuzz.nim tests/fuzz/seeds 2000 &&
    nim c -r -d:release --hints:off tests/fuzz/fuzzui.nim 200 &&
    for f in fuzz_store fuzz_models fuzz_maps; do nim c -r -d:release --hints:off tests/fuzz/$f.nim 500 || exit 1; done'
fi
step android-mock sh tests/android_mock/run.sh
if [ "$quick" != quick ] && command -v node >/dev/null && command -v clang >/dev/null; then
  step wasm-node sh tests/web/node.sh
fi
step tools sh -c 'nim c -d:release --hints:off -o:build/cicheck/retroapk src/retroapk.nim &&
  nim c -d:release --hints:off -o:build/cicheck/retrokit src/retrokit.nim &&
  nim c -d:release --hints:off -o:build/cicheck/retroios src/retroios.nim'
# (what the systems workflow builds in subfolders: the kit found from there)
step subfolders sh -c 'nim c --noNimblePath --hints:off --compileOnly tests/live/livecheck.nim &&
  nim c --noNimblePath --hints:off --compileOnly tools/live/compare.nim &&
  nim c --noNimblePath --hints:off --compileOnly tests/access/accesscheck.nim'
echo "cicheck: $failed failed"
exit $failed
