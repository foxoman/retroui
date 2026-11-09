#!/usr/bin/env python3
"""A small stand-in for the services Retro Mail talks to, for its tests:
Microsoft's and Google's sign-in (OAuth 2.0 with PKCE), Microsoft Graph's
mail, categories and calendar, the Gmail API (with its batch and upload
endpoints) and Google Calendar; meeting invitations, automatic replies, raw
messages and Anthropic's Messages API (under /ai) for tests/test_mailextra.nim;
events made, changed and deleted in both calendars for tests/test_calendar.nim.
State lives in memory; GET /test/state shows it, POST /test/newmail adds a
message to both inboxes.

    python3 tests/mailmock.py 8765

Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net
"""
import base64, hashlib, json, re, sys, threading, time, urllib.parse
from email import message_from_bytes, policy
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LOCK = threading.Lock()
NOW = time.time()

def iso(t):
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(t))

def b64u(b):
    return base64.urlsafe_b64encode(b).decode().rstrip("=")

def jwt(claims):
    return b64u(b'{"alg":"none"}') + "." + b64u(json.dumps(claims).encode()) + "."

PIXEL = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAIAAABLbSncAAAAGklEQVR4nGP4z8DAwMDAxMDAwMDAwMDAwAAAOAAD"
    "+u3b3gAAAABJRU5ErkJggg==")

NEWSLETTER = """<html><head><style>.pre{display:none;font-size:0;max-height:0}
.btn td{background:#0063b1;padding:10px 18px}.btn a{color:#ffffff;text-decoration:none}</style></head>
<body><span class="pre">This preheader must not show.</span>
<table width="100%" bgcolor="#eeeeee" cellpadding="0" cellspacing="0"><tr><td align="center">
<table width="600" bgcolor="#ffffff" cellpadding="16"><tr><td>
<h1 style="color:#003366">Retro Weekly</h1><p>Three new toolkits this week, and a
<b>big</b> one for Nim.</p><img src="cid:logo1" width="8" height="8" alt="logo">
<img src="https://example.com/banner.png" width="560" height="120" alt="Banner">
<table class="btn"><tr><td><a href="https://example.com/read">Read more</a></td></tr></table>
</td></tr></table></td></tr></table></body></html>"""

ARABIC = """<div dir="rtl"><p>مرحبا سلطان، هذا اختبار للبريد العربي مع كلمة English في الوسط.</p>
<p>الاجتماع يوم الثلاثاء الساعة 2</p></div>"""

def seed():
    g = {"me": {"displayName": "Sultan Al Isaiee", "mail": "sultan@contoso.com"},
         "folders": {}, "messages": {}, "deltas": {}, "categories": [
             {"displayName": "Retro", "color": "preset7"}, {"displayName": "Finance", "color": "preset4"}],
         "sent": [], "seq": 100, "events": []}
    for fid, name in [("f-inbox", "Inbox"), ("f-drafts", "Drafts"), ("f-sent", "Sent Items"),
                      ("f-trash", "Deleted Items"), ("f-archive", "Archive"),
                      ("f-junk", "Junk Email"), ("f-outbox", "Outbox"), ("f-proj", "Projects")]:
        g["folders"][fid] = {"id": fid, "displayName": name, "parentFolderId": "root",
                             "childFolderCount": 1 if fid == "f-proj" else 0,
                             "unreadItemCount": 0, "totalItemCount": 0}
    g["folders"]["f-proj-retro"] = {"id": "f-proj-retro", "displayName": "Retro", "parentFolderId": "f-proj",
                                    "childFolderCount": 0, "unreadItemCount": 0, "totalItemCount": 0}
    def add(mid, folder, frm, subj, html, t, conv, read=False, cats=(), att=False, to="sultan@contoso.com",
            focused=True):
        g["messages"][mid] = {
            "id": mid, "conversationId": conv, "subject": subj, "parentFolderId": folder,
            "from": {"emailAddress": {"name": frm[0], "address": frm[1]}},
            "toRecipients": [{"emailAddress": {"name": "", "address": to}}], "ccRecipients": [],
            "receivedDateTime": iso(t), "isRead": read, "flag": {"flagStatus": "notFlagged"},
            "importance": "normal", "hasAttachments": att, "categories": list(cats),
            "bodyPreview": re.sub("<[^>]+>", " ", re.sub(r"(?is)<(style|head)\b.*?</\1>", " ", html))[:120].strip(),
            "inferenceClassification": "focused" if focused else "other",
            "internetMessageId": "<%s@contoso.com>" % mid, "isDraft": False,
            "body": {"contentType": "html", "content": html}, "attachments": []}
    add("m1", "f-inbox", ("Ahmed Al Rawahi", "ahmed@contoso.com"), "Meeting about the Photo app",
        "<p>Tuesday at 2 is good for me. Should I bring the test images?</p>", NOW - 3600, "c1")
    add("m2", "f-sent", ("Sultan Al Isaiee", "sultan@contoso.com"), "Re: Meeting about the Photo app",
        "<p>Yes please, the RAW ones too.</p><div id=\"Signature\"><p><b>Sultan Al Isaiee</b><br>Retro Nim UI</p></div>"
        "<hr><div id=\"divRplyFwdMsg\"><b>From:</b> Ahmed</div><div id=\"Signature\"><p>Ahmed's own</p></div>",
        NOW - 3000, "c1", read=True, to="ahmed@contoso.com")
    add("m3", "f-inbox", ("Retro Weekly", "news@retroweekly.example"), "Retro Weekly: three new toolkits",
        NEWSLETTER, NOW - 7200, "c3", cats=["Retro"], att=True, focused=False)
    g["messages"]["m3"]["internetMessageHeaders"] = [
        {"name": "List-Unsubscribe", "value": "<http://HOST/unsub/m3>, <mailto:leave@retroweekly.example?subject=leave%20me>"},
        {"name": "List-Unsubscribe-Post", "value": "List-Unsubscribe=One-Click"}]
    g["messages"]["m3"]["attachments"] = [
        {"@odata.type": "#microsoft.graph.fileAttachment", "id": "a1", "name": "logo.png",
         "contentType": "image/png", "size": len(PIXEL), "isInline": True, "contentId": "logo1",
         "contentBytes": base64.b64encode(PIXEL).decode()}]
    add("m4", "f-inbox", ("Muna Al Balushi", "muna@contoso.com"), "Invoice 1047 -- please check",
        "<p>The VAT line is counted twice.</p>", NOW - 86400 - 500, "c4", cats=["Finance"], att=True)
    g["messages"]["m4"]["attachments"] = [
        {"@odata.type": "#microsoft.graph.fileAttachment", "id": "a2", "name": "invoice-1047.pdf",
         "contentType": "application/pdf", "size": 9, "isInline": False,
         "contentBytes": base64.b64encode(b"%PDF-1.4\n").decode()}]
    add("m5", "f-inbox", ("Sara Al Kindi", "sara@contoso.com"), "تجربة البريد العربي", ARABIC,
        NOW - 2 * 86400, "c5")
    add("m6", "f-proj-retro", ("GitHub", "noreply@github.com"), "[retro] CI passed",
        "<p>All jobs passed.</p>", NOW - 3 * 86400, "c6", read=True)
    g["events"] = [{"id": "e1", "subject": "Photo app with Ahmed", "isAllDay": False,
                    "location": {"displayName": "Room 2"},
                    "start": {"dateTime": iso(NOW + 3600)[:-1]}, "end": {"dateTime": iso(NOW + 7200)[:-1]}}]

    gm = {"email": "foxoman@gmail.example", "history": 1000, "labels": [
        {"id": "INBOX", "name": "INBOX", "type": "system"}, {"id": "SENT", "name": "SENT", "type": "system"},
        {"id": "TRASH", "name": "TRASH", "type": "system"}, {"id": "SPAM", "name": "SPAM", "type": "system"},
        {"id": "DRAFT", "name": "DRAFT", "type": "system"}, {"id": "STARRED", "name": "STARRED", "type": "system"},
        {"id": "UNREAD", "name": "UNREAD", "type": "system"},
        {"id": "Label_1", "name": "Family", "type": "user", "color": {"backgroundColor": "#a479e2"}}],
        "messages": {}, "historyLog": [], "sent": [], "events": []}
    def gadd(mid, thread, labels, frm, subj, html, t, raw_parts=None, att=None):
        parts = [{"partId": "0", "mimeType": "text/html", "filename": "",
                  "headers": [{"name": "Content-Type", "value": "text/html; charset=utf-8"}],
                  "body": {"size": len(html.encode()), "data": b64u(html.encode())}}]
        if att:
            parts.append(att)
        gm["messages"][mid] = {
            "id": mid, "threadId": thread, "labelIds": labels, "snippet": re.sub("<[^>]+>", " ", html)[:100].strip(),
            "internalDate": str(int(t * 1000)), "sizeEstimate": 2000 + len(html),
            "payload": {"mimeType": "multipart/mixed", "headers": [
                {"name": "From", "value": "%s <%s>" % frm}, {"name": "To", "value": gm["email"]},
                {"name": "Subject", "value": subj}, {"name": "Message-ID", "value": "<%s@mail.gmail.example>" % mid},
                {"name": "Date", "value": time.strftime("%a, %d %b %Y %H:%M:%S +0000", time.gmtime(t))}],
                "parts": parts}}
    gadd("g1", "t1", ["INBOX", "UNREAD", "CATEGORY_PERSONAL"], ("Khalid Al Siyabi", "khalid@example.om"),
         "Photos from the weekend", "<p>Twelve pictures from Jebel Shams.</p>", NOW - 1800,
         att={"partId": "1", "mimeType": "image/jpeg", "filename": "shams.jpg",
              "headers": [{"name": "Content-Disposition", "value": "attachment; filename=shams.jpg"}],
              "body": {"size": 4, "attachmentId": "ga1"}})
    gadd("g2", "t1", ["SENT"], ("Sultan", gm["email"]), "Re: Photos from the weekend",
         "<p>Send them!</p>", NOW - 1700)
    gadd("g3", "t3", ["INBOX", "CATEGORY_PROMOTIONS", "Label_1"], ("Shop", "deals@shop.example"),
         "=?UTF-8?B?2LnYsdi2INiu2KfYtQ==?=", "<p>Big sale</p>", NOW - 5000)
    gm["messages"]["g3"]["payload"]["headers"].append(
        {"name": "List-Unsubscribe", "value": "<mailto:unsubscribe@shop.example?subject=stop>"})
    gm["events"] = [{"id": "ge1", "summary": "Family dinner", "status": "confirmed",
                     "start": {"dateTime": iso(NOW + 86400)}, "end": {"dateTime": iso(NOW + 90000)}}]
    return {"graph": g, "gmail": gm, "codes": {}, "tokens": {}, "log": []}

S = seed()

def gmail_counts():
    pass

class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *a):
        pass

    def body(self):
        return self._body

    def send(self, code, obj=None, raw=None, ctype="application/json", headers=()):
        data = raw if raw is not None else (b"" if obj is None else json.dumps(obj).encode())
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        for k, v in headers:
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(data)

    def authed(self):
        a = self.headers.get("Authorization", "")
        tok = a[7:] if a.startswith("Bearer ") else ""
        info = S["tokens"].get(tok)
        if not info or info["exp"] < time.time():
            self.send(401, {"error": {"code": "InvalidAuthenticationToken", "message": "Access token has expired or is not yet valid."}})
            return None
        return info

    # ---- dispatch ----
    def do_GET(self): self.route("GET")
    def do_POST(self): self.route("POST")
    def do_PATCH(self): self.route("PATCH")
    def do_DELETE(self): self.route("DELETE")
    def do_PUT(self): self.route("PUT")

    def route(self, meth):
        n = int(self.headers.get("Content-Length") or 0)
        self._body = self.rfile.read(n) if n else b""   # (always read: the connection is kept)
        u = urllib.parse.urlsplit(self.path)
        path, q = u.path, urllib.parse.parse_qs(u.query)
        S["log"].append(meth + " " + path)
        try:
            with LOCK:
                if path.startswith("/test/"): return self.test(meth, path, q)
                if path == "/dns/resolve":
                    name = q.get("name", [""])[0]
                    ans = [{"name": name, "type": 15, "data": "1 aspmx.l.google.com."}] if name.endswith(".example") or name == "foxoman.net" else []
                    return self.send(200, {"Status": 0, "Answer": ans})
                if path.startswith("/ms/") or path.startswith("/g/"): return self.oauth(meth, path, q)
                if path.startswith("/upload-session/"): return self.upload(meth, path)
                if path.startswith("/v1.0/"): return self.graph(meth, path[5:], q)
                if path.startswith("/batch/gmail/v1"): return self.gbatch()
                if path.startswith("/upload/gmail/v1/users/me/messages/send"): return self.gsend_upload()
                if path.startswith("/gmail/v1/users/me"): return self.gmail(meth, path[18:], q)
                if path.startswith("/calendar/v3/"): return gcal(self, meth, path[12:], q)
                if path.startswith("/ai/"): return ai(self, meth, path)
                if path.startswith("/unsub/") and meth == "POST":
                    S.setdefault("unsubs", []).append({"id": path[7:], "body": self.body().decode()})
                    return self.send(200, {})
            self.send(404, {"error": {"message": "no such endpoint " + path}})
        except Exception as e:
            import traceback; traceback.print_exc()
            self.send(500, {"error": {"message": str(e)}})

    # ---- test helpers ----
    def test(self, meth, path, q):
        if path == "/test/state":
            g, gm = S["graph"], S["gmail"]
            return self.send(200, {"graph": {"messages": g["messages"], "sent": g["sent"], "categories": g["categories"]},
                                   "gmail": {"messages": gm["messages"], "sent": gm["sent"], "labels": gm["labels"]},
                                   "log": S["log"][-400:], "unsubs": S.get("unsubs", [])})
        if path == "/test/newmail":
            g = S["graph"]
            g["seq"] += 1
            mid = "m%d" % g["seq"]
            g["messages"][mid] = dict(g["messages"]["m1"], id=mid, subject="Fresh news %d" % g["seq"],
                                      conversationId="c" + mid, isRead=False, receivedDateTime=iso(time.time()),
                                      internetMessageId="<%s@x>" % mid)
            gm = S["gmail"]
            gm["history"] += 1
            gid = "gn%d" % g["seq"]
            gm["messages"][gid] = json.loads(json.dumps(gm["messages"]["g1"]))
            gm["messages"][gid].update(id=gid, threadId="t" + gid, internalDate=str(int(time.time() * 1000)))
            gm["historyLog"].append((gm["history"], "added", gid))
            return self.send(200, {"graph": mid, "gmail": gid})
        if path == "/test/expire":
            for t in S["tokens"].values(): t["exp"] = 0
            return self.send(200, {})
        if path in ("/test/invites", "/test/extra"): return test_extra(self, path)
        if path == "/test/calendar": return test_calendar(self, meth)
        self.send(404, {})

    # ---- OAuth ----
    def oauth(self, meth, path, q):
        if path.endswith("/v2.0/.well-known/openid-configuration"):
            dom = path.split("/")[2]
            if dom in ("contoso.com", "organizations", "common"):
                return self.send(200, {"issuer": "https://login.microsoftonline.com/x/v2.0"})
            return self.send(400, {"error": "invalid_tenant"})
        if path.endswith("/authorize") or path == "/g/auth":
            for k in ("client_id", "redirect_uri", "state", "code_challenge", "scope"):
                if k not in q: return self.send(400, raw=("missing " + k).encode(), ctype="text/plain")
            if q.get("code_challenge_method", [""])[0] != "S256":
                return self.send(400, raw=b"S256 only", ctype="text/plain")
            code = "code%d" % len(S["codes"])
            S["codes"][code] = {"challenge": q["code_challenge"][0], "redirect": q["redirect_uri"][0],
                                "client": q["client_id"][0], "google": path == "/g/auth"}
            loc = q["redirect_uri"][0] + ("&" if "?" in q["redirect_uri"][0] else "?") + \
                urllib.parse.urlencode({"code": code, "state": q["state"][0]})
            return self.send(302, raw=b"", headers=[("Location", loc)])
        if path.endswith("/token") or path == "/g/token":
            f = urllib.parse.parse_qs(self.body().decode())
            gt = f.get("grant_type", [""])[0]
            google = path == "/g/token"
            if gt == "authorization_code":
                c = S["codes"].pop(f.get("code", [""])[0], None)
                if not c: return self.send(400, {"error": "invalid_grant", "error_description": "bad code"})
                v = f.get("code_verifier", [""])[0]
                if b64u(hashlib.sha256(v.encode()).digest()) != c["challenge"]:
                    return self.send(400, {"error": "invalid_grant", "error_description": "PKCE verification failed"})
                if f.get("redirect_uri", [""])[0] != c["redirect"]:
                    return self.send(400, {"error": "invalid_grant", "error_description": "redirect_uri mismatch"})
                if google and not f.get("client_secret", [""])[0]:
                    return self.send(400, {"error": "invalid_client", "error_description": "client_secret is missing"})
            elif gt == "refresh_token":
                if not f.get("refresh_token", [""])[0].startswith("rt-"):
                    return self.send(400, {"error": "invalid_grant", "error_description": "AADSTS70008: expired"})
            else:
                return self.send(400, {"error": "unsupported_grant_type"})
            n = len(S["tokens"])
            at = "at-%d-%s" % (n, "g" if google else "m")
            S["tokens"][at] = {"google": google, "exp": time.time() + 3600}
            email = S["gmail"]["email"] if google else S["graph"]["me"]["mail"]
            return self.send(200, {"access_token": at, "refresh_token": "rt-%d" % n, "expires_in": 3600,
                                   "token_type": "Bearer", "scope": f.get("scope", [""])[0],
                                   "id_token": jwt({"email": email, "name": "Sultan Al Isaiee",
                                                    "preferred_username": email})})
        self.send(404, {})

    # ---- Microsoft Graph ----
    def graph(self, meth, path, q):
        if not self.authed(): return
        g = S["graph"]
        base = "http://%s/v1.0" % self.headers.get("Host")
        if path == "/me": return self.send(200, g["me"])
        if path == "/$batch":
            req = json.loads(self.body())
            out = []
            names = {"inbox": "f-inbox", "drafts": "f-drafts", "sentitems": "f-sent", "deleteditems": "f-trash",
                     "archive": "f-archive", "junkemail": "f-junk", "outbox": "f-outbox"}
            for r in req["requests"]:
                n = r["url"].split("/")[-1].split("?")[0]
                ev = graph_find(n) if r["url"].startswith("/me/events/") else None
                if ev: out.append({"id": r["id"], "status": 200, "body": graph_view(ev)})
                elif n in names: out.append({"id": r["id"], "status": 200, "body": {"id": names[n]}})
                else: out.append({"id": r["id"], "status": 404, "body": {}})
            return self.send(200, {"responses": out})
        m = re.match(r"^/me/mailFolders(?:/([^/]+)/childFolders)?$", path)
        if m and meth == "GET":
            parent = m.group(1) or "root"
            vals = []
            for f in g["folders"].values():
                if f["parentFolderId"] == parent:
                    f = dict(f)
                    f["unreadItemCount"] = sum(1 for x in g["messages"].values() if x["parentFolderId"] == f["id"] and not x["isRead"])
                    f["totalItemCount"] = sum(1 for x in g["messages"].values() if x["parentFolderId"] == f["id"])
                    vals.append(f)
            return self.send(200, {"value": vals})
        m = re.match(r"^/me/mailFolders/([^/]+)/messages$", path)
        if m and meth == "GET":
            names = {"sentitems": "f-sent", "inbox": "f-inbox"}
            fid = names.get(m.group(1), m.group(1))
            ms = sorted([x for x in g["messages"].values() if x["parentFolderId"] == fid],
                        key=lambda x: x["receivedDateTime"], reverse=True)
            return self.send(200, {"value": [{"id": x["id"], "subject": x["subject"], "body": x["body"],
                                              "from": x["from"], "sentDateTime": x["receivedDateTime"]} for x in ms]})
        m = re.match(r"^/me/mailFolders/([^/]+)/messages/delta$", path)
        if m:
            fid = m.group(1)
            token = q.get("$deltatoken", [None])[0]
            since = g["deltas"].get(token, {}) if token else None
            items = []
            for x in g["messages"].values():
                ver = x.get("_ver", 0)
                if x["parentFolderId"] == fid:
                    if since is None or ver > since.get(x["id"], -1):
                        items.append({k: v for k, v in x.items() if not k.startswith("_") and k not in ("body", "attachments")})
            if since is not None:
                for mid in since:
                    x = g["messages"].get(mid)
                    if x is None or x["parentFolderId"] != fid:
                        items.append({"id": mid, "@removed": {"reason": "deleted"}})
            # pages of 2 to exercise nextLink
            skip = int(q.get("$skiptoken", ["0"])[0])
            page = items[skip:skip + 2]
            res = {"value": page}
            keep = "&".join("%s=%s" % (k, urllib.parse.quote(v[0])) for k, v in q.items() if k != "$skiptoken")
            if skip + 2 < len(items):
                res["@odata.nextLink"] = "%s/me/mailFolders/%s/messages/delta?%s&$skiptoken=%d" % (base, fid, keep, skip + 2)
            else:
                tok = "d%d" % len(g["deltas"])
                g["deltas"][tok] = {x["id"]: x.get("_ver", 0) for x in g["messages"].values() if x["parentFolderId"] == fid}
                res["@odata.deltaLink"] = "%s/me/mailFolders/%s/messages/delta?$deltatoken=%s" % (base, fid, tok)
            return self.send(200, res)
        m = re.match(r"^/me/messages/([^/]+)(/.*)?$", path)
        if m:
            mid, rest = m.group(1), m.group(2) or ""
            x = g["messages"].get(mid)
            if x is None: return self.send(404, {"error": {"code": "ErrorItemNotFound", "message": "The specified object was not found in the store."}})
            if rest == "" and meth == "GET" and "_event" in x and "eventMessage/event" in q.get("$expand", [""])[0]:
                return self.send(200, dict({k: v for k, v in x.items() if not k.startswith("_")}, event=x["_event"]))
            if rest == "" and meth == "GET":
                if "internetMessageHeaders" in x:      # (the list's address on this server)
                    y = json.loads(json.dumps(x).replace("HOST", self.headers.get("Host")))
                    return self.send(200, y)
                return self.send(200, x)
            if rest == "/$value" and meth == "GET": return self.send(200, raw=graph_mime(x), ctype="text/plain")
            if rest == "" and meth == "PATCH":
                ch = json.loads(self.body())
                for k, v in ch.items():
                    if k == "body": x["body"] = {"contentType": v.get("contentType", "html").lower(), "content": v["content"]}
                    else: x[k] = v
                x["_ver"] = x.get("_ver", 0) + 1
                return self.send(200, x)
            if rest == "" and meth == "DELETE":
                del g["messages"][mid]
                return self.send(204, raw=b"")
            if rest == "/attachments" and meth == "GET":
                return self.send(200, {"value": [{k: v for k, v in a.items() if k not in ("contentBytes", "contentId")} for a in x["attachments"]]})
            if rest == "/attachments" and meth == "POST":
                a = json.loads(self.body())
                a["id"] = "na%d" % len(x["attachments"])
                a["size"] = len(base64.b64decode(a.get("contentBytes", "")))
                x["attachments"].append(a)
                return self.send(201, a)
            if rest == "/attachments/createUploadSession":
                item = json.loads(self.body())["AttachmentItem"]
                sid = "%s-%d" % (mid, len(x["attachments"]))
                S.setdefault("uploads", {})[sid] = {"msg": mid, "name": item["name"], "size": item["size"], "data": b""}
                return self.send(201, {"uploadUrl": "http://%s/upload-session/%s" % (self.headers.get("Host"), sid)})
            m2 = re.match(r"^/attachments/([^/]+)(/\$value)?$", rest)
            if m2:
                a = next((a for a in x["attachments"] if a["id"] == m2.group(1)), None)
                if not a: return self.send(404, {"error": {"message": "no attachment"}})
                if m2.group(2): return self.send(200, raw=base64.b64decode(a["contentBytes"]), ctype=a["contentType"])
                return self.send(200, a)
            if rest == "/move":
                dest = json.loads(self.body())["destinationId"]
                g["seq"] += 1
                nid = "m%d" % g["seq"]
                y = dict(x, id=nid, parentFolderId=dest)
                y["_ver"] = x.get("_ver", 0) + 1
                del g["messages"][mid]
                g["messages"][nid] = y
                return self.send(201, y)
            if rest in ("/createReply", "/createReplyAll", "/createForward"):
                g["seq"] += 1
                nid = "m%d" % g["seq"]
                d = {"id": nid, "conversationId": x["conversationId"], "subject": ("Fw: " if "Forward" in rest else "Re: ") + x["subject"],
                     "parentFolderId": "f-drafts", "from": {"emailAddress": {"name": "Sultan Al Isaiee", "address": g["me"]["mail"]}},
                     "toRecipients": [] if "Forward" in rest else [x["from"]], "ccRecipients": [], "receivedDateTime": iso(time.time()),
                     "isRead": True, "flag": {"flagStatus": "notFlagged"}, "importance": "normal", "hasAttachments": False,
                     "categories": [], "bodyPreview": "", "inferenceClassification": "focused", "isDraft": True,
                     "internetMessageId": "<%s@x>" % nid, "body": {"contentType": "html", "content": "<p>quoted</p>"},
                     "attachments": [dict(a) for a in x["attachments"]] if "Forward" in rest else [], "_replyOf": mid}
                g["messages"][nid] = d
                return self.send(201, d)
            if rest == "/send":
                x["isDraft"] = False
                x["parentFolderId"] = "f-sent"
                x["_ver"] = x.get("_ver", 0) + 1
                g["sent"].append({k: v for k, v in x.items()})
                return self.send(202, raw=b"")
        if path == "/me/messages" and meth == "POST":
            d = json.loads(self.body())
            g["seq"] += 1
            nid = "m%d" % g["seq"]
            d.update(id=nid, conversationId="c" + nid, parentFolderId="f-drafts", isDraft=True, attachments=[],
                     receivedDateTime=iso(time.time()), isRead=True, flag={"flagStatus": "notFlagged"},
                     **{"from": {"emailAddress": {"name": "Sultan Al Isaiee", "address": g["me"]["mail"]}}})
            g["messages"][nid] = d
            return self.send(201, d)
        if path == "/me/messages" and meth == "GET":
            s = q.get("$search", [""])[0].strip('"').lower()
            vals = [x for x in g["messages"].values() if s in x["subject"].lower() or s in x["body"]["content"].lower()]
            return self.send(200, {"value": [{k: v for k, v in x.items() if not k.startswith("_") and k not in ("body", "attachments")} for x in vals]})
        if path == "/me/outlook/masterCategories":
            if meth == "GET": return self.send(200, {"value": g["categories"]})
            c = json.loads(self.body())
            if any(x["displayName"].lower() == c["displayName"].lower() for x in g["categories"]):
                return self.send(409, {"error": {"message": "exists"}})
            g["categories"].append(c)
            return self.send(201, c)
        if path == "/me/calendarView":
            return self.send(200, {"value": graph_calendar_view()})
        if graph_cal(self, meth, path): return
        if graph_extra(self, meth, path): return
        self.send(404, {"error": {"code": "BadRequest", "message": "no such Graph path " + path}})

    def upload(self, meth, path):
        sid = path.split("/")[-1]
        u = S["uploads"][sid]
        data = self.body()
        rng = self.headers.get("Content-Range", "")
        m = re.match(r"bytes (\d+)-(\d+)/(\d+)", rng)
        if not m or int(m.group(1)) != len(u["data"]): return self.send(416, {"error": {"message": "bad range " + rng}})
        u["data"] += data
        if len(u["data"]) >= u["size"]:
            x = S["graph"]["messages"][u["msg"]]
            x["attachments"].append({"id": "big%d" % len(x["attachments"]), "name": u["name"], "size": len(u["data"]),
                                     "contentType": "application/octet-stream", "isInline": False,
                                     "contentBytes": base64.b64encode(u["data"]).decode()})
            return self.send(201, {})
        return self.send(200, {"nextExpectedRanges": ["%d-" % len(u["data"])]})

    # ---- Gmail ----
    def gmail(self, meth, path, q):
        if not self.authed(): return
        gm = S["gmail"]
        if path == "/profile": return self.send(200, {"emailAddress": gm["email"], "historyId": str(gm["history"])})
        if path == "/labels" and meth == "GET": return self.send(200, {"labels": gm["labels"]})
        if path == "/settings/sendAs":
            return self.send(200, {"sendAs": [
                {"sendAsEmail": "other@alias.example", "signature": "<div>alias</div>"},
                {"sendAsEmail": gm["email"], "isPrimary": True, "isDefault": True,
                 "signature": "<div dir=\"ltr\"><b>Sultan</b><br>www.foxoman.net</div>"}]})
        if path == "/labels" and meth == "POST":
            b = json.loads(self.body())
            if "color" in b and b["color"]["backgroundColor"] not in ("#4a86e8", "#16a766", "#cc3a21", "#ffad47", "#a479e2", "#2da2bb"):
                return self.send(400, {"error": {"message": "Label color is not on the allowed palette"}})
            lid = "Label_%d" % (len(gm["labels"]) + 1)
            lab = {"id": lid, "name": b["name"], "type": "user"}
            if "color" in b: lab["color"] = b["color"]
            gm["labels"].append(lab)
            return self.send(200, lab)
        m = re.match(r"^/labels/([^/]+)$", path)
        if m:
            lid = m.group(1)
            ms = [x for x in gm["messages"].values() if lid in x["labelIds"]]
            return self.send(200, {"id": lid, "messagesTotal": len(ms), "messagesUnread": sum(1 for x in ms if "UNREAD" in x["labelIds"])})
        if path == "/messages" and meth == "GET":
            qq = q.get("q", [""])[0]
            ms = sorted(gm["messages"].values(), key=lambda x: -int(x["internalDate"]))
            if qq and not qq.startswith("newer_than"):
                ms = [x for x in ms if qq.lower() in x["snippet"].lower() or qq.lower() in json.dumps(x["payload"]["headers"]).lower()]
            return self.send(200, {"messages": [{"id": x["id"], "threadId": x["threadId"]} for x in ms]})
        if path == "/history":
            start = int(q.get("startHistoryId", ["0"])[0])
            if start < 1000: return self.send(404, {"error": {"code": 404, "message": "Requested entity was not found."}})
            hist = []
            for (hid, kind, mid) in gm["historyLog"]:
                if hid > start:
                    key = {"added": "messagesAdded", "deleted": "messagesDeleted", "labels": "labelsAdded"}[kind]
                    hist.append({"id": str(hid), key: [{"message": {"id": mid}}]})
            return self.send(200, {"history": hist, "historyId": str(gm["history"])})
        m = re.match(r"^/messages/([^/]+)(/.*)?$", path)
        if m:
            mid, rest = m.group(1), m.group(2) or ""
            x = gm["messages"].get(mid)
            if x is None: return self.send(404, {"error": {"code": 404, "message": "Requested entity was not found."}})
            if rest == "": return self.send(200, self.gview(x, q.get("format", ["full"])[0]))
            if rest == "/modify":
                b = json.loads(self.body())
                for l in b.get("addLabelIds", []):
                    if l not in x["labelIds"]: x["labelIds"].append(l)
                x["labelIds"] = [l for l in x["labelIds"] if l not in b.get("removeLabelIds", [])]
                gm["history"] += 1
                gm["historyLog"].append((gm["history"], "labels", mid))
                return self.send(200, {"id": mid, "labelIds": x["labelIds"]})
            if rest in ("/trash", "/untrash"):
                if rest == "/trash":
                    x["labelIds"] = [l for l in x["labelIds"] if l != "INBOX"] + ["TRASH"]
                else:
                    x["labelIds"] = [l for l in x["labelIds"] if l != "TRASH"]
                gm["history"] += 1
                gm["historyLog"].append((gm["history"], "labels", mid))
                return self.send(200, {"id": mid, "labelIds": x["labelIds"]})
            m2 = re.match(r"^/attachments/([^/]+)$", rest)
            if m2 and m2.group(1) in x.get("_atts", {}): return self.send(200, x["_atts"][m2.group(1)])
            if m2: return self.send(200, {"size": 4, "data": b64u(b"\xff\xd8\xff\xd9")})
        if gmail_extra(self, meth, path): return
        self.send(404, {"error": {"code": 404, "message": "no such Gmail path " + path}})

    def gview(self, x, fmt):
        if fmt == "raw":
            return {"id": x["id"], "threadId": x["threadId"], "labelIds": x["labelIds"], "raw": b64u(gmail_mime(x))}
        y = json.loads(json.dumps(x))
        if fmt == "metadata":
            y["payload"] = {"mimeType": x["payload"]["mimeType"], "headers": x["payload"]["headers"]}
        return y

    def gbatch(self):
        if not self.authed(): return
        ct = self.headers.get("Content-Type", "")
        b = ct.split("boundary=")[1].strip('"')
        body = self.body().decode()
        out_b = "batch_mock_42"
        out = ""
        for part in body.split("--" + b):
            m = re.search(r"Content-ID: <([^>]+)>.*?\r\n\r\nGET (\S+)", part, re.S)
            if not m: continue
            cid, url = m.group(1), m.group(2)
            u = urllib.parse.urlsplit(url)
            mid = u.path.split("/")[-1]
            fmt = urllib.parse.parse_qs(u.query).get("format", ["full"])[0]
            x = S["gmail"]["messages"].get(mid)
            if x:
                js = json.dumps(self.gview(x, fmt))
                status = "200 OK"
            else:
                js = json.dumps({"error": {"code": 404}})
                status = "404 Not Found"
            out += "--%s\r\nContent-Type: application/http\r\nContent-ID: <response-%s>\r\n\r\nHTTP/1.1 %s\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n%s\r\n" % (out_b, cid, status, js)
        out += "--%s--\r\n" % out_b
        self.send(200, raw=out.encode(), ctype="multipart/mixed; boundary=" + out_b)

    def gsend_upload(self):
        if not self.authed(): return
        ct = self.headers.get("Content-Type", "")
        b = ct.split("boundary=")[1].strip('"')
        body = self.body()
        parts = body.split(b"--" + b.encode())
        meta, raw = {}, b""
        for p in parts:
            if b"application/json" in p[:200]:
                meta = json.loads(p.split(b"\r\n\r\n", 1)[1].strip())
            elif b"message/rfc822" in p[:200]:
                raw = p.split(b"\r\n\r\n", 1)[1]
                if raw.endswith(b"\r\n"): raw = raw[:-2]
        msg = message_from_bytes(raw, policy=policy.default)
        extra()["raw_sent"].append(raw.decode("utf-8", "replace"))
        gm = S["gmail"]
        gid = "gs%d" % (len(gm["sent"]) + 1)
        gm["sent"].append({"threadId": meta.get("threadId", ""), "subject": str(msg["subject"]), "to": str(msg["to"]),
                           "in_reply_to": str(msg.get("In-Reply-To", "")), "parts": [p.get_content_type() for p in msg.walk()],
                           "attachments": [p.get_filename() for p in msg.walk() if p.get_filename()]})
        return self.send(200, {"id": gid, "threadId": meta.get("threadId") or gid, "labelIds": ["SENT"]})

# ---- meeting invitations, automatic replies, raw messages, the assistant ----
# POST /test/invites adds two invitations to each service (not there before,
# so the first sync's counts stay); GET /test/extra shows the answers given,
# the settings, the raw mail Gmail sent and the assistant's requests.

def extra():
    return S.setdefault("extra", {"answers": [], "ai": [], "raw_sent": [], "patches": []})

def enc_word(s):
    return s if s.isascii() else "=?UTF-8?B?%s?=" % base64.b64encode(s.encode()).decode()

def mime_of(headers, html):
    """A message's MIME source: its headers, the HTML base64-encoded."""
    out = "".join("%s: %s\r\n" % (k, v) for k, v in headers)
    body = base64.encodebytes(html.encode()).decode().replace("\n", "\r\n")
    return (out + "MIME-Version: 1.0\r\nContent-Type: text/html; charset=utf-8\r\n"
            "Content-Transfer-Encoding: base64\r\n\r\n" + body).encode()

def graph_mime(x):
    f = x["from"]["emailAddress"]
    t = time.strptime(x["receivedDateTime"][:19], "%Y-%m-%dT%H:%M:%S")
    return mime_of([("From", "%s <%s>" % (enc_word(f["name"]), f["address"])),
                    ("To", ", ".join(r["emailAddress"]["address"] for r in x["toRecipients"])),
                    ("Subject", enc_word(x["subject"])), ("Message-ID", x["internetMessageId"]),
                    ("Date", time.strftime("%a, %d %b %Y %H:%M:%S +0000", t))], x["body"]["content"])

def gmail_mime(x):
    def html_of(p):
        if p.get("mimeType") == "text/html" and p.get("body", {}).get("data"):
            return base64.urlsafe_b64decode(p["body"]["data"] + "==").decode()
        for c in p.get("parts", []):
            h = html_of(c)
            if h: return h
        return ""
    return mime_of([(h["name"], h["value"]) for h in x["payload"]["headers"]], html_of(x["payload"]))

def ics(lines):
    """iCalendar lines, CRLF-ended and folded at 75 octets (as RFC 5545 wants)."""
    out = []
    for l in lines:
        b, first = l.encode(), True
        while len(b) > (75 if first else 74):
            n = 75 if first else 74
            while (b[n] & 0xC0) == 0x80: n -= 1
            out.append((b"" if first else b" ") + b[:n])
            b, first = b[n:], False
        out.append((b"" if first else b" ") + b)
    return b"\r\n".join(out) + b"\r\n"

ICS_GOOGLE = ics([
    "BEGIN:VCALENDAR", "PRODID:-//Google Inc//Google Calendar 70.9054//EN", "VERSION:2.0",
    "CALSCALE:GREGORIAN", "METHOD:REQUEST", "BEGIN:VTIMEZONE", "TZID:Asia/Muscat",
    "X-LIC-LOCATION:Asia/Muscat", "BEGIN:STANDARD", "TZOFFSETFROM:+0400", "TZOFFSETTO:+0400",
    "TZNAME:+04", "DTSTART:19700101T000000", "END:STANDARD", "END:VTIMEZONE", "BEGIN:VEVENT",
    "DTSTART;TZID=Asia/Muscat:20261110T100000", "DTEND;TZID=Asia/Muscat:20261110T113000",
    "DTSTAMP:20261103T080000Z", "ORGANIZER;CN=Khalid Al Siyabi:mailto:khalid@example.om",
    "UID:7kq3trip2026@google.com",
    "ATTENDEE;CUTYPE=INDIVIDUAL;ROLE=REQ-PARTICIPANT;PARTSTAT=ACCEPTED;CN=Khalid Al Siyabi;X-NUM-GUESTS=0:mailto:khalid@example.om",
    "ATTENDEE;CUTYPE=INDIVIDUAL;ROLE=REQ-PARTICIPANT;PARTSTAT=NEEDS-ACTION;RSVP=TRUE;CN=foxoman@gmail.example;X-NUM-GUESTS=0:mailto:foxoman@gmail.example",
    "CREATED:20261103T075900Z",
    "DESCRIPTION:Agenda:\\n1. Photos\\, maps and the route\\n2. Who drives – رحلة جبل شمس\\; bring water",
    "LAST-MODIFIED:20261103T080000Z", "LOCATION:Jebel Shams\\, Al Hamra", "SEQUENCE:2",
    "STATUS:CONFIRMED", "SUMMARY:Trip planning", "TRANSP:OPAQUE", "END:VEVENT", "END:VCALENDAR"])

ICS_OUTLOOK = ics([
    "BEGIN:VCALENDAR", "METHOD:REQUEST", "PRODID:Microsoft Exchange Server 2010", "VERSION:2.0",
    "BEGIN:VTIMEZONE", "TZID:Arabian Standard Time", "BEGIN:STANDARD", "DTSTART:16010101T000000",
    "TZOFFSETFROM:+0400", "TZOFFSETTO:+0400", "END:STANDARD", "BEGIN:DAYLIGHT", "DTSTART:16010101T000000",
    "TZOFFSETFROM:+0400", "TZOFFSETTO:+0400", "END:DAYLIGHT", "END:VTIMEZONE", "BEGIN:VEVENT",
    "ORGANIZER;CN=Muna Al Balushi:mailto:muna@contoso.com",
    "ATTENDEE;ROLE=REQ-PARTICIPANT;PARTSTAT=NEEDS-ACTION;RSVP=TRUE;CN=Sultan:mailto:FOXOMAN@gmail.example",
    "DESCRIPTION;LANGUAGE=en-US:Closing the year.\\n", "UID:040000008200E00074C5B7101A82E0080000000050F1C2",
    "SUMMARY;LANGUAGE=en-US:National Day holiday", "DTSTART;VALUE=DATE:20261118",
    "DTEND;VALUE=DATE:20261120", "CLASS:PUBLIC", "PRIORITY:5", "DTSTAMP:20261103T090000Z",
    "TRANSP:TRANSPARENT", "STATUS:CONFIRMED", "SEQUENCE:0", "LOCATION;LANGUAGE=en-US:",
    "X-MICROSOFT-CDO-ALLDAYEVENT:TRUE", "END:VEVENT", "END:VCALENDAR"])

def seed_invites():
    g, gm = S["graph"], S["gmail"]
    if "inv1" in g["messages"]: return
    evs = g.setdefault("evs", {})
    evs["ev-1"] = {"id": "ev-1", "iCalUId": "040000008200E00074C5B7101A82E00800000000A1B2C3", "subject": "Photo app review",
                   "start": {"dateTime": "2026-11-12T06:00:00.0000000", "timeZone": "UTC"},
                   "end": {"dateTime": "2026-11-12T07:00:00.0000000", "timeZone": "UTC"},
                   "isAllDay": False, "location": {"displayName": "Room 2"}, "type": "singleInstance",
                   "organizer": {"emailAddress": {"name": "Ahmed Al Rawahi", "address": "ahmed@contoso.com"}},
                   "responseStatus": {"response": "notResponded", "time": "0001-01-01T00:00:00Z"},
                   "responseRequested": True, "isCancelled": False, "bodyPreview": "Let us go through the photo app."}
    evs["ev-2"] = dict(evs["ev-1"], id="ev-2", iCalUId="040000008200E00074C5B7101A82E00800000000D4E5F6",
                       subject="Budget 2027", isCancelled=True)
    for mid, ev, mt, subj in (("inv1", "ev-1", "meetingRequest", "Photo app review"),
                              ("inv2", "ev-2", "meetingCancelled", "Canceled: Budget 2027")):
        x = json.loads(json.dumps(g["messages"]["m1"]))
        x.update({"id": mid, "conversationId": "c" + mid, "subject": subj, "isRead": False,
                  "@odata.type": "#microsoft.graph.eventMessageRequest" if mt == "meetingRequest" else "#microsoft.graph.eventMessage",
                  "meetingMessageType": mt, "internetMessageId": "<%s@contoso.com>" % mid, "_event": evs[ev]})
        g["messages"][mid] = x
    def part(pid, mime, data=None, att=None, ctype=None, fname="", disp=None):
        hs = [{"name": "Content-Type", "value": ctype or mime}]
        if disp: hs.append({"name": "Content-Disposition", "value": disp})
        body = {"size": len(data or b"")}
        if att: body["attachmentId"] = att
        else: body["data"] = b64u(data)
        return {"partId": pid, "mimeType": mime, "filename": fname, "headers": hs, "body": body}
    def msg(mid, thread, frm, subj, parts, atts):
        gm["messages"][mid] = {
            "id": mid, "threadId": thread, "labelIds": ["INBOX", "UNREAD"], "snippet": subj,
            "internalDate": str(int(time.time() * 1000)), "sizeEstimate": 5000, "_atts": atts,
            "payload": {"mimeType": "multipart/mixed", "headers": [
                {"name": "From", "value": "%s <%s>" % frm}, {"name": "To", "value": gm["email"]},
                {"name": "Subject", "value": subj}, {"name": "Message-ID", "value": "<%s@mail.gmail.example>" % mid},
                {"name": "Date", "value": time.strftime("%a, %d %b %Y %H:%M:%S +0000", time.gmtime())}],
                "parts": parts}}
    msg("gi1", "ti1", ("Khalid Al Siyabi", "khalid@example.om"),
        "Invitation: Trip planning @ Tue 10 Nov 2026 10am - 11:30am (GST) (foxoman@gmail.example)",
        [{"partId": "0", "mimeType": "multipart/alternative", "filename": "", "headers": [], "body": {"size": 0}, "parts": [
            part("0.0", "text/plain", b"Khalid Al Siyabi has invited you to Trip planning", ctype='text/plain; charset="UTF-8"'),
            part("0.1", "text/html", b"<p>Khalid Al Siyabi has invited you to <b>Trip planning</b></p>", ctype='text/html; charset="UTF-8"'),
            part("0.2", "text/calendar", ICS_GOOGLE, ctype='text/calendar; charset="UTF-8"; method=REQUEST')]},
         part("1", "application/ics", att="ics-gi1", ctype='application/ics; name="invite.ics"', fname="invite.ics",
              disp='attachment; filename="invite.ics"')],
        {"ics-gi1": {"size": len(ICS_GOOGLE), "data": b64u(ICS_GOOGLE)}})
    msg("gi2", "ti2", ("Muna Al Balushi", "muna@contoso.com"), "National Day holiday",
        [part("0", "text/html", b"<p>Closing the year.</p>", ctype="text/html; charset=utf-8"),
         part("1", "text/calendar", att="cal-gi2", ctype='text/calendar; charset="utf-8"; method=REQUEST')],
        {"cal-gi2": {"size": len(ICS_OUTLOOK), "data": b64u(ICS_OUTLOOK)}})

def test_extra(h, path):
    if path == "/test/invites":
        seed_invites()
        return h.send(200, {"graph": ["inv1", "inv2"], "gmail": ["gi1", "gi2"]})
    g, gm = S["graph"], S["gmail"]
    return h.send(200, {"extra": extra(), "autoReply": g.get("autoReply"), "vacation": gm.get("vacation"),
                        "events": g.get("evs", {}), "sent": g["sent"], "gsent": gm["sent"]})

def bad(h, msg):
    h.send(400, {"error": {"code": "BadRequest", "message": msg}})
    return True

def graph_extra(h, meth, path):
    g = S["graph"]
    m = re.match(r"^/me/events/([^/]+)/(accept|tentativelyAccept|decline)$", path)
    if m and meth == "POST":
        ev = g.get("evs", {}).get(m.group(1))
        if ev is None:
            h.send(404, {"error": {"code": "ErrorItemNotFound", "message": "The specified object was not found in the store."}})
            return True
        b = json.loads(h.body() or b"{}")
        if any(k not in ("comment", "sendResponse", "proposedNewTime") for k in b) or \
           not isinstance(b.get("sendResponse", True), bool) or not isinstance(b.get("comment", ""), str):
            return bad(h, "Invalid request body")
        extra()["answers"].append({"event": m.group(1), "action": m.group(2), "comment": b.get("comment", ""),
                                   "sendResponse": b.get("sendResponse", True)})
        ev["responseStatus"] = {"response": {"accept": "accepted", "tentativelyAccept": "tentativelyAccepted",
                                             "decline": "declined"}[m.group(2)]}
        h.send(202, raw=b"")
        return True
    ar = g.setdefault("autoReply", {
        "status": "disabled", "externalAudience": "all", "internalReplyMessage": "", "externalReplyMessage": "",
        "scheduledStartDateTime": {"dateTime": "2026-11-20T08:00:00.0000000", "timeZone": "Arabian Standard Time"},
        "scheduledEndDateTime": {"dateTime": "2026-11-27T17:00:00.0000000", "timeZone": "Arabian Standard Time"}})
    if path == "/me/mailboxSettings/automaticRepliesSetting" and meth == "GET":
        h.send(200, ar)
        return True
    if path == "/me/mailboxSettings" and meth == "GET":
        h.send(200, {"automaticRepliesSetting": ar, "timeZone": "Arabian Standard Time"})
        return True
    if path == "/me/mailboxSettings" and meth == "PATCH":
        b = json.loads(h.body() or b"{}")
        new = b.get("automaticRepliesSetting")
        if not isinstance(new, dict): return bad(h, "automaticRepliesSetting is missing")
        st, aud = new.get("status", ar["status"]), new.get("externalAudience", ar["externalAudience"])
        if st not in ("disabled", "alwaysEnabled", "scheduled"): return bad(h, "bad status " + str(st))
        if aud not in ("none", "contactsOnly", "all"): return bad(h, "bad externalAudience " + str(aud))
        if st == "scheduled":
            for k in ("scheduledStartDateTime", "scheduledEndDateTime"):
                v = new.get(k, ar.get(k))
                if not (isinstance(v, dict) and v.get("dateTime") and v.get("timeZone")):
                    return bad(h, k + " is required when scheduled")
        extra()["patches"].append(b)
        ar.update(new)
        h.send(200, {"automaticRepliesSetting": ar})
        return True
    return False

def gmail_extra(h, meth, path):
    gm = S["gmail"]
    if path != "/settings/vacation": return False
    v = gm.setdefault("vacation", {"enableAutoReply": False, "responseSubject": "", "responseBodyPlainText": "",
                                   "responseBodyHtml": "", "restrictToContacts": False, "restrictToDomain": False})
    if meth == "GET":
        h.send(200, v)
        return True
    if meth == "PUT":
        b = json.loads(h.body() or b"{}")
        if not isinstance(b.get("enableAutoReply"), bool): return bad(h, "enableAutoReply is required")
        for k in ("startTime", "endTime"):
            if k in b and not (isinstance(b[k], str) and b[k].isdigit()): return bad(h, k + ": an int64 (as a string)")
        if "startTime" in b and "endTime" in b and int(b["startTime"]) >= int(b["endTime"]):
            return bad(h, "Start time must be before end time")
        gm["vacation"] = b
        h.send(200, b)
        return True
    return False

def ai(h, meth, path):
    """Anthropic's Messages API, as far as the tests need: the headers checked, a canned answer."""
    def err(code, kind, msg, headers=()):
        h.send(code, {"type": "error", "error": {"type": kind, "message": msg}}, headers=headers)
    if path != "/ai/v1/messages" or meth != "POST": return err(404, "not_found_error", "Not found")
    hd = {k.lower(): v for k, v in h.headers.items()}
    rec = {"headers": {k: hd.get(k, "") for k in ("x-api-key", "anthropic-version", "content-type")}, "body": None}
    extra()["ai"].append(rec)
    key = hd.get("x-api-key", "")
    if key == "sk-ant-busy":
        return err(429, "rate_limit_error", "Number of request tokens has exceeded your per-minute rate limit",
                   headers=[("retry-after", "7")])
    if key != "sk-ant-test": return err(401, "authentication_error", "invalid x-api-key")
    if hd.get("anthropic-version") != "2023-06-01": return err(400, "invalid_request_error", "anthropic-version: bad or missing")
    if not hd.get("content-type", "").startswith("application/json"):
        return err(400, "invalid_request_error", "content-type must be application/json")
    try: b = json.loads(h.body())
    except ValueError: return err(400, "invalid_request_error", "the body is not JSON")
    rec["body"] = b
    ms = b.get("messages")
    if not isinstance(b.get("model"), str) or not isinstance(b.get("max_tokens"), int) or not ms or \
       ms[0].get("role") != "user" or not isinstance(ms[0].get("content"), str):
        return err(400, "invalid_request_error", "model, max_tokens and messages are required")
    sysp = b.get("system", "")
    if sysp.startswith("Translate"): text = "مرحبا أحمد، الثلاثاء الساعة 2 مناسب."
    elif "suggest replies" in sysp:
        text = 'Here they are:\n["Yes, Tuesday at 2 works for me.", "Which room is it in?", "Sorry, I cannot make it this week."]'
    else:
        text = "- The photo app meeting is on Tuesday at 2.\n- Ahmed brings the test images.\n\nWhat is asked of you:\n- Confirm the time."
    h.send(200, {"id": "msg_mock_%d" % len(extra()["ai"]), "type": "message", "role": "assistant", "model": b["model"],
                 "content": [{"type": "text", "text": text}], "stop_reason": "end_turn", "stop_sequence": None,
                 "usage": {"input_tokens": 10, "output_tokens": 20}})

# ---- the calendars: events made, changed and deleted -------------------------------------------
# Graph: POST /me/events, GET / PATCH / DELETE /me/events/{id}, POST .../cancel,
# GET /me/calendar (which online meetings the account has); a series' first
# three events in calendarView. Google: events list / get / insert / patch /
# delete under /calendar/v3/calendars/primary, a series' first three
# instances with singleEvents=true. Both check what they get as the services
# do. GET /test/calendar shows the events and every request; POST
# /test/calendar {"teams": false} makes the Graph account one without Teams.

import datetime
from zoneinfo import ZoneInfo

WINZONES = {"Arabian Standard Time": "Asia/Dubai", "Pacific Standard Time": "America/Los_Angeles",
            "W. Europe Standard Time": "Europe/Berlin", "Eastern Standard Time": "America/New_York",
            "UTC": "UTC"}
GRAPH_FIELDS = {"subject", "body", "start", "end", "isAllDay", "location", "attendees", "isReminderOn",
                "reminderMinutesBeforeStart", "isOnlineMeeting", "onlineMeetingProvider", "recurrence",
                "showAs", "sensitivity", "importance", "categories"}
DAYS = {"sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"}
STAMP = re.compile(r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(\.\d+)?$")

def cal():
    c = S.setdefault("cal", {"teams": True, "seq": 0, "gexc": {}, "gseq": 0})
    S["graph"].setdefault("exc", {})
    return c

def cal_log(service, op, eid, body=None, query=None):
    extra().setdefault("calendar", []).append({"service": service, "op": op, "id": eid, "body": body,
                                                "query": query or {}})

# (where Python has no zone database -- Windows without the tzdata package --
# the zones the tests use, at their November offsets)
FIXED = {"UTC": 0, "Etc/UTC": 0, "Asia/Muscat": 4, "Asia/Dubai": 4, "Europe/Paris": 1,
         "Europe/Berlin": 1, "America/New_York": -5, "America/Los_Angeles": -8}

def zone_of(name):
    iana = WINZONES.get(name, name)
    try: return ZoneInfo(iana)
    except Exception:
        if iana in FIXED: return datetime.timezone(datetime.timedelta(hours=FIXED[iana]), iana)
        return None

def wall(s):
    return datetime.datetime.strptime(s[:19], "%Y-%m-%dT%H:%M:%S")

def add_months(d, n):
    y, m = divmod(d.month - 1 + n, 12)
    for day in (d.day, 30, 29, 28):
        try: return d.replace(year=d.year + y, month=m + 1, day=day)
        except ValueError: pass

def step(d, kind, k):
    if kind == "daily": return d + datetime.timedelta(days=k)
    if kind == "weekly": return d + datetime.timedelta(days=7 * k)
    if kind in ("absoluteMonthly", "relativeMonthly", "MONTHLY"): return add_months(d, k)
    if kind in ("absoluteYearly", "relativeYearly", "YEARLY"): return add_months(d, 12 * k)
    return d + datetime.timedelta(days=(1 if kind == "DAILY" else 7) * k)

# -- Graph --

def graph_check(ev):
    """What Graph would refuse in an event; "" when it takes it."""
    for k in ev:
        if k not in GRAPH_FIELDS and not k.startswith("_") and k not in ("id", "type", "isOrganizer", "organizer",
                                                                         "onlineMeeting", "seriesMasterId"):
            return "Could not find a property named '%s' on type 'microsoft.graph.event'." % k
    for k in ("start", "end"):
        t = ev.get(k)
        if not isinstance(t, dict) or not STAMP.match(t.get("dateTime") or "") or not t.get("timeZone"):
            return k + ": a dateTime and a timeZone are required"
        if zone_of(t["timeZone"]) is None: return "TimeZoneNotSupportedException: " + t["timeZone"]
    if ev.get("isAllDay"):
        if any(not ev[k]["dateTime"][11:19] == "00:00:00" for k in ("start", "end")) or \
           ev["start"]["timeZone"] != ev["end"]["timeZone"]:
            return "An all-day event must start and end at midnight, in one time zone"
    if graph_utc(ev["end"]) < graph_utc(ev["start"]): return "The end must not be before the start"
    for a in ev.get("attendees") or []:
        if "@" not in (a.get("emailAddress") or {}).get("address", "") or a.get("type") not in ("required", "optional", "resource"):
            return "attendees: an emailAddress and a type"
    if ev.get("isOnlineMeeting") and ev.get("onlineMeetingProvider") not in cal_allowed():
        return "The online meeting provider is not allowed for this account"
    if "body" in ev and (ev["body"] or {}).get("contentType", "").lower() not in ("text", "html"):
        return "body: contentType text or html"
    if "isReminderOn" in ev and not isinstance(ev["isReminderOn"], bool): return "isReminderOn: a boolean"
    r = ev.get("recurrence")
    if r is not None:
        p, rg = r.get("pattern") or {}, r.get("range") or {}
        t = p.get("type")
        if t not in ("daily", "weekly", "absoluteMonthly", "relativeMonthly", "absoluteYearly", "relativeYearly"):
            return "recurrence: a pattern type"
        if p.get("interval", 0) < 1: return "recurrence: the interval"
        if t == "weekly" and (not p.get("daysOfWeek") or any(d not in DAYS for d in p["daysOfWeek"])):
            return "recurrence: daysOfWeek is required for a weekly pattern"
        if t == "absoluteMonthly" and not 1 <= p.get("dayOfMonth", 0) <= 31: return "recurrence: dayOfMonth"
        if t == "absoluteYearly" and not (1 <= p.get("dayOfMonth", 0) <= 31 and 1 <= p.get("month", 0) <= 12):
            return "recurrence: dayOfMonth and month"
        if rg.get("type") not in ("noEnd", "endDate", "numbered") or not re.match(r"^\d{4}-\d\d-\d\d$", rg.get("startDate", "")):
            return "recurrence: a range with a startDate"
    return ""

def cal_allowed():
    return ["teamsForBusiness"] if cal()["teams"] else []

def graph_utc(t):
    z = zone_of(t.get("timeZone") or "UTC")
    return wall(t["dateTime"]).replace(tzinfo=z).astimezone(datetime.timezone.utc)

def graph_view(ev):
    """An event as Graph shows it with Prefer: outlook.timezone="UTC"."""
    out = {k: v for k, v in ev.items() if not k.startswith("_")}
    for k in ("start", "end"):
        if k not in ev: continue
        if ev.get("isAllDay"): out[k] = {"dateTime": ev[k]["dateTime"][:19] + ".0000000", "timeZone": "UTC"}
        else: out[k] = {"dateTime": graph_utc(ev[k]).strftime("%Y-%m-%dT%H:%M:%S.0000000"), "timeZone": "UTC"}
    return out

def graph_occurrences(ev):
    """A series' first three events, each of its own."""
    g, kind = S["graph"], ev["recurrence"]["pattern"]["type"]
    cal()
    out = []
    for k in range(3):
        oid = "%s-occ%d" % (ev["id"], k)
        x = g["exc"].get(oid, {})
        if x is None: continue                      # (deleted)
        occ = {kk: v for kk, v in ev.items() if kk != "recurrence"}
        for t in ("start", "end"):
            occ[t] = dict(ev[t], dateTime=step(wall(ev[t]["dateTime"]), kind, k).strftime("%Y-%m-%dT%H:%M:%S"))
        occ.update(x)
        occ.update(id=oid, type="occurrence" if not x else "exception", seriesMasterId=ev["id"])
        out.append(occ)
    return out

def graph_calendar_view():
    out = []
    for ev in S["graph"]["events"]:
        if ev.get("recurrence"): out += [graph_view(o) for o in graph_occurrences(ev)]
        else: out.append(graph_view(ev))
    return out

def graph_find(eid):
    for ev in S["graph"]["events"]:
        if ev["id"] == eid: return ev
        if ev.get("recurrence") and eid.startswith(ev["id"] + "-occ"):
            for o in graph_occurrences(ev):
                if o["id"] == eid: return o

def graph_cal(h, meth, path):
    g = S["graph"]
    c = cal()
    if path == "/me/calendar" and meth == "GET":
        h.send(200, {"id": "cal-1", "name": "Calendar", "allowedOnlineMeetingProviders": cal_allowed(),
                     "defaultOnlineMeetingProvider": cal_allowed()[0] if cal_allowed() else "none"})
        return True
    if path == "/me/events" and meth == "POST":
        b = json.loads(h.body() or b"{}")
        cal_log("graph", "create", "", b)
        err = graph_check(b)
        if err: return bad(h, err)
        c["seq"] += 1
        ev = dict(b, id="ev-new-%d" % c["seq"], type="seriesMaster" if b.get("recurrence") else "singleInstance",
                  isOrganizer=True, organizer={"emailAddress": {"name": g["me"]["displayName"], "address": g["me"]["mail"]}})
        ev["attendees"] = [dict(a, status={"response": "none"}) for a in b.get("attendees", [])]
        if b.get("isOnlineMeeting"):
            ev["onlineMeeting"] = {"joinUrl": "https://teams.microsoft.example/l/meetup-join/" + ev["id"]}
        g["events"].append(ev)
        h.send(201, graph_view(ev))
        return True
    m = re.match(r"^/me/events/([^/]+)(/cancel)?$", path)
    if not m: return False
    eid, cancel = m.group(1), m.group(2)
    ev = graph_find(eid)
    if ev is None:
        h.send(404, {"error": {"code": "ErrorItemNotFound", "message": "The specified object was not found in the store."}})
        return True
    occurrence = "seriesMasterId" in ev
    if meth == "GET" and not cancel:
        h.send(200, graph_view(ev))
        return True
    if meth == "PATCH" and not cancel:
        b = json.loads(h.body() or b"{}")
        cal_log("graph", "update", eid, b)
        if occurrence and "recurrence" in b: return bad(h, "An occurrence cannot have a recurrence")
        new = dict(ev, **b)
        if new.get("recurrence") is None: new.pop("recurrence", None)
        err = graph_check(new)
        if err: return bad(h, err)
        if b.get("isOnlineMeeting") and "onlineMeeting" not in new:
            new["onlineMeeting"] = {"joinUrl": "https://teams.microsoft.example/l/meetup-join/" + eid}
        if occurrence:
            g["exc"][eid] = dict(g["exc"].get(eid) or {}, **b)
        else:
            new["type"] = "seriesMaster" if new.get("recurrence") else "singleInstance"
            ev.clear()
            ev.update(new)
        h.send(200, graph_view(new))
        return True
    if (meth == "DELETE" and not cancel) or (meth == "POST" and cancel):
        b = json.loads(h.body() or b"{}") if cancel else None
        cal_log("graph", "cancel" if cancel else "delete", eid, b)
        if cancel and not ev.get("isOrganizer"):
            return bad(h, "Your request can't be completed. You need to be an organizer to cancel a meeting.")
        if occurrence: g["exc"][eid] = None
        else: g["events"].remove(ev)
        h.send(202 if cancel else 204, raw=b"")
        return True
    return False

# -- Google --

GCAL_FIELDS = {"summary", "description", "location", "start", "end", "attendees", "reminders", "recurrence",
               "conferenceData", "colorId", "transparency", "visibility"}

def gtime(t):
    """A Google start or end as an aware datetime (None for a whole day)."""
    if t.get("date"): return None
    s = t["dateTime"]
    if s.endswith("Z") or re.search(r"[+-]\d\d:\d\d$", s):
        return datetime.datetime.fromisoformat(s.replace("Z", "+00:00"))
    return datetime.datetime.fromisoformat(s).replace(tzinfo=ZoneInfo(t["timeZone"]))

def gcal_check(ev):
    for k in ev:
        if k not in GCAL_FIELDS and not k.startswith("_") and k not in ("id", "status", "organizer", "creator",
                                                                        "hangoutLink", "recurringEventId", "kind"):
            return "Unknown field: " + k
    for k in ("start", "end"):
        t = ev.get(k)
        if not isinstance(t, dict) or bool(t.get("date")) == bool(t.get("dateTime")):
            return k + ": a date or a dateTime"
        if t.get("timeZone") is not None:
            try: ZoneInfo(t["timeZone"])
            except Exception: return "Invalid time zone definition for %s time." % k
        if t.get("date") and not re.match(r"^\d{4}-\d\d-\d\d$", t["date"]): return k + ": a bad date"
        if t.get("dateTime"):
            s = t["dateTime"]
            if not (s.endswith("Z") or re.search(r"[+-]\d\d:\d\d$", s)) and not t.get("timeZone"):
                return "Missing time zone definition for %s time." % k
            if ev.get("recurrence") and not t.get("timeZone"):
                return "Missing time zone definition for %s time (a recurring event)." % k
    if bool(ev["start"].get("date")) != bool(ev["end"].get("date")): return "start and end: both dates or both times"
    if ev["start"].get("date"):
        if ev["end"]["date"] <= ev["start"]["date"]: return "The specified time range is empty."
    elif gtime(ev["end"]) < gtime(ev["start"]): return "The specified time range is empty."
    for r in ev.get("recurrence") or []:
        if not re.match(r"^(RRULE|EXRULE|RDATE|EXDATE)[:;]", r): return "Invalid recurrence rule."
    for a in ev.get("attendees") or []:
        if "@" not in a.get("email", ""): return "Invalid attendee email."
    rem = ev.get("reminders")
    if rem is not None:
        if rem.get("useDefault") and rem.get("overrides"): return "Cannot specify both default reminders and overrides at the same time."
        for o in rem.get("overrides") or []:
            if o.get("method") not in ("popup", "email") or not 0 <= o.get("minutes", -1) <= 40320:
                return "Invalid reminder."
    return ""

def gcal_conference(ev, q, b):
    """conferenceData.createRequest, as Google takes it: only with conferenceDataVersion=1."""
    if q.get("conferenceDataVersion", ["0"])[0] != "1" or "conferenceData" not in b: return ""
    cd = b["conferenceData"]
    if cd is None:
        ev.pop("conferenceData", None)
        ev.pop("hangoutLink", None)
        return ""
    cr = cd.get("createRequest") or {}
    if not cr.get("requestId") or (cr.get("conferenceSolutionKey") or {}).get("type") not in ("hangoutsMeet", "eventHangout", "eventNamedHangout"):
        return "Invalid conference type value."
    link = "https://meet.google.example/" + ev["id"]
    ev["hangoutLink"] = link
    ev["conferenceData"] = {"conferenceId": ev["id"], "conferenceSolution": {"key": {"type": "hangoutsMeet"}, "name": "Google Meet"},
                            "createRequest": dict(cr, status={"statusCode": "success"}),
                            "entryPoints": [{"entryPointType": "video", "uri": link, "label": link[8:]}]}
    return ""

def gcal_view(ev):
    out = {k: v for k, v in ev.items() if not k.startswith("_")}
    for k in ("start", "end"):
        if k in ev and ev[k].get("dateTime"):
            out[k] = {"dateTime": gtime(ev[k]).isoformat(), "timeZone": ev[k].get("timeZone") or "UTC"}
    return out

def gcal_instances(ev):
    freq = re.search(r"FREQ=(\w+)", ev["recurrence"][0]).group(1)
    out = []
    for k in range(3):
        inst = {kk: v for kk, v in ev.items() if kk != "recurrence"}
        if ev["start"].get("date"):
            for t in ("start", "end"):
                d = datetime.datetime.strptime(ev[t]["date"], "%Y-%m-%d")
                inst[t] = {"date": step(d, freq, k).strftime("%Y-%m-%d")}
            iid = ev["id"] + "_" + inst["start"]["date"].replace("-", "")
        else:
            for t in ("start", "end"):
                a = gtime(ev[t])
                inst[t] = {"dateTime": step(a.replace(tzinfo=None), freq, k).replace(tzinfo=a.tzinfo).isoformat(),
                           "timeZone": ev[t]["timeZone"]}
            iid = ev["id"] + "_" + gtime(inst["start"]).astimezone(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        x = cal()["gexc"].get(iid, {})
        if x is None: continue
        inst.update(x)
        inst.update(id=iid, recurringEventId=ev["id"])
        out.append(inst)
    return out

def gcal_find(eid):
    for ev in S["gmail"]["events"]:
        if ev["id"] == eid: return ev
        if ev.get("recurrence") and eid.startswith(ev["id"] + "_"):
            for i in gcal_instances(ev):
                if i["id"] == eid: return i

def gcal(h, meth, path, q):
    if not h.authed(): return
    gm, c = S["gmail"], cal()
    for k in ("sendUpdates",):
        if k in q and q[k][0] not in ("all", "externalOnly", "none"): return bad(h, "Invalid value for sendUpdates")
    query = {k: v[0] for k, v in q.items() if k in ("sendUpdates", "conferenceDataVersion")}
    if path == "/calendars/primary/events" and meth == "GET":
        items = []
        for ev in gm["events"]:
            if ev.get("recurrence") and q.get("singleEvents", ["false"])[0] == "true": items += gcal_instances(ev)
            else: items.append(ev)
        return h.send(200, {"kind": "calendar#events", "defaultReminders": [{"method": "popup", "minutes": 10}],
                            "items": [gcal_view(x) for x in items]})
    if path == "/calendars/primary/events" and meth == "POST":
        b = json.loads(h.body() or b"{}")
        cal_log("google", "create", "", b, query)
        c["gseq"] += 1
        ev = {k: v for k, v in b.items() if k != "conferenceData"}
        ev.update(id="gev%d" % c["gseq"], status="confirmed", kind="calendar#event",
                  organizer={"email": gm["email"], "self": True}, creator={"email": gm["email"], "self": True})
        ev["attendees"] = [dict(a, responseStatus="needsAction") for a in b.get("attendees", [])]
        err = gcal_check(ev) or gcal_conference(ev, q, b)
        if err:
            c["gseq"] -= 1
            return bad(h, err)
        gm["events"].append(ev)
        return h.send(200, gcal_view(ev))
    m = re.match(r"^/calendars/primary/events/([^/]+)$", path)
    if not m: return h.send(404, {"error": {"code": 404, "message": "Not Found"}})
    eid = m.group(1)
    ev = gcal_find(eid)
    if ev is None:
        return h.send(404, {"error": {"code": 404, "message": "Not Found"}})
    instance = "recurringEventId" in ev
    if meth == "GET": return h.send(200, gcal_view(ev))
    if meth == "PATCH":
        b = json.loads(h.body() or b"{}")
        cal_log("google", "update", eid, b, query)
        new = json.loads(json.dumps(ev))
        for k, v in b.items():
            if k == "conferenceData": continue
            if v is None: new.pop(k, None)
            elif k in ("start", "end") and isinstance(v, dict):
                t = dict(new.get(k) or {})
                for kk, vv in v.items():
                    if vv is None: t.pop(kk, None)
                    else: t[kk] = vv
                new[k] = t
            else: new[k] = v
        if instance and new.get("recurrence"): return bad(h, "An instance cannot have a recurrence")
        if new.get("recurrence") == []: new.pop("recurrence")
        err = gcal_check(new) or gcal_conference(new, q, b)
        if err: return bad(h, err)
        if instance:
            c["gexc"][eid] = {k: v for k, v in new.items() if k not in ("id", "recurringEventId")}
        else:
            ev.clear()
            ev.update(new)
        return h.send(200, gcal_view(new))
    if meth == "DELETE":
        cal_log("google", "delete", eid, None, query)
        if instance: c["gexc"][eid] = None
        else: gm["events"].remove(ev)
        return h.send(204, raw=b"")
    h.send(405, {"error": {"code": 405, "message": "Method not allowed"}})

def test_calendar(h, meth):
    c = cal()
    if meth == "POST":
        b = json.loads(h.body() or b"{}")
        if "teams" in b: c["teams"] = bool(b["teams"])
    h.send(200, {"graph": S["graph"]["events"], "google": S["gmail"]["events"],
                 "log": extra().get("calendar", []), "teams": c["teams"]})

if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8765
    srv = ThreadingHTTPServer(("127.0.0.1", port), H)
    print("mailmock on", port, flush=True)
    srv.serve_forever()
