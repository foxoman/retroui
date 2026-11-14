# Lesson 16: Shipping

**Level:** advanced · **Time:** 30 minutes · **You learn:** packages for every store, signed, and updates inside the app

## Packages

| For | Command |
|---|---|
| Windows | `nim c -d:release -d:mingw app.nim` (from any system); `retrokit sign app.exe` (Authenticode, with a time stamp); `retrokit msix app.exe` for the Store |
| macOS | `retrokit mac app --sign:ID --notarize:PROFILE` -- the .app, signed (Developer ID) and notarized |
| Linux | `retrokit linux app` -- .deb, .rpm, Arch's PKGBUILD, a .tar.gz with an install.sh |
| Android | `retroapk app.nim --aab --key:upload.pem` for Google Play |
| iOS | `retroios app.nim --ipa`, then `retrokit ipa App.app` for TestFlight and the App Store |
| Web | `retrokit web app.nim`: copy build/web to any static host |

[BUILDING.md](../../BUILDING.md) has each step, the keys and what each store asks.

## Updates inside the app

```nim
import retroui
import retroui/update

# Updates inside the app: the file you publish, signed with your key
# (`retrokit update-key` once, `retrokit update-sign update.json` each release).
const PublicKey = "01VFThQl2gEEkWYqnvsvw+bbRTD59hQ2SAdg6kBwDjU="
var said = ""

app "Shop", 360, 100, version = "1.2.0":
  if button("Check for &updates"):
    let u = checkForUpdate("https://example.com/shop/update.json", PublicKey, "1.2.0")
    if u.available:
      let file = downloadUpdate(u)   # its SHA-256 checked
      if installUpdate(file): restartApp()
    else: said = if u.error.len > 0: u.error else: "This is the newest."
  label said
```

`retrokit update-key` makes your key pair once (keep the private one out of your repository); `retrokit update-sign update.json` signs each release's update file. The app checks the signature with the public key built into it, downloads the file for its system, checks its SHA-256 and installs it -- only the pieces that changed, where the system allows.

## Before you ship

- `version` in `app` (or `reportedVersion`): a crash report names it.
- The About box (`aboutBox`): your name, the version, the credits.
- Run the checks of Lesson 15, and `sh tools/warncheck.sh`-style warnings in your own code.

## What you learned

- Packages for each system and store; updates signed and checked.

## Try it

Make a .deb of the Notepad of Lesson 4 and install it: build it (`nim c -d:release notepad.nim`), then `retrokit linux notepad`.
