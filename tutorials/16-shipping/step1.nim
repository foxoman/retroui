#> build-only
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
