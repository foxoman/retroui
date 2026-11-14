#!/usr/bin/env python3
"""Regenerate the icon font and the tables made from it.

Maintainers only: users of the library never run this, the outputs are
checked in. Needs Python 3 with fontTools (`pip install fonttools`) and
two files from the Nerd Fonts project in the folder given as argument:

    SymbolsNerdFont-Regular.ttf   (release asset NerdFontsSymbolsOnly.zip)
    glyphnames.json               (glyphnames.json in the repository root)

    python3 tools/genfonts.py ~/nerd

Writes:
    src/retroui/fonts/Icons.ttf    a subset of the Nerd symbols (+ .ttf.z)
    src/retroui/nerdicons.nim      a constant per icon: nfFolder = "\\uF07B"
    src/retroui/arabicdata.nim     Arabic letter forms and joining types

(The text fonts, GNU FreeFont, are made by tools/genfreefont.py.)
"""
import json, os, subprocess, sys, unicodedata

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
OUT = os.path.join(ROOT, "src", "retro")

# name in Nim (nfName) = Nerd Fonts glyph name
ICONS = """
Folder=fa-folder FolderOpen=fa-folder_open FolderPlus=fa-folder_plus
File=fa-file FileText=fa-file_lines FileCode=fa-file_code
FileImage=fa-file_image FileAudio=fa-file_audio FileVideo=fa-file_video
FileZip=fa-file_zipper FilePdf=fa-file_pdf FileWord=fa-file_word
FileExcel=fa-file_excel FilePowerpoint=fa-file_powerpoint
FileCsv=fa-file_csv FileExport=fa-file_export FileImport=fa-file_import
Files=fa-files_o Home=fa-home Search=fa-search Cog=fa-cog Cogs=fa-cogs
Sliders=fa-sliders Wrench=fa-wrench Trash=fa-trash Save=fa-floppy_o
Check=fa-check CheckSquare=fa-check_square Square=fa-square_o
CheckCircle=fa-check_circle Times=fa-times TimesCircle=fa-times_circle
Plus=fa-plus PlusCircle=fa-plus_circle Minus=fa-minus
MinusCircle=fa-minus_circle ArrowLeft=fa-arrow_left
ArrowRight=fa-arrow_right ArrowUp=fa-arrow_up ArrowDown=fa-arrow_down
ChevronLeft=fa-chevron_left ChevronRight=fa-chevron_right
ChevronUp=fa-chevron_up ChevronDown=fa-chevron_down CaretLeft=fa-caret_left
CaretRight=fa-caret_right CaretUp=fa-caret_up CaretDown=fa-caret_down
AngleDoubleLeft=fa-angle_double_left AngleDoubleRight=fa-angle_double_right
LevelUp=fa-level_up Undo=fa-undo Redo=fa-repeat Refresh=fa-refresh
Sync=fa-arrows_rotate Copy=fa-copy Cut=fa-scissors Paste=fa-paste
Edit=fa-edit Pencil=fa-pencil Eraser=fa-eraser Star=fa-star StarO=fa-star_o
Heart=fa-heart HeartO=fa-heart_o Bookmark=fa-bookmark Tag=fa-tag
Tags=fa-tags Flag=fa-flag Download=fa-download Upload=fa-upload
CloudDownload=fa-cloud_download CloudUpload=fa-cloud_upload Cloud=fa-cloud
Share=fa-share_alt ShareSquare=fa-share_square_o
ExternalLink=fa-external_link Link=fa-link Unlink=fa-unlink
Paperclip=fa-paperclip Print=fa-print User=fa-user Users=fa-users
UserPlus=fa-user_plus Lock=fa-lock Unlock=fa-unlock Key=fa-key
Shield=fa-shield Eye=fa-eye EyeSlash=fa-eye_slash Bell=fa-bell
BellSlash=fa-bell_slash Calendar=fa-calendar Calculator=fa-calculator
CalendarCheck=fa-calendar_check_o Clock=fa-clock_o History=fa-history
Hourglass=fa-hourglass Envelope=fa-envelope Inbox=fa-inbox
Send=fa-paper_plane Phone=fa-phone Comment=fa-comment Comments=fa-comments
Camera=fa-camera Image=fa-image Music=fa-music Film=fa-film
Video=fa-video_camera Play=fa-play Pause=fa-pause Stop=fa-stop
Forward=fa-forward Backward=fa-backward StepForward=fa-step_forward
StepBackward=fa-step_backward VolumeUp=fa-volume_up VolumeOff=fa-volume_off
Microphone=fa-microphone Wifi=fa-wifi Bluetooth=fa-bluetooth
Battery=fa-battery_full Plug=fa-plug Power=fa-power_off
Database=fa-database Server=fa-server Hdd=fa-hdd_o SdCard=fa-sd_card
Usb=fa-usb Desktop=fa-desktop Laptop=fa-laptop Mobile=fa-mobile
Tablet=fa-tablet Keyboard=fa-keyboard_o Terminal=fa-terminal Code=fa-code
Bug=fa-bug Git=fa-git Github=fa-github Android=fa-android Apple=fa-apple
Windows=fa-windows Linux=fa-linux BarChart=fa-bar_chart
LineChart=fa-line_chart PieChart=fa-pie_chart AreaChart=fa-area_chart
Table=fa-table List=fa-list ListUl=fa-list_ul ListOl=fa-list_ol
ThList=fa-th_list Th=fa-th ThLarge=fa-th_large Columns=fa-columns
Filter=fa-filter Sort=fa-sort SortAsc=fa-sort_alpha_asc
SortDesc=fa-sort_alpha_desc Bars=fa-bars EllipsisH=fa-ellipsis_h
EllipsisV=fa-ellipsis_v Info=fa-info_circle Question=fa-question_circle
Warning=fa-warning Exclamation=fa-exclamation_circle Ban=fa-ban
Globe=fa-globe Language=fa-language MapMarker=fa-map_marker Map=fa-map
Compass=fa-compass Sun=fa-sun_o Moon=fa-moon_o Palette=fa-palette
PaintBrush=fa-paint_brush Magic=fa-magic Rocket=fa-rocket Bolt=fa-bolt
Fire=fa-fire Leaf=fa-leaf Gift=fa-gift Money=fa-money
CreditCard=fa-credit_card ShoppingCart=fa-shopping_cart
Building=fa-building Briefcase=fa-briefcase Book=fa-book
Newspaper=fa-newspaper_o Graduation=fa-graduation_cap Trophy=fa-trophy
ThumbsUp=fa-thumbs_up ThumbsDown=fa-thumbs_down Expand=fa-expand
Compress=fa-compress SearchPlus=fa-search_plus SearchMinus=fa-search_minus
Crop=fa-crop Font=fa-font Bold=fa-bold Italic=fa-italic
Underline=fa-underline Strikethrough=fa-strikethrough
AlignLeft=fa-align_left AlignCenter=fa-align_center
AlignRight=fa-align_right AlignJustify=fa-align_justify Indent=fa-indent
Outdent=fa-outdent Quote=fa-quote_left Header=fa-header Archive=fa-archive
Box=fa-box Cube=fa-cube Cubes=fa-cubes Sitemap=fa-sitemap Random=fa-random
Retweet=fa-retweet SignIn=fa-sign_in SignOut=fa-sign_out Circle=fa-circle
CircleO=fa-circle_o DotCircle=fa-dot_circle_o ToggleOn=fa-toggle_on
ToggleOff=fa-toggle_off Markdown=dev-markdown Nim=seti-nim
Python=dev-python Javascript=dev-javascript Html=dev-html5 Css=dev-css3
Json=seti-json
C=seti-c Cpp=seti-cpp Java=seti-java Go=seti-go Rust=seti-rust
Shell=seti-shell Xml=seti-xml Yaml=seti-yml FontFile=seti-font
WindowMaximize=fa-window_maximize WindowRestore=fa-window_restore
WindowMinimize=fa-window_minimize WindowClose=fa-window_close
Spinner=fa-spinner CircleNotch=fa-circle_notch Clipboard=fa-clipboard
Recycle=fa-recycle FileTree=md-file_tree RenameBox=md-rename_box
Hashtag=fa-hashtag At=fa-at Lightbulb=fa-lightbulb Thumbtack=fa-thumbtack
Microchip=fa-microchip Grip=fa-grip_vertical
SortAlpha=md-sort_alphabetical_ascending ViewList=md-view_list
ViewGrid=md-view_grid ViewModule=md-view_module DotsGrid=md-dots_grid
SelectAll=md-select_all FileHidden=md-file_hidden FolderStar=md-folder_star
FolderDownload=md-folder_download FolderImage=md-folder_image
FolderMusic=md-folder_music FolderZip=md-folder_zip Harddisk=md-harddisk
SdCardAlt=md-sd Cellphone=md-cellphone Application=md-application
FormatSize=md-format_size ThemeLightDark=md-theme_light_dark
Translate=md-translate Console=md-console FolderSearch=md-folder_search
FileFind=md-file_find SwapVertical=md-swap_vertical
CheckboxMultiple=md-checkbox_multiple_marked Package=md-package_variant
FileDocument=md-file_document Movie=md-movie ImageMultiple=md-image_multiple
MusicBox=md-music_box FileCog=md-file_cog TextBox=md-text_box
FolderNetwork=md-folder_network FolderCog=md-folder_cog
FolderLock=md-folder_lock FolderHome=md-folder_home TrashCan=md-trash_can
ContentSave=md-content_save Pin=md-pin SplitVertical=md-view_split_vertical
DockLeft=md-dock_left CheckboxBlank=md-checkbox_blank_outline
CheckboxMarked=md-checkbox_marked RadioMarked=md-radiobox_marked
RadioBlank=md-radiobox_blank ToggleSwitch=md-toggle_switch
ToggleSwitchOff=md-toggle_switch_off Loading=md-loading Alert=md-alert
AlertCircle=md-alert_circle InfoOutline=md-information_outline
HelpCircle=md-help_circle CloseCircle=md-close_circle
FileRestore=md-file_restore FolderMove=md-folder_move FileMove=md-file_move
Selection=md-selection FolderUpload=md-folder_upload TextSearch=md-text_search
LetterCase=md-format_letter_case Hex=md-hexadecimal MusicNote=md-music_note
FileQuestion=md-file_question Cancel=md-cancel
"""


def run(*args):
    subprocess.run(args, check=True)


def subset(src, unicodes, dst):
    run("pyftsubset", src, "--unicodes=" + unicodes, "--output-file=" + dst,
        "--no-hinting", "--layout-features=", "--legacy-kern",
        "--drop-tables+=GSUB,GPOS,GDEF,MATH,FFTM,gasp,PfEd",
        "--name-IDs=0,1,2,3,4,5,6", "--name-languages=*", "--notdef-outline")


def icons(nerd):
    names = json.load(open(os.path.join(nerd, "glyphnames.json")))
    out, seen = [], set()
    for item in ICONS.split():
        nim, glyph = item.split("=")
        code = int(names[glyph]["code"], 16)
        if nim in seen:
            sys.exit("icon named twice: " + nim)
        seen.add(nim)
        out.append((nim, glyph, code))
    return out


def write_icons(table):
    with open(os.path.join(OUT, "nerdicons.nim"), "w") as f:
        f.write("# Generated by tools/genfonts.py -- do not edit.\n")
        f.write("## Icons from the Nerd Fonts symbols (Font Awesome, Material\n")
        f.write("## Design, Seti, Devicons), drawn as text in any size and color:\n")
        f.write("##\n## .. code-block:: nim\n")
        f.write("##   button(nfFolderOpen & \" Open\")\n")
        f.write("##   label(nfStar, color(220, 160, 0))\n\n")
        f.write("const\n")
        for nim, glyph, code in table:
            f.write('  nf%s* = "%s"  ## %s\n' % (nim, chr(code).encode(
                "unicode_escape").decode().replace("\\U000", "\\u{").replace(
                "\\u", "\\u") + ("}" if code > 0xFFFF else ""), glyph))
        f.write("\n  nerdIconNames* = [\n")
        for nim, glyph, code in table:
            f.write('    ("%s", nf%s),\n' % (nim, nim))
        f.write("  ]\n    ## Every icon by name, for pickers and galleries.\n")


def arabic():
    """Letter -> (isolated, final, initial, medial) presentation forms, the
    lam-alef ligatures, and joining types, from the decompositions of the
    presentation form blocks."""
    forms = {}
    ligs = {}
    for cp in list(range(0xFB50, 0xFE00)) + list(range(0xFE70, 0xFF00)):
        d = unicodedata.decomposition(chr(cp))
        if not d.startswith("<"):
            continue
        tag, rest = d.split(">")
        tag = tag[1:]
        parts = [int(x, 16) for x in rest.split()]
        if tag not in ("isolated", "final", "initial", "medial"):
            continue
        if len(parts) == 1:
            k = parts[0]
            if not (0x0600 <= k <= 0x06FF or 0x0750 <= k <= 0x077F):
                continue
            slot = ("isolated", "final", "initial", "medial").index(tag)
            forms.setdefault(k, [0, 0, 0, 0])
            if forms[k][slot] == 0:
                forms[k][slot] = cp
        elif len(parts) == 2 and parts[0] == 0x0644 and 0xFEF5 <= cp <= 0xFEFC:
            ligs.setdefault(parts[1], [0, 0])
            ligs[parts[1]][0 if tag == "isolated" else 1] = cp
    with open(os.path.join(OUT, "arabicdata.nim"), "w") as f:
        f.write("# Generated by tools/genfonts.py -- do not edit.\n")
        f.write("## Arabic contextual forms (Unicode presentation forms).\n\n")
        f.write("const\n  arabicForms* = [\n")
        for k in sorted(forms):
            v = forms[k]
            f.write("    (0x%04X'u16, [0x%04X'u16, 0x%04X'u16, 0x%04X'u16, 0x%04X'u16]),\n"
                    % (k, v[0], v[1], v[2], v[3]))
        f.write("  ]\n    ## letter, [isolated, final, initial, medial] (0: none)\n")
        f.write("  lamAlef* = [\n")
        for k in sorted(ligs):
            f.write("    (0x%04X'u16, 0x%04X'u16, 0x%04X'u16),\n" % (k, ligs[k][0], ligs[k][1]))
        f.write("  ]\n    ## alef kind, lam-alef isolated, lam-alef final\n")


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    nerd = sys.argv[1]
    fonts = os.path.join(OUT, "fonts")
    os.makedirs(fonts, exist_ok=True)
    table = icons(nerd)
    codes = ",".join("U+%04X" % c for _, _, c in table)
    subset(os.path.join(nerd, "SymbolsNerdFont-Regular.ttf"), codes,
           os.path.join(fonts, "Icons.ttf"))
    write_icons(table)
    arabic()
    # what the apps carry: the fonts zlib-compressed (typeset.nim unpacks them)
    import zlib
    for name in ["Icons"]:
        path = os.path.join(fonts, name + ".ttf")
        with open(path, "rb") as f:
            data = f.read()
        with open(path + ".z", "wb") as f:
            f.write(zlib.compress(data, 9))


main()
