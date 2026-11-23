#!/usr/bin/env python3
"""Line icons: a Nerd Fonts symbol for each pixel icon that has a fitting
one (Material Design mostly), drawn in the text's color where the pixel art
would not show -- dark themes, OLED black -- or when the user prefers them.

Maintainers only: the outputs are checked in. Needs fontTools and the
Nerd Fonts symbols font (release asset NerdFontsSymbolsOnly.zip).

    python3 tools/genlineicons.py ~/nerd/SymbolsNerdFont-Regular.ttf

Writes src/retroui/lineicons.nim (the twins, by pixel icon) and adds the
glyphs it needs to src/retroui/fonts/Icons.ttf (and Icons.ttf.z), keeping
every glyph that is there already.
"""
import os, sys, zlib, re

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
FONTS = os.path.join(ROOT, "src", "retroui", "fonts")

# pixel icon -> Nerd Fonts glyph name (and a color of its own, 0 = the text's)
TWINS = {
    "Folder": ("md-folder", 0xE8B23A), "FolderOpen": ("md-folder_open", 0xE8B23A),
    "Documents": ("md-folder_text", 0xE8B23A), "Downloads": ("md-folder_download", 0xE8B23A),
    "Pictures": ("md-folder_image", 0xE8B23A), "Music": ("md-folder_music", 0xE8B23A),
    "Videos": ("md-folder_play", 0xE8B23A), "FolderStar": ("md-folder_star", 0xE8B23A),
    "FolderPlus": ("md-folder_plus", 0xE8B23A), "FolderUp": ("md-folder_upload", 0xE8B23A),
    "Home": "md-home", "Desktop": "md-monitor", "Computer": "md-desktop_tower_monitor",
    "Drive": "md-harddisk", "SdCard": "md-sd", "Phone": "md-cellphone", "Trash": "md-trash_can_outline",
    "TrashFull": "md-trash_can", "File": "md-file_outline", "Text": "md-file_document_outline",
    "Markdown": "md-language_markdown", "Code": "md-file_code", "Web": "md-web", "Data": "md-database",
    "Sheet": "md-file_table", "Document": "md-file_document", "Slides": "md-file_presentation_box",
    "Pdf": ("md-file_pdf_box", 0xE05050), "Image": "md-file_image", "Audio": "md-file_music",
    "Video": "md-file_video", "Archive": "md-zip_box", "App": "md-application", "Script": "md-script_text",
    "Font": "md-format_font", "Info": ("md-information", 0x4A90E2), "Question": ("md-help_circle", 0x4A90E2),
    "Error": ("md-close_circle", 0xE04848), "Warning": ("md-alert", 0xE8B23A), "New": "md-file_plus",
    "Open": "md-folder_open", "Save": "md-content_save", "Cut": "md-content_cut", "Copy": "md-content_copy",
    "Paste": "md-content_paste", "Print": "md-printer", "Help": "md-help_circle_outline",
    "Back": "md-arrow_left", "Forward": "md-arrow_right", "Up": "md-arrow_up", "Refresh": "md-refresh",
    "Delete": "md-delete", "Rename": "md-rename_box", "Properties": "md-tune", "Search": "md-magnify",
    "Details": "md-view_list", "Icons": "md-view_grid", "Star": ("md-star", 0xE8B23A),
    "Share": "md-share_variant", "Select": "md-select_all", "Undo": "md-undo", "Redo": "md-redo",
    "Settings": "md-cog", "Tiles": "md-view_dashboard", "Tree": "md-file_tree", "Preview": "md-eye",
    "TwoPanes": "md-view_split_vertical", "Columns": "md-view_column_outline", "Eye": "md-eye", "OpenWith": "md-open_in_app", "Bell": "md-bell",
    "Check": "md-check", "Lock": "md-lock", "Play": "md-play", "User": "md-account", "Inbox": "md-inbox",
    "Fit": "md-fit_to_page_outline", "Hourglass": "md-timer_sand", "Hourglass2": "md-timer_sand_complete",
    "Chart": "md-chart_bar", "PieChart": "md-chart_pie", "Report": "md-file_chart", "Map": "md-map",
    "Cube": "md-cube_outline", "Paint": "md-palette", "Speaker": "md-volume_high", "Camera": "md-camera",
    "Calendar": "md-calendar", "Clock": "md-clock_outline", "Kanban": "md-view_column",
    "Gantt": "md-chart_gantt", "OrgChart": "md-sitemap", "Calculator": "md-calculator", "Mail": "md-email",
    "Database": "md-database", "Globe": "md-earth", "Window": "md-window_maximize", "Terminal": "md-console",
    "Gauge": "md-gauge", "Key": "md-key", "Add": "md-plus", "Remove": "md-minus", "Filter": "md-filter",
    "Sort": "md-sort", "Pin": "md-pin", "ZoomIn": "md-magnify_plus", "ZoomOut": "md-magnify_minus",
    "Pause": "md-pause", "Stop": "md-stop", "Record": ("md-record", 0xE04848),
    # the image editor's tools
    "MarqueeRect": "md-select", "MarqueeEllipse": "md-selection_ellipse", "Lasso": "md-lasso",
    "MoveTool": "md-cursor_move", "MagicWand": "md-magic_staff", "HandTool": "md-hand_back_right",
    "ZoomTool": "md-magnify", "Crop": "md-crop", "Eraser": "md-eraser", "Pencil": "md-pencil",
    "LineTool": "md-vector_line", "Airbrush": "md-spray", "Brush": "md-brush", "Stamp": "md-stamper",
    "Smudge": "md-gesture", "Blur": "md-water", "Sharpen": "md-triangle_outline",
    "Dodge": "md-white_balance_sunny", "Burn": "md-fire", "Sponge": "md-texture",
    "Pen": "md-fountain_pen_tip", "PathArrow": "md-cursor_default_outline", "PenAdd": "md-pen_plus",
    "PenRemove": "md-pen_minus", "ConvertPoint": "md-vector_curve", "TypeTool": "md-format_text",
    "Gradient": "md-gradient_horizontal", "Bucket": "md-format_color_fill", "Eyedropper": "md-eyedropper",
    "StandardMode": "md-checkbox_blank_outline", "QuickMask": "md-image_filter_center_focus",
    "ScreenWindow": "md-window_maximize", "ScreenFullMenu": "md-dock_window", "ScreenFull": "md-fullscreen",
    "SpotHeal": "md-bandage", "Heal": "md-bandage", "Patch": "md-texture_box", "RedEye": "md-flash_red_eye",
    "AdjustLayer": "md-circle_half_full", "LayerMask": "md-image_filter_center_focus",
    "AlignLeft": "md-format_align_left", "AlignCenter": "md-format_align_center",
    "AlignRight": "md-format_align_right", "JustifyLeft": "md-format_align_justify",
    "JustifyCenter": "md-format_align_justify", "JustifyRight": "md-format_align_justify",
    "JustifyAll": "md-format_align_justify", "FauxBold": "md-format_bold", "FauxItalic": "md-format_italic",
    "AllCaps": "md-format_letter_case_upper", "SmallCaps": "md-format_letter_case",
    "Superscript": "md-format_superscript", "Subscript": "md-format_subscript",
    "Underline": "md-format_underline", "Strikethrough": "md-format_strikethrough",
    "WarpText": "md-format_text_wrapping_wrap", "TypePath": "md-vector_curve",
    "LayerStyle": "md-function_variant", "Character": "md-format_size", "Paragraph": "md-format_paragraph",
    "RectShape": "md-rectangle_outline", "RoundRectShape": "md-square_rounded_outline",
    "EllipseShape": "md-ellipse_outline", "PolygonShape": "md-pentagon_outline",
    "CustomShape": "md-shape_outline", "ShapeLayer": "md-shape", "ClipLayer": "md-subdirectory_arrow_right",
    "Plugin": "md-puzzle", "Symmetry": "md-flip_horizontal", "ProofColors": "md-invert_colors",
    "SmartObject": "md-image_frame", "QuickSelect": "md-brush_variant", "ObjectSelect": "md-selection_search",
    "PathSelect": "md-cursor_default", "HistoryBrush": "md-history", "MixerBrush": "md-format_paint",
    "RemoveTool": "md-eraser_variant", "ContentMove": "md-arrow_expand_all", "Navigator": "md-compass_outline",
    "History": "md-history", "Snapshot": "md-camera", "Actions": "md-play_box_outline", "Guides": "md-ruler",
    "Grid": "md-grid", "AlignEdgeLeft": "md-align_horizontal_left",
    "AlignEdgeHCenter": "md-align_horizontal_center", "AlignEdgeRight": "md-align_horizontal_right",
    "AlignEdgeTop": "md-align_vertical_top", "AlignEdgeVCenter": "md-align_vertical_center",
    "AlignEdgeBottom": "md-align_vertical_bottom", "Warp": "md-vector_polyline",
    "PuppetWarp": "md-pin_outline", "Sky": "md-weather_partly_cloudy", "FillLayer": "md-format_color_fill",
    "SelNew": "md-checkbox_blank_outline", "SelAdd": "md-vector_union",
    "SelSubtract": "md-vector_difference_ab", "SelIntersect": "md-vector_intersection",
    "GradLinear": "md-gradient_horizontal", "GradRadial": "md-circle_opacity", "GradAngle": "md-angle_acute",
    "GradReflected": "md-gradient_vertical", "GradDiamond": "md-rhombus_outline",
    "MarqueeRow": "md-arrow_left_right", "MarqueeColumn": "md-arrow_up_down", "PolyLasso": "md-vector_polygon",
    "TypeMask": "md-format_text_variant_outline", "PatternStamp": "md-checkerboard",
    "MoreTools": "md-dots_horizontal", "PerspCrop": "md-crop_rotate", "BgEraser": "md-eraser_variant",
    "FreeformPen": "md-draw", "CurvaturePen": "md-vector_bezier", "StarShape": "md-star_outline",
    "Spiral": "md-rotate_right", "ColorReplace": "md-format_color_highlight",
    "Slice": "md-content_cut", "Note": "md-file_document_outline", "Count": "md-pin",
    "RotateView": "md-screen_rotation", "ArtHistory": "md-brush_variant", "Timeline": "md-filmstrip",
    "ParaStyle": "md-format_pilcrow", "CharStyle": "md-format_letter_case", "OpenType": "md-format_font",
    "ScriptEdit": "md-script_text_outline", "Language": "md-translate",
    "Layers": "md-layers_triple_outline", "Channels": "md-circle_multiple_outline",
    "Swatches": "md-palette_swatch_outline", "ColorPanel": "md-palette_outline",
    "Histogram": "md-chart_histogram", "Glyphs": "md-format_letter_matches",
    "Commands": "md-gesture_tap_button", "ToolPresets": "md-tag_outline", "LayerComps": "md-layers_edit",
    "Libraries": "md-bookshelf", "Scratch": "md-draw", "ColorThemes": "md-view_column",
    "Patterns": "md-checkerboard", "BrushSettings": "md-tune_variant", "QuickActions": "md-lightning_bolt",
    "SelectionBrush": "md-brush_variant", "AdjustBrush": "md-circle_half_full", "ContentTrace": "md-draw",
    # (0.72: every tool an icon of its own)
    "MagicEraser": "md-auto_fix", "MagicWandShapes": "md-creation", "MagneticLasso": "md-magnet",
    "LassoPoints": "md-vector_point", "VectorCrop": "md-crop_free", "SliceSelect": "md-cursor_pointer",
    "BrushVector": "md-brush_outline", "PathEraser": "md-vector_polyline_remove",
    "EraserShapes": "md-vector_difference", "SymbolStainer": "md-water_opacity",
    "SymbolSprayer": "md-spray_bottle", "SymbolShifter": "md-arrow_all", "SymbolSizer": "md-arrow_expand",
    "SymbolScruncher": "md-arrow_collapse_all", "SymbolSpinner": "md-rotate_3d_variant",
    "ToneBrush": "md-contrast_circle", "LivePaintBucket": "md-pail", "LivePaintSelect": "md-select_group",
    "GroupSelect": "md-cursor_default_click", "ShapeBuilder": "md-shape_plus",
    "ColorSamplerTool": "md-eyedropper_variant", "PerspSelect": "md-perspective_more",
    "TypeMaskVertical": "md-format_text_rotation_down_vertical",
    "TypePathVertical": "md-format_text_rotation_up", "Join": "md-vector_link", "Smooth": "md-sine_wave",
    "Reshape": "md-vector_polyline_edit", "MedianBrush": "md-blur", "PageTool": "md-book_open_page_variant",
    "ChartStacked": "md-chart_bar_stacked", "ChartBar": "md-chart_box_outline",
    "ChartBarStacked": "md-chart_timeline", "ChartLine": "md-chart_line",
    "ChartArea": "md-chart_areaspline", "ChartScatter": "md-chart_scatter_plot", "ChartRadar": "md-radar",
    "TypeVertical": "md-format_text_rotation_vertical", "TypeArea": "md-format_textbox",
    "TypeAreaVertical": "md-text_box_outline", "TouchType": "md-format_text_variant",
    "TriangleShape": "md-vector_triangle", "FrameRect": "md-close_box_outline",
    "FrameEllipse": "md-close_circle_outline", "FramePolygon": "md-close_octagon_outline",
    "Contour": "md-image_filter_hdr", "PolarGrid": "md-target", "ArcShape": "md-vector_radius",
    "CornerTool": "md-rounded_corner", "Scallop": "md-flower_outline", "Crystallize": "md-snowflake",
    "Twirl": "md-weather_hurricane", "Bloat": "md-circle_expand", "Wrinkle": "md-wave", "Deform": "md-bone",
    "MeshTool": "md-dots_grid", "MeshWarp": "md-waves", "WidthTool": "md-arrow_expand_vertical",
    "RotateTool": "md-rotate_left", "ShearTool": "md-skew_more", "ScaleTool": "md-resize",
    "FreeTransform": "md-vector_square_edit", "PointTransform": "md-vector_square_close",
    "AreaTool": "md-ruler_square", "DimensionTool": "md-ruler_square_compass", "Shaper": "md-draw_pen",
    "GradientFeather": "md-feather", "BlendTool": "md-vector_combine", "ArtboardTool": "md-crop_square",
    "KnifeTool": "md-knife",
}


def pixel_names():
    src = open(os.path.join(ROOT, "src", "retroui", "pixelicons.nim")).read()
    m = re.search(r'const pixelIconNames\* = \[(.*?)\]', src, re.S)
    return [s.strip().strip('"') for s in m.group(1).split(',')]


def main():
    from fontTools.ttLib import TTFont
    from fontTools import subset
    nerd = sys.argv[1]
    full = TTFont(nerd)
    by_name = {v: k for k, v in full.getBestCmap().items()}
    names = pixel_names()
    rows = []
    want = set()
    for i, n in enumerate(names):
        t = TWINS.get(n)
        if t is None:
            continue
        g, col = (t, 0) if isinstance(t, str) else t
        if g not in by_name:
            print("no glyph", g, "for", n)
            continue
        rows.append((i, by_name[g], col, n))
        want.add(by_name[g])
    # the icon font as it is (its glyphs kept exactly: a newer Nerd Fonts may have
    # redrawn some), and these
    path = os.path.join(FONTS, "Icons.ttf")
    font = TTFont(path)
    have = set(font.getBestCmap().keys())
    add = sorted(want - have)
    if add:
        opts = subset.Options()
        opts.layout_features = []
        opts.notdef_outline = True
        opts.glyph_names = False
        opts.hinting = False
        extra = TTFont(nerd)
        sub = subset.Subsetter(opts)
        sub.populate(unicodes=add)
        sub.subset(extra)
        ecmap = extra.getBestCmap()
        glyf, hmtx = font['glyf'], font['hmtx']
        order = list(font.getGlyphOrder())
        for cp in add:
            g = extra['glyf'][ecmap[cp]]
            assert not g.isComposite(), hex(cp)
            n = 'u%X' % cp
            glyf[n] = g
            hmtx[n] = extra['hmtx'][ecmap[cp]]
            if n not in order:
                order.append(n)
            for t in font['cmap'].tables:
                if t.format == 12 or cp <= 0xFFFF:
                    t.cmap[cp] = n
        font.setGlyphOrder(order)
        glyf.glyphOrder = order
        font.save(path)
    data = open(path, 'rb').read()
    open(path + '.z', 'wb').write(zlib.compress(data, 9))
    nim = os.path.join(ROOT, "src", "retroui", "lineicons.nim")
    head = open(nim).read().split('const lineTwins* = [')[0]   # (its header kept as it is)
    out = [head + 'const lineTwins* = [']
    for i, cp, col, n in rows:
        out.append('  (%d, "\\u{%X}", 0x%06X\'u32),  # %s' % (i, cp, col, n))
    out.append(']')
    out.append('  ## (pixel icon, its line twin, its own color -- 0: the text\'s)')
    open(nim, "w").write('\n'.join(out) + '\n')
    print(len(rows), "twins;", len(want - have), "glyphs added;", len(data), "bytes")


if __name__ == "__main__":
    main()
