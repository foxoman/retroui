## Android's Settings pages, from Nim by reflection (retroui/native). (The
## VPN is in vpn.nim.) Off Android nothing opens.

import retroui/native

const FlagNewTask = 0x10000000          # Intent.FLAG_ACTIVITY_NEW_TASK

proc onAndroid*(): bool = javaAvailable()
  ## Running as the Android app (an APK).

proc openSettingsPage*(action: string): bool {.discardable.} =
  ## Opens a page of Android's Settings, e.g. "android.settings.VPN_SETTINGS".
  ## Falls back to Settings' start.
  if not javaAvailable(): return false
  for a in [action, "android.settings.SETTINGS"]:
    var ok = false
    onUiThread:
      let intent = javaNew("android.content.Intent", a)
      if not intent.isNil:
        discard javaCall(intent, "addFlags", FlagNewTask)
        discard javaActivity("startActivity", intent)
        ok = javaError().len == 0
        javaRelease(intent)
    if ok: return true
  false
