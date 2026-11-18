## Exchange Web Services (EWS): the mail of a company's own Exchange
## server (2010 and later) -- and of Exchange Online, with an OAuth token --
## over SOAP and HTTPS: the folders, what changed in one since last time
## (SyncFolderItems), the messages' fields and their whole source (MIME),
## read and flagged, categories, moves and deletes, a search (AQS), and
## sending (the message's MIME, a copy kept in Sent Items). Signs in with a
## password (Basic, else NTLM -- `retroui/ntlm` -- the way Windows servers
## ask) or a token.
##
## .. code-block:: nim
##   import retroui/ews
##   let c = ewsConnect("https://mail.example.com/EWS/Exchange.asmx", "EXAMPLE\\maryam", password)
##   for f in c.folders(): echo f.name, " ", f.role, " ", f.unread
##   let ch = c.syncItems(inboxId, "")          # all of it the first time, then what changed
##   for it in c.getItems(ch.changed): echo it.subject, " ", it.fromEmail
##   echo c.mimeOf(ch.changed[0])               # the whole message
##   c.setRead(id, true)
##   c.sendMime(raw)
##
## Every call blocks (run them on a thread of their own); the connection
## is kept open between them (NTLM signs in the connection). `EwsError`
## carries the server's words (`code`: its ResponseCode, "ErrorItemNotFound").
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[strutils, base64, xmlparser, xmltree, times, uri, strtabs]
import netconn, ntlm
export netconn.NetError

type
  EwsError* = object of IOError
    ## The server refused (`status`: 401 a sign-in refused; 0 no answer) or
    ## an operation failed (`code`: its ResponseCode).
    status*: int
    code*: string
  EwsClient* = ref object
    ## A connection to one mailbox's Exchange (`ewsConnect`).
    url*: string
    user, password, bearer: string
    host, path: string
    port: int
    tls, insecure: bool
    conn: NetConn
    useNtlm: bool
    version*: string            ## the RequestServerVersion asked ("Exchange2013_SP1"; older servers: 2010)
    timeoutSec: int
  EwsFolder* = object
    id*, changeKey*, parentId*, name*: string
    role*: string               ## inbox, sent, drafts, trash, junk, archive, outbox, or ""
    total*, unread*: int
  EwsItem* = object
    id*, changeKey*, folderId*: string
    subject*, fromName*, fromEmail*, toList*, ccList*: string
    received*: float            ## epoch seconds
    size*: int
    read*, hasAttachments*, flagged*, important*: bool
    messageId*, inReplyTo*, references*, conversation*: string
    categories*: seq[string]
    preview*: string
  EwsChanges* = object
    changed*: seq[string]       ## items new or changed (`getItems` them)
    deleted*: seq[string]
    readChanged*: seq[tuple[id: string; read: bool]]
    state*: string              ## the next call's `state`
    done*: bool                 ## all of it told (else ask again from `state`)

const
  roles = [("inbox", "inbox"), ("sentitems", "sent"), ("drafts", "drafts"), ("deleteditems", "trash"),
           ("junkemail", "junk"), ("archive", "archive"), ("outbox", "outbox")]
  itemProps = ["item:Subject", "message:From", "message:ToRecipients", "message:CcRecipients",
               "item:DateTimeReceived", "item:Size", "message:IsRead", "item:HasAttachments",
               "message:InternetMessageId", "message:InReplyTo", "message:References",
               "item:Importance", "item:Categories", "item:ConversationId", "item:ParentFolderId"]
  props2013 = ["item:Flag", "item:Preview"]

proc ewsFail(msg: string; status = 0; code = "") {.noreturn.} =
  var e = newException(EwsError, msg)
  e.status = status
  e.code = code
  raise e

proc esc(s: string): string =
  s.multiReplace(("&", "&amp;"), ("<", "&lt;"), (">", "&gt;"), ("\"", "&quot;"))

# ---- HTTP, kept alive -----------------------------------------------------------------

proc closeConn(c: EwsClient) =
  if c.conn != nil:
    c.conn.close()
    c.conn = nil

proc roundTrip(c: EwsClient; body, auth: string): tuple[status: int; headers: seq[(string, string)]; body: string] =
  ## (one POST on the kept connection -- made again when the server closed it)
  for attempt in 0 .. 1:
    try:
      if c.conn == nil:
        c.conn = openSecured(c.host, c.port, (if c.tls: secTls else: secNone), c.timeoutSec, c.insecure)
      var req = "POST " & c.path & " HTTP/1.1\r\nHost: " & c.host &
                "\r\nContent-Type: text/xml; charset=utf-8\r\nAccept: text/xml\r\n" &
                "Connection: keep-alive\r\nContent-Length: " & $body.len & "\r\n"
      if auth.len > 0: req.add "Authorization: " & auth & "\r\n"
      req.add "\r\n"
      c.conn.write(req & body)
      let status = c.conn.readLine()
      let sp = status.split(' ')
      if sp.len < 2 or not sp[0].startsWith("HTTP/"): ewsFail("not an HTTP answer: " & status)
      result.status = try: parseInt(sp[1]) except ValueError: 0
      var length = -1
      var chunked, closing = false
      while true:
        let l = c.conn.readLine()
        if l.len == 0: break
        let k = l.find(':')
        if k <= 0: continue
        let name = l[0 ..< k].strip.toLowerAscii
        let value = l[k + 1 .. ^1].strip
        result.headers.add (name, value)
        case name
        of "content-length": length = try: parseInt(value) except ValueError: -1
        of "transfer-encoding": chunked = "chunked" in value.toLowerAscii
        of "connection": closing = "close" in value.toLowerAscii
        else: discard
      if chunked:
        while true:
          let sz = c.conn.readLine().split(';')[0].strip
          let n = try: parseHexInt(sz) except ValueError: 0
          if n == 0:
            while c.conn.readLine().len > 0: discard
            break
          result.body.add c.conn.readBytes(n)
          discard c.conn.readLine()
      elif length >= 0:
        result.body = c.conn.readBytes(length)
      else:
        closing = true
        try:
          while true: result.body.add c.conn.readLine() & "\n"
        except NetError: discard
      if closing: c.closeConn()
      return
    except NetError:
      c.closeConn()
      if attempt == 1: raise

proc authHeaderOf(headers: seq[(string, string)]; kind: string): string =
  for (k, v) in headers:
    if k == "www-authenticate" and v.toLowerAscii.startsWith(kind & " "):
      return v[kind.len + 1 .. ^1].strip

proc post(c: EwsClient; body: string): string =
  ## (a SOAP request sent, signed in as the server asks; the answer's XML)
  if c.bearer.len > 0:
    let r = c.roundTrip(body, "Bearer " & c.bearer)
    if r.status == 401: ewsFail("the token was refused", 401)
    if r.status != 200 and r.status != 500: ewsFail("the server answered " & $r.status, r.status)
    return r.body
  if not c.useNtlm:
    let r = c.roundTrip(body, "Basic " & encode(c.user & ":" & c.password))
    if r.status != 401:
      if r.status != 200 and r.status != 500: ewsFail("the server answered " & $r.status, r.status)
      return r.body
    var offers = false
    for (k, v) in r.headers:
      if k == "www-authenticate" and (v.toLowerAscii.startsWith("ntlm") or v.toLowerAscii.startsWith("negotiate")):
        offers = true
    if not offers: ewsFail("the server refused the user name or password", 401)
    c.useNtlm = true
  # NTLM: the three messages on one connection
  let first = c.roundTrip(body, "NTLM " & ntlmNegotiate())
  if first.status != 401:
    if first.status == 200 or first.status == 500: return first.body   # (signed in already: the connection)
    ewsFail("the server answered " & $first.status, first.status)
  let ch = authHeaderOf(first.headers, "ntlm")
  if ch.len == 0: ewsFail("the server refused the user name or password", 401)
  var t3 = ""
  try: t3 = ntlmAuthenticate(ch, c.user, c.password)
  except ValueError: ewsFail("the server's NTLM challenge is damaged", 401)
  let r = c.roundTrip(body, "NTLM " & t3)
  if r.status == 401: ewsFail("the server refused the user name or password", 401)
  if r.status != 200 and r.status != 500: ewsFail("the server answered " & $r.status, r.status)
  r.body

# ---- SOAP -------------------------------------------------------------------------------

proc local(tag: string): string =
  let k = tag.find(':')
  if k >= 0: tag[k + 1 .. ^1] else: tag

proc kid(n: XmlNode; name: string): XmlNode =
  if n == nil or n.kind != xnElement: return nil
  for k in n:
    if k.kind == xnElement and local(k.tag) == name: return k

proc kids(n: XmlNode; name: string): seq[XmlNode] =
  if n == nil or n.kind != xnElement: return
  for k in n:
    if k.kind == xnElement and local(k.tag) == name: result.add k

proc findAll(n: XmlNode; name: string; into: var seq[XmlNode]) =
  if n == nil or n.kind != xnElement: return
  for k in n:
    if k.kind == xnElement:
      if local(k.tag) == name: into.add k
      findAll(k, name, into)

proc textOf(n: XmlNode): string = (if n == nil: "" else: n.innerText.strip)

proc attrOf(n: XmlNode; name: string): string =
  if n == nil or n.kind != xnElement or n.attrs == nil: return ""
  for k, v in n.attrs:
    if local(k) == name: return v

proc envelope(c: EwsClient; body: string): string =
  "<?xml version=\"1.0\" encoding=\"utf-8\"?>" &
  "<soap:Envelope xmlns:soap=\"http://schemas.xmlsoap.org/soap/envelope/\" " &
  "xmlns:t=\"http://schemas.microsoft.com/exchange/services/2006/types\" " &
  "xmlns:m=\"http://schemas.microsoft.com/exchange/services/2006/messages\">" &
  "<soap:Header><t:RequestServerVersion Version=\"" & c.version & "\"/></soap:Header>" &
  "<soap:Body>" & body & "</soap:Body></soap:Envelope>"

proc soap(c: EwsClient; body: string; skipGone = false): seq[XmlNode] =
  ## (the operation's response messages; the first error raises -- with
  ## `skipGone`, not an item gone meanwhile: it is left out)
  let xml = c.post(c.envelope(body))
  var doc: XmlNode
  try: doc = parseXml(xml)
  except CatchableError: ewsFail("the server's answer is not XML")
  var faults: seq[XmlNode]
  findAll(doc, "Fault", faults)
  if faults.len > 0:
    let why = textOf(kid(faults[0], "faultstring"))
    var codes: seq[XmlNode]
    findAll(faults[0], "ResponseCode", codes)
    let code = if codes.len > 0: textOf(codes[0]) else: ""
    ewsFail(if why.len > 0: why else: "the server failed", 500, code)
  var msgs: seq[XmlNode]
  findAll(doc, "ResponseMessages", msgs)
  if msgs.len == 0: ewsFail("the server's answer has no response")
  for m in msgs[0]:
    if m.kind != xnElement: continue
    if attrOf(m, "ResponseClass") == "Error":
      let code = textOf(kid(m, "ResponseCode"))
      if skipGone and code == "ErrorItemNotFound": continue
      ewsFail(textOf(kid(m, "MessageText")), 200, code)
    result.add m

proc call(c: EwsClient; body: string; skipGone = false): seq[XmlNode] =
  ## (as `soap`, once more as Exchange 2010 when the server is older)
  try: result = c.soap(body, skipGone)
  except EwsError as e:
    if e.code == "ErrorInvalidServerVersion" and c.version != "Exchange2010_SP2":
      c.version = "Exchange2010_SP2"
      result = c.soap(body.multiReplace(("<t:FieldURI FieldURI=\"item:Flag\"/>", ""),
                                        ("<t:FieldURI FieldURI=\"item:Preview\"/>", "")), skipGone)
    else: raise

proc ewsConnect*(url, user, password: string; bearer = ""; timeoutSec = 60; insecure = false): EwsClient =
  ## Signs in to the EWS at `url` ("https://mail.example.com/EWS/Exchange.asmx";
  ## a host alone gets that path) with a password ("DOMAIN\\user" or the
  ## address) or an OAuth `bearer` token. Raises `EwsError` (401: refused).
  var u = url.strip
  if not u.startsWith("http"): u = "https://" & u
  let p = parseUri(u)
  result = EwsClient(url: u, user: user, password: password, bearer: bearer, host: p.hostname,
                     tls: p.scheme == "https", insecure: insecure, version: "Exchange2013_SP1",
                     timeoutSec: timeoutSec)
  result.port = if p.port.len > 0: parseInt(p.port) elif result.tls: 443 else: 80
  result.path = if p.path.len > 1: p.path else: "/EWS/Exchange.asmx"
  # (signed in once, to be sure: the Inbox's folder)
  discard result.call("<m:GetFolder><m:FolderShape><t:BaseShape>IdOnly</t:BaseShape></m:FolderShape>" &
                      "<m:FolderIds><t:DistinguishedFolderId Id=\"inbox\"/></m:FolderIds></m:GetFolder>")

proc close*(c: EwsClient) =
  ## Closes the kept connection.
  if c != nil: c.closeConn()

# ---- folders ---------------------------------------------------------------------------

proc folderOf(n: XmlNode): EwsFolder =
  let fid = kid(n, "FolderId")
  result.id = attrOf(fid, "Id")
  result.changeKey = attrOf(fid, "ChangeKey")
  result.parentId = attrOf(kid(n, "ParentFolderId"), "Id")
  result.name = textOf(kid(n, "DisplayName"))
  result.total = try: parseInt(textOf(kid(n, "TotalCount"))) except ValueError: 0
  result.unread = try: parseInt(textOf(kid(n, "UnreadCount"))) except ValueError: 0

proc folders*(c: EwsClient): seq[EwsFolder] =
  ## The mailbox's mail folders (all levels), with what each is for.
  let r = c.call("<m:FindFolder Traversal=\"Deep\"><m:FolderShape><t:BaseShape>AllProperties</t:BaseShape>" &
                 "</m:FolderShape><m:Restriction><t:IsEqualTo><t:FieldURI FieldURI=\"folder:FolderClass\"/>" &
                 "<t:FieldURIOrConstant><t:Constant Value=\"IPF.Note\"/></t:FieldURIOrConstant></t:IsEqualTo>" &
                 "</m:Restriction><m:ParentFolderIds><t:DistinguishedFolderId Id=\"msgfolderroot\"/>" &
                 "</m:ParentFolderIds></m:FindFolder>")
  var root = ""
  for m in r:
    var fs: seq[XmlNode]
    findAll(m, "Folder", fs)
    for f in fs: result.add folderOf(f)
  # what each is for: the distinguished folders' ids
  var known: seq[tuple[id, role: string]]
  for (d, role) in @roles & @[("msgfolderroot", "root")]:
    try:
      let g = c.call("<m:GetFolder><m:FolderShape><t:BaseShape>IdOnly</t:BaseShape></m:FolderShape>" &
                     "<m:FolderIds><t:DistinguishedFolderId Id=\"" & d & "\"/></m:FolderIds></m:GetFolder>")
      var fid: seq[XmlNode]
      if g.len > 0: findAll(g[0], "FolderId", fid)
      if fid.len > 0:
        if role == "root": root = attrOf(fid[0], "Id")
        else: known.add (attrOf(fid[0], "Id"), role)
    except EwsError: discard           # (an older server: no Archive)
  for f in result.mitems:
    for k in known:
      if k.id == f.id: f.role = k.role
    if f.parentId == root: f.parentId = ""

# ---- items -----------------------------------------------------------------------------

proc parseTime(s: string): float =
  let t = s.strip
  try: result = parse(t[0 ..< min(19, t.len)], "yyyy-MM-dd'T'HH:mm:ss", utc()).toTime.toUnixFloat
  except CatchableError: result = 0

proc mailboxText(n: XmlNode): tuple[name, email: string] =
  let mb = kid(n, "Mailbox")
  (textOf(kid(mb, "Name")), textOf(kid(mb, "EmailAddress")))

proc listOf(n: XmlNode): string =
  var parts: seq[string]
  for mb in kids(n, "Mailbox"):
    let name = textOf(kid(mb, "Name"))
    let email = textOf(kid(mb, "EmailAddress"))
    parts.add(if name.len > 0 and name != email: name & " <" & email & ">" else: email)
  parts.join(", ")

proc itemOf(n: XmlNode): EwsItem =
  let iid = kid(n, "ItemId")
  result.id = attrOf(iid, "Id")
  result.changeKey = attrOf(iid, "ChangeKey")
  result.folderId = attrOf(kid(n, "ParentFolderId"), "Id")
  result.subject = textOf(kid(n, "Subject"))
  (result.fromName, result.fromEmail) = mailboxText(kid(n, "From"))
  result.toList = listOf(kid(n, "ToRecipients"))
  result.ccList = listOf(kid(n, "CcRecipients"))
  result.received = parseTime(textOf(kid(n, "DateTimeReceived")))
  result.size = try: parseInt(textOf(kid(n, "Size"))) except ValueError: 0
  result.read = textOf(kid(n, "IsRead")) == "true"
  result.hasAttachments = textOf(kid(n, "HasAttachments")) == "true"
  result.important = textOf(kid(n, "Importance")) == "High"
  result.flagged = textOf(kid(kid(n, "Flag"), "FlagStatus")) == "Flagged"
  result.messageId = textOf(kid(n, "InternetMessageId"))
  result.inReplyTo = textOf(kid(n, "InReplyTo"))
  result.references = textOf(kid(n, "References"))
  result.conversation = attrOf(kid(n, "ConversationId"), "Id")
  result.preview = textOf(kid(n, "Preview"))
  for s in kids(kid(n, "Categories"), "String"): result.categories.add textOf(s)

proc fieldsXml(c: EwsClient): string =
  for p in itemProps: result.add "<t:FieldURI FieldURI=\"" & p & "\"/>"
  if c.version != "Exchange2010_SP2":
    for p in props2013: result.add "<t:FieldURI FieldURI=\"" & p & "\"/>"

proc syncItems*(c: EwsClient; folderId, state: string; max = 200): EwsChanges =
  ## What changed in a folder since `state` ("": all of it): the ids of
  ## messages new or changed, of those gone, those only read or unread.
  ## Ask again from `state` until `done`.
  let r = c.call("<m:SyncFolderItems><m:ItemShape><t:BaseShape>IdOnly</t:BaseShape></m:ItemShape>" &
                 "<m:SyncFolderId><t:FolderId Id=\"" & esc(folderId) & "\"/></m:SyncFolderId>" &
                 (if state.len > 0: "<m:SyncState>" & esc(state) & "</m:SyncState>" else: "") &
                 "<m:MaxChangesReturned>" & $max & "</m:MaxChangesReturned>" &
                 "<m:SyncScope>NormalItems</m:SyncScope></m:SyncFolderItems>")
  if r.len == 0: return
  let m = r[0]
  result.state = textOf(kid(m, "SyncState"))
  result.done = textOf(kid(m, "IncludesLastItemInRange")) != "false"
  let changes = kid(m, "Changes")
  if changes == nil: return
  for ch in changes:
    if ch.kind != xnElement: continue
    var ids: seq[XmlNode]
    findAll(ch, "ItemId", ids)
    let id = if ids.len > 0: attrOf(ids[0], "Id") else: ""
    if id.len == 0: continue
    case local(ch.tag)
    of "Create", "Update": result.changed.add id
    of "Delete": result.deleted.add id
    of "ReadFlagChange": result.readChanged.add (id, textOf(kid(ch, "IsRead")) == "true")
    else: discard

proc getItems*(c: EwsClient; ids: openArray[string]): seq[EwsItem] =
  ## The messages' fields (fifty at a time to the server); one gone
  ## meanwhile (moved, deleted elsewhere) is left out.
  var i = 0
  while i < ids.len:
    var xs = ""
    for k in i ..< min(ids.len, i + 50): xs.add "<t:ItemId Id=\"" & esc(ids[k]) & "\"/>"
    let r = c.call("<m:GetItem><m:ItemShape><t:BaseShape>IdOnly</t:BaseShape><t:AdditionalProperties>" &
                   c.fieldsXml & "</t:AdditionalProperties></m:ItemShape><m:ItemIds>" & xs &
                   "</m:ItemIds></m:GetItem>", skipGone = true)
    for m in r:
      for items in kids(m, "Items"):
        for it in items:
          if it.kind == xnElement: result.add itemOf(it)
    i += 50

proc mimeOf*(c: EwsClient; id: string): string =
  ## The message's whole source (RFC 5322).
  let r = c.call("<m:GetItem><m:ItemShape><t:BaseShape>IdOnly</t:BaseShape>" &
                 "<t:IncludeMimeContent>true</t:IncludeMimeContent></m:ItemShape><m:ItemIds>" &
                 "<t:ItemId Id=\"" & esc(id) & "\"/></m:ItemIds></m:GetItem>")
  var mc: seq[XmlNode]
  if r.len > 0: findAll(r[0], "MimeContent", mc)
  if mc.len == 0: ewsFail("the server gave no source for the message", 200, "ErrorItemNotFound")
  try: result = decode(textOf(mc[0]))
  except CatchableError: result = ""

proc update(c: EwsClient; id, field, value: string; setIt = true) =
  let fieldXml = "<t:FieldURI FieldURI=\"" & field & "\"/>"
  let change = if setIt:
                 "<t:SetItemField>" & fieldXml & "<t:Message>" & value & "</t:Message></t:SetItemField>"
               else: "<t:DeleteItemField>" & fieldXml & "</t:DeleteItemField>"
  discard c.call("<m:UpdateItem MessageDisposition=\"SaveOnly\" ConflictResolution=\"AlwaysOverwrite\">" &
                 "<m:ItemChanges><t:ItemChange><t:ItemId Id=\"" & esc(id) & "\"/><t:Updates>" & change &
                 "</t:Updates></t:ItemChange></m:ItemChanges></m:UpdateItem>")

proc setRead*(c: EwsClient; id: string; read: bool) =
  ## Read, or unread.
  c.update(id, "message:IsRead", "<t:IsRead>" & $read & "</t:IsRead>")

proc setFlag*(c: EwsClient; id: string; on: bool) =
  ## Flagged for follow-up, or not (Exchange 2013 and later).
  c.update(id, "item:Flag", "<t:Flag><t:FlagStatus>" & (if on: "Flagged" else: "NotFlagged") &
           "</t:FlagStatus></t:Flag>")

proc setCategories*(c: EwsClient; id: string; categories: openArray[string]) =
  ## The message's categories (its tags), all of them.
  if categories.len == 0:
    c.update(id, "item:Categories", "", setIt = false)
  else:
    var xs = ""
    for s in categories: xs.add "<t:String>" & esc(s) & "</t:String>"
    c.update(id, "item:Categories", "<t:Categories>" & xs & "</t:Categories>")

proc folderTarget(folder: string): string =
  for (d, _) in roles:
    if folder == d: return "<t:DistinguishedFolderId Id=\"" & d & "\"/>"
  "<t:FolderId Id=\"" & esc(folder) & "\"/>"

proc moveItems*(c: EwsClient; ids: openArray[string]; folder: string): seq[string] =
  ## Moved to `folder` (an id, or "inbox", "deleteditems"...): their new ids.
  var xs = ""
  for id in ids: xs.add "<t:ItemId Id=\"" & esc(id) & "\"/>"
  let r = c.call("<m:MoveItem><m:ToFolderId>" & folderTarget(folder) & "</m:ToFolderId><m:ItemIds>" & xs &
                 "</m:ItemIds><m:ReturnNewItemIds>true</m:ReturnNewItemIds></m:MoveItem>")
  for m in r:
    var n: seq[XmlNode]
    findAll(m, "ItemId", n)
    result.add(if n.len > 0: attrOf(n[0], "Id") else: "")

proc deleteItems*(c: EwsClient; ids: openArray[string]; forever = false) =
  ## To Deleted Items, or (`forever`) gone.
  var xs = ""
  for id in ids: xs.add "<t:ItemId Id=\"" & esc(id) & "\"/>"
  discard c.call("<m:DeleteItem DeleteType=\"" & (if forever: "HardDelete" else: "MoveToDeletedItems") &
                 "\"><m:ItemIds>" & xs & "</m:ItemIds></m:DeleteItem>")

proc sendMime*(c: EwsClient; raw: string) =
  ## Sends message `raw` (RFC 5322: its recipients are its To, Cc and Bcc),
  ## a copy kept in Sent Items.
  discard c.call("<m:CreateItem MessageDisposition=\"SendAndSaveCopy\"><m:SavedItemFolderId>" &
                 "<t:DistinguishedFolderId Id=\"sentitems\"/></m:SavedItemFolderId><m:Items><t:Message>" &
                 "<t:MimeContent CharacterSet=\"UTF-8\">" & encode(raw) & "</t:MimeContent>" &
                 "</t:Message></m:Items></m:CreateItem>")

proc findItems*(c: EwsClient; folder, query: string; max = 100): seq[string] =
  ## The ids of the messages in `folder` (an id, or "inbox"...) that
  ## `query` finds (Exchange's search: words, "from:sara", "subject:report").
  let r = c.call("<m:FindItem Traversal=\"Shallow\"><m:ItemShape><t:BaseShape>IdOnly</t:BaseShape>" &
                 "</m:ItemShape><m:IndexedPageItemView MaxEntriesReturned=\"" & $max &
                 "\" Offset=\"0\" BasePoint=\"Beginning\"/><m:ParentFolderIds>" & folderTarget(folder) &
                 "</m:ParentFolderIds><m:QueryString>" & esc(query) & "</m:QueryString></m:FindItem>")
  for m in r:
    var n: seq[XmlNode]
    findAll(m, "ItemId", n)
    for x in n: result.add attrOf(x, "Id")
