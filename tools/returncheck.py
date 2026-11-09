#!/usr/bin/env python3
"""Finds `return x` after `result` was used in the same proc.

Nim 2.2 leaks the value `result` held when a proc returns with `return x`
after `result` was set: a picture, a string, a seq, an object -- whatever
it held is never freed (`return nil` too). Write `result = x; return`, or
keep the value in a local until it is whole. This check lists every
`return <value>` that comes after a use of `result` (or in a loop that
uses it) in a proc that returns something with memory (not a number, a
bool, a pointer). It ends with 1 when
it found one.

    python3 tools/returncheck.py            (from the repository's root)
    python3 tools/returncheck.py app.nim src/   (your own files and folders)
"""
import os
import glob
import re
import sys

PLAIN = re.compile(
    r'^(int|int8|int16|int32|int64|uint|uint8|uint16|uint32|uint64|float|float32|'
    r'float64|bool|char|byte|cint|cuint|clong|culong|csize_t|pointer|cstring|Color|'
    r'Rect|Vec2|Vec3|Mat|Quat|Natural|Positive|BiggestInt|Time|Duration|ptr .*|'
    r'tuple\[[a-z, ]*: (int|float|bool|int64|float32|uint32)\])$')
SIG_END = re.compile(r'\)\s*(:\s*[^=]+)?(\{\.[^}]*\.\})?\s*=\s*(#.*)?$')
CODE = re.compile(r'"(?:[^"\\]|\\.)*"')   # (string literals: "oauth.result" is no use of result)
RTYPE = re.compile(r'\)\s*:\s*([^={]+?)\s*(\{\.[^}]*\.\})?\s*=\s*(#.*)?$')


def check(path):
    found = []
    lines = open(path, encoding='utf-8').read().split('\n')
    stack = []

    def close(proc, last):
        while proc['loops']:
            ind, start = proc['loops'].pop()
            proc['regions'][start] = last
        uses = proc['uses']
        for n, text, loops in proc['returns']:
            before = [u for u in uses if u < n]
            inloop = [u for u in uses for st in loops if st <= u <= proc['regions'].get(st, last)]
            if before or inloop:
                at = (before or inloop)[0]
                found.append(f'{path}:{n}: {text}  (result used on line {at})')

    last = 0
    for n, line in enumerate(lines, 1):
        text = line.strip()
        if not text or text.startswith('#'):
            continue
        ind = len(line) - len(line.lstrip())
        head = re.match(r'^(\s*)(proc|func|method|converter)\s+[^(]*\(', line)
        while stack and ind <= stack[-1]['ind']:
            close(stack.pop(), last)
        if stack:
            loops = stack[-1]['loops']
            while loops and ind <= loops[-1][0]:
                li, start = loops.pop()
                stack[-1]['regions'][start] = last
        last = n
        if head:
            sig, k = line, n
            while not SIG_END.search(sig) and k < len(lines) and k < n + 8:
                sig += ' ' + lines[k].strip()
                k += 1
            rt = RTYPE.search(sig)
            stack.append({'ind': ind, 'uses': [], 'returns': [], 'loops': [], 'regions': {},
                          'rtype': rt.group(1).strip() if rt else ''})
            continue
        if not stack:
            continue
        top = stack[-1]
        if not top['rtype'] or PLAIN.match(top['rtype']) or top['rtype'].startswith(('var ', 'lent ')):
            continue
        if re.match(r'^\s*(for|while)\b', line):
            top['loops'].append((ind, n))
        if re.search(r'\breturn\s+(?!$|#)\S', line) and not re.search(r'\breturn\s+result\s*$', line):
            top['returns'].append((n, text, [st for _, st in top['loops']]))
        elif re.search(r'\bresult\b', CODE.sub('""', line)):
            top['uses'].append(n)
    while stack:
        close(stack.pop(), last)
    return found


def main():
    if len(sys.argv) > 1:
        files = []
        for a in sys.argv[1:]:
            if os.path.isdir(a):
                files += sorted(glob.glob(os.path.join(a, '**', '*.nim'), recursive=True))
            else:
                files.append(a)
    else:
        files = sorted(glob.glob('src/**/*.nim', recursive=True)) + \
            sorted(glob.glob('examples/**/*.nim', recursive=True))
    found = []
    for f in files:
        found += check(f)
    for f in found:
        print(f)
    print(f'returncheck: {len(files)} files, {len(found)} returns after result')
    sys.exit(1 if found else 0)


if __name__ == '__main__':
    main()
