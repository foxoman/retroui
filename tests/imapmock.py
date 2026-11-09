#!/usr/bin/env python3
"""A small IMAP4rev1 and SMTP server for the tests of retroui/imap,
retroui/smtp and Retro Mail's IMAP accounts (tests/test_imap.nim): one
account (me@example.test, password "secret"), its folders with
special-use flags, UIDs, flags and keywords, SEARCH, FETCH of headers and
whole messages, STORE, COPY, MOVE, EXPUNGE, APPEND, CREATE, CONDSTORE's
counters; SMTP with AUTH PLAIN and LOGIN, the messages it takes kept.
With a certificate and a key, both also speak TLS (IMAP on its own port,
and STARTTLS on both). State lives in memory: "ADMIN STATE" on the IMAP
port answers it as JSON; "ADMIN NEWMAIL" puts a message in the Inbox.

    python3 tests/imapmock.py IMAPPORT SMTPPORT [CERT KEY TLSPORT]

Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net
"""
import json, re, socket, ssl, sys, threading, time, base64

LOCK = threading.Lock()
USER, PASSWORD = "me@example.test", "secret"
NOW = time.time()

def msg(i, frm, subj, body, days_ago=0, extra="", at=None):
    t = at if at is not None else NOW - days_ago * 86400 - i * 60
    date = time.strftime("%a, %d %b %Y %H:%M:%S +0000", time.gmtime(t))
    raw = ("From: %s\r\nTo: Me <me@example.test>\r\nSubject: %s\r\nDate: %s\r\n"
           "Message-ID: <m%d@example.test>\r\n%sMIME-Version: 1.0\r\n"
           "Content-Type: text/plain; charset=utf-8\r\n\r\n%s\r\n") % (frm, subj, date, i, extra, body)
    return {"raw": raw.encode(), "flags": [], "date": t}

class Box:
    def __init__(self, name, special=""):
        self.name, self.special = name, special
        self.validity = 1000 + len(name)
        self.next = 1
        self.msgs = {}           # uid -> msg
        self.modseq = 1
    def add(self, m):
        uid = self.next
        self.next += 1
        m = dict(m)
        m["modseq"] = self.modseq = self.modseq + 1
        self.msgs[uid] = m
        return uid

BOXES = {}
def box(name, special=""):
    BOXES[name] = Box(name, special)
    return BOXES[name]

inbox = box("INBOX")
box("Sent", "\\Sent")
box("Drafts", "\\Drafts")
box("Trash", "\\Trash")
box("Junk", "\\Junk")
box("Archive", "\\Archive")
box("Work")
box("Entw&APw-rfe")                       # (Entwürfe: a name in modified UTF-7)
inbox.add(msg(1, "Ali <ali@example.test>", "Hello from Ali", "Salam, how are you?"))
u = inbox.add(msg(2, "Sara <sara@example.test>", "The report", "Here it is.", 1))
inbox.msgs[u]["flags"] = ["\\Seen"]
u = inbox.add(msg(3, "Omar <omar@example.test>", "=?UTF-8?B?2YXYsdit2KjYpw==?=", "Marhaba.", 2,
                  "Importance: high\r\n"))
inbox.msgs[u]["flags"] = ["\\Flagged", "Work"]
inbox.add(msg(4, "Old <old@example.test>", "An old one", "Long ago.", 400))
SENT_MAIL = []                             # (what SMTP took)

def quote(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'

def internal(t):
    return time.strftime("%d-%b-%Y %H:%M:%S +0000", time.gmtime(t))

def parse_set(s, uids):
    """A UID set ("1:3,7,9:*") as the UIDs of `uids` in it."""
    top = max(uids) if uids else 0
    out = set()
    for part in s.split(","):
        if ":" in part:
            a, b = part.split(":")
            a = top if a == "*" else int(a)
            b = top if b == "*" else int(b)
            lo, hi = min(a, b), max(a, b)
            out |= {u for u in uids if lo <= u <= hi}
            if "*" in part and uids and lo > top: out.add(top)   # (n:* names the last one)
        else:
            v = top if part == "*" else int(part)
            if v in uids: out.add(v)
    return sorted(out)

def tokens(s):
    """The words of a command: atoms, quoted strings, (lists) kept whole."""
    out, i = [], 0
    while i < len(s):
        c = s[i]
        if c == " ": i += 1; continue
        if c == '"':
            j, v = i + 1, ""
            while s[j] != '"':
                if s[j] == "\\": j += 1
                v += s[j]; j += 1
            out.append(v); i = j + 1
        elif c == "(":
            depth, j = 0, i
            while True:
                if s[j] == "(": depth += 1
                elif s[j] == ")":
                    depth -= 1
                    if depth == 0: break
                j += 1
            out.append(s[i:j + 1]); i = j + 1
        else:
            j = i
            while j < len(s) and s[j] != " ":
                if s[j] == "[":
                    j = s.index("]", j)
                j += 1
            out.append(s[i:j]); i = j
    return out

class Conn:
    def __init__(self, sock, tls_ctx):
        self.s, self.ctx = sock, tls_ctx
        self.buf = b""
        self.authed = False
        self.sel = None
        self.condstore = False
    def send(self, b):
        if isinstance(b, str): b = b.encode()
        self.s.sendall(b)
    def line(self):
        while b"\r\n" not in self.buf:
            d = self.s.recv(65536)
            if not d: raise EOFError
            self.buf += d
        l, self.buf = self.buf.split(b"\r\n", 1)
        return l
    def read(self, n):
        while len(self.buf) < n:
            d = self.s.recv(65536)
            if not d: raise EOFError
            self.buf += d
        b, self.buf = self.buf[:n], self.buf[n:]
        return b
    def full(self):
        """A command line with its literals inline (as text: latin-1)."""
        l = self.line()
        while True:
            m = re.search(rb"\{(\d+)(\+?)\}$", l)
            if not m: break
            n = int(m.group(1))
            if not m.group(2): self.send("+ go on\r\n")
            l = l[:m.start()] + b'"' + self.read(n).replace(b"\\", b"\\\\").replace(b'"', b'\\"') + b'"' + self.line()
        return l.decode("latin-1")

def caps(c):
    base = "IMAP4rev1 LITERAL+ SASL-IR UIDPLUS MOVE SPECIAL-USE CONDSTORE ENABLE IDLE NAMESPACE"
    if c.ctx and not isinstance(c.s, ssl.SSLSocket): base += " STARTTLS"
    return base + (" AUTH=PLAIN" if not c.authed else "")

def fetch_items(c, b, uid, m, what):
    parts = ["UID %d" % uid]
    want = what.upper()
    if "FLAGS" in want: parts.append("FLAGS (%s)" % " ".join(m["flags"]))
    if "RFC822.SIZE" in want: parts.append("RFC822.SIZE %d" % len(m["raw"]))
    if "INTERNALDATE" in want: parts.append('INTERNALDATE "%s"' % internal(m["date"]))
    if "MODSEQ" in want or c.condstore: parts.append("MODSEQ (%d)" % m["modseq"])
    lit = None
    hm = re.search(r"BODY(\.PEEK)?\[HEADER\.FIELDS \(([^)]*)\)\]", what, re.I)
    if hm:
        names = [n.lower() for n in hm.group(2).split()]
        head = m["raw"].split(b"\r\n\r\n", 1)[0].split(b"\r\n")
        keep = b"".join(h + b"\r\n" for h in head if h.split(b":", 1)[0].lower().decode() in names) + b"\r\n"
        lit = ("BODY[HEADER.FIELDS (%s)]" % hm.group(2).upper(), keep)
    elif re.search(r"BODY(\.PEEK)?\[\]", what, re.I):
        lit = ("BODY[]", m["raw"])
        if not re.search(r"\.PEEK", what, re.I) and "\\Seen" not in m["flags"]:
            m["flags"].append("\\Seen")
    head = "* %d FETCH (%s" % (sorted(b.msgs).index(uid) + 1, " ".join(parts))
    if lit:
        c.send(head + " %s {%d}\r\n" % (lit[0], len(lit[1])))
        c.send(lit[1] + b")\r\n")
    else:
        c.send(head + ")\r\n")

def search(b, crit):
    uids = sorted(b.msgs)
    w = tokens(crit)
    out = set(uids)
    i = 0
    while i < len(w):
        k = w[i].upper()
        if k == "ALL": pass
        elif k == "UID":
            out &= set(parse_set(w[i + 1], uids)); i += 1
        elif k == "SINCE":
            t = time.mktime(time.strptime(w[i + 1], "%d-%b-%Y")) - time.timezone
            out &= {u for u in uids if b.msgs[u]["date"] >= t - 86400}; i += 1
        elif k == "UNSEEN":
            out &= {u for u in uids if "\\Seen" not in b.msgs[u]["flags"]}
        elif k == "TEXT":
            q = w[i + 1].lower().encode(); i += 1
            out &= {u for u in uids if q in b.msgs[u]["raw"].lower()}
        i += 1
    return sorted(out)

def imap_session(sock, tls_ctx, implicit):
    try:
        if implicit: sock = tls_ctx.wrap_socket(sock, server_side=True)
        c = Conn(sock, tls_ctx)
        c.send("* OK [CAPABILITY %s] mock IMAP ready\r\n" % caps(c))
        while True:
            l = c.full()
            if not l: continue
            sp = l.split(" ", 2)
            tag, cmd = sp[0], sp[1].upper() if len(sp) > 1 else ""
            rest = sp[2] if len(sp) > 2 else ""
            with LOCK:
                if handle(c, tag, cmd, rest) == "bye": return
    except (EOFError, OSError, ssl.SSLError):
        pass
    finally:
        try: sock.close()
        except OSError: pass

def handle(c, tag, cmd, rest):
    ok = lambda text="done": c.send("%s OK %s\r\n" % (tag, text))
    no = lambda text: c.send("%s NO %s\r\n" % (tag, text))
    if cmd == "CAPABILITY":
        c.send("* CAPABILITY %s\r\n" % caps(c)); ok()
    elif cmd == "NOOP": ok()
    elif cmd == "LOGOUT":
        c.send("* BYE see you\r\n"); ok(); return "bye"
    elif cmd == "STARTTLS":
        ok("begin TLS")
        c.s = c.ctx.wrap_socket(c.s, server_side=True)
        c.buf = b""
    elif cmd == "LOGIN":
        u, p = tokens(rest)[:2]
        if u == USER and p == PASSWORD:
            c.authed = True; ok("[CAPABILITY %s] signed in" % caps(c))
        else: no("[AUTHENTICATIONFAILED] wrong user name or password")
    elif cmd == "AUTHENTICATE":
        w = rest.split()
        data = w[1] if len(w) > 1 else None
        if data is None:
            c.send("+ \r\n"); data = c.line().decode()
        parts = base64.b64decode(data).split(b"\0")
        if len(parts) == 3 and parts[1].decode() == USER and parts[2].decode() == PASSWORD:
            c.authed = True; ok("[CAPABILITY %s] signed in" % caps(c))
        else: no("[AUTHENTICATIONFAILED] wrong user name or password")
    elif cmd == "ADMIN":
        w = rest.split(" ", 1)
        if w[0].upper() == "STATE":
            st = {n: {str(u): {"flags": m["flags"], "subject": re.search(rb"Subject: ([^\r]*)", m["raw"]).group(1).decode()}
                      for u, m in b.msgs.items()} for n, b in BOXES.items()}
            st["_sent"] = [s.decode("latin-1") for s in SENT_MAIL]
            j = json.dumps(st)
            c.send("* ADMIN {%d}\r\n%s\r\n" % (len(j.encode()), j)); ok()
        elif w[0].upper() == "NEWMAIL":
            inbox.add(msg(100 + inbox.next, "New <new@example.test>", "Brand new", "Just came.",
                          at=time.time()))
            ok()
    elif not c.authed:
        c.send("%s BAD sign in first\r\n" % tag)
    elif cmd == "ENABLE":
        if "CONDSTORE" in rest.upper(): c.condstore = True
        c.send("* ENABLED %s\r\n" % rest); ok()
    elif cmd == "LIST":
        for n, b in BOXES.items():
            flags = ["\\HasNoChildren"] + ([b.special] if b.special else [])
            c.send('* LIST (%s) "/" %s\r\n' % (" ".join(flags), quote(n)))
        ok()
    elif cmd in ("SELECT", "EXAMINE"):
        w = tokens(rest)
        b = BOXES.get(w[0]) or BOXES.get(w[0].upper())
        if b is None: return no("no such folder")
        if len(w) > 1 and "CONDSTORE" in w[1].upper(): c.condstore = True
        c.sel = b
        c.send("* %d EXISTS\r\n* 0 RECENT\r\n" % len(b.msgs))
        c.send("* OK [UIDVALIDITY %d] valid\r\n* OK [UIDNEXT %d] next\r\n" % (b.validity, b.next))
        c.send("* OK [HIGHESTMODSEQ %d] counter\r\n" % b.modseq)
        c.send("* FLAGS (\\Seen \\Flagged \\Deleted \\Draft \\Answered)\r\n")
        ok("[READ-%s] selected" % ("ONLY" if cmd == "EXAMINE" else "WRITE"))
    elif cmd == "STATUS":
        w = tokens(rest)
        b = BOXES.get(w[0])
        if b is None: return no("no such folder")
        unseen = len([1 for m in b.msgs.values() if "\\Seen" not in m["flags"]])
        c.send("* STATUS %s (MESSAGES %d UNSEEN %d UIDNEXT %d UIDVALIDITY %d)\r\n" %
               (quote(b.name), len(b.msgs), unseen, b.next, b.validity))
        ok()
    elif cmd == "CREATE":
        n = tokens(rest)[0]
        if n in BOXES: return no("[ALREADYEXISTS] it is there")
        box(n); ok()
    elif cmd == "APPEND":
        w = tokens(rest)
        b = BOXES.get(w[0])
        if b is None: return no("[TRYCREATE] no such folder")
        flags = w[1][1:-1].split() if len(w) > 2 and w[1].startswith("(") else []
        raw = w[-1].encode("latin-1")
        uid = b.add({"raw": raw, "flags": flags, "date": time.time()})
        ok("[APPENDUID %d %d] appended" % (b.validity, uid))
    elif cmd == "UID":
        sub, _, args = rest.partition(" ")
        sub = sub.upper()
        b = c.sel
        if b is None: return c.send("%s BAD select a folder first\r\n" % tag)
        if sub == "SEARCH":
            c.send("* SEARCH %s\r\n" % " ".join(map(str, search(b, args)))); ok()
        elif sub == "FETCH":
            w = tokens(args)
            uids = parse_set(w[0], sorted(b.msgs))
            changed = 0
            m = re.search(r"\(CHANGEDSINCE (\d+)\)", args, re.I)
            if m: changed = int(m.group(1))
            for u in uids:
                if changed and b.msgs[u]["modseq"] <= changed: continue
                fetch_items(c, b, u, b.msgs[u], w[1])
            ok()
        elif sub == "STORE":
            w = tokens(args)
            uids = parse_set(w[0], sorted(b.msgs))
            op = w[1].upper()
            flags = w[2][1:-1].split()
            for u in uids:
                m = b.msgs[u]
                if op.startswith("+"):
                    for f in flags:
                        if f not in m["flags"]: m["flags"].append(f)
                elif op.startswith("-"):
                    m["flags"] = [f for f in m["flags"] if f not in flags]
                else: m["flags"] = flags
                b.modseq += 1
                m["modseq"] = b.modseq
            ok()
        elif sub in ("COPY", "MOVE"):
            w = tokens(args)
            uids = parse_set(w[0], sorted(b.msgs))
            dest = BOXES.get(w[1])
            if dest is None: return no("[TRYCREATE] no such folder")
            new = [dest.add(dict(b.msgs[u], flags=list(b.msgs[u]["flags"]))) for u in uids]
            code = "[COPYUID %d %s %s]" % (dest.validity, ",".join(map(str, uids)), ",".join(map(str, new)))
            if sub == "MOVE":
                c.send("* OK %s moved\r\n" % code)
                for u in uids:
                    c.send("* %d EXPUNGE\r\n" % (sorted(b.msgs).index(u) + 1))
                    del b.msgs[u]
                ok("moved")
            else: ok(code + " copied")
        elif sub == "EXPUNGE":
            uids = parse_set(args, sorted(b.msgs))
            for u in uids:
                if "\\Deleted" in b.msgs[u]["flags"]:
                    c.send("* %d EXPUNGE\r\n" % (sorted(b.msgs).index(u) + 1))
                    del b.msgs[u]
            ok()
        else: c.send("%s BAD unknown UID command\r\n" % tag)
    elif cmd == "EXPUNGE":
        b = c.sel
        for u in sorted(b.msgs):
            if "\\Deleted" in b.msgs[u]["flags"]:
                c.send("* %d EXPUNGE\r\n" % (sorted(b.msgs).index(u) + 1))
                del b.msgs[u]
        ok()
    else:
        c.send("%s BAD unknown command %s\r\n" % (tag, cmd))

def smtp_session(sock, tls_ctx):
    c = Conn(sock, tls_ctx)
    c.send("220 mock ESMTP ready\r\n")
    authed = False
    rcpts = []
    try:
        while True:
            l = c.line().decode("latin-1")
            u = l.upper()
            if u.startswith("EHLO"):
                ext = ["250-mock", "250-SIZE 10000000", "250-8BITMIME", "250-AUTH PLAIN LOGIN"]
                if c.ctx and not isinstance(c.s, ssl.SSLSocket): ext.append("250-STARTTLS")
                ext.append("250 SMTPUTF8")
                c.send("\r\n".join(ext) + "\r\n")
            elif u.startswith("STARTTLS"):
                c.send("220 go ahead\r\n")
                c.s = c.ctx.wrap_socket(c.s, server_side=True); c.buf = b""
            elif u.startswith("AUTH PLAIN"):
                p = base64.b64decode(l.split()[2]).split(b"\0")
                authed = p[1].decode() == USER and p[2].decode() == PASSWORD
                c.send("235 fine\r\n" if authed else "535 5.7.8 wrong user name or password\r\n")
            elif u.startswith("AUTH LOGIN"):
                c.send("334 VXNlcm5hbWU6\r\n"); user = base64.b64decode(c.line()).decode()
                c.send("334 UGFzc3dvcmQ6\r\n"); pw = base64.b64decode(c.line()).decode()
                authed = user == USER and pw == PASSWORD
                c.send("235 fine\r\n" if authed else "535 5.7.8 wrong user name or password\r\n")
            elif u.startswith("MAIL FROM"):
                rcpts = []
                c.send("250 ok\r\n" if authed else "530 5.7.0 sign in first\r\n")
            elif u.startswith("RCPT TO"):
                to = l[l.index("<") + 1:l.index(">")]
                if to.endswith("@nowhere.test"): c.send("550 5.1.1 no such person\r\n")
                else:
                    rcpts.append(to); c.send("250 ok\r\n")
            elif u == "DATA":
                c.send("354 go on\r\n")
                data = b""
                while True:
                    ln = c.line()
                    if ln == b".": break
                    if ln.startswith(b".."): ln = ln[1:]
                    data += ln + b"\r\n"
                with LOCK: SENT_MAIL.append(b"RCPT " + ",".join(rcpts).encode() + b"\r\n" + data)
                c.send("250 2.0.0 queued\r\n")
            elif u == "RSET": c.send("250 ok\r\n")
            elif u == "QUIT":
                c.send("221 bye\r\n"); return
            else: c.send("502 what?\r\n")
    except (EOFError, OSError, ssl.SSLError):
        pass
    finally:
        try: c.s.close()
        except OSError: pass

def serve(port, fn):
    s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("127.0.0.1", port)); s.listen(16)
    while True:
        k, _ = s.accept()
        threading.Thread(target=fn, args=(k,), daemon=True).start()

if __name__ == "__main__":
    imap_port, smtp_port = int(sys.argv[1]), int(sys.argv[2])
    ctx = None
    if len(sys.argv) > 5:
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain(sys.argv[3], sys.argv[4])
        threading.Thread(target=serve, args=(int(sys.argv[5]), lambda k: imap_session(k, ctx, True)),
                         daemon=True).start()
    threading.Thread(target=serve, args=(smtp_port, lambda k: smtp_session(k, ctx)), daemon=True).start()
    serve(imap_port, lambda k: imap_session(k, ctx, False))
