#!/usr/bin/env python3
"""Finds a `var` that Nim 2.2 overwrites without freeing what it held.

`var x: T` declared without a value, given one in a branch (an `if` with
no `else`, a `case`, a `try`) or in a loop, and then given another in the
block it was declared in: Nim takes the second for the first ever given
(it is not sure the first ran) and copies it over without freeing the
first -- a seq, a string, a picture, an object of them is never freed:

    var small: seq[uint32]
    if s > 1: small = shrunk(b, s)
    ...
    small = @[]                 # (what shrunk made is never freed)

Give `x` its value where it is declared (`var small: seq[uint32] = @[]`,
`var small = if s > 1: shrunk(b, s) else: @[]`). This check lists every
such `var` of a type with memory (not a number, a bool, a pointer, or an
object of only those). It ends with 1 when it found one.

    python3 tools/writecheck.py            (from the repository's root)
    python3 tools/writecheck.py app.nim src/   (your own files and folders)

Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net
"""
import glob
import os
import re
import sys

PLAIN = re.compile(
    r'^(int|int8|int16|int32|int64|uint|uint8|uint16|uint32|uint64|float|float32|'
    r'float64|bool|char|byte|cint|cuint|clong|culong|csize_t|cfloat|cdouble|pointer|'
    r'cstring|Natural|Positive|BiggestInt|BiggestUInt|BiggestFloat|Time|Duration|'
    r'MonoTime|Rune|Ticks|Month|WeekDay|Id|Key|Hash|set\[.*\]|ptr .*|range\[.*\]|'
    r'array\[[^,]+,\s*(int|int8|int16|int32|int64|uint|uint8|uint16|uint32|uint64|'
    r'float|float32|float64|bool|char|byte)\])$')
MEMORY = re.compile(r'^(seq\[|string$|ref\b|proc\b|JsonNode$|Table\[|OrderedTable\[|'
                    r'CountTable\[|HashSet\[|OrderedSet\[|Deque\[|TableRef\[|StringTableRef$|'
                    r'XmlNode$|Option\[(seq|string|ref|JsonNode))')
HEADER = re.compile(r'^\s*(if|elif|else|when|of|case|for|while|try|except|finally|block)\b')
WRITE = r'(?:^\s*|:\s+|;\s*)%s\s*=(?!=)'
# (what else gives a variable memory: filled, grown, a field given)
FILL = (r'(?:\b%(n)s\s*\.\s*(?:add|setLen|setLenUninit|insert|incl|newSeq)\b|'
        r'\b(?:add|setLen|insert|incl|newSeq|newString)\s*\(\s*%(n)s\b|\b%(n)s\s*&=|'
        r'(?:^\s*|:\s+|;\s*)%(n)s\s*\.\s*\w+\s*=(?!=))')
ROUTINE = re.compile(r'^\s*(proc|func|iterator|method|template|macro|converter)\b')


def indent(l):
    return len(l) - len(l.lstrip(' '))


def code_of(l):
    """(the line without its comment and string literals)"""
    l = re.sub(r'"(?:[^"\\]|\\.)*"', '""', l)
    return l.split('#', 1)[0].rstrip()


# ---- which types have memory ----------------------------------------------------------------

def gather_types(paths):
    """{name: definition text} of every type the files declare"""
    defs = {}
    for p in paths:
        try:
            lines = open(p, encoding='utf-8', errors='replace').read().split('\n')
        except OSError:
            continue
        in_type = None
        for i, raw in enumerate(lines):
            l = code_of(raw)
            if re.match(r'^\s*type\b', l):
                in_type = indent(l)
                m = re.match(r'^\s*type\s+(\w+)\*?\s*(\[[^\]]*\])?\s*(\{\.[^}]*\.\})?\s*=\s*(.*)$', l)
                if m:
                    defs[m.group(1)] = body(lines, i, m.group(4), indent(l))
                continue
            if in_type is not None:
                if l.strip() and indent(l) <= in_type and not l.lstrip().startswith(')'):
                    in_type = None
                    continue
                m = re.match(r'^\s*(\w+)\*?\s*(\[[^\]]*\])?\s*(\{\.[^}]*\.\})?\s*=\s*(.*)$', l)
                if m and indent(l) == in_type + 2:
                    defs[m.group(1)] = body(lines, i, m.group(4), indent(l))
    return defs


def body(lines, i, first, ind):
    out = [first]
    for l in lines[i + 1:]:
        c = code_of(l)
        if c.strip() and indent(c) <= ind:
            break
        out.append(c)
    return '\n'.join(out)


def memory_types(defs):
    """the names of the declared types with memory (ref, seq, string, closures,
    or an object, tuple or array holding one)"""
    mem = set()
    changed = True

    def has_memory(t):
        t = t.strip()
        if not t:
            return False
        if MEMORY.match(t):
            return True
        if PLAIN.match(t):
            return False
        base = re.match(r'^(?:sink |var |lent |distinct )?(\w+)', t)
        if base and base.group(1) in mem:
            return True
        if base and base.group(1) in ('seq', 'string', 'ref', 'proc', 'JsonNode', 'Table'):
            return True
        if t.startswith(('tuple[', '(', 'array[', 'Option[')):
            return any(has_memory(x) for x in re.split(r'[\[\],():]', t)[1:] if x.strip())
        return False

    while changed:
        changed = False
        for name, d in defs.items():
            if name in mem:
                continue
            first = d.split('\n', 1)[0].strip()
            if re.match(r'^ref\b', first) or re.match(r'^proc\b', first):
                mem.add(name)
                changed = True
                continue
            if first.startswith('enum') or first.startswith('distinct ') and PLAIN.match(first[9:].strip()):
                continue
            if first.startswith(('object', 'tuple')) or first == '':
                for f in re.findall(r'(?:^|[,\n])\s*[\w*, ]+:\s*([^=\n#]+)', d.split('\n', 1)[-1] if '\n' in d else ''):
                    if has_memory(f):
                        mem.add(name)
                        changed = True
                        break
                else:
                    if first.startswith('tuple[') and has_memory(first):
                        mem.add(name)
                        changed = True
                continue
            if has_memory(first):
                mem.add(name)
                changed = True
    return mem


def type_has_memory(t, mem, plain_known):
    t = t.strip()
    if PLAIN.match(t):
        return False
    if MEMORY.match(t):
        return True
    base = re.match(r'^(\w+)', t)
    if not base:
        return True
    n = base.group(1)
    if n in mem:
        return True
    if n in plain_known:
        return False
    if t.startswith(('tuple[', '(', 'array[')):
        return any(type_has_memory(x, mem, plain_known) for x in re.split(r'[\[\],():]', t)[1:]
                   if x.strip() and not x.strip().isdigit() and ':' not in x)
    return True     # (a type of another library's: as if it had)


# ---- the writes ------------------------------------------------------------------------------

def in_closure(lines, at, top):
    """(line `at` is in a proc made inside the block: a routine of its own)"""
    ind = indent(lines[at])
    j = at - 1
    while j >= 0 and ind > top:
        l = code_of(lines[j])
        if l.strip() and indent(l) < ind:
            ind = indent(l)
            if re.search(r'\b(proc|func|iterator)\b|=>', l):
                return True
        j -= 1
    return False


def context(lines, at, top):
    """the headers (line, kind, indent) around line `at`, out to indent `top`"""
    out = []
    ind = indent(lines[at])
    c = code_of(lines[at])
    m = HEADER.match(c)
    if m and ':' in c and not c.endswith(':'):
        out.append((at, m.group(1), ind))      # (one line: `if c: x = y`)
    j = at - 1
    while j >= 0 and ind > top:
        l = code_of(lines[j])
        if l.strip() and indent(l) < ind:
            ind = indent(l)
            m = HEADER.match(l)
            if m and ind >= top:
                out.append((j, m.group(1), ind))
            if ind <= top:
                break
        j -= 1
    return list(reversed(out))


def chain_start(lines, h):
    """(the line of the `if` or `case` an `elif`/`else`/`of` header belongs to)"""
    line, kind, ind = h
    if kind in ('if', 'case', 'when', 'try'):
        return line
    j = line - 1
    while j >= 0:
        l = code_of(lines[j])
        if l.strip() and indent(l) == ind and re.match(r'^\s*(if|case|when|try)\b', l):
            return j
        if l.strip() and indent(l) < ind:
            return j
        j -= 1
    return line


def exclusive(lines, c1, c2):
    """two writes in different branches of the same `if` or `case`"""
    for a, b in zip(c1, c2):
        if a[0] == b[0]:
            continue
        if a[2] == b[2] and chain_start(lines, a) == chain_start(lines, b) and \
           a[1] in ('if', 'elif', 'else', 'of', 'when', 'try', 'except', 'finally') and \
           b[1] in ('if', 'elif', 'else', 'of', 'when', 'try', 'except', 'finally'):
            return True
        return False
    return False


def given_in_every_branch(lines, writes, top, name):
    """an `if` with an `else` (or a `case` with one) right in the block,
    each of its branches giving the value: given for sure after it"""
    for w, c in writes:
        line = code_of(lines[w])
        if len(c) == 1 and c[0][0] == w and ' else:' in line and \
           len(re.findall(WRITE % re.escape(name), line)) >= 2:
            return True              # (`if c: x = a else: x = b`)
    heads = {}
    for w, c in writes:
        if c and c[0][2] == top and c[0][1] in ('if', 'elif', 'else', 'of', 'except') and \
           (len(c) == 1 or c[1][1] in ('if', 'elif', 'else', 'of') and False):
            heads.setdefault(chain_start(lines, c[0]), set()).add(c[0][0])
    for start, given in heads.items():
        # the chain's branches: its headers at the same indent, up to the end
        ind = indent(lines[start])
        branches = []
        j = start
        while j < len(lines):
            l = code_of(lines[j])
            if l.strip() and indent(l) < ind:
                break
            if l.strip() and indent(l) == ind:
                m = HEADER.match(l)
                if j != start and not (m and m.group(1) in ('elif', 'else', 'of', 'except')):
                    break
                if m and m.group(1) in ('if', 'elif', 'else', 'of', 'except'):
                    branches.append((j, m.group(1)))
            j += 1
        if any(k == 'else' for _, k in branches) and all(b in given for b, _ in branches):
            return True
    return False


def empty_when(lines, c, name):
    """(a write under `if x == nil`, `if x.len == 0`: x holds nothing then)"""
    n = re.escape(name)
    empty = (r'\b%s\s*(==\s*nil|\.isNil|\.len\s*(==\s*0|<\s*1)|==\s*""|==\s*@\[\])' % n +
             r'|\bisNil\s*\(\s*%s\s*\)|\blen\s*\(\s*%s\s*\)\s*==\s*0' % (n, n))
    for line, kind, _ in reversed(c):
        if kind in ('if', 'elif'):
            head = code_of(lines[line])
            head = head.split(':', 1)[0] if head.count(':') else head
            if re.search(empty, head) and ' or ' not in head:
                return True
            return False
    return False


def leaves(lines, w):
    """(the write is followed by a `return` or a `raise` in its branch: it never
    reaches a later one)"""
    l = code_of(lines[w])
    if re.search(r';\s*(return|raise)\b', l):
        return True
    ind = indent(lines[w])
    m = HEADER.match(l)
    if m and ':' in l and not l.endswith(':'):
        return False                  # (one line `if c: x = y`)
    for j in range(w + 1, min(len(lines), w + 40)):
        c = code_of(lines[j])
        if not c.strip():
            continue
        if indent(c) < ind:
            return False
        if indent(c) == ind and re.match(r'^\s*(return|raise)\b', c):
            return True
    return False


def routine_start(lines, i):
    """(1 + the line a proc's signature that ends at line `i` starts at; 0: none)"""
    for j in range(i, max(-1, i - 12), -1):
        l = code_of(lines[j])
        if re.match(r'^\s*(proc|func|method|converter)\b', l):
            return j + 1
        if j < i and (l.rstrip().endswith('=') or not l.strip()):
            return 0
    return 0


def check(path, mem, plain_known):
    found = []
    try:
        lines = open(path, encoding='utf-8', errors='replace').read().split('\n')
    except OSError:
        return found
    for i, raw in enumerate(lines):
        l = code_of(raw)
        decls = []
        m = re.match(r'^(\s*)var\s+(\w+(?:\s*,\s*\w+)*)\s*:\s*([^=]+?)\s*$', l)
        if m:
            for n in m.group(2).split(','):
                decls.append((n.strip(), m.group(3), len(m.group(1))))
        elif re.match(r'^\s*var\s*$', l):
            j = i + 1
            while j < len(lines) and (not lines[j].strip() or indent(lines[j]) > indent(l)):
                mm = re.match(r'^\s*([\w, ]+?)\s*:\s*([^=]+?)\s*$', code_of(lines[j]))
                if mm:
                    for n in mm.group(1).split(','):
                        decls.append((n.strip(), mm.group(2), indent(l)))
                j += 1
        # (a proc's `result`: declared at its start, without a value)
        r = re.search(r'\)\s*:\s*([^={]+?)\s*(\{\.[^}]*\.\})?\s*=\s*$', l)
        if r and routine_start(lines, i):
            j = i + 1
            while j < len(lines) and not code_of(lines[j]).strip():
                j += 1
            if j < len(lines) and indent(lines[j]) > indent(lines[routine_start(lines, i) - 1]):
                decls.append(('result', r.group(1), indent(lines[j]), i + 1))
        for decl in decls:
            name, typ, top = decl[:3]
            first = decl[3] if len(decl) > 3 else i + 1
            if '{.noinit.}' in typ or not type_has_memory(typ, mem, plain_known):
                continue
            writes = []
            k = first
            while k < len(lines):
                c = code_of(lines[k])
                if c.strip() and indent(c) < top:
                    break
                if c.strip() and indent(c) == top and ROUTINE.match(c):
                    break
                given = re.search(WRITE % re.escape(name), c)
                if (given or re.search(FILL % {'n': re.escape(name)}, c)) and \
                   not in_closure(lines, k, top):
                    # (a `block:` is no branch)
                    writes.append((k, [h for h in context(lines, k, top) if h[1] != 'block'],
                                   bool(given)))
                k += 1
            for n2, (w2, c2, given) in enumerate(writes):
                if any(not c1 for _, c1, _ in writes[:n2]) or \
                   given_in_every_branch(lines, [(w, c) for w, c, g in writes[:n2] if g], top, name):
                    break                    # (given for sure before: freed)
                if not given or any(h[1] in ('for', 'while') for h in c2):
                    continue                 # (filled, not given; or in a loop of its own: freed)
                if empty_when(lines, c2, name):
                    continue                 # (only when it holds nothing: none to free)
                earlier = [(w1, c1) for w1, c1, _ in writes[:n2]
                           if w1 != w2 and not exclusive(lines, c1, c2) and not leaves(lines, w1)]
                if earlier:
                    found.append((path, i + 1, name, typ, earlier[0][0] + 1, w2 + 1))
                    break
    return found


def files(args):
    out = []
    for a in args:
        if os.path.isdir(a):
            # (what builds made -- a build/ folder anywhere -- is not looked at)
            out += [f for f in glob.glob(os.path.join(a, '**', '*.nim'), recursive=True)
                    if os.sep + 'build' + os.sep not in f]
        else:
            out.append(a)
    return sorted(set(out))


def main():
    args = sys.argv[1:] or ['src', 'examples', 'tools', 'tests', 'tutorials']
    paths = files(args)
    here = os.path.dirname(os.path.abspath(__file__))
    kit = files([os.path.join(here, '..', 'src')])
    defs = gather_types(paths + kit)
    mem = memory_types(defs)
    plain_known = set(defs) - mem
    found = []
    for p in paths:
        found += check(p, mem, plain_known)
    for path, line, name, typ, w1, w2 in found:
        print(f"{path}:{line}: var {name}: {typ} -- given at {w1} in a branch or loop, "
              f"then at {w2}: give it its value where it is declared")
    print(f"writecheck: {len(paths)} files, {len(found)} vars given twice")
    sys.exit(1 if found else 0)


if __name__ == '__main__':
    main()
