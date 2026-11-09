## The system's notifications: the bubble, banner or card outside the
## window ("New mail from Khalid") that shows while the app is behind
## others, minimized or, on a phone, closed to the background -- and the
## unread count on the app's icon.
##
## - **Linux, BSD:** the desktop's notification service (D-Bus
##   org.freedesktop.Notifications: GNOME, KDE, Xfce, dunst, mako...)
##   through `gdbus`, or `notify-send` where only that is there. A `tag`
##   replaces the notification shown before with the same tag.
## - **Termux:** the phone's own notifications through Termux:API
##   (`pkg install termux-api` and the Termux:API app).
## - **Windows:** a balloon of the app's icon in the notification area
##   (Windows 10 and 11 show it as a toast, kept in the Action Center);
##   the icon goes away with the balloon and when the app ends.
## - **macOS:** Notification Center (through `osascript`); `setBadge`
##   writes the count on the app's icon in the Dock.
## - **Android apps:** NotificationManager, a "Mail" channel, the app's
##   icon; a tap opens the app. Android 13 and newer ask the user once
##   (the APK needs `retroapk --permission:POST_NOTIFICATIONS`; the window
##   asks, never a background check); `setBadge` puts the count on the
##   app's notifications, which launchers show. Both work with the app
##   closed too, from its background check (`retroui/bgcheck`).
## - **iOS:** none (`notify` answers false).
## - **A web page** (`retrokit web`): the browser's notifications (it asks
##   the user once, at the first `notify`); `setBadge` puts the count on
##   the installed app's icon where the browser can (Chrome, Edge, Safari).
##
## Nothing waits on the system: the slow parts (starting `gdbus`, the
## notification area's thread) run off the UI thread. Call these from the
## UI thread (or a background check's).
##
## .. code-block:: nim
##   import retroui, retroui/notify
##   discard notifyAvailable()          # (at start: the system is asked once, ahead)
##   ...
##   if not notify("New mail", "Khalid: the drill plan", app = "Retro Mail", tag = "inbox"):
##     toast("Khalid: the drill plan", title = "New mail")   # no system notifications here
##   setBadge(unreadCount)

when defined(wasm):
  include notify_web
else:
  include notify_os
