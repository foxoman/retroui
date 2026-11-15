#!/usr/bin/env python3
"""Nim 2.4 refuses what Nim 2.2 allowed: a loop variable kept by a nested proc ("'x' is of
type <lent T> which cannot be captured"). Only a real build says so, not `nim check`, and it
stops at the first one.

  python3 tools/lentfix.py FILE.nim [nim flags...]      # NIM=/path/to/nim-2.4 to name the compiler

compiles FILE (to C only: `nim c --compileOnly`) again and again; each time it stops at such
a variable, the loop is given a copy of it (`let x = x`) as its first line. It prints what it
changed and stops at any other error. Run from the repository's folder, for the apps and
tests changed, before a release:

  for f in examples/*.nim tests/test_*.nim; do python3 tools/lentfix.py $f; done
"""
import re, subprocess, sys, shutil, os, tempfile
NIM = os.environ.get('NIM', 'nim')
if len(sys.argv) < 2:
    print(__doc__)
    sys.exit(1)
target = sys.argv[1]; flags = sys.argv[2:]
cache = os.path.join(tempfile.gettempdir(), 'lentfix-' + os.path.basename(target).replace('.nim', '') + ('-w' if any('wasm' in f for f in flags) else ''))
pat = re.compile(r"Error: '(\w+)' is of type <lent [^>]*> which cannot be captured.*declared here: ([^(]+)\((\d+), (\d+)\)")
fixed = 0
for _ in range(80):
    out = subprocess.run([NIM, 'c', '--compileOnly', '--hints:off', '--warnings:off', '--path:src', '--path:tests', '-d:release',
                          '--nimcache:' + cache] + flags + [target], capture_output=True, text=True)
    text = out.stdout + out.stderr
    errs = [l for l in text.splitlines() if 'Error' in l]
    if not errs:
        print('clean %s (%d fixed)' % (target, fixed)); break
    m = pat.search(errs[0])
    if not m:
        print('OTHER %s: %s' % (target, errs[0][:300])); break
    name, f, dl = m.group(1), m.group(2).strip(), int(m.group(3))
    lines = open(f).read().split('\n')
    k = dl - 1
    head = lines[k]
    if not head.lstrip().startswith('for '):
        print('NOTFOR %s:%d %s' % (f, dl, head.strip()[:120])); break
    ind = len(head) - len(head.lstrip())
    while not lines[k].rstrip().endswith(':'):
        k += 1
        if k - dl > 6: break
    if not lines[k].rstrip().endswith(':'):
        print('ONELINE %s:%d %s' % (f, dl, head.strip()[:140])); break
    lines.insert(k + 1, ' ' * (ind + 2) + 'let %s = %s' % (name, name) + '   # (its own copy: a proc below keeps it -- Nim 2.4 asks for it)')
    open(f, 'w').write('\n'.join(lines))
    fixed += 1
    print('fixed %s:%d %s' % (os.path.relpath(f), dl, name))
shutil.rmtree(cache, ignore_errors=True)
