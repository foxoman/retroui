#!/usr/bin/env python3
"""Mail servers for the tests of POP3, JMAP and Exchange (EWS): one mailbox
each, in memory, on 127.0.0.1 -- the three ports it chose printed first,
on one line ("pop3 jmap ews").

    python3 tests/protomock.py

POP3: USER me@example.test / PASS secret; UIDL, LIST, STAT, TOP, RETR,
DELE, RSET, QUIT, CAPA, AUTH PLAIN. JMAP: "Authorization: Bearer
token-123"; the session, Mailbox/get, Email/query, Email/get,
Email/changes, Email/set, Email/import, Identity/get,
EmailSubmission/set, upload, download. EWS: Basic is refused (as many
Exchange servers do), NTLM (v2) checked -- user EXAMPLE\\me, password
secret -- GetFolder, FindFolder, SyncFolderItems, GetItem (with its
MIME), UpdateItem, MoveItem, DeleteItem, CreateItem, FindItem.

Each takes "GET /admin/newmail" (JMAP's and EWS's ports) or "ADMIN
NEWMAIL" (POP3's) to have a message come, and "GET /admin/state" for what
it holds (JSON).
"""
import base64, hashlib, hmac, json, re, socket, struct, sys, threading, time, html
from email.utils import formatdate

LOCK = threading.Lock()


def msg(n, frm, subject, body, at):
    return ("From: %s\r\nTo: Me <me@example.test>\r\nSubject: %s\r\nDate: %s\r\n"
            "Message-ID: <m%d@example.test>\r\nContent-Type: text/plain; charset=utf-8\r\n\r\n%s\r\n"
            % (frm, subject, formatdate(at), n, body)).encode()


NOW = time.time()

# ---- POP3 ---------------------------------------------------------------------------------
POP = [{"uid": "u0", "raw": msg(0, "Old <old@example.test>", "From long ago", "Old.", NOW - 400 * 86400)},
       {"uid": "u1", "raw": msg(1, "Ali <ali@example.test>", "Hello from POP", "Salam!", NOW - 3600)},
       {"uid": "u2", "raw": msg(2, "Sara <sara@example.test>", "Second", "Two.", NOW - 1800)}]
POP_NEXT = [3]


def pop_session(s):
    f = s.makefile("rb")
    send = lambda t: s.sendall(t if isinstance(t, bytes) else t.encode())
    send("+OK mock POP3 ready\r\n")
    authed = False
    user = None
    deleted = set()
    try:
        while True:
            line = f.readline()
            if not line:
                return
            l = line.decode("latin-1").rstrip("\r\n")
            cmd, _, arg = l.partition(" ")
            cmd = cmd.upper()
            with LOCK:
                box = list(POP)
            if cmd == "CAPA":
                send("+OK\r\nUSER\r\nUIDL\r\nTOP\r\nSASL PLAIN\r\n.\r\n")
            elif cmd == "USER":
                user = arg; send("+OK\r\n")
            elif cmd == "PASS":
                if user == "me@example.test" and arg == "secret":
                    authed = True; send("+OK signed in\r\n")
                else:
                    send("-ERR [AUTH] wrong user name or password\r\n")
            elif cmd == "AUTH" and arg.upper().startswith("PLAIN "):
                p = base64.b64decode(arg.split()[1]).split(b"\0")
                authed = p[1] == b"me@example.test" and p[2] == b"secret"
                send("+OK\r\n" if authed else "-ERR [AUTH] refused\r\n")
            elif cmd == "ADMIN" and arg.upper() == "NEWMAIL":
                with LOCK:
                    n = POP_NEXT[0]; POP_NEXT[0] += 1
                    POP.append({"uid": "u%d" % n, "raw": msg(n, "New <new@example.test>", "POP news", "Fresh.", time.time())})
                send("+OK\r\n")
            elif cmd == "QUIT":
                with LOCK:
                    for uid in deleted:
                        POP[:] = [m for m in POP if m["uid"] != uid]
                send("+OK bye\r\n"); return
            elif not authed:
                send("-ERR sign in first\r\n")
            elif cmd == "STAT":
                send("+OK %d %d\r\n" % (len(box), sum(len(m["raw"]) for m in box)))
            elif cmd == "UIDL":
                send("+OK\r\n" + "".join("%d %s\r\n" % (i + 1, m["uid"]) for i, m in enumerate(box)
                                          if m["uid"] not in deleted) + ".\r\n")
            elif cmd == "LIST":
                send("+OK\r\n" + "".join("%d %d\r\n" % (i + 1, len(m["raw"])) for i, m in enumerate(box)
                                          if m["uid"] not in deleted) + ".\r\n")
            elif cmd in ("RETR", "TOP"):
                w = arg.split()
                i = int(w[0]) - 1
                if i < 0 or i >= len(box):
                    send("-ERR no such message\r\n"); continue
                raw = box[i]["raw"]
                if cmd == "TOP":
                    raw = raw.split(b"\r\n\r\n", 1)[0] + b"\r\n\r\n"
                lines = [(b"." + x if x.startswith(b".") else x) for x in raw.split(b"\r\n")]
                send(b"+OK\r\n" + b"\r\n".join(lines).rstrip(b"\r\n") + b"\r\n.\r\n")
            elif cmd == "DELE":
                i = int(arg) - 1
                deleted.add(box[i]["uid"]); send("+OK marked\r\n")
            elif cmd == "RSET":
                deleted.clear(); send("+OK\r\n")
            elif cmd == "NOOP":
                send("+OK\r\n")
            else:
                send("-ERR what?\r\n")
    except OSError:
        pass
    finally:
        s.close()


# ---- the HTTP ones -------------------------------------------------------------------------

def http_serve(conn, handler):
    f = conn.makefile("rb")
    try:
        while True:
            line = f.readline()
            if not line:
                return
            meth, path, _ = line.decode().split(" ", 2)
            headers = {}
            while True:
                h = f.readline().decode().rstrip("\r\n")
                if not h:
                    break
                k, _, v = h.partition(":")
                headers[k.strip().lower()] = v.strip()
            body = f.read(int(headers.get("content-length", "0") or 0))
            status, extra, out = handler(conn, meth, path, headers, body)
            if isinstance(out, str):
                out = out.encode()
            head = "HTTP/1.1 %d X\r\nContent-Length: %d\r\n" % (status, len(out))
            for k, v in extra:
                head += "%s: %s\r\n" % (k, v)
            conn.sendall(head.encode() + b"\r\n" + out)
            if any(k.lower() == "connection" and v == "close" for k, v in extra):
                return
    except (OSError, ValueError):
        pass
    except Exception:
        import traceback
        traceback.print_exc(file=sys.stderr)
    finally:
        conn.close()


# ---- JMAP ---------------------------------------------------------------------------------
JM = {"state": 1, "mailboxes": [
    {"id": "mb-in", "name": "Inbox", "role": "inbox", "parentId": None},
    {"id": "mb-sent", "name": "Sent", "role": "sent", "parentId": None},
    {"id": "mb-trash", "name": "Trash", "role": "trash", "parentId": None},
    {"id": "mb-work", "name": "Work", "role": None, "parentId": "mb-in"}],
    "emails": {}, "blobs": {}, "log": [], "sent": []}


def jm_add(eid, frm_name, frm, subject, body, at, mbox="mb-in", keywords=None, created=1):
    raw = msg(len(JM["emails"]) + 10, "%s <%s>" % (frm_name, frm), subject, body, at)
    blob = "blob-" + eid
    JM["blobs"][blob] = raw
    JM["emails"][eid] = {"id": eid, "blobId": blob, "threadId": "t-" + eid, "mailboxIds": {mbox: True},
                         "keywords": keywords or {}, "size": len(raw),
                         "receivedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(at)),
                         "messageId": ["m-%s@example.test" % eid], "inReplyTo": None, "references": None,
                         "from": [{"name": frm_name, "email": frm}],
                         "to": [{"name": "Me", "email": "me@example.test"}], "cc": [],
                         "subject": subject, "preview": body[:40], "hasAttachment": False,
                         "_created": created, "_updated": created}


jm_add("e1", "Omar", "omar@example.test", "JMAP hello", "Hello over JMAP.", NOW - 7200, keywords={"$flagged": True})
jm_add("e2", "Huda", "huda@example.test", "Read already", "Old news.", NOW - 3600, keywords={"$seen": True})
jm_add("e3", "Zaid", "zaid@example.test", "Project", "In Work.", NOW - 600, mbox="mb-work")
JM["destroyed"] = []


def jm_handle(conn, meth, path, headers, body):
    if path.startswith("/admin/"):
        with LOCK:
            if path == "/admin/newmail":
                JM["state"] += 1
                jm_add("e%d" % (len(JM["emails"]) + 10), "New", "new@example.test", "JMAP news", "Fresh.",
                       time.time(), created=JM["state"])
            return 200, [], json.dumps({k: v for k, v in JM.items() if k != "blobs"}, default=str)
    if headers.get("authorization") != "Bearer token-123":
        return 401, [("WWW-Authenticate", "Bearer")], "{}"
    host = "http://127.0.0.1:%d" % JM_PORT
    if path in ("/.well-known/jmap", "/jmap/session"):
        return 200, [("Content-Type", "application/json")], json.dumps({
            "capabilities": {"urn:ietf:params:jmap:core": {"maxCallsInRequest": 16},
                             "urn:ietf:params:jmap:mail": {}, "urn:ietf:params:jmap:submission": {}},
            "accounts": {"A1": {"name": "me@example.test"}},
            "primaryAccounts": {"urn:ietf:params:jmap:mail": "A1", "urn:ietf:params:jmap:submission": "A1"},
            "username": "me@example.test", "apiUrl": "/jmap/api",
            "downloadUrl": host + "/jmap/download/{accountId}/{blobId}/{name}?type={type}",
            "uploadUrl": host + "/jmap/upload/{accountId}/", "state": "s1"})
    if path.startswith("/jmap/download/"):
        blob = path.split("/")[4]
        with LOCK:
            if blob not in JM["blobs"]:
                return 404, [], "no such blob"
            return 200, [("Content-Type", "message/rfc822")], JM["blobs"][blob]
    if path.startswith("/jmap/upload/"):
        with LOCK:
            bid = "up-%d" % len(JM["blobs"])
            JM["blobs"][bid] = body
        return 201, [], json.dumps({"accountId": "A1", "blobId": bid, "type": "message/rfc822", "size": len(body)})
    if path != "/jmap/api":
        return 404, [], "{}"
    req = json.loads(body)
    out = []
    with LOCK:
        for name, args, cid in req["methodCalls"]:
            JM["log"].append(name)
            out.append(jm_method(name, args, cid))
    return 200, [("Content-Type", "application/json")], json.dumps({"methodResponses": out, "sessionState": "s1"})


def jm_method(name, args, cid):
    E = JM["emails"]
    st = str(JM["state"])
    if name == "Mailbox/get":
        lst = []
        for b in JM["mailboxes"]:
            inb = [e for e in E.values() if b["id"] in e["mailboxIds"]]
            lst.append(dict(b, totalEmails=len(inb), unreadEmails=sum(1 for e in inb if "$seen" not in e["keywords"])))
        if args.get("ids") == []:
            lst = []
        return [name, {"accountId": "A1", "state": st, "list": lst}, cid]
    if name == "Email/query":
        f = args.get("filter") or {}
        res = list(E.values())
        if "inMailbox" in f:
            res = [e for e in res if f["inMailbox"] in e["mailboxIds"]]
        if "text" in f:
            q = f["text"].lower()
            res = [e for e in res if q in (e["subject"] + e["preview"]).lower()]
        res.sort(key=lambda e: e["receivedAt"], reverse=True)
        pos, lim = args.get("position", 0), args.get("limit", 100)
        return [name, {"accountId": "A1", "ids": [e["id"] for e in res[pos:pos + lim]], "total": len(res),
                       "position": pos, "queryState": st}, cid]
    if name == "Email/get":
        ids = args.get("ids")
        if ids == []:
            return [name, {"accountId": "A1", "state": st, "list": [], "notFound": []}, cid]
        lst = []
        for i in ids:
            if i in E:
                e = {k: v for k, v in E[i].items() if not k.startswith("_")}
                if args.get("fetchHTMLBodyValues"):
                    text = JM["blobs"][e["blobId"]].split(b"\r\n\r\n", 1)[1].decode()
                    e["bodyValues"] = {"1": {"value": text}}
                    e["textBody"] = [{"partId": "1", "type": "text/plain"}]
                    e["htmlBody"] = [{"partId": "1", "type": "text/plain"}]
                    e["attachments"] = []
                lst.append(e)
        return [name, {"accountId": "A1", "state": st, "list": lst,
                       "notFound": [i for i in ids if i not in E]}, cid]
    if name == "Email/changes":
        since = int(args["sinceState"])
        if since < 1:
            return ["error", {"type": "cannotCalculateChanges"}, cid]
        created = [e["id"] for e in E.values() if e["_created"] > since]
        updated = [e["id"] for e in E.values() if e["_updated"] > since and e["_created"] <= since]
        destroyed = [d for (d, s) in JM["destroyed"] if s > since]
        return [name, {"accountId": "A1", "oldState": str(since), "newState": st, "hasMoreChanges": False,
                       "created": created, "updated": updated, "destroyed": destroyed}, cid]
    if name == "Email/set":
        JM["state"] += 1
        updated = {}
        for i, patch in (args.get("update") or {}).items():
            e = E.get(i)
            if not e:
                continue
            for k, v in patch.items():
                if k.startswith("keywords/"):
                    kw = k.split("/", 1)[1]
                    if v: e["keywords"][kw] = True
                    else: e["keywords"].pop(kw, None)
                elif k == "mailboxIds":
                    e["mailboxIds"] = v
                elif k.startswith("mailboxIds/"):
                    mb = k.split("/", 1)[1]
                    if v: e["mailboxIds"][mb] = True
                    else: e["mailboxIds"].pop(mb, None)
            e["_updated"] = JM["state"]
            updated[i] = None
        for i in args.get("destroy") or []:
            E.pop(i, None)
            JM["destroyed"].append((i, JM["state"]))
        return [name, {"accountId": "A1", "newState": str(JM["state"]), "updated": updated,
                       "destroyed": args.get("destroy") or []}, cid]
    if name == "Email/import":
        JM["state"] += 1
        created = {}
        for k, v in args["emails"].items():
            eid = "imp-%d" % len(E)
            raw = JM["blobs"][v["blobId"]]
            sub = re.search(rb"Subject: ([^\r]*)", raw)
            E[eid] = {"id": eid, "blobId": v["blobId"], "threadId": "t-" + eid, "mailboxIds": v["mailboxIds"],
                      "keywords": v.get("keywords", {}), "size": len(raw),
                      "receivedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "messageId": [],
                      "inReplyTo": None, "references": None, "from": [{"name": "Me", "email": "me@example.test"}],
                      "to": [], "cc": [], "subject": sub.group(1).decode() if sub else "", "preview": "",
                      "hasAttachment": False, "_created": JM["state"], "_updated": JM["state"]}
            created[k] = {"id": eid, "blobId": v["blobId"]}
        return [name, {"accountId": "A1", "created": created}, cid]
    if name == "Identity/get":
        return [name, {"accountId": "A1", "list": [{"id": "id-1", "name": "Me", "email": "me@example.test"}]}, cid]
    if name == "EmailSubmission/set":
        for k, v in args["create"].items():
            JM["sent"].append({"emailId": v["emailId"], "rcpt": [r["email"] for r in v["envelope"]["rcptTo"]],
                               "subject": E[v["emailId"]]["subject"]})
        return [name, {"accountId": "A1", "created": {k: {"id": "sub-1"} for k in args["create"]}}, cid]
    return ["error", {"type": "unknownMethod"}, cid]


# ---- EWS (Exchange) -------------------------------------------------------------------------

def md4(data):
    def F(x, y, z): return (x & y) | (~x & z)
    def G(x, y, z): return (x & y) | (x & z) | (y & z)
    def H(x, y, z): return x ^ y ^ z
    rot = lambda x, n: ((x << n) | (x >> (32 - n))) & 0xffffffff
    m = bytearray(data) + b"\x80"
    while len(m) % 64 != 56: m += b"\0"
    m += struct.pack("<Q", len(data) * 8)
    h = [0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476]
    for o in range(0, len(m), 64):
        X = struct.unpack("<16I", m[o:o + 64])
        a, b, c, d = h
        for i in (0, 4, 8, 12):
            a = rot((a + F(b, c, d) + X[i]) & 0xffffffff, 3)
            d = rot((d + F(a, b, c) + X[i + 1]) & 0xffffffff, 7)
            c = rot((c + F(d, a, b) + X[i + 2]) & 0xffffffff, 11)
            b = rot((b + F(c, d, a) + X[i + 3]) & 0xffffffff, 19)
        for i in (0, 1, 2, 3):
            a = rot((a + G(b, c, d) + X[i] + 0x5a827999) & 0xffffffff, 3)
            d = rot((d + G(a, b, c) + X[i + 4] + 0x5a827999) & 0xffffffff, 5)
            c = rot((c + G(d, a, b) + X[i + 8] + 0x5a827999) & 0xffffffff, 9)
            b = rot((b + G(c, d, a) + X[i + 12] + 0x5a827999) & 0xffffffff, 13)
        for i in (0, 2, 1, 3):
            a = rot((a + H(b, c, d) + X[i] + 0x6ed9eba1) & 0xffffffff, 3)
            d = rot((d + H(a, b, c) + X[i + 8] + 0x6ed9eba1) & 0xffffffff, 9)
            c = rot((c + H(d, a, b) + X[i + 4] + 0x6ed9eba1) & 0xffffffff, 11)
            b = rot((b + H(c, d, a) + X[i + 12] + 0x6ed9eba1) & 0xffffffff, 15)
        h = [(x + y) & 0xffffffff for x, y in zip(h, [a, b, c, d])]
    return struct.pack("<4I", *h)


EW = {"folders": {"f-root": ("msgfolderroot", "Top", None), "f-in": ("inbox", "Inbox", "f-root"),
                  "f-sent": ("sentitems", "Sent Items", "f-root"), "f-del": ("deleteditems", "Deleted Items", "f-root"),
                  "f-drafts": ("drafts", "Drafts", "f-root"), "f-junk": ("junkemail", "Junk Email", "f-root"),
                  "f-proj": (None, "Projects", "f-in")},
      "items": {}, "log": [], "sent": [], "seq": 1, "changes": []}


def ew_add(iid, folder, frm_name, frm, subject, body, at, read=False, flagged=False):
    raw = msg(len(EW["items"]) + 50, "%s <%s>" % (frm_name, frm), subject, body, at)
    EW["seq"] += 1
    EW["items"][iid] = {"id": iid, "folder": folder, "fromName": frm_name, "from": frm, "subject": subject,
                        "at": at, "read": read, "flagged": flagged, "raw": raw, "categories": []}
    EW["changes"].append((EW["seq"], folder, "Create", iid))


ew_add("i1", "f-in", "Nasser", "nasser@example.test", "Exchange hello", "From the Exchange.", NOW - 5000, flagged=True)
ew_add("i2", "f-in", "Laila", "laila@example.test", "Meeting notes", "Notes.", NOW - 4000, read=True)
ew_add("i3", "f-proj", "Khalid", "khalid@example.test", "Plan", "Q4 plan.", NOW - 3000)
NTLM_CHALLENGE = b"\x01\x23\x45\x67\x89\xab\xcd\xef"
NTLM_OK = set()


def ntlm_check(t3):
    # the NTLMv2 answer, worked out again here: EXAMPLE\me, "secret"
    s = base64.b64decode(t3)
    def field(o):
        n, off = struct.unpack("<H", s[o:o + 2])[0], struct.unpack("<I", s[o + 4:o + 8])[0]
        return s[off:off + n]
    nt, dom, user = field(20), field(28), field(36)
    key = hmac.new(md4("secret".encode("utf-16le")), (user.decode("utf-16le").upper() + dom.decode("utf-16le")).encode("utf-16le"),
                   hashlib.md5).digest()
    proof, temp = nt[:16], nt[16:]
    return hmac.new(key, NTLM_CHALLENGE + temp, hashlib.md5).digest() == proof and \
        user.decode("utf-16le").lower() == "me" and dom.decode("utf-16le").upper() == "EXAMPLE"


def x(s):
    return html.escape(s, quote=True)


def item_xml(it, mime=False):
    out = '<t:Message><t:ItemId Id="%s" ChangeKey="ck"/><t:ParentFolderId Id="%s"/>' % (it["id"], it["folder"])
    if mime:
        out += "<t:MimeContent CharacterSet=\"UTF-8\">%s</t:MimeContent>" % base64.b64encode(it["raw"]).decode()
    out += "<t:Subject>%s</t:Subject><t:DateTimeReceived>%s</t:DateTimeReceived><t:Size>%d</t:Size>" % (
        x(it["subject"]), time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(it["at"])), len(it["raw"]))
    if it["categories"]:
        out += "<t:Categories>%s</t:Categories>" % "".join("<t:String>%s</t:String>" % x(c) for c in it["categories"])
    out += "<t:Importance>Normal</t:Importance><t:HasAttachments>false</t:HasAttachments>"
    out += "<t:Flag><t:FlagStatus>%s</t:FlagStatus></t:Flag>" % ("Flagged" if it["flagged"] else "NotFlagged")
    out += "<t:ConversationId Id=\"c-%s\"/>" % it["id"]
    out += ("<t:From><t:Mailbox><t:Name>%s</t:Name><t:EmailAddress>%s</t:EmailAddress></t:Mailbox></t:From>"
            % (x(it["fromName"]), x(it["from"])))
    out += ("<t:ToRecipients><t:Mailbox><t:Name>Me</t:Name><t:EmailAddress>me@example.test</t:EmailAddress>"
            "</t:Mailbox></t:ToRecipients>")
    out += "<t:IsRead>%s</t:IsRead><t:InternetMessageId>&lt;%s@example.test&gt;</t:InternetMessageId>" % (
        "true" if it["read"] else "false", it["id"])
    return out + "</t:Message>"


def ew_folder_id(dist):
    for k, (d, n, p) in EW["folders"].items():
        if d == dist:
            return k
    return None


def ew_op(body):
    b = body.decode()
    op = re.search(r"<soap:Body>\s*<m:(\w+)", b).group(1)
    EW["log"].append(op)
    ok = lambda name, inner="": '<m:%sResponseMessage ResponseClass="Success"><m:ResponseCode>NoError</m:ResponseCode>%s</m:%sResponseMessage>' % (name, inner, name)
    msgs = []
    if op == "GetFolder":
        for d in re.findall(r'DistinguishedFolderId Id="(\w+)"', b):
            fid = ew_folder_id(d)
            if fid is None:
                msgs.append('<m:GetFolderResponseMessage ResponseClass="Error"><m:MessageText>no such folder</m:MessageText><m:ResponseCode>ErrorFolderNotFound</m:ResponseCode></m:GetFolderResponseMessage>')
            else:
                msgs.append(ok("GetFolder", '<m:Folders><t:Folder><t:FolderId Id="%s"/></t:Folder></m:Folders>' % fid))
        rname = "GetFolder"
    elif op == "FindFolder":
        fs = ""
        for k, (d, n, p) in EW["folders"].items():
            if k == "f-root":
                continue
            inb = [i for i in EW["items"].values() if i["folder"] == k]
            fs += ('<t:Folder><t:FolderId Id="%s" ChangeKey="ck"/><t:ParentFolderId Id="%s"/><t:FolderClass>IPF.Note</t:FolderClass>'
                   '<t:DisplayName>%s</t:DisplayName><t:TotalCount>%d</t:TotalCount><t:UnreadCount>%d</t:UnreadCount></t:Folder>'
                   % (k, p, x(n), len(inb), sum(1 for i in inb if not i["read"])))
        msgs.append(ok("FindFolder", '<m:RootFolder TotalItemsInView="%d" IncludesLastItemInRange="true"><t:Folders>%s</t:Folders></m:RootFolder>' % (len(EW["folders"]) - 1, fs)))
        rname = "FindFolder"
    elif op == "SyncFolderItems":
        fid = re.search(r'<m:SyncFolderId><t:FolderId Id="([^"]+)"', b).group(1)
        st = re.search(r"<m:SyncState>(\d+)</m:SyncState>", b)
        since = int(st.group(1)) if st else 0
        ch = ""
        if since == 0:
            # (the first time: what is in the folder now, as Exchange gives it)
            for it in EW["items"].values():
                if it["folder"] == fid:
                    ch += "<t:Create><t:Message><t:ItemId Id=\"%s\" ChangeKey=\"ck\"/></t:Message></t:Create>" % it["id"]
        for (sq, folder, kind, iid) in (EW["changes"] if since > 0 else []):
            if sq > since and folder == fid:
                if kind == "ReadFlagChange":
                    if iid not in EW["items"]:
                        continue
                    ch += "<t:ReadFlagChange><t:ItemId Id=\"%s\"/><t:IsRead>%s</t:IsRead></t:ReadFlagChange>" % (iid, "true" if EW["items"][iid]["read"] else "false")
                else:
                    ch += "<t:%s><t:Message><t:ItemId Id=\"%s\" ChangeKey=\"ck\"/></t:Message></t:%s>" % (kind, iid, kind) if kind != "Delete" else "<t:Delete><t:ItemId Id=\"%s\"/></t:Delete>" % iid
        msgs.append(ok("SyncFolderItems", "<m:SyncState>%d</m:SyncState><m:IncludesLastItemInRange>true</m:IncludesLastItemInRange><m:Changes>%s</m:Changes>" % (EW["seq"], ch)))
        rname = "SyncFolderItems"
    elif op == "GetItem":
        mime = "<t:IncludeMimeContent>true</t:IncludeMimeContent>" in b
        for iid in re.findall(r'<t:ItemId Id="([^"]+)"', b):
            it = EW["items"].get(iid)
            if it is None:
                msgs.append('<m:GetItemResponseMessage ResponseClass="Error"><m:MessageText>gone</m:MessageText><m:ResponseCode>ErrorItemNotFound</m:ResponseCode></m:GetItemResponseMessage>')
            else:
                msgs.append(ok("GetItem", "<m:Items>%s</m:Items>" % item_xml(it, mime)))
        rname = "GetItem"
    elif op == "UpdateItem":
        iid = re.search(r'<t:ItemId Id="([^"]+)"', b).group(1)
        it = EW["items"][iid]
        EW["seq"] += 1
        m = re.search(r"<t:IsRead>(\w+)</t:IsRead>", b)
        if m:
            it["read"] = m.group(1) == "true"
            EW["changes"].append((EW["seq"], it["folder"], "ReadFlagChange", iid))
        m = re.search(r"<t:FlagStatus>(\w+)</t:FlagStatus>", b)
        if m:
            it["flagged"] = m.group(1) == "Flagged"
            EW["changes"].append((EW["seq"], it["folder"], "Update", iid))
        if 'FieldURI="item:Categories"' in b:
            it["categories"] = [html.unescape(c) for c in re.findall(r"<t:String>([^<]*)</t:String>", b)]
            EW["changes"].append((EW["seq"], it["folder"], "Update", iid))
        msgs.append(ok("UpdateItem", '<m:Items><t:Message><t:ItemId Id="%s" ChangeKey="ck2"/></t:Message></m:Items>' % iid))
        rname = "UpdateItem"
    elif op == "MoveItem":
        to = re.search(r"<m:ToFolderId>(.*?)</m:ToFolderId>", b).group(1)
        d = re.search(r'DistinguishedFolderId Id="(\w+)"', to)
        dest = ew_folder_id(d.group(1)) if d else re.search(r'FolderId Id="([^"]+)"', to).group(1)
        for iid in re.findall(r'<t:ItemId Id="([^"]+)"', b.split("</m:ToFolderId>")[1]):
            it = EW["items"].pop(iid)
            EW["seq"] += 1
            EW["changes"].append((EW["seq"], it["folder"], "Delete", iid))
            nid = iid + "m"
            it["id"], it["folder"] = nid, dest
            EW["items"][nid] = it
            EW["seq"] += 1
            EW["changes"].append((EW["seq"], dest, "Create", nid))
            msgs.append(ok("MoveItem", '<m:Items><t:Message><t:ItemId Id="%s"/></t:Message></m:Items>' % nid))
        rname = "MoveItem"
    elif op == "DeleteItem":
        for iid in re.findall(r'<t:ItemId Id="([^"]+)"', b):
            it = EW["items"].pop(iid, None)
            if it:
                EW["seq"] += 1
                EW["changes"].append((EW["seq"], it["folder"], "Delete", iid))
                if 'DeleteType="MoveToDeletedItems"' in b:
                    it["folder"] = "f-del"
                    EW["items"][iid] = it
                    EW["seq"] += 1
                    EW["changes"].append((EW["seq"], "f-del", "Create", iid))
            msgs.append(ok("DeleteItem"))
        rname = "DeleteItem"
    elif op == "CreateItem":
        raw = base64.b64decode(re.search(r"<t:MimeContent[^>]*>([^<]*)</t:MimeContent>", b).group(1))
        sub = re.search(rb"Subject: ([^\r]*)", raw)
        EW["sent"].append({"subject": sub.group(1).decode() if sub else "", "to": re.findall(rb"^To: (.*)$", raw, re.M)[0].decode()})
        ew_add("s%d" % len(EW["items"]), "f-sent", "Me", "me@example.test", sub.group(1).decode() if sub else "", "", time.time(), read=True)
        msgs.append(ok("CreateItem", "<m:Items/>"))
        rname = "CreateItem"
    elif op == "FindItem":
        q = html.unescape(re.search(r"<m:QueryString>(.*?)</m:QueryString>", b).group(1)).lower()
        ids = "".join('<t:Message><t:ItemId Id="%s"/></t:Message>' % i["id"] for i in EW["items"].values()
                      if q in i["subject"].lower() or q in i["raw"].decode().lower())
        msgs.append(ok("FindItem", '<m:RootFolder IncludesLastItemInRange="true"><t:Items>%s</t:Items></m:RootFolder>' % ids))
        rname = "FindItem"
    else:
        return 500, "<soap:Fault><faultstring>unknown operation</faultstring></soap:Fault>"
    return 200, ('<?xml version="1.0" encoding="utf-8"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">'
                 '<s:Body><m:%sResponse xmlns:m="http://schemas.microsoft.com/exchange/services/2006/messages" '
                 'xmlns:t="http://schemas.microsoft.com/exchange/services/2006/types"><m:ResponseMessages>%s'
                 '</m:ResponseMessages></m:%sResponse></s:Body></s:Envelope>' % (rname, "".join(msgs), rname))


def ew_handle(conn, meth, path, headers, body):
    if path.startswith("/admin/"):
        with LOCK:
            if path == "/admin/newmail":
                ew_add("n%d" % len(EW["items"]), "f-in", "New", "new@example.test", "EWS news", "Fresh.", time.time())
            st = {k: v for k, v in EW.items() if k not in ("items",)}
            st["items"] = {k: {kk: vv for kk, vv in v.items() if kk != "raw"} for k, v in EW["items"].items()}
            return 200, [], json.dumps(st, default=str)
    auth = headers.get("authorization", "")
    if conn not in NTLM_OK:
        if auth.startswith("Basic "):
            return 401, [("WWW-Authenticate", "NTLM"), ("WWW-Authenticate", "Negotiate")], ""
        if auth.startswith("NTLM "):
            t = base64.b64decode(auth[5:])
            if struct.unpack("<I", t[8:12])[0] == 1:
                dom = "EXAMPLE".encode("utf-16le")
                ti = struct.pack("<HH", 2, len(dom)) + dom + struct.pack("<HH", 0, 0)
                t2 = (b"NTLMSSP\0" + struct.pack("<I", 2) + struct.pack("<HHI", 0, 0, 48) +
                      struct.pack("<I", 0x628a8215) + NTLM_CHALLENGE + b"\0" * 8 +
                      struct.pack("<HHI", len(ti), len(ti), 48) + ti)
                return 401, [("WWW-Authenticate", "NTLM " + base64.b64encode(t2).decode())], ""
            if not ntlm_check(auth[5:]):
                return 401, [("WWW-Authenticate", "NTLM")], ""
            NTLM_OK.add(conn)
        else:
            return 401, [("WWW-Authenticate", "NTLM")], ""
    with LOCK:
        st, out = ew_op(body)
    return st, [("Content-Type", "text/xml; charset=utf-8")], out


def serve(sock, fn):
    while True:
        k, _ = sock.accept()
        threading.Thread(target=fn, args=(k,), daemon=True).start()


def listen():
    s = socket.socket()
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("127.0.0.1", 0))
    s.listen(16)
    return s


if __name__ == "__main__":
    p, j, e = listen(), listen(), listen()
    JM_PORT = j.getsockname()[1]
    print(p.getsockname()[1], j.getsockname()[1], e.getsockname()[1], flush=True)
    threading.Thread(target=serve, args=(p, pop_session), daemon=True).start()
    threading.Thread(target=serve, args=(j, lambda c: http_serve(c, jm_handle)), daemon=True).start()
    serve(e, lambda c: http_serve(c, ew_handle))
