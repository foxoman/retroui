#!/usr/bin/env python3
"""Finds `s.add` given something read from the end of `s` itself.

Nim 2.4.2 builds `s.add s[^1] + x` (and a tuple or object made from
`s[^1]` in the call) so that it makes room in `s` first -- which can move
the seq -- and only then reads `s[^1]` where the seq was: memory already
freed (docs/nim-bugs.md). A sum of floats reads garbage; under the
sanitizers it is a use after free. Take the value first:

    let next = acc[^1] + d
    acc.add next

This check lists every `X.add ...` whose argument reads `X[^`. A call that
wraps it (`s.add f(s[^1])`) is made before the room and is safe, but it is
listed too: write it the same way. It ends with 1 when it found one.

    python3 tools/addcheck.py            (from the repository's root)
    python3 tools/addcheck.py app.nim src/   (your own files and folders)
"""
import os
import re
import sys

ADD = re.compile(r'(?<![\w.])([A-Za-z_][\w.]*)\.add\(?(.*)$')
CODE = re.compile(r'"(?:[^"\\]|\\.)*"')   # (string literals left out)


def files(args):
    for a in args:
        if os.path.isdir(a):
            for dp, dn, fn in os.walk(a):
                dn[:] = [d for d in dn if d not in ('build', 'nimcache', '.git', 'oe6')]
                for f in sorted(fn):
                    if f.endswith('.nim'):
                        yield os.path.join(dp, f)
        elif a.endswith('.nim'):
            yield a


def main():
    roots = sys.argv[1:] or ['src', 'examples', 'tools', 'tests']
    found = 0
    n = 0
    for p in files(roots):
        n += 1
        try:
            lines = open(p, encoding='utf-8', errors='replace').read().split('\n')
        except OSError:
            continue
        for i, line in enumerate(lines):
            code = CODE.sub('""', line.split('#', 1)[0] if '"' not in line else line)
            for m in ADD.finditer(code):
                name, rest = m.group(1), m.group(2)
                if re.search(r'(?<![\w.])' + re.escape(name) + r'\[\^', rest):
                    print('%s:%d: %s' % (p, i + 1, line.strip()))
                    found += 1
    print('addcheck: %d files, %d adds that read their own seq from its end' % (n, found))
    sys.exit(1 if found else 0)


if __name__ == '__main__':
    main()
