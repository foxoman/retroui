## (included by webnative) Linux and BSD: WebKitGTK, loaded when the first
## page is shown. GTK runs in a thread of its own with its own connection to
## the X server; each page is a GTK window of WebKit's put inside the app's
## window (reparented) where the widget is. The app's thread sends it orders
## (`g_idle_add`, which GTK's thread runs) and reads what it reports under a
## lock: nothing of GTK is touched from the app's thread.
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[locks, dynlib, os, tables, exitprocs]
from std/posix import exitnow
import uirelays/drivers/x11_driver

proc c_atexit(f: proc () {.noconv.}): cint {.importc: "atexit", header: "<stdlib.h>".}

var teardownSkipped = false

proc skipWebKitTeardown() {.noconv.} =
  ## (WebKitGTK's own teardown at the program's end runs on the program's
  ## main thread, not on the thread WebKit lives on, and stops the program
  ## with SIGABRT once a video played too: the program ends here, its work
  ## done, with its own exit code)
  try:
    flushFile(stdout)
    flushFile(stderr)
  except IOError: discard
  exitnow(cint(getProgramResult()))

type
  GtkCmdKind = enum gcShow, gcHide, gcClose, gcNav, gcRun, gcAllow, gcQuit, gcPermit, gcClear,
                    gcBlock
  GtkCmd = object
    kind: GtkCmdKind
    key: string
    x, y, w, h: int
    parent: uint
    text: string
    start: string             ## (gcShow: the page's start script, for a view made now)
    nav: WebNav
    hosts: seq[string]
    zoom: float
    permit: set[WebPermission]
  GtkView = object
    win, wv, ucm: pointer
    xid: culong
    loaded: string
    hosts: seq[string]
    zoom: float
    permit: set[WebPermission]
  XImage {.bycopy.} = object
    width, height, xoffset, format: cint
    data: ptr UncheckedArray[uint8]
    byteOrder, bitmapUnit, bitmapBitOrder, bitmapPad, depth, bytesPerLine, bitsPerPixel: cint
    redMask, greenMask, blueMask: culong
    obdata: pointer
    createImage, destroyImage, getPixel, putPixel, subImage, addPixel: pointer

  GCallback = proc () {.cdecl.}

var
  gtkLock: Lock
  gtkCmds: seq[GtkCmd]                       # (under the lock)
  gtkShared: Table[string, WebNativeState]   # (under the lock)
  gtkState = 0                               # 0 not started, 1 starting, 2 ready, -1 none,
                                             # 3 ended
  gtkThread: Thread[void]
  gtkViews: Table[string, GtkView]           # (GTK's thread only)
  gtkKeyOf: Table[pointer, string]           # (GTK's thread only) a view's or manager's key
  gtkXDpy: pointer                           # (GTK's thread only) GTK's X connection
  gtkPlaces: Table[string, tuple[xid: culong; w, h: int]]   # (under the lock) for pictures
  gtkDownloads: Table[pointer, string]       # (GTK's thread only) a download's page
  gtkPermits: Table[string, set[WebPermission]]   # (under the lock) what the app allows
  gtkFilter: pointer                         # (GTK's thread only) the block list, compiled
  gtkBlockSent = 0                           # (the app's thread) the block list given GTK

  # GTK, GDK, GLib, GObject
  gtk_init_check: proc (argc, argv: pointer): cint {.cdecl, gcsafe.}
  gtk_main: proc () {.cdecl, gcsafe.}
  gtk_main_quit: proc () {.cdecl, gcsafe.}
  gtk_window_new: proc (kind: cint): pointer {.cdecl, gcsafe.}
  gtk_window_set_default_size: proc (w: pointer; width, height: cint) {.cdecl, gcsafe.}
  gtk_window_move: proc (w: pointer; x, y: cint) {.cdecl, gcsafe.}
  gtk_window_resize: proc (w: pointer; width, height: cint) {.cdecl, gcsafe.}
  gtk_container_add: proc (c, w: pointer) {.cdecl, gcsafe.}
  gtk_widget_show_all: proc (w: pointer) {.cdecl, gcsafe.}
  gtk_widget_show: proc (w: pointer) {.cdecl, gcsafe.}
  gtk_widget_hide: proc (w: pointer) {.cdecl, gcsafe.}
  gtk_widget_destroy: proc (w: pointer) {.cdecl, gcsafe.}
  gtk_widget_grab_focus: proc (w: pointer) {.cdecl, gcsafe.}
  gtk_widget_get_window: proc (w: pointer): pointer {.cdecl, gcsafe.}
  gdk_x11_window_get_xid: proc (w: pointer): culong {.cdecl, gcsafe.}
  gdk_display_get_default: proc (): pointer {.cdecl, gcsafe.}
  gdk_x11_display_get_xdisplay: proc (d: pointer): pointer {.cdecl, gcsafe.}
  g_idle_add: proc (f: proc (data: pointer): cint {.cdecl, gcsafe.}; data: pointer): cuint {.cdecl, gcsafe.}
  g_free: proc (p: pointer) {.cdecl, gcsafe.}
  g_signal_connect_data: proc (inst: pointer; signal: cstring; handler: GCallback;
                               data, destroy: pointer; flags: cint): culong {.cdecl, gcsafe.}
  XReparentWindow: proc (dpy: pointer; w, parent: culong; x, y: cint): cint {.cdecl, gcsafe.}
  XSetInputFocus: proc (dpy: pointer; w: culong; revert: cint; time: culong): cint {.cdecl, gcsafe.}
  XFlush: proc (dpy: pointer): cint {.cdecl, gcsafe.}
  # WebKit
  webkit_user_content_manager_new: proc (): pointer {.cdecl, gcsafe.}
  webkit_user_content_manager_register_script_message_handler: proc (m: pointer; name: cstring): cint {.cdecl, gcsafe.}
  webkit_user_script_new: proc (src: cstring; frames, time: cint; allow, deny: pointer): pointer {.cdecl, gcsafe.}
  webkit_user_content_manager_add_script: proc (m, s: pointer) {.cdecl, gcsafe.}
  webkit_web_view_new_with_user_content_manager: proc (m: pointer): pointer {.cdecl, gcsafe.}
  webkit_web_view_get_settings: proc (v: pointer): pointer {.cdecl, gcsafe.}
  webkit_settings_set_enable_developer_extras: proc (s: pointer; on: cint) {.cdecl, gcsafe.}
  webkit_web_view_load_uri: proc (v: pointer; uri: cstring) {.cdecl, gcsafe.}
  webkit_web_view_load_html: proc (v: pointer; html, base: cstring) {.cdecl, gcsafe.}
  webkit_web_view_get_uri: proc (v: pointer): cstring {.cdecl, gcsafe.}
  webkit_web_view_get_title: proc (v: pointer): cstring {.cdecl, gcsafe.}
  webkit_web_view_get_estimated_load_progress: proc (v: pointer): cdouble {.cdecl, gcsafe.}
  webkit_web_view_can_go_back: proc (v: pointer): cint {.cdecl, gcsafe.}
  webkit_web_view_can_go_forward: proc (v: pointer): cint {.cdecl, gcsafe.}
  webkit_web_view_go_back: proc (v: pointer) {.cdecl, gcsafe.}
  webkit_web_view_go_forward: proc (v: pointer) {.cdecl, gcsafe.}
  webkit_web_view_reload: proc (v: pointer) {.cdecl, gcsafe.}
  webkit_web_view_stop_loading: proc (v: pointer) {.cdecl, gcsafe.}
  webkit_web_view_set_zoom_level: proc (v: pointer; z: cdouble) {.cdecl, gcsafe.}
  webkit_web_view_evaluate_javascript: proc (v: pointer; js: cstring; length: int;
      world, source, cancel, cb, data: pointer) {.cdecl, gcsafe.}
  webkit_web_view_run_javascript: proc (v: pointer; js: cstring; cancel, cb, data: pointer) {.cdecl, gcsafe.}
  webkit_navigation_policy_decision_get_navigation_action: proc (d: pointer): pointer {.cdecl, gcsafe.}
  webkit_navigation_action_get_request: proc (a: pointer): pointer {.cdecl, gcsafe.}
  webkit_uri_request_get_uri: proc (r: pointer): cstring {.cdecl, gcsafe.}
  webkit_policy_decision_ignore: proc (d: pointer) {.cdecl, gcsafe.}
  webkit_javascript_result_get_js_value: proc (r: pointer): pointer {.cdecl, gcsafe.}
  jsc_value_to_string: proc (v: pointer): cstring {.cdecl, gcsafe.}
  # pictures of a page (the app's thread, its own X connection)
  XGetImage: proc (dpy: pointer; d: culong; x, y: cint; w, h: cuint; planes: culong;
                   format: cint): ptr XImage {.cdecl, gcsafe.}
  # the app's own address (app://local/...)
  g_malloc: proc (n: csize_t): pointer {.cdecl, gcsafe.}
  g_object_unref: proc (o: pointer) {.cdecl, gcsafe.}
  g_quark_from_static_string: proc (s: cstring): uint32 {.cdecl, gcsafe.}
  g_error_new_literal: proc (domain: uint32; code: cint; msg: cstring): pointer {.cdecl, gcsafe.}
  g_error_free: proc (e: pointer) {.cdecl, gcsafe.}
  g_memory_input_stream_new_from_data: proc (data: pointer; n: int; free: pointer): pointer {.cdecl, gcsafe.}
  g_type_check_instance_is_a: proc (inst: pointer; t: csize_t): cint {.cdecl, gcsafe.}
  webkit_web_context_get_default: proc (): pointer {.cdecl, gcsafe.}
  webkit_web_context_get_website_data_manager: proc (c: pointer): pointer {.cdecl, gcsafe.}
  webkit_website_data_manager_clear: proc (m: pointer; types: cint; timespan: int64;
      cancel, cb, data: pointer) {.cdecl, gcsafe.}
  # the block list (2.24 and later): WebKit's content rules, compiled once
  g_bytes_new: proc (data: pointer; n: csize_t): pointer {.cdecl, gcsafe.}
  g_bytes_unref: proc (b: pointer) {.cdecl, gcsafe.}
  webkit_user_content_filter_store_new: proc (path: cstring): pointer {.cdecl, gcsafe.}
  webkit_user_content_filter_store_save: proc (st: pointer; id: cstring; source: pointer;
      cancel, cb, data: pointer) {.cdecl, gcsafe.}
  webkit_user_content_filter_store_save_finish: proc (st, res: pointer; err: ptr pointer): pointer {.cdecl, gcsafe.}
  webkit_user_content_manager_add_filter: proc (m, f: pointer) {.cdecl, gcsafe.}
  webkit_user_content_manager_remove_all_filters: proc (m: pointer) {.cdecl, gcsafe.}
  webkit_user_content_filter_unref: proc (f: pointer) {.cdecl, gcsafe.}
  webkit_web_context_register_uri_scheme: proc (c: pointer; scheme: cstring; cb, data, destroy: pointer) {.cdecl, gcsafe.}
  webkit_web_context_get_security_manager: proc (c: pointer): pointer {.cdecl, gcsafe.}
  webkit_security_manager_register_uri_scheme_as_secure: proc (m: pointer; s: cstring) {.cdecl, gcsafe.}
  webkit_security_manager_register_uri_scheme_as_cors_enabled: proc (m: pointer; s: cstring) {.cdecl, gcsafe.}
  webkit_uri_scheme_request_get_path: proc (r: pointer): cstring {.cdecl, gcsafe.}
  webkit_uri_scheme_request_finish: proc (r, stream: pointer; n: int64; mime: cstring) {.cdecl, gcsafe.}
  webkit_uri_scheme_request_finish_error: proc (r, err: pointer) {.cdecl, gcsafe.}
  # what a page asks to use
  webkit_permission_request_allow: proc (r: pointer) {.cdecl, gcsafe.}
  webkit_permission_request_deny: proc (r: pointer) {.cdecl, gcsafe.}
  webkit_user_media_permission_request_get_type: proc (): csize_t {.cdecl, gcsafe.}
  webkit_geolocation_permission_request_get_type: proc (): csize_t {.cdecl, gcsafe.}
  webkit_notification_permission_request_get_type: proc (): csize_t {.cdecl, gcsafe.}
  webkit_user_media_permission_is_for_audio_device: proc (r: pointer): cint {.cdecl, gcsafe.}
  webkit_user_media_permission_is_for_video_device: proc (r: pointer): cint {.cdecl, gcsafe.}
  # printing, downloads
  webkit_print_operation_new: proc (v: pointer): pointer {.cdecl, gcsafe.}
  webkit_print_operation_run_dialog: proc (op, parent: pointer): cint {.cdecl, gcsafe.}
  webkit_download_get_request: proc (d: pointer): pointer {.cdecl, gcsafe.}
  webkit_download_get_web_view: proc (d: pointer): pointer {.cdecl, gcsafe.}
  webkit_download_set_destination: proc (d: pointer; uri: cstring) {.cdecl, gcsafe.}
  webkit_download_get_estimated_progress: proc (d: pointer): cdouble {.cdecl, gcsafe.}
  webkit_response_policy_decision_is_mime_type_supported: proc (d: pointer): cint {.cdecl, gcsafe.}
  webkit_policy_decision_download: proc (d: pointer) {.cdecl, gcsafe.}

initLock gtkLock

const
  GtkWindowPopup = 1.cint
  InjectTopFrame = 1.cint
  InjectAtStart = 0.cint
  PolicyNavigation = 0.cint
  PolicyNewWindow = 1.cint
  PolicyResponse = 2.cint
  RevertToParent = 2.cint

proc loadGtk(): bool =
  ## GTK 3, WebKitGTK and the libraries they come with; false when one is
  ## not on this system.
  template lib(names: openArray[string]): LibHandle =
    var h: LibHandle = nil
    for n in names:
      h = loadLib(n)
      if h != nil: break
    if h == nil: return false
    h
  template get(h: LibHandle; v: untyped; name: string; needed = true) =
    v = cast[typeof(v)](h.symAddr(name))
    if v == nil and needed: return false
  let gtk = lib(["libgtk-3.so.0", "libgtk-3.so"])
  let gdk = lib(["libgdk-3.so.0", "libgdk-3.so"])
  let glib = lib(["libglib-2.0.so.0", "libglib-2.0.so"])
  let gobj = lib(["libgobject-2.0.so.0", "libgobject-2.0.so"])
  let x11 = lib(["libX11.so.6", "libX11.so"])
  let wk = lib(["libwebkit2gtk-4.1.so.0", "libwebkit2gtk-4.1.so", "libwebkit2gtk-4.0.so.37",
                 "libwebkit2gtk-4.0.so"])
  gtk.get(gtk_init_check, "gtk_init_check")
  gtk.get(gtk_main, "gtk_main")
  gtk.get(gtk_main_quit, "gtk_main_quit")
  gtk.get(gtk_window_new, "gtk_window_new")
  gtk.get(gtk_window_set_default_size, "gtk_window_set_default_size")
  gtk.get(gtk_window_move, "gtk_window_move")
  gtk.get(gtk_window_resize, "gtk_window_resize")
  gtk.get(gtk_container_add, "gtk_container_add")
  gtk.get(gtk_widget_show_all, "gtk_widget_show_all")
  gtk.get(gtk_widget_show, "gtk_widget_show")
  gtk.get(gtk_widget_hide, "gtk_widget_hide")
  gtk.get(gtk_widget_destroy, "gtk_widget_destroy")
  gtk.get(gtk_widget_grab_focus, "gtk_widget_grab_focus")
  gtk.get(gtk_widget_get_window, "gtk_widget_get_window")
  gdk.get(gdk_x11_window_get_xid, "gdk_x11_window_get_xid")
  gdk.get(gdk_display_get_default, "gdk_display_get_default")
  gdk.get(gdk_x11_display_get_xdisplay, "gdk_x11_display_get_xdisplay")
  glib.get(g_idle_add, "g_idle_add")
  glib.get(g_free, "g_free")
  gobj.get(g_signal_connect_data, "g_signal_connect_data")
  x11.get(XReparentWindow, "XReparentWindow")
  x11.get(XSetInputFocus, "XSetInputFocus")
  x11.get(XFlush, "XFlush")
  x11.get(XGetImage, "XGetImage")
  let gio = lib(["libgio-2.0.so.0", "libgio-2.0.so"])
  glib.get(g_malloc, "g_malloc")
  glib.get(g_quark_from_static_string, "g_quark_from_static_string")
  glib.get(g_error_new_literal, "g_error_new_literal")
  glib.get(g_error_free, "g_error_free")
  gobj.get(g_object_unref, "g_object_unref")
  gobj.get(g_type_check_instance_is_a, "g_type_check_instance_is_a")
  gio.get(g_memory_input_stream_new_from_data, "g_memory_input_stream_new_from_data")
  glib.get(g_bytes_new, "g_bytes_new")
  glib.get(g_bytes_unref, "g_bytes_unref")
  wk.get(webkit_user_content_filter_store_new, "webkit_user_content_filter_store_new", false)
  wk.get(webkit_user_content_filter_store_save, "webkit_user_content_filter_store_save", false)
  wk.get(webkit_user_content_filter_store_save_finish, "webkit_user_content_filter_store_save_finish", false)
  wk.get(webkit_user_content_manager_add_filter, "webkit_user_content_manager_add_filter", false)
  wk.get(webkit_user_content_manager_remove_all_filters,
         "webkit_user_content_manager_remove_all_filters", false)
  wk.get(webkit_user_content_filter_unref, "webkit_user_content_filter_unref", false)
  wk.get(webkit_user_content_manager_new, "webkit_user_content_manager_new")
  wk.get(webkit_user_content_manager_register_script_message_handler,
         "webkit_user_content_manager_register_script_message_handler")
  wk.get(webkit_user_script_new, "webkit_user_script_new")
  wk.get(webkit_user_content_manager_add_script, "webkit_user_content_manager_add_script")
  wk.get(webkit_web_view_new_with_user_content_manager, "webkit_web_view_new_with_user_content_manager")
  wk.get(webkit_web_view_get_settings, "webkit_web_view_get_settings")
  wk.get(webkit_settings_set_enable_developer_extras, "webkit_settings_set_enable_developer_extras")
  wk.get(webkit_web_view_load_uri, "webkit_web_view_load_uri")
  wk.get(webkit_web_view_load_html, "webkit_web_view_load_html")
  wk.get(webkit_web_view_get_uri, "webkit_web_view_get_uri")
  wk.get(webkit_web_view_get_title, "webkit_web_view_get_title")
  wk.get(webkit_web_view_get_estimated_load_progress, "webkit_web_view_get_estimated_load_progress")
  wk.get(webkit_web_view_can_go_back, "webkit_web_view_can_go_back")
  wk.get(webkit_web_view_can_go_forward, "webkit_web_view_can_go_forward")
  wk.get(webkit_web_view_go_back, "webkit_web_view_go_back")
  wk.get(webkit_web_view_go_forward, "webkit_web_view_go_forward")
  wk.get(webkit_web_view_reload, "webkit_web_view_reload")
  wk.get(webkit_web_view_stop_loading, "webkit_web_view_stop_loading")
  wk.get(webkit_web_view_set_zoom_level, "webkit_web_view_set_zoom_level")
  # (2.40 and later; older ones have run_javascript)
  wk.get(webkit_web_view_evaluate_javascript, "webkit_web_view_evaluate_javascript", false)
  wk.get(webkit_web_view_run_javascript, "webkit_web_view_run_javascript", false)
  if webkit_web_view_evaluate_javascript == nil and webkit_web_view_run_javascript == nil:
    return false
  wk.get(webkit_navigation_policy_decision_get_navigation_action,
         "webkit_navigation_policy_decision_get_navigation_action")
  wk.get(webkit_navigation_action_get_request, "webkit_navigation_action_get_request")
  wk.get(webkit_uri_request_get_uri, "webkit_uri_request_get_uri")
  wk.get(webkit_policy_decision_ignore, "webkit_policy_decision_ignore")
  wk.get(webkit_javascript_result_get_js_value, "webkit_javascript_result_get_js_value")
  wk.get(webkit_web_context_get_default, "webkit_web_context_get_default")
  wk.get(webkit_web_context_get_website_data_manager, "webkit_web_context_get_website_data_manager",
         needed = false)
  wk.get(webkit_website_data_manager_clear, "webkit_website_data_manager_clear", needed = false)
  wk.get(webkit_web_context_register_uri_scheme, "webkit_web_context_register_uri_scheme")
  wk.get(webkit_web_context_get_security_manager, "webkit_web_context_get_security_manager")
  wk.get(webkit_security_manager_register_uri_scheme_as_secure,
         "webkit_security_manager_register_uri_scheme_as_secure")
  wk.get(webkit_security_manager_register_uri_scheme_as_cors_enabled,
         "webkit_security_manager_register_uri_scheme_as_cors_enabled", false)
  wk.get(webkit_uri_scheme_request_get_path, "webkit_uri_scheme_request_get_path")
  wk.get(webkit_uri_scheme_request_finish, "webkit_uri_scheme_request_finish")
  wk.get(webkit_uri_scheme_request_finish_error, "webkit_uri_scheme_request_finish_error")
  wk.get(webkit_permission_request_allow, "webkit_permission_request_allow")
  wk.get(webkit_permission_request_deny, "webkit_permission_request_deny")
  wk.get(webkit_user_media_permission_request_get_type, "webkit_user_media_permission_request_get_type")
  wk.get(webkit_geolocation_permission_request_get_type, "webkit_geolocation_permission_request_get_type")
  wk.get(webkit_notification_permission_request_get_type, "webkit_notification_permission_request_get_type")
  wk.get(webkit_user_media_permission_is_for_audio_device, "webkit_user_media_permission_is_for_audio_device")
  wk.get(webkit_user_media_permission_is_for_video_device, "webkit_user_media_permission_is_for_video_device")
  wk.get(webkit_print_operation_new, "webkit_print_operation_new")
  wk.get(webkit_print_operation_run_dialog, "webkit_print_operation_run_dialog")
  wk.get(webkit_download_get_request, "webkit_download_get_request")
  wk.get(webkit_download_get_web_view, "webkit_download_get_web_view")
  wk.get(webkit_download_set_destination, "webkit_download_set_destination")
  wk.get(webkit_download_get_estimated_progress, "webkit_download_get_estimated_progress")
  wk.get(webkit_response_policy_decision_is_mime_type_supported,
         "webkit_response_policy_decision_is_mime_type_supported")
  wk.get(webkit_policy_decision_download, "webkit_policy_decision_download")
  # (JavaScriptCore comes with WebKit)
  wk.get(jsc_value_to_string, "jsc_value_to_string", false)
  if jsc_value_to_string == nil:
    let jsc = lib(["libjavascriptcoregtk-4.1.so.0", "libjavascriptcoregtk-4.1.so",
                   "libjavascriptcoregtk-4.0.so.18", "libjavascriptcoregtk-4.0.so"])
    jsc.get(jsc_value_to_string, "jsc_value_to_string")
  true

# ---- in GTK's thread ------------------------------------------------------------------------------

proc keyOf(p: pointer): string =
  {.cast(gcsafe).}: gtkKeyOf.getOrDefault(p, "")

template shared(key: string; body: untyped) =
  ## `it`: the page's state, under the lock.
  {.cast(gcsafe).}:
    withLock gtkLock:
      if gtkShared.hasKey(key):
        var it {.inject.} = addr gtkShared[key]
        body

proc onChange(wv, a, b: pointer) {.cdecl, gcsafe.} =
  ## The page's address, title, loading or history changed.
  let key = keyOf(wv)
  if key.len == 0: return
  let u = webkit_web_view_get_uri(wv)
  let t = webkit_web_view_get_title(wv)
  let p = int(webkit_web_view_get_estimated_load_progress(wv) * 100)
  let back = webkit_web_view_can_go_back(wv) != 0
  let fwd = webkit_web_view_can_go_forward(wv) != 0
  shared(key):
    it.url = if u == nil: "" else: $u
    it.title = if t == nil: "" else: $t
    it.progress = clamp(p, 0, 100)
    it.canBack = back
    it.canForward = fwd

proc onMessage(ucm, res, data: pointer) {.cdecl, gcsafe.} =
  ## `retro.post(text)` in the page.
  let key = keyOf(ucm)
  if key.len == 0 or res == nil: return
  let v = webkit_javascript_result_get_js_value(res)
  if v == nil: return
  let s = jsc_value_to_string(v)
  if s == nil: return
  let text = $s
  g_free(s)
  shared(key): it.notes.add text

proc onPolicy(wv, decision: pointer; kind: cint; data: pointer): cint {.cdecl, gcsafe.} =
  ## Where the page goes: an address it is not allowed is kept from it (the
  ## app is told); a new window opens in the same view.
  if kind == PolicyResponse:
    # (what the page cannot show -- an archive, a program -- is downloaded)
    if webkit_response_policy_decision_is_mime_type_supported(decision) == 0:
      webkit_policy_decision_download(decision)
      return 1
    return 0
  if kind != PolicyNavigation and kind != PolicyNewWindow: return 0
  let key = keyOf(wv)
  let action = webkit_navigation_policy_decision_get_navigation_action(decision)
  if action == nil: return 0
  let req = webkit_navigation_action_get_request(action)
  let u = if req == nil: nil else: webkit_uri_request_get_uri(req)
  if u == nil: return 0
  let url = $u
  var hosts: seq[string]
  {.cast(gcsafe).}:
    if gtkViews.hasKey(key): hosts = gtkViews[key].hosts
  if not allowedBy(hosts, url):
    webkit_policy_decision_ignore(decision)
    shared(key): it.blocked.add url
    return 1
  if kind == PolicyNewWindow:
    webkit_policy_decision_ignore(decision)
    webkit_web_view_load_uri(wv, url.cstring)
    return 1
  0

proc onPermission(wv, req, data: pointer): cint {.cdecl, gcsafe.} =
  ## A page asks to use the camera, the microphone, the location or
  ## notifications: allowed only what the app allowed (`webPermit`); the
  ## rest is refused and the app told.
  let key = keyOf(wv)
  var wanted: set[WebPermission]
  if g_type_check_instance_is_a(req, webkit_user_media_permission_request_get_type()) != 0:
    if webkit_user_media_permission_is_for_video_device(req) != 0: wanted.incl wpCamera
    if webkit_user_media_permission_is_for_audio_device(req) != 0: wanted.incl wpMicrophone
  elif g_type_check_instance_is_a(req, webkit_geolocation_permission_request_get_type()) != 0:
    wanted.incl wpLocation
  elif g_type_check_instance_is_a(req, webkit_notification_permission_request_get_type()) != 0:
    wanted.incl wpNotifications
  var permit: set[WebPermission]
  {.cast(gcsafe).}:
    if gtkViews.hasKey(key): permit = gtkViews[key].permit
  if wanted.len > 0 and wanted <= permit:
    webkit_permission_request_allow(req)
  else:
    webkit_permission_request_deny(req)
    shared(key):
      for p in wanted - permit:
        if p notin it.asked: it.asked.add p
  1

proc onAppScheme(req, data: pointer) {.cdecl, gcsafe.} =
  ## app://local/PATH: a file of the app's folder (`webNativeAppFolder`).
  let p = webkit_uri_scheme_request_get_path(req)
  let file = appFile(if p == nil: "" else: $p)
  var body = ""
  if file.len > 0:
    try: body = readFile(file) except IOError, OSError: discard
  if file.len == 0 or (body.len == 0 and getFileSize(file) > 0):
    let e = g_error_new_literal(g_quark_from_static_string("retro"), 404, "Not in the app's folder")
    webkit_uri_scheme_request_finish_error(req, e)
    g_error_free(e)
    return
  let mem = g_malloc(csize_t(max(1, body.len)))
  if body.len > 0: copyMem(mem, addr body[0], body.len)
  let stream = g_memory_input_stream_new_from_data(mem, body.len, cast[pointer](g_free))
  webkit_uri_scheme_request_finish(req, stream, int64(body.len), mimeOf(file).cstring)
  g_object_unref(stream)

proc dlKey(dl: pointer): string =
  {.cast(gcsafe).}: gtkDownloads.getOrDefault(dl, "")

proc onDownloadDest(dl: pointer; name: cstring; data: pointer): cint {.cdecl, gcsafe.} =
  ## Where a download goes: the user's Downloads folder, a free name there.
  let base = downloadsFolder()
  try: createDir(base) except OSError: discard
  var file = base / (if name == nil or name[0] == '\0': "download" else: extractFilename($name))
  var n = 1
  let (dir, stem, ext) = file.splitFile
  while fileExists(file):
    file = dir / stem & " (" & $n & ")" & ext
    inc n
  webkit_download_set_destination(dl, fileUrl(file).cstring)
  let key = dlKey(dl)
  shared(key):
    for d in it.downloads.mitems:
      if d.file.len == 0 and not d.done: d.file = file
  1

proc onDownloadProgress(dl, spec, data: pointer) {.cdecl, gcsafe.} =
  let key = dlKey(dl)
  let p = int(webkit_download_get_estimated_progress(dl) * 100)
  shared(key):
    if it.downloads.len > 0: it.downloads[^1].progress = clamp(p, 0, 100)

proc onDownloadDone(dl, data: pointer) {.cdecl, gcsafe.} =
  let key = dlKey(dl)
  shared(key):
    for d in it.downloads.mitems:
      if not d.done and not d.failed:
        d.done = true
        d.progress = 100
        break

proc onDownloadFailed(dl, err, data: pointer) {.cdecl, gcsafe.} =
  let key = dlKey(dl)
  shared(key):
    for d in it.downloads.mitems:
      if not d.done and not d.failed:
        d.failed = true
        break

proc onDownload(ctx, dl, data: pointer) {.cdecl, gcsafe.} =
  ## A page starts a download: into the Downloads folder, the app told.
  let key = keyOf(webkit_download_get_web_view(dl))
  let req = webkit_download_get_request(dl)
  let u = if req == nil: nil else: webkit_uri_request_get_uri(req)
  {.cast(gcsafe).}: gtkDownloads[dl] = key
  shared(key): it.downloads.add WebDownload(url: if u == nil: "" else: $u)
  discard g_signal_connect_data(dl, "decide-destination", cast[GCallback](onDownloadDest), nil, nil, 0)
  discard g_signal_connect_data(dl, "notify::estimated-progress", cast[GCallback](onDownloadProgress),
                                nil, nil, 0)
  discard g_signal_connect_data(dl, "finished", cast[GCallback](onDownloadDone), nil, nil, 0)
  discard g_signal_connect_data(dl, "failed", cast[GCallback](onDownloadFailed), nil, nil, 0)

proc onPress(widget, event, data: pointer): cint {.cdecl, gcsafe.} =
  ## A press in the page: the keyboard goes to it.
  let key = keyOf(widget)
  {.cast(gcsafe).}:
    if gtkViews.hasKey(key):
      let v = gtkViews[key]
      discard XSetInputFocus(gtkXDpy, v.xid, RevertToParent, 0)
      discard XFlush(gtkXDpy)
      gtk_widget_grab_focus(v.wv)
  0

proc onFocus(win, event, data: pointer): cint {.cdecl, gcsafe.} =
  let key = keyOf(win)
  shared(key): it.focused = true
  0

proc onFullOn(wv, data: pointer): cint {.cdecl, gcsafe.} =
  ## An element of the page goes full screen (WebKit goes on with it).
  shared(keyOf(wv)): it.fullscreen = true
  0

proc onFullOff(wv, data: pointer): cint {.cdecl, gcsafe.} =
  shared(keyOf(wv)): it.fullscreen = false
  0

proc onBlur(win, event, data: pointer): cint {.cdecl, gcsafe.} =
  let key = keyOf(win)
  shared(key): it.focused = false
  0

proc connect(inst: pointer; signal: string; handler: pointer) =
  discard g_signal_connect_data(inst, signal.cstring, cast[GCallback](handler), nil, nil, 0)

proc load(v: var GtkView; url: string) =
  v.loaded = url
  if url.startsWith("html:"): webkit_web_view_load_html(v.wv, url[5 .. ^1].cstring, nil)
  elif url.len > 0 and url[0] == '/': webkit_web_view_load_uri(v.wv, fileUrl(url).cstring)
  else: webkit_web_view_load_uri(v.wv, url.cstring)

proc runJs(wv: pointer; js: string) =
  if webkit_web_view_evaluate_javascript != nil:
    webkit_web_view_evaluate_javascript(wv, js.cstring, -1, nil, nil, nil, nil, nil)
  else:
    webkit_web_view_run_javascript(wv, js.cstring, nil, nil, nil)

proc onFilter(store, res, data: pointer) {.cdecl, gcsafe.} =
  ## (the block list compiled: given to every view, and to those made after)
  {.cast(gcsafe).}:
    var err: pointer
    let f = webkit_user_content_filter_store_save_finish(store, res, addr err)
    g_object_unref(store)
    if f == nil:
      if err != nil:
        stderr.writeLine "retroui: WebKit refused the block list"
        g_error_free(err)
      return
    if gtkFilter != nil: webkit_user_content_filter_unref(gtkFilter)
    gtkFilter = f
    for v in gtkViews.values:
      webkit_user_content_manager_remove_all_filters(v.ucm)
      webkit_user_content_manager_add_filter(v.ucm, f)

proc exec(c: GtkCmd) =
  {.cast(gcsafe).}:
    case c.kind
    of gcShow:
      var v = gtkViews.getOrDefault(c.key)
      if v.wv == nil:
        v.ucm = webkit_user_content_manager_new()
        gtkKeyOf[v.ucm] = c.key
        connect(v.ucm, "script-message-received::retro", onMessage)
        discard webkit_user_content_manager_register_script_message_handler(v.ucm, "retro")
        webkit_user_content_manager_add_script(v.ucm, webkit_user_script_new(
          (shimFor("window.webkit.messageHandlers.retro.postMessage") & c.start).cstring,
          InjectTopFrame, InjectAtStart, nil, nil))
        if gtkFilter != nil: webkit_user_content_manager_add_filter(v.ucm, gtkFilter)
        v.wv = webkit_web_view_new_with_user_content_manager(v.ucm)
        gtkKeyOf[v.wv] = c.key
        if not teardownSkipped:
          # (after WebKit registered its own end: this one runs before it)
          teardownSkipped = true
          discard c_atexit(skipWebKitTeardown)
        # (Inspect Element in the page's menu only when asked for)
        webkit_settings_set_enable_developer_extras(webkit_web_view_get_settings(v.wv),
                                                    cint(webToolsWanted()))
        for s in ["notify::uri", "notify::title", "notify::estimated-load-progress",
                  "load-changed"]:
          connect(v.wv, s, onChange)
        connect(v.wv, "decide-policy", onPolicy)
        connect(v.wv, "permission-request", onPermission)
        connect(v.wv, "button-press-event", onPress)
        connect(v.wv, "enter-fullscreen", onFullOn)
        connect(v.wv, "leave-fullscreen", onFullOff)
        v.win = gtk_window_new(GtkWindowPopup)
        gtkKeyOf[v.win] = c.key
        connect(v.win, "focus-in-event", onFocus)
        connect(v.win, "focus-out-event", onBlur)
        gtk_window_set_default_size(v.win, cint(max(1, c.w)), cint(max(1, c.h)))
        gtk_container_add(v.win, v.wv)
        gtk_widget_show_all(v.win)
        v.xid = gdk_x11_window_get_xid(gtk_widget_get_window(v.win))
        discard XReparentWindow(gtkXDpy, v.xid, culong(c.parent), cint(c.x), cint(c.y))
        discard XFlush(gtkXDpy)
      else:
        gtk_widget_show(v.win)
      gtk_window_move(v.win, cint(c.x), cint(c.y))
      gtk_window_resize(v.win, cint(max(1, c.w)), cint(max(1, c.h)))
      if c.zoom > 0 and c.zoom != v.zoom:
        v.zoom = c.zoom
        webkit_web_view_set_zoom_level(v.wv, c.zoom)
      if c.text != v.loaded: v.load(c.text)
      v.permit = c.permit
      gtkViews[c.key] = v
      withLock gtkLock: gtkPlaces[c.key] = (v.xid, max(1, c.w), max(1, c.h))
    of gcHide:
      if gtkViews.hasKey(c.key): gtk_widget_hide(gtkViews[c.key].win)
    of gcClose:
      if gtkViews.hasKey(c.key):
        let v = gtkViews[c.key]
        gtkKeyOf.del v.wv
        gtkKeyOf.del v.ucm
        gtkKeyOf.del v.win
        gtk_widget_destroy(v.win)
        gtkViews.del c.key
        withLock gtkLock: gtkPlaces.del c.key
    of gcNav:
      if gtkViews.hasKey(c.key):
        let wv = gtkViews[c.key].wv
        case c.nav
        of wnBack: webkit_web_view_go_back(wv)
        of wnForward: webkit_web_view_go_forward(wv)
        of wnReload: webkit_web_view_reload(wv)
        of wnStop: webkit_web_view_stop_loading(wv)
        of wnPrint:
          let op = webkit_print_operation_new(wv)
          discard webkit_print_operation_run_dialog(op, nil)
          g_object_unref(op)
    of gcRun:
      if gtkViews.hasKey(c.key): runJs(gtkViews[c.key].wv, c.text)
    of gcAllow:
      if gtkViews.hasKey(c.key): gtkViews[c.key].hosts = c.hosts
    of gcPermit:
      if gtkViews.hasKey(c.key): gtkViews[c.key].permit = c.permit
    of gcBlock:
      # (the block list as WebKit's content rules: compiled, kept on disk)
      if webkit_user_content_filter_store_save == nil: return
      if c.text == "[]":
        if gtkFilter != nil:
          for v in gtkViews.values: webkit_user_content_manager_remove_all_filters(v.ucm)
          webkit_user_content_filter_unref(gtkFilter)
          gtkFilter = nil
        return
      let dir = getCacheDir() / "retroui" / "webfilters"
      try: createDir(dir) except OSError: discard
      let store = webkit_user_content_filter_store_new(dir.cstring)
      let bytes = g_bytes_new(unsafeAddr c.text[0], csize_t(c.text.len))
      webkit_user_content_filter_store_save(store, "retro-blocked", bytes, nil,
                                            cast[pointer](onFilter), nil)
      g_bytes_unref(bytes)
    of gcClear:
      # (cookies, caches, the sites' storage: every kind WebKit keeps -- the
      #  bits of WebKitWebsiteDataTypes up to DOM_CACHE -- of all time)
      if webkit_web_context_get_website_data_manager != nil and
         webkit_website_data_manager_clear != nil:
        let m = webkit_web_context_get_website_data_manager(webkit_web_context_get_default())
        if m != nil: webkit_website_data_manager_clear(m, 0x3FFF, 0, nil, nil, nil)
    of gcQuit:
      # (every page let go, then GTK's loop ends: before the app's own end,
      #  which frees what this thread uses)
      for k, v in gtkViews: gtk_widget_destroy(v.win)
      gtkViews.clear()
      gtkKeyOf.clear()
      gtk_main_quit()

proc drain(data: pointer): cint {.cdecl, gcsafe.} =
  ## The app's orders, run in GTK's thread.
  var cmds: seq[GtkCmd]
  {.cast(gcsafe).}:
    withLock gtkLock: swap(cmds, gtkCmds)
  for c in cmds: exec(c)
  0

proc webkitLoop() {.thread.} =
  {.cast(gcsafe).}:
    if gtk_init_check(nil, nil) == 0:
      withLock gtkLock: gtkState = -1
      return
    gtkXDpy = gdk_x11_display_get_xdisplay(gdk_display_get_default())
    # the app's own address, and downloads, for every page
    let ctx = webkit_web_context_get_default()
    webkit_web_context_register_uri_scheme(ctx, "app", cast[pointer](onAppScheme), nil, nil)
    let sm = webkit_web_context_get_security_manager(ctx)
    webkit_security_manager_register_uri_scheme_as_secure(sm, "app")
    if webkit_security_manager_register_uri_scheme_as_cors_enabled != nil:
      webkit_security_manager_register_uri_scheme_as_cors_enabled(sm, "app")
    discard g_signal_connect_data(ctx, "download-started", cast[GCallback](onDownload), nil, nil, 0)
    withLock gtkLock: gtkState = 2
    gtk_main()
    withLock gtkLock: gtkState = 3

# ---- in the app's thread --------------------------------------------------------------------------

proc webNativeAvailable*(): bool =
  ## Whether the system has a browser engine the kit can show pages in
  ## (WebKitGTK here, with the X11 driver's window). The first call starts
  ## it (a second or so). Not with the Wayland driver: there is no X11
  ## window to put pages in.
  if x11Window() == 0: return false
  if gtkState == 0:
    gtkState = 1
    if not loadGtk():
      gtkState = -1
      return false
    putEnv("GDK_BACKEND", "x11")      # (its windows go inside an X11 window)
    createThread(gtkThread, webkitLoop)
  var waited = 0
  while true:
    var s: int
    withLock gtkLock: s = gtkState
    if s != 1 or waited >= 5000: break
    sleep(10)
    waited += 10
  var s: int
  withLock gtkLock: s = gtkState
  s == 2 and x11Window() != 0

proc send(c: sink GtkCmd) =
  if not webNativeAvailable(): return
  withLock gtkLock:
    if c.kind == gcShow and not gtkShared.hasKey(c.key):
      gtkShared[c.key] = WebNativeState(progress: 0)
    gtkCmds.add c
  discard g_idle_add(drain, nil)

proc webNativeShow*(key: string; r: Rect; url: string; zoom: float) =
  ## The page `key` placed at `r` (window pixels), showing `url`; `zoom`
  ## (> 0) the size of its text and pictures.
  var permit: set[WebPermission]
  withLock gtkLock: permit = gtkPermits.getOrDefault(key)
  let blocks = blockListNow()
  if blocks.gen != gtkBlockSent:
    # (the block list first: views made from here on get it once it is compiled)
    gtkBlockSent = blocks.gen
    send GtkCmd(kind: gcBlock, text: contentRules(blocks.hosts, blocks.patterns, blocks.spared))
  send GtkCmd(kind: gcShow, key: key, x: r.x, y: r.y, w: r.w, h: r.h, parent: x11Window(),
              text: url, zoom: zoom, permit: permit, start: startScriptOf(key))

proc webNativeSnap*(key: string) =
  ## A picture of the page as it is on the screen now, taken from its
  ## window (X11): in the next `webNativeTake`'s `snapshot`.
  if gtkState != 2: return
  var place: tuple[xid: culong; w, h: int]
  withLock gtkLock: place = gtkPlaces.getOrDefault(key)
  let dpy = x11Display()
  if place.xid == 0 or dpy == nil: return
  let img = XGetImage(dpy, place.xid, 0, 0, cuint(place.w), cuint(place.h), not culong(0), 2)  # ZPixmap
  if img == nil: return
  if img.bitsPerPixel == 32 and img.width > 0 and img.height > 0:
    let pic = newBitmap(img.width, img.height)
    for y in 0 ..< img.height:
      let row = cast[ptr UncheckedArray[uint32]](addr img.data[y * img.bytesPerLine])
      for x in 0 ..< img.width: pic.px[y * img.width + x] = row[x] or 0xFF000000'u32
    pic.opaque = true
    withLock gtkLock:
      if gtkShared.hasKey(key): gtkShared[key].snapshot = pic
  discard cast[proc (i: ptr XImage): cint {.cdecl, gcsafe.}](img.destroyImage)(img)

proc webNativePermit*(key: string; allowed: set[WebPermission]) =
  ## What the page may use when it asks (the rest is refused).
  withLock gtkLock: gtkPermits[key] = allowed
  if gtkState == 2: send GtkCmd(kind: gcPermit, key: key, permit: allowed)

proc webNativeAppUrl*(path: string): string =
  ## The address of the file `path` of the app's folder (`webNativeAppFolder`).
  "app://local/" & path.strip(chars = {'/'})

proc webNativeShutdown*() =
  ## Every page let go and the engine stopped, before the app ends (GTK's
  ## thread would go on using what the app's end frees).
  if gtkState != 2: return
  send GtkCmd(kind: gcQuit)
  var waited = 0
  while waited < 3000:
    var s: int
    withLock gtkLock: s = gtkState
    if s != 2: break
    sleep(5)
    waited += 5
  var s: int
  withLock gtkLock: s = gtkState
  if s == 3: joinThread(gtkThread)

proc webNativeClearData*() =
  ## Clears what WebKit keeps of the pages: cookies, its caches, the sites'
  ## storage.
  if gtkState == 2: send GtkCmd(kind: gcClear)

proc webNativeSuspend*(key: string) = discard
  ## (WebKit slows a hidden page's timers by itself)

proc webNativeHide*(key: string) = send GtkCmd(kind: gcHide, key: key)
  ## Hides the page (kept with its place in history).

proc webNativeClose*(key: string) =
  ## Lets the page go.
  send GtkCmd(kind: gcClose, key: key)
  if gtkState == 2:
    withLock gtkLock: gtkShared.del key

proc webNativeNav*(key: string; what: WebNav) = send GtkCmd(kind: gcNav, key: key, nav: what)
  ## Back, Forward, Reload or Stop in the page.

proc webNativeRun*(key: string; js: string) = send GtkCmd(kind: gcRun, key: key, text: js)
  ## Runs `js` in the page (what it posts comes as notes).

proc webNativeAllow*(key: string; hosts: seq[string]) =
  ## The hosts the page may open (none: any).
  send GtkCmd(kind: gcAllow, key: key, hosts: hosts)

proc webNativeTake*(key: string): WebNativeState =
  ## The page now, and what it posted since the last look.
  if gtkState != 2: return
  withLock gtkLock:
    if gtkShared.hasKey(key):
      result = gtkShared[key]
      gtkShared[key].notes.setLen(0)
      gtkShared[key].blocked.setLen(0)
      gtkShared[key].asked.setLen(0)
      gtkShared[key].snapshot = nil
      # (a download finished or failed is told once)
      var keep: seq[WebDownload]
      for d in gtkShared[key].downloads:
        if not (d.done or d.failed): keep.add d
      gtkShared[key].downloads = keep
