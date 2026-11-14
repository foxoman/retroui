## retroios -- build an iOS app bundle (.app) from a retro app.
##
## Needs a Mac with Xcode (its clang, the iOS SDK, codesign, simctl), no
## Xcode project. On Linux an iOS SDK and `lld` link an unsigned bundle.
##
##   retroios app.nim --simulator --run       # build, start in the Simulator
##   retroios app.nim --sign:"Apple Development: Me (TEAM)" \
##              --profile:dev.mobileprovision --device:"My iPhone" --run
##
## Run `retroios --help` for every option.

import std/[os, osproc, strutils, parseopt]
import retroui/appicon
from retroui/macapp import ipaOf, MacError

const Usage = """
retroios -- build an iOS .app from a retro app

  retroios app.nim [options]

Options:
  --name:TEXT        app name on the home screen (default: file name)
  --id:BUNDLE_ID     bundle id, e.g. org.me.myapp (default: org.retro.<file>)
  --version:X.Y      version (default 1.0); --code:N build number (default 1)
  --icon:FILE.png    1024x1024 icon (default: the drawn 3.1 window)
  --simulator        build for the iOS Simulator (default: a device)
  --min-ios:V        lowest iOS version (default 14.0)
  --sdk:PATH         the iOS SDK (default: from xcrun)
  --sign:IDENTITY    codesign identity for a device build
  --profile:FILE     provisioning profile to embed (device builds)
  --device:NAME      device to install on with --run (devicectl)
  --run              install and start it
  --nim:FLAG         pass a flag to the Nim compiler (repeatable)
  --cleartext        the app may use plain http:// addresses (App Transport
                     Security's NSAllowsArbitraryLoads: a browser, a podcast
                     player)
  --ipa              also the .ipa (Payload/<Name>.app, zipped) that TestFlight
                     and the App Store take, beside the bundle
  -o:DIR.app         output bundle (default: build/ios-<file>/<Name>.app)
  --verbose          show the commands
"""

var verbose = false

proc die(msg: string) {.noreturn.} =
  stderr.writeLine "retroios: " & msg
  quit 1

proc run(cmd, what: string): string =
  if verbose: echo "+ ", cmd
  let (output, code) = execCmdEx(cmd)
  if code != 0:
    stderr.write output
    die what & " failed (exit code " & $code & ")"
  output.strip

proc xmlEscape(s: string): string =
  s.multiReplace(("&", "&amp;"), ("<", "&lt;"), (">", "&gt;"), ("\"", "&quot;"))

proc infoPlist(name, id, exe, version, code, minIos: string; simulator: bool;
               audio = false; cleartext = false): string =
  let platform = if simulator: "iPhoneSimulator" else: "iPhoneOS"
  # (a sound of audioView plays on in the background)
  var modes = if audio: "  <key>UIBackgroundModes</key><array><string>audio</string></array>\n" else: ""
  if cleartext:
    modes.add "  <key>NSAppTransportSecurity</key><dict><key>NSAllowsArbitraryLoads</key><true/></dict>\n"
  """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleDisplayName</key><string>$1</string>
  <key>CFBundleName</key><string>$1</string>
  <key>CFBundleExecutable</key><string>$3</string>
  <key>CFBundleIdentifier</key><string>$2</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$4</string>
  <key>CFBundleVersion</key><string>$5</string>
  <key>CFBundleSupportedPlatforms</key><array><string>$7</string></array>
  <key>MinimumOSVersion</key><string>$6</string>
  <key>NSCameraUsageDescription</key><string>$1 uses the camera when you ask it to.</string>
  <key>NSMicrophoneUsageDescription</key><string>$1 records sound when you ask it to.</string>
  <key>LSRequiresIPhoneOS</key><true/>
$8  <key>UIDeviceFamily</key><array><integer>1</integer><integer>2</integer></array>
  <key>UIRequiredDeviceCapabilities</key><array><string>arm64</string></array>
  <key>UILaunchScreen</key><dict/>
  <key>UIRequiresFullScreen</key><false/>
  <key>UIStatusBarStyle</key><string>UIStatusBarStyleDefault</string>
  <key>UISupportedInterfaceOrientations</key>
  <array>
    <string>UIInterfaceOrientationPortrait</string>
    <string>UIInterfaceOrientationLandscapeLeft</string>
    <string>UIInterfaceOrientationLandscapeRight</string>
  </array>
  <key>UISupportedInterfaceOrientations~ipad</key>
  <array>
    <string>UIInterfaceOrientationPortrait</string>
    <string>UIInterfaceOrientationPortraitUpsideDown</string>
    <string>UIInterfaceOrientationLandscapeLeft</string>
    <string>UIInterfaceOrientationLandscapeRight</string>
  </array>
  <key>CFBundleIcons</key>
  <dict><key>CFBundlePrimaryIcon</key><dict>
    <key>CFBundleIconFiles</key><array><string>AppIcon60x60</string></array>
  </dict></dict>
  <key>CFBundleIcons~ipad</key>
  <dict><key>CFBundlePrimaryIcon</key><dict>
    <key>CFBundleIconFiles</key><array><string>AppIcon60x60</string><string>AppIcon76x76</string><string>AppIcon83.5x83.5</string></array>
  </dict></dict>
</dict>
</plist>
""" % [xmlEscape(name), xmlEscape(id), xmlEscape(exe), xmlEscape(version),
       xmlEscape(code), xmlEscape(minIos), platform, modes]

proc main() =
  var
    src, name, id, outDir, iconPath, sdk, identity, profile, device = ""
    version = "1.0"
    code = "1"
    minIos = "14.0"
    simulator, runIt, makeIpa, cleartext = false
    nimFlags: seq[string]
  for kind, key, val in getopt(commandLineParams()):
    case kind
    of cmdArgument: src = key
    of cmdLongOption, cmdShortOption:
      case key.normalize
      of "name": name = val
      of "id": id = val
      of "version": version = val
      of "code": code = val
      of "icon": iconPath = val
      of "simulator", "sim": simulator = true
      of "minios": minIos = val
      of "sdk": sdk = val
      of "sign": identity = val
      of "profile": profile = val
      of "device": device = val
      of "run": runIt = true
      of "nim": nimFlags.add val
      of "o", "out", "output": outDir = val
      of "ipa": makeIpa = true
      of "cleartext": cleartext = true
      of "verbose", "v": verbose = true
      of "help", "h": echo Usage; quit 0
      else: die "unknown option --" & key & " (see --help)"
    of cmdEnd: discard
  if src.len == 0: (echo Usage; quit 1)
  if not fileExists(src): die "no such file: " & src
  let base = src.splitFile.name
  if name.len == 0: name = base.capitalizeAscii
  if id.len == 0:
    var clean = ""
    for c in base.toLowerAscii:
      if c in {'a'..'z', '0'..'9'}: clean.add c
    id = "org.retro." & (if clean.len > 0: clean else: "app")
  var exe = ""
  for c in name:
    if c.isAlphaNumeric: exe.add c
  if exe.len == 0: exe = "App"
  if outDir.len == 0:
    outDir = src.parentDir / "build" / "ios-" & base / exe & ".app"
  let onMac = defined(macosx)
  let sdkName = if simulator: "iphonesimulator" else: "iphoneos"
  if sdk.len == 0:
    if not onMac: die "give the iOS SDK with --sdk (or build on a Mac with Xcode)"
    sdk = run("xcrun --sdk " & sdkName & " --show-sdk-path", "finding the iOS SDK")
  let clang = if onMac: run("xcrun --sdk " & sdkName & " -f clang", "finding clang")
              else: findExe("clang")
  if clang.len == 0: die "clang is not on the PATH"
  let cpu = if simulator and hostCPU == "amd64": "amd64" else: "arm64"
  let arch = if cpu == "amd64": "x86_64" else: "arm64"
  let target = arch & "-apple-ios" & minIos & (if simulator: "-simulator" else: "")
  var flags = "-target " & target & " -isysroot " & quoteShell(sdk)
  var linkFlags = flags
  if not onMac: linkFlags.add " -fuse-ld=lld"     # ld64.lld, from LLVM
  createDir(outDir)
  let work = outDir.parentDir
  echo "Compiling ", src, " for ", target, " ..."
  var args = @[findExe("nim"), "c", "--os:macosx", "--cpu:" & cpu, "-d:ios",
               "--noMain", "-d:release", "--cc:clang", "--clang.exe:" & clang,
               "--clang.linkerexe:" & clang, "--passC:" & flags,
               "--passL:" & linkFlags, "--nimcache:" & work / "nimcache",
               "--hints:off", "-o:" & outDir / exe]
  args.add nimFlags
  args.add src
  discard run(quoteShellCommand(args), "compiling")
  # (the app plays sounds with audioView: they play on in the background)
  var audio = false
  for f in walkFiles(work / "nimcache" / "*media.nim.c"):
    if "audioView__" in readFile(f): audio = true
  writeFile(outDir / "Info.plist",
            infoPlist(name, id, exe, version, code, minIos, simulator, audio, cleartext))
  writeFile(outDir / "PkgInfo", "APPL????")
  # icons: a given 1024 px PNG is copied for every size (iOS scales it)
  for (file, px) in [("AppIcon60x60@2x.png", 120), ("AppIcon60x60@3x.png", 180),
                     ("AppIcon76x76@2x~ipad.png", 152),
                     ("AppIcon83.5x83.5@2x~ipad.png", 167)]:
    if iconPath.len > 0: copyFile(iconPath, outDir / file)
    else:
      let p = iconPng(px, opaque = true)
      var s = newString(p.len)
      copyMem(addr s[0], unsafeAddr p[0], p.len)
      writeFile(outDir / file, s)
  # sign
  if onMac:
    if identity.len > 0:
      if profile.len == 0 and not simulator:
        die "a device build needs --profile (a .mobileprovision for " & id & ")"
      var ent = ""
      if profile.len > 0:
        copyFile(profile, outDir / "embedded.mobileprovision")
        let plist = work / "profile.plist"
        discard run("security cms -D -i " & quoteShell(profile) & " > " &
                    quoteShell(plist), "reading the profile")
        ent = work / "entitlements.plist"
        discard run("/usr/libexec/PlistBuddy -x -c 'Print :Entitlements' " &
                    quoteShell(plist) & " > " & quoteShell(ent),
                    "reading the entitlements")
      discard run(quoteShellCommand(@["codesign", "--force", "--sign", identity] &
                  (if ent.len > 0: @["--entitlements", ent] else: @[]) &
                  @[outDir]), "codesign")
    else:
      discard run(quoteShellCommand(["codesign", "--force", "--sign", "-", outDir]),
                  "codesign")
      if not simulator:
        echo "Note: signed ad hoc; a device needs --sign and --profile."
  else:
    echo "Note: not signed (codesign runs on a Mac)."
  echo "Built ", outDir, " (", id, ")"
  if makeIpa:
    if simulator: die "an .ipa is of a device build (leave out --simulator)"
    let ipa = outDir.changeFileExt("ipa")
    try: ipaOf(outDir, ipa)
    except MacError as e: die e.msg
    echo "Built ", ipa, (if identity.len == 0: " (not signed for the App Store: --sign, --profile)" else: "")
  if runIt:
    if not onMac: die "--run needs a Mac"
    if simulator:
      discard run(quoteShellCommand(["xcrun", "simctl", "install", "booted", outDir]),
                  "installing (is a Simulator running? open -a Simulator)")
      discard run(quoteShellCommand(["xcrun", "simctl", "launch", "booted", id]),
                  "starting it")
    else:
      if device.len == 0: die "--run on a device needs --device (xcrun devicectl list devices)"
      discard run(quoteShellCommand(["xcrun", "devicectl", "device", "install", "app",
                                     "--device", device, outDir]), "installing")
      discard run(quoteShellCommand(["xcrun", "devicectl", "device", "process",
                                     "launch", "--device", device, id]), "starting it")
    echo "Started."

when isMainModule: main()
