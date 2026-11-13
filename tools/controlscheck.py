#!/usr/bin/env python3
"""Checks that docs/controls.md shows every control of Retro Nim UI.

Lists every exported proc, template and macro of the widget modules
(MODULES below) and fails when one that is a control is not shown in
docs/controls.md with its signature. What is not a control -- a drawing
helper, the begin/end halves of a template that is shown, a model or
data proc -- is named in NOT_CONTROLS, each group with why, so the check
stays meaningful: a new control added to a module fails it until the
guide shows it (tools/shots.nim) or it is put here with a reason.

    python3 tools/controlscheck.py            (from the repository's root)
    python3 tools/controlscheck.py --list     (also every name and where it is)
"""

import os
import re
import sys

MODULES = [
    "widgets", "business", "extras", "morecontrols", "records", "desktop",
    "toolcustom", "dock", "textwidgets", "filewidgets", "charts", "planning",
    "mapview", "view3d", "htmlview", "markdown", "richedit", "media",
    "qrcode", "canvas2d", "report", "pdfview", "board", "tilemap",
    "capture", "mediasession",
]
# Not in the list: calendar (there is no calendar.nim: `calendar` is in
# business), photowidgets (Retro Photo's own panels, not for other apps),
# core (the frame loop and layout: shown in the guide's Layout part, and
# checked below as LAYOUT).

# Layout from core that the guide must show (its Layout part).
LAYOUT = ["row", "col", "spring", "space", "adaptive", "responsive", "isCompact",
          "sizeClass", "dp", "pushId", "withId"]

NOT_CONTROLS = {
    "widgets": {
        # the 3.1 look's drawing helpers, used by controls and custom drawing
        "raised", "sunken", "outline", "mixColor", "hoverColor", "hotFace",
        "lumaOfColor", "contrastInk", "softLight", "raisedFace", "buttonFace",
        "fieldFrame", "etchedBox", "etchedLine", "titleColors", "windowFrame",
        "captionButton", "controlMenuMark", "ditherFill", "hdDetail", "arrow",
        "captionArrow", "captionRestore", "captionMark", "pattern", "focusDots", "itemTextY",
        "boxH", "checkBox", "radioDisc", "drawLabeled", "labeledSize",
        "paletteTabH", "paletteTabFace",
        # input helpers for controls of one's own
        "spaceKey", "mnemonicHit", "doubleClicked", "tapped", "scrubLabel",
        # text helpers (lines, the caret's stops)
        "wrapLines", "ellipsize", "buttonWidth", "clusterAfter", "clusterBefore",
        # scroll bars drawn by hand (every control scrolls by itself)
        "scrollbarAt", "scrollBarFor", "vscroll", "hscroll",
        # begin/end halves of templates the guide shows (group, tabs,
        # scrollPanel, panel, menubar, menu, submenu, contextMenu, popupMenu,
        # toolbar, statusRow, dialog)
        "endGroup", "beginTabs", "endTabs", "beginScroll", "endScroll",
        "beginPanel", "endPanel", "beginMenubar", "endMenubar", "beginMenu",
        "endMenu", "beginSubmenu", "beginContextMenu", "beginPopupMenuFor",
        "beginToolbar", "endToolbar", "beginStatusBar", "endStatusBar",
        "beginDialog", "endDialog",
        # the 3.1 window frame's own parts (drawn by the toolkit for the app)
        "frameLayout", "framePartAt", "systemPart", "sizingBorder", "sizeGripMark",
        # a converter, and the picture of a button
        "toButtonPic",
    },
    "business": {
        # Date, the plain value the date controls edit
        "date", "daysInMonth", "valid", "today", "dayNumber", "fromDayNumber",
        "addDays", "addMonths", "weekday", "<", "<=", "$", "parseDate",
        # begin/end halves of tree and split
        "beginTree", "endTree", "beginNode", "endNode", "nodeRect",
        "beginSplit", "splitNext", "endSplit",
        # numbers as text, a folder
        "formatNumber", "parseNumber", "downloadsDir",
    },
    "extras": {
        # the switch's drawing (toggle and switchAt are shown)
        "drawSwitch", "drawSpinner", "drawFacts",
        # colors as text and HSL; the custom colors kept in settings
        "hexOf", "parseHexColor", "toHsl", "fromHsl", "storeCustomColors",
        "restoreCustomColors",
        # begin/end halves of expander and card
        "beginExpander", "endExpander", "beginCard", "endCard",
    },
    "morecontrols": {
        "hideSnackbar", "snackbarShown", "snackbarLeft",    # snackbar's state
    },
    "records": {
        "maskSlotCount",                                     # a mask's length
        "beginWizard", "endWizard",                          # wizard's halves
    },
    "desktop": {
        "PaletteTitleH", "PalettePad", "paletteSize", "mdiWindowSize",
        "beginMdi", "endMdi", "beginMdiWindow", "endMdiWindow",
        "mdiIsActive", "mdiTitleDragged", "mdiAreaRect",     # MDI state
        "keyFor", "setKey", "commandsOf", "storeKeymap", "restoreKeymap",
        "systemName", "aboutInfo",                           # keymap and About data
        "globalHotkey", "globalHotkeyTaken", "releaseGlobalHotkey",  # the system's (docs/system.md)
    },
    "dock": {  # (the dock's model; dockPanels draws it)
        "dockPanel", "newDock", "addColumn", "addGroup", "width", "hasPanel",
        "panelShown", "closePanel", "showPanel", "togglePanel", "toJson",
        "loadDock", "keys", "panelHeaderH", "coverRects", "dockMenuOpen",
    },
    "toolcustom": {
        "toolKeys", "toolKeysText",                          # the bar as text
    },
    "filewidgets": {  # (the folder model and the picture cache)
        "fileGlyph", "placeGlyph", "newPictureCache", "release", "pictures",
        "get", "failed", "loading", "clear", "pixelsKept", "cachedPicture",
        "drawFit", "drawPicture", "globMatch", "matchesAny", "diskSpaceCached",
        "searching", "applyView", "newFolderModel", "reload", "open",
        "askAccess", "accessApp", "canGoBack", "canGoForward", "canGoUp",
        "goBack", "goForward", "goUp", "loadingPath", "loadingFor",
        "selectAfterLoad", "setFilter", "search", "searchBusy", "stopSearch",
        "update", "current", "markedCount", "selectedItems", "selectedPaths",
        "selectAll", "selectMatching", "clearSelection", "folderStats",
        "makeFolder", "makeFile", "rename", "batchNames", "renameAll", "dropped",
        "jobFor", "jobTitle", "shownName", "fileColumns", "editName",
        "permissionsText", "forgetFolderTree", "placeList", "textFileStatus",
        "durationText", "jobSummary", "picturesDir", "askStorage",
        "newTrashList",
    },
    "charts": {  # (numbers and CSV tables)
        "compact", "fmtValue", "niceRange", "toNumber", "colIndex", "cell",
        "column", "labels", "numericColumns", "exportResult",
    },
    "mapview": {  # (the world's data)
        "countryCount", "countryIndex", "countryNameAt", "countryA2At",
        "countryA3At", "cityLatLon", "mapPoint", "mapLatLonAt", "countryAtLatLon",
    },
    "capture": {  # (a webcam's pixels, a WAV header: helpers of the recorder)
        "yuyvToBitmap", "wavHeader",
    },
    "view3d": {  # (the scene's model)
        "vec3", "newMesh", "triangleCount", "add", "addLine", "addLabel",
        "sceneChanged", "centerMesh", "loadObj", "loadStl", "bounds", "renders",
        # turns and matrices, for the parts' places
        "quat", "quatAxis", "*", "quatEuler", "slerp", "compose", "decompose",
    },
    "htmlview": {
        "htmlTitle", "htmlImagesChanged", "htmlZoomStep", "htmlToText",
        "htmlPageInfo",
        # a page's call to the app answered (`webHandle`'s `WebCall`)
        "reply", "fail", "send", "finish", "closed",
    },
    "markdown": {
        "parseMarkdown", "cssColor", "toggleTask",
    },
    "richedit": {  # (the document's model and commands)
        "paraText", "richDoc", "richCanUndo", "richCanRedo", "richUndo",
        "richRedo", "richBold", "richItalic", "richUnderline", "richStrike",
        "richMono", "richColor", "richSize", "richLink", "richClearFormat",
        "richList", "richAlign", "richIndent", "richInsert", "richInsertDoc",
        "richState", "richParaKind", "richAlignment", "richSelection",
        "richCaret", "richSelect", "richSelectAll", "richSelectedText",
        "isEmpty", "richMisspelled", "richReplace", "richNextMisspelled",
        "richAskLink", "richLinkAt", "richClickedLink", "richCaretRect",
        "richFocused", "toHtml", "toPlainText",
        "<", "<=",                                       # RichPos compared
    },
    "media": {  # (sound, and reading and writing video files)
        "==", "$", "soundPlaying", "stopSound", "stopAllSounds", "setSoundVolume",
        "videoPlaysInWindow", "closeVideo", "ffmpegExe", "videoInfo",
        "videoFrameAt", "closeVideoReader", "videoFrame", "videoDuration",
        "videoFrames", "addVideoPreviews", "videoEncodeAvailable", "beginVideo",
        "addFrame", "finish",
    },
    "qrcode": {
        "qrFits", "qrEncode", "qrPath", "[]",
    },
    "canvas2d": {  # the HTML5 Canvas 2D context's methods (MDN documents them)
        "addColorStop", "addPath", "arc", "arcTo", "beginPath", "bezierCurveTo",
        "clearRect", "clip", "closePath", "createConicGradient", "createImageData",
        "createLinearGradient", "createPattern", "createRadialGradient",
        "direction", "direction=",
        "drawImage", "ellipse", "encodePng", "endCanvas2D", "fill", "fillRect",
        "fillStyle", "fillStyle=", "fillText", "font", "font=", "getImageData",
        "getLineDash", "getTransform", "globalAlpha", "globalAlpha=",
        "globalCompositeOperation", "globalCompositeOperation=", "height",
        "imageSmoothingEnabled", "imageSmoothingEnabled=", "isPointInPath",
        "isPointInStroke", "lineCap", "lineCap=", "lineDashOffset",
        "lineDashOffset=", "lineJoin", "lineJoin=", "lineTo", "lineWidth",
        "lineWidth=", "measureText", "miterLimit", "miterLimit=", "moveTo",
        "newPath2D", "parseColor", "pixelHeight", "pixelRatio", "pixelWidth",
        "putImageData", "quadraticCurveTo", "rect", "reset", "resetTransform",
        "restore", "rotate", "roundRect", "save", "savePng", "scale",
        "setLineDash", "setTransform", "shadowBlur", "shadowBlur=", "shadowColor",
        "shadowColor=", "shadowOffsetX", "shadowOffsetX=", "shadowOffsetY",
        "shadowOffsetY=", "stroke", "strokeRect", "strokeStyle", "strokeStyle=",
        "strokeText", "textAlign", "textAlign=", "textBaseline", "textBaseline=",
        "timesRasterized", "toBitmap", "transform", "translate", "width",
    },
    "report": {  # building a report's pages (reportView shows them)
        "addHeader", "beginKeep", "endKeep", "heading", "image", "imageCell",
        "imageFile", "list", "pageBreak", "pageCount", "pageTexts", "paragraph",
        "pdfBytes", "renderPage", "rowCount", "rule", "setBackground", "space",
        "span", "table", "toPdf", "keepTogether", "cell",
    },
    "pdfview": {  # (the open document; pdfView shows it)
        "closePdfView", "fitWidth", "goToPage", "pageSizePt", "pdfPage",
        "setZoom", "zoomIn", "zoomOut", "zoomPercent", "addPdfPreviews",
    },
}

# board.nim is the whiteboard's document (shapes, pages, undo, SVG and PDF):
# it has no control of its own (Retro Board, examples/retroboard.nim, draws
# it), so none of its names are controls.
WHOLE_MODULE_NOT_CONTROLS = {"board"}

DECL = re.compile(r"^(proc|template|macro|func|iterator|converter)\s+(`[^`]+`|[A-Za-z_][A-Za-z0-9_]*=?)\s*\*")


def exported(path):
    """(name, line) of each exported routine of a module."""
    out = []
    with open(path, encoding="utf-8") as f:
        for n, line in enumerate(f, 1):
            m = DECL.match(line)
            if m:
                out.append((m.group(2).strip("`"), n))
    return out


def shown(md_path):
    """The names whose signature is shown in a code block of the guide."""
    names = set()
    in_code = False
    with open(md_path, encoding="utf-8") as f:
        for line in f:
            if line.startswith("```"):
                in_code = not in_code
                continue
            if in_code:
                m = DECL.match(line)
                if m:
                    names.add(m.group(2).strip("`"))
    return names


def mentioned(md_path):
    with open(md_path, encoding="utf-8") as f:
        text = f.read()
    return set(re.findall(r"`([A-Za-z_][A-Za-z0-9_]*)", text)) | shown(md_path)


def main():
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    md = os.path.join(root, "docs", "controls.md")
    have = shown(md)
    named = mentioned(md)
    listing = "--list" in sys.argv
    missing, controls = [], set()
    for mod in MODULES:
        path = os.path.join(root, "src", "retroui", mod + ".nim")
        if not os.path.exists(path):
            print("controlscheck: no module", mod)
            sys.exit(2)
        for name, line in exported(path):
            if mod in WHOLE_MODULE_NOT_CONTROLS or name in NOT_CONTROLS.get(mod, ()):
                continue
            if name in controls:
                continue
            controls.add(name)
            ok = name in have
            if listing:
                print(("  shown  " if ok else "MISSING  ") + name + "  (" + mod + ".nim:" + str(line) + ")")
            if not ok:
                missing.append((name, mod, line))
    layout_missing = [n for n in LAYOUT if n not in named]
    stale = []          # names of NOT_CONTROLS no module has any more
    for mod, names in NOT_CONTROLS.items():
        there = {n for n, _ in exported(os.path.join(root, "src", "retroui", mod + ".nim"))}
        stale += ["%s (%s.nim)" % (n, mod) for n in sorted(names) if n not in there]
    print("controlscheck: %d controls in %d modules, %d shown in docs/controls.md, %d missing"
          % (len(controls), len(MODULES), len(controls) - len(missing), len(missing)))
    for name, mod, line in missing:
        print("  missing: %s  (src/retroui/%s.nim:%d)" % (name, mod, line))
    for n in layout_missing:
        print("  missing from the Layout part: %s" % n)
    for n in stale:
        print("  NOT_CONTROLS names a routine no module has (remove it): %s" % n)
    if missing or layout_missing or stale:
        sys.exit(1)
    print("controlscheck: every control is in the guide")


if __name__ == "__main__":
    main()
