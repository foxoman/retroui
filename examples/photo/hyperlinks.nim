## Retro Atelier: hyperlinks, cross-references, text variables and bookmarks, as the layout
## program has them -- Type > Hyperlinks & Cross-References (a web or mail address, a page, a
## text destination; a cross-reference that shows the page its destination is on), Type > Text
## Variables (the file's name, the dates, a running header), Window > Bookmarks (the PDF's
## outline). The PDF made of it keeps them as links and bookmarks (included by photo.nim).

var
  hlDlg: tuple[open: bool; kind: int; url, dest: string; page: int; name: string; mode: string]
    ## (New Hyperlink: 0 a URL, 1 a page, 2 a text destination; New Hyperlink Destination: its
    ## name; Insert Cross-Reference: the destination and its format)
  bmRename: tuple[on: bool; at: int; name: string]

proc knownDests(d: Doc): seq[string] =
  ## (the text destinations there are: the document's, the book's)
  for L in d.layers:
    if not L.isText: continue
    for sp in L.text.spans:
      if sp.style.link.len > 1 and sp.style.link[0] == '=' and sp.style.link[1 .. ^1] notin result:
        result.add sp.style.link[1 .. ^1]
  for k in d.refPages.keys:
    if k notin result: result.add k
  result.sort()

proc linkTarget(): tuple[L: Layer; a, b: int] =
  ## (the text a hyperlink goes on: what is selected in the text being typed, else all of the type
  ## layer picked)
  if te.on:
    let (a, b) = selRange()
    return (te.layer, a, b)
  let L = typeTarget()
  if L == nil: return (nil, 0, 0)
  (L, 0, L.text.runeLen)

proc setLink(name: string; link: string) =
  let (L, a, b) = linkTarget()
  if L == nil:
    status = tr(name) & ": " & tr("select text with the Type tool first")
    return
  if b <= a:
    status = tr(name) & ": " & tr("select the text it is for")
    return
  let v = link
  if te.on:
    editText(proc (t: var TextData) = t.restyle(a, b, proc (s: var CharStyle) = s.link = v))
  else:
    let d = cur()
    d.stepOnce(name, proc () =
      var t = L.text
      t.restyle(a, b, proc (s: var CharStyle) = s.link = v)
      d.setText(L, t))

proc hyperlinkCommand(name: string): bool =
  result = true
  let d = cur()
  case name
  of "New Hyperlink...":
    if d == nil: return
    let (L, a, b) = linkTarget()
    var cur0 = if L != nil and b > a: L.text.styleAt(a).link else: ""
    if cur0.startsWith("="): cur0 = ""
    hlDlg = (true, (if cur0.startsWith("#"): 2 elif cur0.startsWith("page:"): 1 else: 0),
             (if cur0.startsWith("#") or cur0.startsWith("page:"): "https://" elif cur0.len > 0: cur0 else: "https://"),
             (if cur0.startsWith("#"): cur0[1 .. ^1] else: ""),
             (if cur0.startsWith("page:"): (try: parseInt(cur0[5 .. ^1]) except ValueError: 1) else: 1), "", name)
  of "New Hyperlink Destination...":
    if d == nil: return
    var n = d.knownDests.len + 1
    while ("Destination " & $n) in d.knownDests: inc n
    hlDlg = (true, 0, "", "", 1, "Destination " & $n, name)
  of "Insert Cross-Reference...":
    if d == nil: return
    if not te.on:
      status = tr("Insert Cross-Reference: click in a text with the Type tool first")
      return
    let ds = d.knownDests
    hlDlg = (true, 0, "", (if ds.len > 0: ds[0] else: ""), 1, "", name)
  of "Remove Hyperlink": setLink(name, "")
  of "Insert File Name", "Insert Output Date", "Insert Modification Date":
    if te.on:
      insertTyped(case name
                  of "Insert File Name": "<file>"
                  of "Insert Output Date": "<date>"
                  else: "<modified>")
    else: status = tr("Text Variables: click in a text with the Type tool first")
  of "Bookmarks": togglePanel("bookmarks")
  of "New Bookmark":
    if d == nil: return
    # (the text selected: a destination made on it, the bookmark going there; else the page)
    var title = "Page " & (if d.pageLabel.len > 0: d.pageLabel else: "1")
    var dest = ""
    if te.on:
      let (a, b) = selRange()
      if b > a:
        title = te.layer.text.textSlice(a, b).strip.replace("\n", " ")
        if title.runeCount > 60:
          # (the first 60 letters)
          var n = 0
          var cut = title.len
          for i, c in title:
            if (ord(c) and 0xC0) != 0x80:
              if n == 60:
                cut = i
                break
              inc n
          title = title[0 ..< cut]
        var n = d.bookmarks.len + 1
        while ("Bookmark " & $n) in d.knownDests: inc n
        dest = "Bookmark " & $n
        let v = "=" & dest
        editText(proc (t: var TextData) = t.restyle(a, b, proc (s: var CharStyle) = s.link = v))
    d.beginStep("New Bookmark")
    d.touchLayers()
    d.bookmarks.add DocBookmark(title: title, dest: dest)
    d.endStep()
    inc d.ver
  else:
    if name.startsWith("Insert Running Header: "):
      if te.on: insertTyped("<head:" & name["Insert Running Header: ".len .. ^1] & ">")
      else: status = tr("Text Variables: click in a text with the Type tool first")
    else: result = false

proc hyperlinkDialog() =
  if not hlDlg.open: return
  let d = cur()
  if d == nil:
    hlDlg.open = false
    return
  var ok, cancel = false
  let title = hlDlg.mode.replace("...", "")
  dialog(hlDlg.open, title, 420):
    case hlDlg.mode
    of "New Hyperlink...":
      row([110, -1]):
        label "Link To:"
        combo([tr("URL"), tr("Page"), tr("Text Anchor")], hlDlg.kind, w = dp(160))
      case hlDlg.kind
      of 0:
        row([110, -1]):
          label "URL:"
          edit(hlDlg.url)
        label("A web address (https://...) or mail (mailto:name@example.com).", color = ui.theme.gray)
      of 1:
        row([110, 80, -1]):
          label "Page:"
          spin(hlDlg.page, 1, 9999, w = dp(72))
          label ""
      else:
        let ds = d.knownDests
        if ds.len == 0: label("No text destinations yet: Type > Hyperlinks > New Hyperlink Destination.",
                              color = ui.theme.gray)
        else:
          var k = max(0, ds.find(hlDlg.dest))
          row([110, -1]):
            label "Text Anchor:"
            if combo(ds, k, w = dp(220)) or hlDlg.dest.len == 0: hlDlg.dest = ds[clamp(k, 0, ds.high)]
    of "New Hyperlink Destination...":
      row([110, -1]):
        label "Name:"
        edit(hlDlg.name)
      label("The text selected becomes a place hyperlinks and cross-references go to.", color = ui.theme.gray)
    else:
      let ds = d.knownDests
      if ds.len == 0:
        label("No text destinations yet: select text, then Type > Hyperlinks > New Hyperlink Destination.",
              color = ui.theme.gray)
      else:
        var k = max(0, ds.find(hlDlg.dest))
        row([110, -1]):
          label "Destination:"
          if combo(ds, k, w = dp(220)) or hlDlg.dest.len == 0: hlDlg.dest = ds[clamp(k, 0, ds.high)]
        row([110, -1]):
          label "Format:"
          combo([tr("Page Number"), tr("Text & Page Number")], hlDlg.kind, w = dp(200))
    row:
      spring()
      if button("OK", isDefault = true, w = dp(80)): ok = true
      if button("Cancel", w = dp(80)): cancel = true
  if ok:
    hlDlg.open = false
    case hlDlg.mode
    of "New Hyperlink...":
      let link = case hlDlg.kind
                 of 0: hlDlg.url.strip
                 of 1: "page:" & $hlDlg.page
                 else: (if hlDlg.dest.len > 0: "#" & hlDlg.dest else: "")
      if link.len > 0 and link != "https://": setLink("New Hyperlink", link)
    of "New Hyperlink Destination...":
      let nm = hlDlg.name.strip
      if nm.len > 0: setLink("New Hyperlink Destination", "=" & nm)
    else:
      if hlDlg.dest.len > 0 and te.on:
        # (the cross-reference: the page its destination is on, a link to it)
        var text = ""
        if hlDlg.kind == 1:
          for L in d.layers:
            if not L.isText: continue
            for (a, b, link) in L.text.linkRuns:
              if link == "=" & hlDlg.dest and text.len == 0: text = L.text.textSlice(a, b).strip
          if text.len == 0: text = hlDlg.dest
          text = "“" & text & "” " & tr("on page") & " "
        let s = text & "<ref:" & hlDlg.dest & ">"
        let at = min(te.caret, te.anchor)
        insertTyped(s)
        let n = s.runeCount
        let v = "#" & hlDlg.dest
        editText(proc (t: var TextData) = t.restyle(at, at + n, proc (st: var CharStyle) = st.link = v))
  elif cancel:
    hlDlg.open = false

proc bookmarksBody() =
  ## Window > Bookmarks: the document's bookmarks, as the PDF's outline will have them
  let d = cur()
  if d == nil:
    label("No image open", color = ui.theme.gray)
    return
  var pick {.global.} = -1
  let lh = max(ItemH * 4, min(ItemH * 12, remainingH() - ItemH * 3))
  beginScroll(lh, "bookmarklist")
  if d.bookmarks.len == 0: label("(none: New Bookmark)", color = ui.theme.gray)
  for i, bm in d.bookmarks:
    let r = place(available(), ItemH)
    if i == pick: fill(r, ui.theme.select)
    text(r.x + dp(4) + dp(14) * bm.level, itemTextY(r.y), bm.title, if i == pick: ui.theme.selectText else: ui.theme.text)
    let hit = interact(idOf("bookmark:" & $i), r, focusable = false)
    if hit.clicked:
      pick = i
      if ui.clicks >= 2: bmRename = (true, i, bm.title)
  endScroll()
  if bmRename.on and bmRename.at < d.bookmarks.len:
    row([-1, 64, 56]):
      edit(bmRename.name)
      if button("Rename"):
        d.bookmarks[bmRename.at].title = bmRename.name
        bmRename.on = false
        inc d.ver
      if button("Cancel"): bmRename.on = false
  let some = pick >= 0 and pick < d.bookmarks.len
  row:
    if panelIcon(pxNew, "New Bookmark (the text selected, or the page)"): runCommand("New Bookmark")
    if panelIcon(pxForward, "Under the one before", enabled = some and pick > 0):
      d.bookmarks[pick].level = min(d.bookmarks[pick].level + 1, d.bookmarks[pick - 1].level + 1)
      inc d.ver
    if panelIcon(pxBack, "Out a level", enabled = some and d.bookmarks[max(0, pick)].level > 0):
      dec d.bookmarks[pick].level
      inc d.ver
    if panelIcon(pxDelete, "Delete Bookmark", enabled = some):
      d.beginStep("Delete Bookmark")
      d.touchLayers()
      d.bookmarks.delete(pick)
      d.endStep()
      pick = -1
  label("Saved as a PDF: the bookmarks readers list beside the pages.", color = ui.theme.gray)
