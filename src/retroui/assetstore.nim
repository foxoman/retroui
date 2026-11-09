## Free pictures, icons, textures and design resources from the web, for
## an app's "Assets" browser: what each source offers, the request to make
## for a page of results, and the answer read into `AssetItem`s with their
## license and the credit line to keep. Requests go through
## `retroui/assetfetch` (exported here): worker threads and a cache folder.
##
## .. code-block:: nim
##   var q = AssetQuery(source: asOpenverse, kind: akPhoto, text: "mosque", page: 1)
##   let t = fetchAsync(queryUrl(q), maxAgeSec = answerMaxAge(q.source))
##   # ... when its FetchResult came:
##   let page = parsePage(q, readFile(r.path))
##   for it in page.items: discard fetchAsync(it.thumbUrl, group = 1)
##
## Sources, all through their public APIs (no web pages are read):
##
## - Openverse: openly licensed photos and illustrations (Flickr, museums,
##   Wikimedia...), only those that may be used commercially and changed.
## - Wikimedia Commons: free files (CC0, public domain, CC BY, CC BY-SA).
## - Pixabay: photos, illustrations, vectors; needs the app's API key.
## - Iconify: icons of a curated list of sets with permissive licenses.
## - Poly Haven: CC0 textures, and HDRI panoramas as backgrounds.
## - ambientCG: CC0 textures (a zip of maps; `textureFromZip` takes the color one).
## - the Retro Photo Library: brushes, patterns, gradients, swatches,
##   styles and designs from a JSON catalog.
##
## Their terms, which an app must follow: show where results come from
## (`sourceCredit`, Poly Haven's "Powered by Poly Haven" above all); keep
## an item's `attribution` with designs that use it; keep Pixabay's
## answers 24 hours instead of asking again (`answerMaxAge`), and download
## what is used instead of linking to it; send `assetUserAgent`; ask for one
## page at a time (Openverse allows few anonymous searches a day).

import std/[json, strutils, os, algorithm, sets, math, unicode]
import assetfetch, zip, codec

export assetfetch

type
  AssetSource* = enum
    ## Where assets come from (the strings: their names to show; see the
    ## module's notes for what each offers).
    asOpenverse = "Openverse", asWikimedia = "Wikimedia Commons", asPixabay = "Pixabay",
    asPexels = "Pexels", asUnsplash = "Unsplash", asIconify = "Iconify", asPolyHaven = "Poly Haven", asAmbientCG = "ambientCG",
    asLibrary = "Retro Photo Library"
  AssetKind* = enum
    ## What kind of asset is asked for (the strings: the names to show);
    ## `sourcesFor` gives the sources that have a kind.
    akPhoto = "Photos", akIllustration = "Illustrations", akVector = "Vectors (SVG)",
    akIcon = "Icons", akTexture = "Textures", akBackground = "Backgrounds",
    akBrush = "Brushes", akPattern = "Patterns", akGradient = "Gradients",
    akSwatches = "Swatches", akStyle = "Styles", akDesign = "Designs"
  AssetItem* = object
    ## One result of a source: a picture, an icon, a texture, a preset file,
    ## with what is needed to show, download and credit it.
    source*: AssetSource     ## where it comes from
    kind*: AssetKind         ## what it is
    id*, title*: string      ## its id at the source; its name to show
    thumbUrl*: string        ## a small picture (<= ~400 px) for the grid
    previewUrl*: string      ## a bigger one (<= ~1280 px), "" when none
    fullUrl*: string         ## the file itself ("" until `resolve...` gave it)
    ext*: string             ## of fullUrl: "jpg", "png", "svg", "zip", "abr", "pat", "aco", "ase", "grd", "json", "rpd", "psd"...
    width*, height*: int     ## of the full file when known (0 unknown); before
                             ## a Poly Haven item is resolved: the largest there is
    author*, authorUrl*, pageUrl*: string
      ## who made it, their page, and the item's own page at the source
    license*, licenseUrl*: string     ## "CC0", "CC BY 4.0", "Pixabay Content License", "MIT"...
    attribution*: string     ## the credit line to keep with a design that uses it
                             ## ("" when the license asks for none)
    tags*: seq[string]       ## the source's keywords for it
    pingUrl*: string         ## a request to make when the item is used (downloaded,
                             ## inserted): Unsplash counts its downloads so; "" none
    category*: string        ## the `AssetCategory.key` that lists it ("" none):
                             ## an icon's set, a library item's category
  AssetCategory* = object
    ## A category a source can be browsed by (`categoriesOf`).
    name*: string            ## shown in the list
    key*: string             ## what is asked of the source (a category id, search words, an icon set prefix)
  AssetQuery* = object
    ## What to ask a source for: a page of results of a search or a category.
    source*: AssetSource     ## the source asked
    kind*: AssetKind         ## the kind of asset wanted
    text*: string            ## search words ("" = browse `category`)
    category*: string        ## an AssetCategory.key ("" = none)
    page*: int               ## 1-based
    perPage*: int            ## 0 = the source's sensible default (~30)
  AssetPage* = object
    ## A page of results (`parsePage`, `libraryPage`).
    items*: seq[AssetItem]   ## the results, in the source's order
    total*: int              ## -1 when unknown
    hasMore*: bool           ## there is a next page (`page` + 1)
    error*: string           ## why the answer could not be read ("" when it could)

  IconSet* = object
    ## An Iconify icon set offered here (its license checked).
    prefix*, name*, group*: string
      ## Iconify's prefix of the set ("mdi"), its name to show, and the
      ## group it is listed under ("Material", "Emoji"; `iconGroups`)
    license*, spdx*, licenseUrl*: string
      ## its license: the name to show, the SPDX id ("Apache-2.0"), its text
    author*, authorUrl*: string  ## who made the set, and their page
    height*: int             ## of its icons' design grid (0: various)
    color*: bool             ## its icons have their own colors
    samples*: seq[string]    ## a few of its icons' names, to show the set by

var
  pixabayKey*: string
    ## The app's Pixabay API key (Preferences); "" = Pixabay unavailable.
  pexelsKey*: string
    ## The app's Pexels API key (free at pexels.com/api); "" = Pexels unavailable.
  unsplashKey*: string
    ## The app's Unsplash access key (free at unsplash.com/developers); "" =
    ## Unsplash unavailable.
  libraryCatalogUrl*: string
    ## Where the online Retro Photo Library catalog is (JSON, see `parseLibrary`).
  libraryItems: seq[AssetItem]     # what `setLibrary` gave

const
  pexelsApi = "https://api.pexels.com/v1"
  unsplashApi = "https://api.unsplash.com"
  unsplashRef = "?utm_source=retro_photo&utm_medium=referral"   ## (Unsplash asks that its links say who sent the user)
  iconifyApi* = "https://api.iconify.design"
    ## Iconify's API, where icon searches and SVGs come from (`iconSvgUrl`).
  openverseApi = "https://api.openverse.org/v1/images/"
  commonsApi = "https://commons.wikimedia.org/w/api.php"
  pixabayApi = "https://pixabay.com/api/"
  polyHavenApi = "https://api.polyhaven.com"
  polyHavenCdn = "https://cdn.polyhaven.com"
  ambientApi = "https://ambientcg.com/api/v2/full_json"
  cc0Url = "https://creativecommons.org/publicdomain/zero/1.0/"

  iconSets*: seq[IconSet] = @[
    # Material
    IconSet(prefix: "material-symbols", name: "Material Symbols", group: "Material", license: "Apache 2.0", spdx: "Apache-2.0",
            licenseUrl: "https://github.com/google/material-design-icons/blob/master/LICENSE", author: "Google", authorUrl: "https://github.com/google/material-design-icons",
            height: 24, color: false, samples: @["downloading", "privacy-tip", "filter-drama-outline"]),
    IconSet(prefix: "ic", name: "Google Material Icons", group: "Material", license: "Apache 2.0", spdx: "Apache-2.0",
            licenseUrl: "https://github.com/material-icons/material-icons/blob/master/LICENSE", author: "Material Design Authors", authorUrl: "https://github.com/material-icons/material-icons",
            height: 24, color: false, samples: @["baseline-notifications-active", "outline-person-outline", "twotone-videocam-off"]),
    IconSet(prefix: "mdi", name: "Material Design Icons", group: "Material", license: "Apache 2.0", spdx: "Apache-2.0",
            licenseUrl: "https://github.com/Templarian/MaterialDesign/blob/master/LICENSE", author: "Pictogrammers", authorUrl: "https://github.com/Templarian/MaterialDesign",
            height: 24, color: false, samples: @["account-check", "bell-alert-outline", "calendar-edit"]),
    IconSet(prefix: "mdi-light", name: "Material Design Light", group: "Material", license: "Open Font License", spdx: "OFL-1.1",
            licenseUrl: "https://github.com/Templarian/MaterialDesignLight/blob/master/LICENSE.md", author: "Pictogrammers", authorUrl: "https://github.com/Templarian/MaterialDesignLight",
            height: 24, color: false, samples: @["cart", "bell", "login"]),
    # UI 24px
    IconSet(prefix: "tabler", name: "Tabler Icons", group: "UI 24px", license: "MIT", spdx: "MIT",
            licenseUrl: "https://github.com/tabler/tabler-icons/blob/master/LICENSE", author: "Paweł Kuna", authorUrl: "https://github.com/tabler/tabler-icons",
            height: 24, color: false, samples: @["alien", "device-desktop", "photo"]),
    IconSet(prefix: "lucide", name: "Lucide", group: "UI 24px", license: "ISC", spdx: "ISC",
            licenseUrl: "https://github.com/lucide-icons/lucide/blob/main/LICENSE", author: "Lucide Contributors", authorUrl: "https://github.com/lucide-icons/lucide",
            height: 24, color: false, samples: @["circle-check", "award", "house"]),
    IconSet(prefix: "solar", name: "Solar", group: "UI 24px", license: "CC BY 4.0", spdx: "CC-BY-4.0",
            licenseUrl: "https://creativecommons.org/licenses/by/4.0/", author: "480 Design", authorUrl: "https://www.figma.com/community/file/1166831539721848736",
            height: 24, color: false, samples: @["magnifier-zoom-out-broken", "armchair-2-bold-duotone", "traffic-economy-line-duotone"]),
    IconSet(prefix: "mingcute", name: "MingCute Icon", group: "UI 24px", license: "Apache 2.0", spdx: "Apache-2.0",
            licenseUrl: "https://github.com/Richard9394/MingCute/blob/main/LICENSE", author: "MingCute Design", authorUrl: "https://github.com/Richard9394/MingCute",
            height: 24, color: false, samples: @["edit-3-line", "alert-fill", "riding-line"]),
    IconSet(prefix: "ri", name: "Remix Icon", group: "UI 24px", license: "Apache 2.0", spdx: "Apache-2.0",
            licenseUrl: "https://github.com/cyberalien/RemixIcon/blob/master/License", author: "Remix Design", authorUrl: "https://github.com/cyberalien/RemixIcon",
            height: 24, color: false, samples: @["lock-2-line", "mark-pen-fill", "moon-line"]),
    IconSet(prefix: "iconoir", name: "Iconoir", group: "UI 24px", license: "MIT", spdx: "MIT",
            licenseUrl: "https://github.com/iconoir-icons/iconoir/blob/main/LICENSE", author: "Luca Burgio", authorUrl: "https://github.com/iconoir-icons/iconoir",
            height: 24, color: false, samples: @["chat-bubble-check", "edit", "activity"]),
    IconSet(prefix: "hugeicons", name: "Huge Icons", group: "UI 24px", license: "MIT", spdx: "MIT",
            licenseUrl: "", author: "Hugeicons", authorUrl: "https://icon-sets.iconify.design/icon-sets/hugeicons/",
            height: 24, color: false, samples: @["analytics-up", "android", "search-02"]),
    IconSet(prefix: "boxicons", name: "Boxicons", group: "UI 24px", license: "MIT", spdx: "MIT",
            licenseUrl: "https://github.com/box-icons/boxicons-core/blob/main/LICENSE", author: "Boxicons", authorUrl: "https://github.com/box-icons/boxicons-core",
            height: 24, color: false, samples: @["clock-2-filled", "desk", "battery-filled"]),
    IconSet(prefix: "uil", name: "Unicons", group: "UI 24px", license: "Apache 2.0", spdx: "Apache-2.0",
            licenseUrl: "https://github.com/Iconscout/unicons/blob/master/LICENSE", author: "Iconscout", authorUrl: "https://github.com/Iconscout/unicons",
            height: 24, color: false, samples: @["arrow-circle-right", "chat-bubble-user", "edit-alt"]),
    IconSet(prefix: "akar-icons", name: "Akar Icons", group: "UI 24px", license: "MIT", spdx: "MIT",
            licenseUrl: "https://github.com/artcoholic/akar-icons/blob/master/LICENSE", author: "Arturo Wibawa", authorUrl: "https://github.com/artcoholic/akar-icons",
            height: 24, color: false, samples: @["paper", "pencil", "location"]),
    IconSet(prefix: "majesticons", name: "Majesticons", group: "UI 24px", license: "MIT", spdx: "MIT",
            licenseUrl: "https://github.com/halfmage/majesticons/blob/main/LICENSE", author: "Gerrit Halfmann", authorUrl: "https://github.com/halfmage/majesticons",
            height: 24, color: false, samples: @["chats-line", "home", "edit-pen-4-line"]),
    IconSet(prefix: "mynaui", name: "Myna UI Icons", group: "UI 24px", license: "MIT", spdx: "MIT",
            licenseUrl: "https://github.com/praveenjuge/mynaui-icons/blob/main/LICENSE", author: "Praveen Juge", authorUrl: "https://github.com/praveenjuge/mynaui-icons",
            height: 24, color: false, samples: @["signal", "power", "tree"]),
    IconSet(prefix: "icon-park-outline", name: "IconPark Outline", group: "UI 24px", license: "Apache 2.0", spdx: "Apache-2.0",
            licenseUrl: "https://github.com/bytedance/IconPark/blob/master/LICENSE", author: "ByteDance", authorUrl: "https://github.com/bytedance/IconPark",
            height: 24, color: false, samples: @["add-one", "english-mustache", "basketball-clothes"]),
    IconSet(prefix: "pixelarticons", name: "Pixelarticons", group: "UI 24px", license: "MIT", spdx: "MIT",
            licenseUrl: "https://github.com/halfmage/pixelarticons/blob/master/LICENSE", author: "Gerrit Halfmann", authorUrl: "https://github.com/halfmage/pixelarticons",
            height: 24, color: false, samples: @["home", "arrows-horizontal", "heart"]),
    IconSet(prefix: "basil", name: "Basil", group: "UI 24px", license: "CC BY 4.0", spdx: "CC-BY-4.0",
            licenseUrl: "https://creativecommons.org/licenses/by/4.0/", author: "Craftwork", authorUrl: "https://www.figma.com/community/file/931906394678748246",
            height: 24, color: false, samples: @["comment-solid", "search-outline", "lightning-alt-solid"]),
    IconSet(prefix: "lets-icons", name: "Lets Icons", group: "UI 24px", license: "CC BY 4.0", spdx: "CC-BY-4.0",
            licenseUrl: "https://creativecommons.org/licenses/by/4.0/", author: "Leonid Tsvetkov", authorUrl: "https://www.figma.com/community/file/886554014393250663",
            height: 24, color: false, samples: @["search-duotone-line", "view-alt", "message-duotone"]),
    # UI 16px / 32px
    IconSet(prefix: "carbon", name: "Carbon", group: "UI 16px / 32px", license: "Apache 2.0", spdx: "Apache-2.0",
            licenseUrl: "", author: "IBM", authorUrl: "https://github.com/carbon-design-system/carbon/tree/main/packages/icons",
            height: 32, color: false, samples: @["user-certification", "humidity", "edit-off"]),
    IconSet(prefix: "ion", name: "IonIcons", group: "UI 16px / 32px", license: "MIT", spdx: "MIT",
            licenseUrl: "https://github.com/ionic-team/ionicons/blob/main/LICENSE", author: "Ben Sperry", authorUrl: "https://github.com/ionic-team/ionicons",
            height: 32, color: false, samples: @["code-download-sharp", "contrast-outline", "checkmark-done"]),
    IconSet(prefix: "ant-design", name: "Ant Design Icons", group: "UI 16px / 32px", license: "MIT", spdx: "MIT",
            licenseUrl: "https://github.com/ant-design/ant-design-icons/blob/master/LICENSE", author: "HeskeyBaozi", authorUrl: "https://github.com/ant-design/ant-design-icons",
            height: 16, color: false, samples: @["pushpin-filled", "pie-chart-outlined", "shopping-twotone"]),
    IconSet(prefix: "bi", name: "Bootstrap Icons", group: "UI 16px / 32px", license: "MIT", spdx: "MIT",
            licenseUrl: "https://github.com/twbs/icons/blob/main/LICENSE.md", author: "The Bootstrap Authors", authorUrl: "https://github.com/twbs/icons",
            height: 16, color: false, samples: @["graph-up", "card-image", "code-slash"]),
    IconSet(prefix: "gravity-ui", name: "Gravity UI Icons", group: "UI 16px / 32px", license: "MIT", spdx: "MIT",
            licenseUrl: "https://github.com/gravity-ui/icons/blob/main/LICENSE", author: "YANDEX LLC", authorUrl: "https://github.com/gravity-ui/icons/",
            height: 16, color: false, samples: @["magnifier", "bookmark-fill", "display"]),
    IconSet(prefix: "famicons", name: "Famicons", group: "UI 16px / 32px", license: "MIT", spdx: "MIT",
            licenseUrl: "https://github.com/familyjs/famicons/blob/main/LICENSE", author: "Family", authorUrl: "https://github.com/familyjs/famicons",
            height: 32, color: false, samples: @["backspace-outline", "home-sharp", "bluetooth-outline"]),
    # UI Mixed
    IconSet(prefix: "ph", name: "Phosphor", group: "UI Mixed", license: "MIT", spdx: "MIT",
            licenseUrl: "https://github.com/phosphor-icons/core/blob/main/LICENSE", author: "Phosphor Icons", authorUrl: "https://github.com/phosphor-icons/core",
            height: 24, color: false, samples: @["folder-open-duotone", "check-square-offset-thin", "pencil-line-fill"]),
    IconSet(prefix: "fluent", name: "Fluent UI System Icons", group: "UI Mixed", license: "MIT", spdx: "MIT",
            licenseUrl: "https://github.com/microsoft/fluentui-system-icons/blob/main/LICENSE", author: "Microsoft Corporation", authorUrl: "https://github.com/microsoft/fluentui-system-icons",
            height: 0, color: false, samples: @["zoom-out-24-filled", "drink-coffee-24-regular", "photo-filter-24-regular"]),
    IconSet(prefix: "heroicons", name: "HeroIcons", group: "UI Mixed", license: "MIT", spdx: "MIT",
            licenseUrl: "https://github.com/tailwindlabs/heroicons/blob/master/LICENSE", author: "Refactoring UI Inc", authorUrl: "https://github.com/tailwindlabs/heroicons",
            height: 0, color: false, samples: @["camera", "building-library", "receipt-refund"]),
    IconSet(prefix: "octicon", name: "Octicons", group: "UI Mixed", license: "MIT", spdx: "MIT",
            licenseUrl: "https://github.com/primer/octicons/blob/main/LICENSE", author: "GitHub", authorUrl: "https://github.com/primer/octicons/",
            height: 0, color: false, samples: @["alert-24", "bell-slash-24", "hourglass-24"]),
    IconSet(prefix: "radix-icons", name: "Radix Icons", group: "UI Mixed", license: "MIT", spdx: "MIT",
            licenseUrl: "https://github.com/radix-ui/icons/blob/master/LICENSE", author: "WorkOS", authorUrl: "https://github.com/radix-ui/icons",
            height: 15, color: false, samples: @["width", "checkbox", "code"]),
    IconSet(prefix: "clarity", name: "Clarity", group: "UI Mixed", license: "MIT", spdx: "MIT",
            licenseUrl: "https://github.com/vmware/clarity-assets/blob/master/LICENSE", author: "VMware", authorUrl: "https://github.com/vmware/clarity",
            height: 36, color: false, samples: @["help-outline-badged", "heart-broken-solid", "shield-outline-alerted"]),
    IconSet(prefix: "f7", name: "Framework7 Icons", group: "UI Mixed", license: "MIT", spdx: "MIT",
            licenseUrl: "https://github.com/framework7io/framework7-icons/blob/master/LICENSE", author: "Vladimir Kharlampidi", authorUrl: "https://github.com/framework7io/framework7-icons",
            height: 28, color: false, samples: @["hourglass-bottomhalf-fill", "pencil-outline", "rosette"]),
    IconSet(prefix: "system-uicons", name: "System UIcons", group: "UI Mixed", license: "Unlicense", spdx: "Unlicense",
            licenseUrl: "https://github.com/CoreyGinnivan/system-uicons/blob/master/LICENSE", author: "Corey Ginnivan", authorUrl: "https://github.com/CoreyGinnivan/system-uicons",
            height: 21, color: false, samples: @["bell", "message-writing", "write"]),
    IconSet(prefix: "fa7-solid", name: "Font Awesome Solid", group: "UI Mixed", license: "CC BY 4.0", spdx: "CC-BY-4.0",
            licenseUrl: "https://creativecommons.org/licenses/by/4.0/", author: "Dave Gandy", authorUrl: "https://github.com/FortAwesome/Font-Awesome",
            height: 32, color: false, samples: @["location-pin", "gem", "folder"]),
    IconSet(prefix: "fa7-regular", name: "Font Awesome Regular", group: "UI Mixed", license: "CC BY 4.0", spdx: "CC-BY-4.0",
            licenseUrl: "https://creativecommons.org/licenses/by/4.0/", author: "Dave Gandy", authorUrl: "https://github.com/FortAwesome/Font-Awesome",
            height: 32, color: false, samples: @["message", "clock", "folder"]),
    # Multicolor
    IconSet(prefix: "fluent-color", name: "Fluent UI System Color Icons", group: "Multicolor", license: "MIT", spdx: "MIT",
            licenseUrl: "https://github.com/microsoft/fluentui-system-icons/blob/main/LICENSE", author: "Microsoft Corporation", authorUrl: "https://github.com/microsoft/fluentui-system-icons",
            height: 0, color: true, samples: @["mic-20", "alert-32", "wrench-24"]),
    IconSet(prefix: "icon-park", name: "IconPark", group: "Multicolor", license: "Apache 2.0", spdx: "Apache-2.0",
            licenseUrl: "https://github.com/bytedance/IconPark/blob/master/LICENSE", author: "ByteDance", authorUrl: "https://github.com/bytedance/IconPark",
            height: 24, color: true, samples: @["add-one", "english-mustache", "basketball-clothes"]),
    IconSet(prefix: "flat-color-icons", name: "Flat Color Icons", group: "Multicolor", license: "MIT", spdx: "MIT",
            licenseUrl: "", author: "Icons8", authorUrl: "https://github.com/icons8/flat-Color-icons",
            height: 48, color: true, samples: @["edit-image", "donate", "planner"]),
    IconSet(prefix: "streamline-color", name: "Streamline color", group: "Multicolor", license: "CC BY 4.0", spdx: "CC-BY-4.0",
            licenseUrl: "https://creativecommons.org/licenses/by/4.0/", author: "Streamline", authorUrl: "https://github.com/webalys-hq/streamline-vectors",
            height: 28, color: true, samples: @["graph", "pie-chart-flat", "filter-2"]),
    IconSet(prefix: "marketeq", name: "Marketeq", group: "Multicolor", license: "MIT", spdx: "MIT",
            licenseUrl: "", author: "Marketeq", authorUrl: "",
            height: 25, color: true, samples: @["mute", "desk-6", "fishing-hook"]),
    # Logos
    IconSet(prefix: "logos", name: "SVG Logos", group: "Logos", license: "CC0", spdx: "CC0-1.0",
            licenseUrl: "https://raw.githubusercontent.com/gilbarbara/logos/master/LICENSE.txt", author: "Gil Barbara", authorUrl: "https://github.com/gilbarbara/logos",
            height: 0, color: true, samples: @["npm-icon", "uikit", "patreon"]),
    IconSet(prefix: "simple-icons", name: "Simple Icons", group: "Logos", license: "CC0 1.0", spdx: "CC0-1.0",
            licenseUrl: "https://github.com/simple-icons/simple-icons/blob/develop/LICENSE.md", author: "Simple Icons Collaborators", authorUrl: "https://github.com/simple-icons/simple-icons",
            height: 24, color: false, samples: @["wise", "framer", "vuetify"]),
    IconSet(prefix: "cib", name: "CoreUI Brands", group: "Logos", license: "CC0 1.0", spdx: "CC0-1.0",
            licenseUrl: "https://creativecommons.org/publicdomain/zero/1.0/", author: "creativeLabs Łukasz Holeczek", authorUrl: "https://github.com/coreui/coreui-icons",
            height: 32, color: false, samples: @["cc-amazon-pay", "hotjar", "open-id"]),
    IconSet(prefix: "fa7-brands", name: "Font Awesome Brands", group: "Logos", license: "CC BY 4.0", spdx: "CC-BY-4.0",
            licenseUrl: "https://creativecommons.org/licenses/by/4.0/", author: "Dave Gandy", authorUrl: "https://github.com/FortAwesome/Font-Awesome",
            height: 32, color: false, samples: @["strava", "css3", "y-combinator"]),
    IconSet(prefix: "devicon", name: "Devicon", group: "Logos", license: "MIT", spdx: "MIT",
            licenseUrl: "https://github.com/devicons/devicon/blob/master/LICENSE", author: "konpa", authorUrl: "https://github.com/devicons/devicon/tree/master",
            height: 32, color: true, samples: @["windows8", "tensorflow", "logstash"]),
    IconSet(prefix: "skill-icons", name: "Skill Icons", group: "Logos", license: "MIT", spdx: "MIT",
            licenseUrl: "https://github.com/tandpfun/skill-icons/blob/main/LICENSE", author: "tandpfun", authorUrl: "https://github.com/tandpfun/skill-icons",
            height: 24, color: true, samples: @["markdown-light", "vuejs-dark", "html"]),
    IconSet(prefix: "vscode-icons", name: "VSCode Icons", group: "Logos", license: "MIT", spdx: "MIT",
            licenseUrl: "https://github.com/vscode-icons/vscode-icons/blob/master/LICENSE", author: "Roberto Huertas", authorUrl: "https://github.com/vscode-icons/vscode-icons",
            height: 32, color: true, samples: @["file-type-actionscript2", "file-type-json", "file-type-manifest"]),
    # Emoji
    IconSet(prefix: "twemoji", name: "Twitter Emoji", group: "Emoji", license: "CC BY 4.0", spdx: "CC-BY-4.0",
            licenseUrl: "https://creativecommons.org/licenses/by/4.0/", author: "Twitter", authorUrl: "https://github.com/jdecked/twemoji",
            height: 36, color: true, samples: @["anguished-face", "duck", "bell"]),
    IconSet(prefix: "noto", name: "Noto Emoji", group: "Emoji", license: "Apache 2.0", spdx: "Apache-2.0",
            licenseUrl: "https://github.com/googlefonts/noto-emoji/blob/main/svg/LICENSE", author: "Google Inc", authorUrl: "https://github.com/googlefonts/noto-emoji",
            height: 16, color: true, samples: @["beaming-face-with-smiling-eyes", "computer-mouse", "chart-increasing"]),
    IconSet(prefix: "fluent-emoji-flat", name: "Fluent Emoji Flat", group: "Emoji", license: "MIT", spdx: "MIT",
            licenseUrl: "https://github.com/microsoft/fluentui-emoji/blob/main/LICENSE", author: "Microsoft Corporation", authorUrl: "https://github.com/microsoft/fluentui-emoji",
            height: 32, color: true, samples: @["avocado", "ticket", "straight-ruler"]),
    IconSet(prefix: "fluent-emoji", name: "Fluent Emoji", group: "Emoji", license: "MIT", spdx: "MIT",
            licenseUrl: "https://github.com/microsoft/fluentui-emoji/blob/main/LICENSE", author: "Microsoft Corporation", authorUrl: "https://github.com/microsoft/fluentui-emoji",
            height: 32, color: true, samples: @["avocado", "ticket", "straight-ruler"]),
    IconSet(prefix: "emojione", name: "Emoji One (Colored)", group: "Emoji", license: "CC BY 4.0", spdx: "CC-BY-4.0",
            licenseUrl: "https://creativecommons.org/licenses/by/4.0/", author: "Emoji One", authorUrl: "https://github.com/EmojiTwo/emojitwo",
            height: 32, color: true, samples: @["anxious-face-with-sweat", "cloud-with-snow", "studio-microphone"]),
    IconSet(prefix: "fxemoji", name: "Firefox OS Emoji", group: "Emoji", license: "Apache 2.0", spdx: "Apache-2.0",
            licenseUrl: "https://mozilla.github.io/fxemoji/LICENSE.md", author: "Mozilla", authorUrl: "https://github.com/mozilla/fxemoji",
            height: 32, color: true, samples: @["foxweary", "loveletter", "openlock"]),
    # Flags & Maps
    IconSet(prefix: "circle-flags", name: "Circle Flags", group: "Flags & Maps", license: "MIT", spdx: "MIT",
            licenseUrl: "https://github.com/HatScripts/circle-flags/blob/gh-pages/LICENSE", author: "HatScripts", authorUrl: "https://github.com/HatScripts/circle-flags",
            height: 32, color: true, samples: @["ee", "klingon", "jp"]),
    IconSet(prefix: "flag", name: "Flag Icons", group: "Flags & Maps", license: "MIT", spdx: "MIT",
            licenseUrl: "https://github.com/lipis/flag-icons/blob/main/LICENSE", author: "Panayiotis Lipiridis", authorUrl: "https://github.com/lipis/flag-icons",
            height: 0, color: true, samples: @["fr-1x1", "de-1x1", "bh-1x1"]),
    IconSet(prefix: "flagpack", name: "Flagpack", group: "Flags & Maps", license: "MIT", spdx: "MIT",
            licenseUrl: "https://github.com/Yummygum/flagpack-core/blob/main/LICENSE", author: "Yummygum", authorUrl: "https://github.com/Yummygum/flagpack-core",
            height: 24, color: true, samples: @["ci", "gb-ukm", "wf"]),
    IconSet(prefix: "cif", name: "CoreUI Flags", group: "Flags & Maps", license: "CC0 1.0", spdx: "CC0-1.0",
            licenseUrl: "https://creativecommons.org/publicdomain/zero/1.0/", author: "creativeLabs Łukasz Holeczek", authorUrl: "https://github.com/coreui/coreui-icons",
            height: 0, color: true, samples: @["ee", "ca", "sk"]),
    IconSet(prefix: "maki", name: "Maki", group: "Flags & Maps", license: "CC0", spdx: "CC0-1.0",
            licenseUrl: "https://creativecommons.org/publicdomain/zero/1.0/", author: "Mapbox", authorUrl: "https://github.com/mapbox/maki",
            height: 15, color: false, samples: @["entrance-alt1", "clothing-store", "grocery"]),
    IconSet(prefix: "temaki", name: "Temaki", group: "Flags & Maps", license: "CC0", spdx: "CC0-1.0",
            licenseUrl: "https://creativecommons.org/publicdomain/zero/1.0/", author: "Bryan Housel", authorUrl: "https://github.com/rapideditor/temaki",
            height: 0, color: false, samples: @["milestone", "elevator", "storage"]),
    # Thematic
    IconSet(prefix: "game-icons", name: "Game Icons", group: "Thematic", license: "CC BY 3.0", spdx: "CC-BY-3.0",
            licenseUrl: "https://github.com/game-icons/icons/blob/master/license.txt", author: "GameIcons", authorUrl: "https://github.com/game-icons/icons",
            height: 0, color: false, samples: @["diamond-trophy", "thrown-spear", "rank-3"]),
    IconSet(prefix: "healthicons", name: "Health Icons", group: "Thematic", license: "MIT", spdx: "MIT",
            licenseUrl: "https://github.com/resolvetosavelives/healthicons/blob/main/LICENSE", author: "Resolve to Save Lives", authorUrl: "https://github.com/resolvetosavelives/healthicons",
            height: 24, color: false, samples: @["cold-chain", "emergency-post", "asthma-outline"]),
    IconSet(prefix: "meteocons", name: "Meteocons", group: "Thematic", license: "MIT", spdx: "MIT",
            licenseUrl: "https://github.com/basmilius/weather-icons/blob/dev/LICENSE", author: "Bas Milius", authorUrl: "https://github.com/basmilius/weather-icons",
            height: 32, color: true, samples: @["hurricane-fill", "sunrise-fill", "windsock"]),
    IconSet(prefix: "wi", name: "Weather Icons", group: "Thematic", license: "Open Font License", spdx: "OFL-1.1",
            licenseUrl: "https://scripts.sil.org/cms/scripts/page.php?site_id=nrsi&id=OFL", author: "Erik Flowers", authorUrl: "https://github.com/erikflowers/weather-icons",
            height: 30, color: false, samples: @["day-hail", "barometer", "day-windy"]),
    IconSet(prefix: "medical-icon", name: "Medical Icons", group: "Thematic", license: "MIT", spdx: "MIT",
            licenseUrl: "https://github.com/samcome/webfont-medical-icons/blob/master/LICENSE", author: "Samuel Frémondière", authorUrl: "https://github.com/samcome/webfont-medical-icons",
            height: 0, color: false, samples: @["i-care-staff-area", "i-nursery", "immunizations"]),
    IconSet(prefix: "academicons", name: "Academicons", group: "Thematic", license: "Open Font License", spdx: "OFL-1.1",
            licenseUrl: "https://scripts.sil.org/cms/scripts/page.php?site_id=nrsi&id=OFL", author: "James Walsh", authorUrl: "https://github.com/jpswalsh/academicons",
            height: 32, color: false, samples: @["conversation", "crossref-square", "stackoverflow"])
  ]
    ## The Iconify sets offered, by group: permissive licenses only (MIT,
    ## Apache 2.0, ISC, CC0, CC BY, OFL, Unlicense), as Iconify lists them.

# ---- small helpers ---------------------------------------------------------------

proc enc(s: string): string =
  ## Percent-encoding for a query value.
  for c in s:
    if c in {'A'..'Z', 'a'..'z', '0'..'9', '-', '.', '_', '~'}: result.add c
    else: result.add '%' & toHex(ord(c), 2)

proc str(n: JsonNode; key: string): string =
  if n != nil and n.kind == JObject:
    let v = n.getOrDefault(key)
    if v != nil:
      case v.kind
      of JString: return v.str
      of JInt: return $v.num
      of JFloat: return $v.fnum
      else: discard
  ""

proc int0(n: JsonNode; key: string): int =
  if n != nil and n.kind == JObject:
    let v = n.getOrDefault(key)
    if v != nil:
      case v.kind
      of JInt: return int(v.num)
      of JFloat: return int(v.fnum)
      of JString: return (try: parseInt(v.str) except ValueError: 0)
      else: discard
  0

proc decodeEntities(s: string): string =
  var i = 0
  while i < s.len:
    if s[i] == '&':
      let e = s.find(';', i)
      if e > i and e - i <= 10:
        let name = s[i + 1 ..< e]
        var rep = ""
        case name
        of "amp": rep = "&"
        of "lt": rep = "<"
        of "gt": rep = ">"
        of "quot": rep = "\""
        of "apos", "#39": rep = "'"
        of "nbsp": rep = " "
        else:
          if name.len > 1 and name[0] == '#':
            try:
              let code = if name[1] in {'x', 'X'}: fromHex[int](name[2 .. ^1]) else: parseInt(name[1 .. ^1])
              if code > 0 and code < 0x110000: rep = $Rune(code)
            except ValueError: discard
        if rep.len > 0:
          result.add rep
          i = e + 1
          continue
    result.add s[i]
    inc i

proc stripHtml*(s: string): string =
  ## Text of an HTML snippet (an artist's name with links): tags out,
  ## entities decoded, spaces collapsed.
  var t = ""
  var tag = ""
  var inTag = false
  for c in s:
    if c == '<' and not inTag:
      inTag = true
      tag.setLen(0)
    elif c == '>' and inTag:
      inTag = false
      # (a line break or a block between two names: a space)
      let name = tag.strip(chars = {'/', ' '}).split({' ', '/'})[0].toLowerAscii
      if name in ["br", "p", "div", "li", "td", "tr", "dd", "dt"]: t.add ' '
    elif inTag: tag.add c
    else: t.add c
  t = decodeEntities(t).replace("\xC2\xA0", " ")
  var sp = true
  for c in t:
    if c in Whitespace:
      if not sp: result.add ' '
      sp = true
    else:
      result.add c
      sp = false
  result = result.strip

proc words(s: string): seq[string] =
  for w in strutils.splitWhitespace(s.toLower):
    if w.len > 0: result.add w

proc matchesAll(ws: seq[string]; hay: string): bool =
  let h = hay.toLower
  for w in ws:
    if w notin h: return false
  true

proc hasArabic(s: string): bool =
  for r in s.runes:
    if int(r) in 0x0600 .. 0x06FF or int(r) in 0x0750 .. 0x077F: return true

proc firstLine(body: string): string =
  ## A short reason from a non-JSON answer ("[ERROR 400] ...").
  result = body.strip.splitLines()[0].strip
  if result.len > 200: result = result[0 ..< 200] & "..."
  if result.len == 0: result = "the source gave an empty answer"

proc addTag(tags: var seq[string]; t: string) =
  let x = t.strip
  if x.len == 0 or x.len >= 60 or tags.len >= 24: return
  for o in tags:
    if cmpIgnoreCase(o, x) == 0: return
  tags.add x

proc perPageOf*(q: AssetQuery): int =
  ## How many items a page of `q` asks for: `perPage`, else the source's
  ## default, within what the source allows.
  let (dflt, most) = case q.source
    of asOpenverse: (20, 20)          # the anonymous limit
    of asWikimedia: (30, 50)
    of asPixabay: (30, 200)
    of asPexels: (30, 80)
    of asUnsplash: (30, 30)
    of asIconify: (60, 200)
    of asAmbientCG: (30, 250)
    of asPolyHaven, asLibrary: (30, 500)
  clamp(if q.perPage > 0: q.perPage else: dflt, if q.source == asPixabay: 3 else: 1, most)

proc pageNo(q: AssetQuery): int = max(1, q.page)

proc slicePage(all: seq[AssetItem]; q: AssetQuery): AssetPage =
  ## A page of a list the answer gave whole.
  let n = perPageOf(q)
  let a = (pageNo(q) - 1) * n
  result.total = all.len
  if a < all.len: result.items = all[a ..< min(all.len, a + n)]
  result.hasMore = a + n < all.len

# ---- what is offered ---------------------------------------------------------------

proc libraryHas(k: AssetKind): bool =
  for it in libraryItems:
    if it.kind == k: return true

proc sourcesFor*(kind: AssetKind): seq[AssetSource] =
  ## The sources that give `kind`, best first. Pixabay is listed even
  ## without a key (see `needsKey`); the library for photos, illustrations,
  ## vectors, icons, textures and backgrounds only when its catalog
  ## (`setLibrary`) has such items.
  case kind
  of akPhoto: result = @[asOpenverse, asWikimedia, asPixabay, asPexels, asUnsplash]
  of akIllustration, akVector: result = @[asOpenverse, asWikimedia, asPixabay]
  of akIcon: result = @[asIconify]
  of akTexture: result = @[asPolyHaven, asAmbientCG]
  of akBackground: result = @[asPolyHaven, asPixabay, asPexels, asUnsplash, asOpenverse]
  of akBrush, akPattern, akGradient, akSwatches, akStyle, akDesign: result = @[asLibrary]; return
  if libraryHas(kind): result.add asLibrary

proc needsKey*(s: AssetSource): bool =
  ## The source needs an API key from the user (`pixabayKey`, `pexelsKey`,
  ## `unsplashKey`: each free from the source's site).
  s in {asPixabay, asPexels, asUnsplash}

proc hasKey*(s: AssetSource): bool =
  ## The source needs no key, or the user gave it one.
  case s
  of asPixabay: pixabayKey.len > 0
  of asPexels: pexelsKey.len > 0
  of asUnsplash: unsplashKey.len > 0
  else: true

proc sourceCredit*(s: AssetSource): string =
  ## The credit to show near that source's results (their terms ask for it).
  case s
  of asOpenverse: "Search by Openverse"
  of asWikimedia: "From Wikimedia Commons"
  of asPixabay: "Images from Pixabay"
  of asPexels: "Photos provided by Pexels"
  of asUnsplash: "Photos from Unsplash"
  of asIconify: "Icons via Iconify"
  of asPolyHaven: "Powered by Poly Haven"
  of asAmbientCG: "Textures from ambientCG.com"
  of asLibrary: "Retro Photo Library"

proc sourceHome*(s: AssetSource): string =
  ## The source's web site (for the credit's link).
  case s
  of asOpenverse: "https://openverse.org"
  of asWikimedia: "https://commons.wikimedia.org"
  of asPixabay: "https://pixabay.com"
  of asPexels: "https://www.pexels.com"
  of asUnsplash: "https://unsplash.com"
  of asIconify: "https://iconify.design"
  of asPolyHaven: "https://polyhaven.com"
  of asAmbientCG: "https://ambientcg.com"
  of asLibrary: ""

proc answerMaxAge*(s: AssetSource): int =
  ## How long (seconds) to keep a source's answers in the cache (the
  ## `maxAgeSec` of `fetchAsync(queryUrl(q))`): Pixabay asks that answers
  ## be kept 24 hours rather than asked again, and its picture links stop
  ## working after that.
  case s
  of asIconify: 7 * 24 * 3600
  of asLibrary: 3600
  else: 24 * 3600

proc cat(name, key: string): AssetCategory = AssetCategory(name: name, key: key)

const
  photoCats = [("Nature", "nature"), ("Business", "business office"), ("Food & Drink", "food"),
    ("Travel", "travel"), ("People", "people"), ("Architecture", "architecture"),
    ("Interiors & Hotels", "hotel interior"), ("Animals", "animals"), ("Technology", "technology"),
    ("Sports", "sport"), ("Flowers", "flowers"), ("Sky & Clouds", "clouds"), ("Water & Sea", "sea"),
    ("Desert", "desert"), ("Mosques", "mosque"), ("Arabic & Islamic Art", "islamic art"),
    ("Arabic Calligraphy", "arabic calligraphy"), ("Oman", "Oman"), ("City at Night", "city night"),
    ("Celebrations", "celebration"), ("Textures", "texture"), ("Backgrounds", "background"),
    ("Abstract", "abstract"), ("Patterns", "pattern")]
  vectorCats = [("Icons & Symbols", "icon"), ("Ornaments", "ornament"), ("Islamic Patterns", "islamic pattern"),
    ("Calligraphy", "calligraphy"), ("Patterns", "pattern"), ("Maps", "map"), ("Flags", "flag"),
    ("Diagrams & Charts", "diagram"), ("Animals", "animal"), ("People", "people"), ("Nature", "nature"),
    ("Food", "food"), ("Buildings", "building"), ("Transport", "vehicle"), ("Frames & Borders", "frame")]
  backgroundCats = [("Abstract", "abstract background"), ("Gradients", "gradient"), ("Bokeh", "bokeh"),
    ("Sky", "sky"), ("Paper", "paper texture"), ("Wood", "wood texture"), ("Marble", "marble"),
    ("Water", "water surface"), ("Landscapes", "landscape"), ("City Skylines", "skyline"),
    ("Sand & Desert", "sand dunes"), ("Islamic Patterns", "islamic pattern")]
  pixabayCats = [("Backgrounds", "backgrounds"), ("Nature", "nature"), ("Business", "business"),
    ("Food & Drink", "food"), ("Travel", "travel"), ("Places", "places"), ("People", "people"),
    ("Buildings", "buildings"), ("Animals", "animals"), ("Computer", "computer"), ("Sports", "sports"),
    ("Fashion", "fashion"), ("Feelings", "feelings"), ("Health", "health"), ("Education", "education"),
    ("Science", "science"), ("Religion", "religion"), ("Industry", "industry"),
    ("Transportation", "transportation"), ("Music", "music")]
    ## Pixabay's own category ids.
  polyTextureCats = [("Brick & Block", "category=brick-block"), ("Wood", "category=wood"),
    ("Wood Planks", "category=wood/boards-planks"), ("Concrete", "category=concrete"),
    ("Plaster & Stucco", "category=concrete/plaster-stucco"), ("Stone", "category=stone"),
    ("Cobblestone & Paving", "category=stone/cobblestone-paving"), ("Ceramic & Tiles", "category=ceramic"),
    ("Terrazzo & Mosaic", "category=ceramic/terrazzo-mosaic"), ("Metal", "category=metal"),
    ("Fabric & Leather", "category=textiles-leather"), ("Ground & Terrain", "category=ground-terrain"),
    ("Sand", "category=ground-terrain/sand"), ("Grass", "category=ground-terrain/grass-vegetation"),
    ("Asphalt & Roads", "category=asphalt-bitumen"), ("Paper & Card", "category=paper-card"),
    ("Plastic & Rubber", "category=plastic-rubber"), ("Organic", "category=organic"),
    ("Glass", "category=glass"), ("Floors", "surface_use=floor"), ("Walls", "surface_use=wall"),
    ("Roofing", "surface_use=roof")]
    ## Poly Haven's taxonomy (`/taxonomy`) and attributes (`/assets?category=`, `?surface_use=`).
  polyHdriCats = [("Pure Skies", "category=pure-skies"), ("Sunrise & Sunset", "time_of_day=sunrise,sunset"),
    ("Night", "time_of_day=night"), ("Clear Sky", "weather=clear"), ("Overcast", "weather=overcast"),
    ("Studio", "category=studio"), ("Interiors", "category=interiors"), ("Outdoor", "environment=outdoor"),
    ("Coast & Water", "category=coast-water"), ("Desert & Arid", "category=desert-arid"),
    ("Fields & Countryside", "category=fields-countryside"), ("Forest & Woodland", "category=forest-woodland"),
    ("Mountains & Hills", "category=mountains-hills"), ("Parks & Gardens", "category=parks-gardens"),
    ("Streets & Town", "category=streets-town"), ("Industrial", "category=industrial"),
    ("Abandoned & Ruins", "category=abandoned-ruins")]
  ambientCats = [("Wood", "wood"), ("Wood Floor", "parquet"), ("Planks", "planks"), ("Bricks", "bricks"),
    ("Tiles", "tiles"), ("Concrete", "concrete"), ("Plaster", "plaster"), ("Marble", "marble"),
    ("Terrazzo", "terrazzo"), ("Rock", "rock"), ("Paving Stones", "paving"), ("Ground", "ground"),
    ("Gravel", "gravel"), ("Grass", "grass"), ("Sand", "sand"), ("Snow", "snow"), ("Bark", "bark"),
    ("Metal", "metal"), ("Rust", "rust"), ("Fabric", "fabric"), ("Carpet", "carpet"), ("Leather", "leather"),
    ("Paper", "paper"), ("Cardboard", "cardboard"), ("Wicker", "wicker"), ("Roofing", "roof"),
    ("Asphalt", "asphalt"), ("Painted", "painted")]
    ## Search words (ambientCG's API filters by keywords; they match tags and names).

proc iconGroups*(): seq[string] =
  ## The groups of `iconSets`, in order.
  for s in iconSets:
    if s.group notin result: result.add s.group

proc iconSetOf*(prefix: string): int =
  ## The index of a set in `iconSets`; -1 when it is not offered.
  for i, s in iconSets:
    if s.prefix == prefix: return i
  -1

proc libraryCategories*(items: seq[AssetItem]; k: AssetKind): seq[AssetCategory] =
  ## The categories of a parsed catalog's items of kind `k`, by name.
  var seen: HashSet[string]
  for it in items:
    if it.kind == k and it.category.len > 0 and it.category.toLower notin seen:
      seen.incl it.category.toLower
      result.add cat(it.category, it.category)
  result.sort(proc (a, b: AssetCategory): int = cmpIgnoreCase(a.name, b.name))

proc categoriesOf*(s: AssetSource; k: AssetKind): seq[AssetCategory] =
  ## The categories to browse `s` for `k` by (a curated list: no request
  ## is made). Iconify: the groups of sets ("group:Material": samples of
  ## each set) followed by each set ("Material / Material Design Icons",
  ## key "mdi": all its icons). The library: those of `setLibrary`'s catalog.
  if s != asLibrary and s notin sourcesFor(k): return
  case s
  of asOpenverse, asWikimedia:
    case k
    of akPhoto, akIllustration:
      for (n, key) in photoCats: result.add cat(n, key)
    of akVector:
      for (n, key) in vectorCats: result.add cat(n, key)
    of akBackground:
      for (n, key) in backgroundCats: result.add cat(n, key)
    else: discard
  of asPixabay:
    if k in {akPhoto, akIllustration, akVector, akBackground}:
      for (n, key) in pixabayCats: result.add cat(n, key)
  of asPexels, asUnsplash:
    case k
    of akPhoto:
      for (n, key) in photoCats: result.add cat(n, key)
    of akBackground:
      for (n, key) in backgroundCats: result.add cat(n, key)
    else: discard
  of asIconify:
    if k == akIcon:
      for g in iconGroups():
        result.add cat(g, "group:" & g)
        for st in iconSets:
          if st.group == g: result.add cat(g & " / " & st.name, st.prefix)
  of asPolyHaven:
    if k == akTexture:
      for (n, key) in polyTextureCats: result.add cat(n, key)
    elif k == akBackground:
      for (n, key) in polyHdriCats: result.add cat(n, key)
  of asAmbientCG:
    if k == akTexture:
      for (n, key) in ambientCats: result.add cat(n, key)
  of asLibrary:
    result = libraryCategories(libraryItems, k)

proc defaultWords(q: AssetQuery): string =
  ## What a search-only source is asked when nothing is typed or picked.
  case q.kind
  of akVector: "ornament"
  of akBackground: "background"
  of akIllustration: "illustration"
  else: "nature"

proc searchWords(q: AssetQuery): string =
  ## The words to search for: those typed, within the category picked.
  let t = q.text.strip
  let c = q.category.strip
  if t.len > 0 and c.len > 0: t & " " & c
  elif t.len > 0: t
  elif c.len > 0: c
  else: defaultWords(q)

# ---- requests ----------------------------------------------------------------------

proc safeKey(key: string): bool =
  ## A category key that goes into a query as it is ("category=wood/bark").
  if key.len == 0 or '=' notin key: return false
  for c in key:
    if c notin {'a'..'z', '0'..'9', '_', '-', '=', ',', '/'}: return false
  true

proc iconPrefixes(q: AssetQuery): seq[string] =
  ## The sets a query looks in: the set picked, the sets of the group
  ## picked, or all.
  let c = q.category
  if c.startsWith("group:"):
    for s in iconSets:
      if s.group == c[6 .. ^1]: result.add s.prefix
  elif c.len > 0 and iconSetOf(c) >= 0: result.add c
  if result.len == 0:
    for s in iconSets: result.add s.prefix

proc queryUrl*(q: AssetQuery): string =
  ## The request to make for `q` ("" when the source cannot answer that
  ## kind, Pixabay has no key, or it is the library: see `libraryPage`).
  let n = perPageOf(q)
  let p = pageNo(q)
  if q.source notin sourcesFor(q.kind) and q.source != asLibrary: return ""
  case q.source
  of asOpenverse:
    result = openverseApi & "?q=" & enc(searchWords(q)) & "&page=" & $p & "&page_size=" & $n &
             "&license_type=commercial,modification&mature=false"
    case q.kind
    of akPhoto: result.add "&category=photograph"
    of akIllustration: result.add "&category=illustration,digitized_artwork"
    of akVector: result.add "&extension=svg"
    else: discard
  of asWikimedia:
    let filter = case q.kind
      of akVector: " filetype:drawing"
      of akIllustration: " illustration filetype:bitmap"
      else: " filetype:bitmap"
    result = commonsApi & "?action=query&format=json&formatversion=2&generator=search&gsrnamespace=6" &
             "&gsrsearch=" & enc(searchWords(q) & filter) & "&gsrlimit=" & $n &
             "&gsroffset=" & $((p - 1) * n) &
             "&prop=imageinfo&iiprop=url%7Csize%7Cmime%7Cextmetadata&iiurlwidth=330" &
             "&iiextmetadatafilter=ObjectName%7CArtist%7CCredit%7CLicenseShortName%7CLicenseUrl%7CLicense%7CAttributionRequired%7CRestrictions" &
             "&iiextmetadatalanguage=en"
  of asPixabay:
    if pixabayKey.len == 0: result = ""; return
    let kind = case q.kind
      of akIllustration: "illustration"
      of akVector: "vector"
      else: "photo"
    var category = q.category
    if category.len == 0 and q.kind == akBackground: category = "backgrounds"
    result = pixabayApi & "?key=" & enc(pixabayKey) & "&image_type=" & kind &
             "&per_page=" & $n & "&page=" & $p & "&safesearch=true"
    let t = q.text.strip
    if t.len > 0:
      result.add "&q=" & enc(if t.len > 100: t[0 ..< 100] else: t)
      if hasArabic(t): result.add "&lang=ar"
    if category.len > 0: result.add "&category=" & enc(category)
  of asPexels:
    if pexelsKey.len == 0: result = ""; return
    # (nothing typed or picked: the photos Pexels picks, "curated")
    let words = if q.text.strip.len > 0 or q.category.strip.len > 0: searchWords(q) else: ""
    result = (if words.len == 0: pexelsApi & "/curated?" else: pexelsApi & "/search?query=" & enc(words) & "&") &
             "per_page=" & $n & "&page=" & $p
    if words.len > 0 and q.kind == akBackground: result.add "&orientation=landscape"
    result = withHeaders(result, [("Authorization", pexelsKey)])
  of asUnsplash:
    if unsplashKey.len == 0: result = ""; return
    # (nothing typed or picked: the popular photos)
    let words = if q.text.strip.len > 0 or q.category.strip.len > 0: searchWords(q) else: ""
    result = if words.len == 0: unsplashApi & "/photos?order_by=popular&per_page=" & $n & "&page=" & $p
             else: unsplashApi & "/search/photos?query=" & enc(words) & "&per_page=" & $n & "&page=" & $p &
                   "&content_filter=high" & (if q.kind == akBackground: "&orientation=landscape" else: "")
    if hasArabic(q.text): result.add "&lang=ar"
    result = withHeaders(result, [("Authorization", "Client-ID " & unsplashKey), ("Accept-Version", "v1")])
  of asIconify:
    let sets = iconPrefixes(q)
    let t = q.text.strip
    if t.len > 0:
      # (`limit` is how many are found in all, 32 to 999; `start` skips)
      let start = (p - 1) * n
      if start + n + 1 > 999: result = ""; return
      result = iconifyApi & "/search?query=" & enc(t) & "&limit=" & $max(32, start + n + 1) &
               "&start=" & $start & "&prefixes=" & sets.join(",")
    elif q.category.len > 0 and not q.category.startsWith("group:"):
      result = iconifyApi & "/collection?prefix=" & enc(q.category) & "&info=true"
    else:
      result = iconifyApi & "/collections?prefixes=" & sets.join(",")
  of asPolyHaven:
    result = polyHavenApi & "/assets?t=" & (if q.kind == akBackground: "hdris" else: "textures")
    let c = q.category.strip
    if c.len > 0:
      result.add (if safeKey(c): "&" & c else: "&c=" & enc(c))
  of asAmbientCG:
    result = ambientApi & "?type=Material&sort=Popular&limit=" & $n & "&offset=" & $((p - 1) * n) &
             "&include=statisticsData%2ClabelData%2CpreviewData%2CfileData"
    let w = (q.text.strip & " " & q.category.strip).strip
    if w.len > 0: result.add "&q=" & enc(w)
  of asLibrary:
    result = ""

# ---- Openverse -------------------------------------------------------------------

proc ccName(code, version: string): string =
  case code
  of "cc0": "CC0 " & (if version.len > 0: version else: "1.0")
  of "pdm": "Public Domain Mark " & (if version.len > 0: version else: "1.0")
  of "by": "CC BY " & version
  of "by-sa": "CC BY-SA " & version
  else: code.toUpperAscii & " " & version

proc parseOpenverse(q: AssetQuery; j: JsonNode): AssetPage =
  if j.kind != JObject or not j.hasKey("results"):
    result.error = (let d = j.str("detail"); if d.len > 0: d else: "Openverse gave no results list")
    return
  result.total = j.int0("result_count")
  result.hasMore = pageNo(q) < j.int0("page_count")
  for r in j["results"]:
    let lic = r.str("license").toLowerAscii
    if lic notin ["cc0", "pdm", "by", "by-sa"]: continue    # (no NC, ND, sampling)
    if r.getOrDefault("mature").getBool(false): continue
    var it = AssetItem(source: asOpenverse, kind: q.kind, id: r.str("id"), category: q.category)
    it.title = r.str("title").strip
    if it.title.len == 0: it.title = "Untitled"
    it.thumbUrl = r.str("thumbnail")
    it.fullUrl = r.str("url")
    it.ext = r.str("filetype").toLowerAscii
    if it.ext.len == 0: it.ext = extOfUrl(it.fullUrl)
    if it.ext == "jpeg": it.ext = "jpg"
    if q.kind == akVector and it.ext != "svg": continue
    it.width = r.int0("width")
    it.height = r.int0("height")
    if it.ext == "svg" or (it.width in 1 .. 1600 and it.height in 1 .. 1600): it.previewUrl = it.fullUrl
    it.author = r.str("creator")
    it.authorUrl = r.str("creator_url")
    it.pageUrl = r.str("foreign_landing_url")
    it.license = ccName(lic, r.str("license_version")).strip
    it.licenseUrl = r.str("license_url")
    it.attribution = r.str("attribution")
    if it.attribution.len == 0 and lic in ["by", "by-sa"]:
      it.attribution = "\"" & it.title & "\"" & (if it.author.len > 0: " by " & it.author else: "") &
                       " is licensed under " & it.license & "."
    let tags = r.getOrDefault("tags")
    if tags != nil and tags.kind == JArray:
      for t in tags: it.tags.addTag t.str("name")
    if it.fullUrl.len > 0 and it.thumbUrl.len > 0: result.items.add it

# ---- Wikimedia Commons -----------------------------------------------------------

const commonsSteps = [330, 500, 960, 1280, 1920, 3840]
  ## (the thumbnail widths Wikimedia serves from its cache)

proc commonsThumb(thumbUrl: string; width: int): string =
  ## A Commons thumbnail address for another width ("330px-" -> "1280px-").
  let slash = thumbUrl.rfind('/')
  if slash < 0: return ""
  let seg = thumbUrl[slash + 1 .. ^1]
  let px = seg.find("px-")
  if px <= 0: return ""
  var a = px - 1
  while a >= 0 and seg[a] in Digits: dec a
  thumbUrl[0 .. slash] & seg[0 .. a] & $width & seg[px .. ^1]

proc commonsStep(below: int): int =
  ## The largest cached thumbnail width smaller than `below` (0: none).
  for s in commonsSteps:
    if s < below: result = s

proc freeCommonsLicense(short, code: string): string =
  ## The license's name when it is a free one kept here (CC0, public
  ## domain, CC BY, CC BY-SA), else "".
  let s = short.strip
  let l = s.toLowerAscii
  let c = code.toLowerAscii
  if l.startsWith("cc0") or l.startsWith("cc-zero") or c == "cc0": return "CC0"
  if l.startsWith("public domain") or l == "pd" or l.startsWith("pd-") or c == "pd" or
     c.startsWith("pd-"): return "Public domain"
  if l.startsWith("cc by-sa") or l.startsWith("cc by ") or l == "cc by" or
     c.startsWith("cc-by-sa") or (c.startsWith("cc-by-") and "nc" notin c and "nd" notin c):
    if "nc" in l.split({' ', '-'}) or "nd" in l.split({' ', '-'}): return ""
    return (if s.len > 0: s else: code.toUpperAscii)
  ""

proc parseCommons(q: AssetQuery; j: JsonNode): AssetPage =
  if j.kind == JObject and j.hasKey("error"):
    result.error = j["error"].str("info")
    if result.error.len == 0: result.error = "Wikimedia Commons refused the request"
    return
  result.total = -1
  result.hasMore = j.kind == JObject and j.hasKey("continue")
  let query = j.getOrDefault("query")
  if query == nil: return                  # (no results at all)
  var pages: seq[JsonNode]
  let ps = query.getOrDefault("pages")
  if ps != nil:
    if ps.kind == JArray:
      for p in ps: pages.add p
    elif ps.kind == JObject:
      for _, p in ps: pages.add p
  pages.sort(proc (a, b: JsonNode): int = cmp(a.int0("index"), b.int0("index")))
  for p in pages:
    let infos = p.getOrDefault("imageinfo")
    if infos == nil or infos.kind != JArray or infos.len == 0: continue
    let ii = infos[0]
    let meta = ii.getOrDefault("extmetadata")
    proc m(key: string): string =
      if meta == nil: "" else: meta.getOrDefault(key).str("value")
    let license = freeCommonsLicense(m("LicenseShortName"), m("License"))
    if license.len == 0: continue
    let mime = ii.str("mime").toLowerAscii
    if not mime.startsWith("image/"): continue
    var it = AssetItem(source: asWikimedia, kind: q.kind, id: p.str("title"), category: q.category)
    it.title = stripHtml(m("ObjectName"))
    if it.title.len == 0:
      it.title = it.id
      if it.title.startsWith("File:"): it.title = it.title[5 .. ^1]
      let dot = it.title.rfind('.')
      if dot > 0: it.title.setLen(dot)
      it.title = it.title.replace('_', ' ')
    let url = ii.str("url")
    let thumb = ii.str("thumburl")
    let w = ii.int0("width")
    let h = ii.int0("height")
    it.thumbUrl = if thumb.len > 0: thumb else: url
    it.pageUrl = ii.str("descriptionurl")
    if mime == "image/svg+xml":
      if q.kind != akVector and q.kind != akIllustration: continue
      it.fullUrl = url
      it.ext = "svg"
      it.width = w
      it.height = h
      it.previewUrl = commonsThumb(thumb, 1280)
    elif q.kind == akVector:
      continue
    elif mime in ["image/jpeg", "image/png", "image/gif", "image/webp"]:
      it.fullUrl = url
      it.ext = extOfUrl(url)
      it.width = w
      it.height = h
      let fit = if max(w, h) > 0: w * 1280 div max(w, h) + 1 else: 0
      let step = commonsStep(min(w, fit))
      it.previewUrl = if max(w, h) <= 1280: url elif step > 0: commonsThumb(thumb, step) else: ""
    else:
      # TIFF, XCF...: the largest JPEG/PNG rendering Wikimedia makes of it
      let step = commonsStep(min(w, 4097))
      if step == 0 or thumb.len == 0: continue
      it.fullUrl = commonsThumb(thumb, step)
      it.ext = extOfUrl(it.fullUrl)
      it.width = step
      it.height = (if w > 0: h * step div w else: 0)
      let fit = if max(w, h) > 0: w * 1280 div max(w, h) + 1 else: 0
      let pstep = commonsStep(min(w, fit))
      it.previewUrl = if pstep > 0: commonsThumb(thumb, pstep) else: ""
    it.author = stripHtml(m("Artist"))
    if it.author.len == 0: it.author = stripHtml(m("Credit"))
    it.license = license
    it.licenseUrl = m("LicenseUrl")
    if it.licenseUrl.startsWith("//"): it.licenseUrl = "https:" & it.licenseUrl
    if license == "CC0" and it.licenseUrl.len == 0: it.licenseUrl = cc0Url
    let who = if it.author.len > 0: it.author else: "Unknown author"
    it.attribution = who & ", " & license &
      (if it.licenseUrl.len > 0 and license.startsWith("CC BY"): " <" & it.licenseUrl & ">" else: "") &
      ", via Wikimedia Commons"
    let restrictions = m("Restrictions")
    if restrictions.len > 0:
      for r in restrictions.split('|'): it.tags.addTag "restriction: " & r
    if it.fullUrl.len > 0: result.items.add it

# ---- Pixabay ----------------------------------------------------------------------

proc parsePixabay(q: AssetQuery; j: JsonNode): AssetPage =
  if j.kind != JObject or not j.hasKey("hits"):
    result.error = "Pixabay gave no results list"
    return
  let hits = j.int0("totalHits")              # (those a search may page through)
  result.total = hits
  result.hasMore = pageNo(q) * perPageOf(q) < hits
  for h in j["hits"]:
    var it = AssetItem(source: asPixabay, kind: q.kind, id: h.str("id"), category: q.category)
    let tags = h.str("tags")
    for t in tags.split(','): it.tags.addTag t
    it.title = if it.tags.len > 0: it.tags[0].capitalizeAscii else: "Pixabay " & it.id
    it.thumbUrl = h.str("previewURL")
    it.previewUrl = h.str("webformatURL")
    it.fullUrl = h.str("largeImageURL")
    if it.fullUrl.len == 0: it.fullUrl = it.previewUrl
    if q.kind == akVector:
      let v = h.str("vectorURL")              # (with full API access only)
      if v.toLowerAscii.endsWith(".svg"): it.fullUrl = v
    it.ext = extOfUrl(it.fullUrl)
    let w = h.int0("imageWidth")
    let hh = h.int0("imageHeight")
    if it.ext == "svg" or max(w, hh) <= 1280:
      it.width = w
      it.height = hh
    elif w > 0 and hh > 0:                     # (largeImageURL: at most 1280)
      it.width = int(round(w * 1280 / max(w, hh)))
      it.height = int(round(hh * 1280 / max(w, hh)))
    it.author = h.str("user")
    let uid = h.str("user_id")
    if it.author.len > 0 and uid.len > 0:
      it.authorUrl = "https://pixabay.com/users/" & it.author & "-" & uid & "/"
    it.pageUrl = h.str("pageURL")
    it.license = "Pixabay Content License"
    it.licenseUrl = "https://pixabay.com/service/license-summary/"
    it.attribution = "Image by " & (if it.author.len > 0: it.author else: "a Pixabay user") & " from Pixabay"
    if it.fullUrl.len > 0: result.items.add it

# ---- Pexels, Unsplash ------------------------------------------------------------

proc fitSide(w, h, bw, bh: int): (int, int) =
  ## `w` x `h` fitted into `bw` x `bh` (never enlarged).
  if w <= 0 or h <= 0: return (0, 0)
  let k = min(1.0, min(bw / w, bh / h))
  (max(1, int(round(w.float * k))), max(1, int(round(h.float * k))))

proc parsePexels(q: AssetQuery; j: JsonNode): AssetPage =
  if j.kind != JObject or not j.hasKey("photos"):
    result.error = (if j.kind == JObject and j.hasKey("error"): j.str("error") else: "Pexels gave no photos")
    return
  result.total = j.int0("total_results")
  result.hasMore = j.str("next_page").len > 0
  for ph in j["photos"]:
    var it = AssetItem(source: asPexels, kind: q.kind, id: ph.str("id"), category: q.category)
    let src = ph.getOrDefault("src")
    it.title = ph.str("alt")
    if it.title.len == 0: it.title = "Pexels " & it.id
    it.thumbUrl = src.str("medium")
    it.previewUrl = src.str("large")
    it.fullUrl = src.str("large2x")         # (at most 1880 x 1300: "original" can be 50 MB)
    if it.fullUrl.len == 0: it.fullUrl = src.str("original")
    it.ext = "jpg"
    (it.width, it.height) = fitSide(ph.int0("width"), ph.int0("height"), 1880, 1300)
    it.author = ph.str("photographer")
    it.authorUrl = ph.str("photographer_url")
    it.pageUrl = ph.str("url")
    it.license = "Pexels License"
    it.licenseUrl = "https://www.pexels.com/license/"
    it.attribution = "Photo by " & (if it.author.len > 0: it.author else: "a Pexels photographer") & " on Pexels"
    for w in it.title.split({' ', ','}):
      if w.len > 3: it.tags.addTag w.toLowerAscii
    if it.fullUrl.len > 0: result.items.add it

proc parseUnsplash(q: AssetQuery; j: JsonNode): AssetPage =
  var list: JsonNode
  if j.kind == JArray:                      # (the popular photos: a bare list)
    list = j
    result.total = -1
    result.hasMore = j.len >= perPageOf(q)
  elif j.kind == JObject and j.hasKey("results"):
    list = j["results"]
    result.total = j.int0("total")
    result.hasMore = pageNo(q) < j.int0("total_pages")
  else:
    var why = "Unsplash gave no photos"
    if j.kind == JObject and j.hasKey("errors") and j["errors"].kind == JArray and j["errors"].len > 0:
      why = j["errors"][0].getStr(why)
    result.error = why
    return
  for ph in list:
    var it = AssetItem(source: asUnsplash, kind: q.kind, id: ph.str("id"), category: q.category)
    let urls = ph.getOrDefault("urls")
    let links = ph.getOrDefault("links")
    let user = ph.getOrDefault("user")
    it.title = ph.str("description")
    if it.title.len == 0: it.title = ph.str("alt_description")
    if it.title.len == 0: it.title = "Unsplash " & it.id
    if it.title.len > 80: it.title = it.title[0 ..< 80] & "..."
    it.title = it.title.capitalizeAscii
    it.thumbUrl = urls.str("small")
    it.previewUrl = urls.str("regular")
    let raw = urls.str("raw")
    it.fullUrl = if raw.len > 0: raw & (if '?' in raw: "&" else: "?") & "w=2400&fm=jpg&q=85&fit=max"
                 else: urls.str("full")
    it.ext = "jpg"
    (it.width, it.height) = fitSide(ph.int0("width"), ph.int0("height"), 2400, 2400)
    it.author = user.str("name")
    let ul = if user != nil: user.getOrDefault("links") else: nil
    if ul.str("html").len > 0: it.authorUrl = ul.str("html") & unsplashRef
    if links.str("html").len > 0: it.pageUrl = links.str("html") & unsplashRef
    let dl = links.str("download_location")
    if dl.len > 0 and unsplashKey.len > 0:
      it.pingUrl = withHeaders(dl, [("Authorization", "Client-ID " & unsplashKey), ("Accept-Version", "v1")])
    it.license = "Unsplash License"
    it.licenseUrl = "https://unsplash.com/license"
    it.attribution = "Photo by " & (if it.author.len > 0: it.author else: "an Unsplash photographer") &
                     " on Unsplash"
    let tags = ph.getOrDefault("tags")
    if tags != nil and tags.kind == JArray:
      for t in tags: it.tags.addTag t.str("title")
    if it.fullUrl.len > 0: result.items.add it

# ---- Iconify --------------------------------------------------------------------

const okIconLicenses = ["MIT", "Apache-2.0", "ISC", "CC0-1.0", "CC-BY-4.0", "CC-BY-3.0", "OFL-1.1",
                        "Unlicense", "BSD-3-Clause", "BSD-2-Clause"]

proc iconSvgUrl*(prefix, name: string; color = ""; height = 0): string =
  ## An icon's SVG from Iconify's API; `color` ("#ffffff") replaces the
  ## `currentColor` of one-color icons, `height` sets its size in pixels.
  result = iconifyApi & "/" & prefix & "/" & name & ".svg"
  var sep = '?'
  if color.len > 0:
    result.add sep & "color=" & enc(color)
    sep = '&'
  if height > 0: result.add sep & "height=" & $height

proc setFromInfo(prefix: string; info: JsonNode): IconSet =
  ## A set's facts: from the curated list, else from Iconify's answer.
  let i = iconSetOf(prefix)
  if i >= 0: return iconSets[i]
  result.prefix = prefix
  if info != nil and info.kind == JObject:
    result.name = info.str("name")
    let lic = info.getOrDefault("license")
    result.license = lic.str("title")
    result.spdx = lic.str("spdx")
    result.licenseUrl = lic.str("url")
    let a = info.getOrDefault("author")
    result.author = a.str("name")
    result.authorUrl = a.str("url")
    result.height = info.int0("height")
    result.group = info.str("category")

proc iconItem(st: IconSet; name: string; q: AssetQuery): AssetItem =
  result = AssetItem(source: asIconify, kind: akIcon, id: st.prefix & ":" & name,
                     title: name.replace('-', ' '), category: st.prefix, ext: "svg")
  result.thumbUrl = iconSvgUrl(st.prefix, name)
  result.fullUrl = result.thumbUrl
  result.width = st.height
  result.height = st.height
  result.author = st.author
  result.authorUrl = st.authorUrl
  result.pageUrl = "https://icon-sets.iconify.design/" & st.prefix & "/" & name & "/"
  result.license = st.license
  result.licenseUrl = st.licenseUrl
  result.attribution = "\"" & name & "\" icon from " & st.name &
                       (if st.author.len > 0: " by " & st.author else: "") & ", " & st.license
  result.tags.addTag st.name
  result.tags.addTag st.group

proc usableSet(st: IconSet): bool = st.spdx in okIconLicenses

proc parseIconify(q: AssetQuery; j: JsonNode): AssetPage =
  if j.kind != JObject:
    result.error = "Iconify gave no list"
    return
  if q.text.strip.len > 0:
    # /search: "prefix:name" from `start` on
    let icons = j.getOrDefault("icons")
    if icons == nil or icons.kind != JArray:
      result.error = "Iconify gave no list"
      return
    let colls = j.getOrDefault("collections")
    let n = perPageOf(q)
    let total = j.int0("total")
    let limit = j.int0("limit")
    result.total = if total < limit: total else: -1
    result.hasMore = icons.len > n or (total >= limit and limit > 0 and limit < 999)
    for ic in icons:
      if result.items.len >= n: break
      let full = ic.getStr
      let c = full.find(':')
      if c <= 0: continue
      let prefix = full[0 ..< c]
      let st = setFromInfo(prefix, if colls != nil: colls.getOrDefault(prefix) else: nil)
      if not usableSet(st): continue
      result.items.add iconItem(st, full[c + 1 .. ^1], q)
  elif j.hasKey("prefix") and (j.hasKey("categories") or j.hasKey("uncategorized")):
    # /collection: one set's icons, by its categories
    let prefix = j.str("prefix")
    let st = setFromInfo(prefix, j.getOrDefault("info"))
    if not usableSet(st):
      result.error = "the icons of \"" & prefix & "\" are not offered (license " & st.license & ")"
      return
    var hidden: HashSet[string]
    let hid = j.getOrDefault("hidden")
    if hid != nil and hid.kind == JArray:
      for h in hid: hidden.incl h.getStr
    var seen: HashSet[string]
    var all: seq[AssetItem]
    proc add(name: string) =
      if name.len > 0 and name notin hidden and not seen.containsOrIncl(name):
        all.add iconItem(st, name, q)
    let cats = j.getOrDefault("categories")
    if cats != nil and cats.kind == JObject:
      for _, names in cats:
        for nm in names: add nm.getStr
    let unc = j.getOrDefault("uncategorized")
    if unc != nil and unc.kind == JArray:
      for nm in unc: add nm.getStr
    result = slicePage(all, q)
  else:
    # /collections: a few icons of each set
    var all: seq[AssetItem]
    for prefix, info in j:
      let st = setFromInfo(prefix, info)
      if not usableSet(st): continue
      var samples: seq[string]
      let sm = info.getOrDefault("samples")
      if sm != nil and sm.kind == JArray:
        for s in sm: samples.add s.getStr
      if samples.len == 0: samples = st.samples
      for s in samples:
        if s.len > 0: all.add iconItem(st, s, q)
    result = slicePage(all, q)

# ---- Poly Haven --------------------------------------------------------------------

proc parsePolyHaven(q: AssetQuery; j: JsonNode): AssetPage =
  if j.kind != JObject:
    result.error = "Poly Haven gave no list"
    return
  let ws = words(q.text)
  var found: seq[(int, AssetItem)]
  for id, a in j:
    if a.kind != JObject: continue
    let hdri = a.int0("type") == 0
    if hdri != (q.kind == akBackground): continue
    var it = AssetItem(source: asPolyHaven, kind: q.kind, id: id, title: a.str("name"),
                       category: q.category)
    if it.title.len == 0: it.title = id.replace('_', ' ')
    var hay = it.title & " " & id & " " & a.str("category") & " " & a.str("description")
    for key in ["tags", "categories"]:
      let t = a.getOrDefault(key)
      if t != nil and t.kind == JArray:
        for x in t:
          it.tags.addTag x.getStr
          hay.add " " & x.getStr
    for part in a.str("category").split('/'): it.tags.addTag part
    if ws.len > 0 and not matchesAll(ws, hay): continue
    let v = a.str("img_version")
    it.thumbUrl = a.str("thumbnail_url")
    if it.thumbUrl.len == 0:
      it.thumbUrl = polyHavenCdn & "/asset_img/thumbs/" & id & ".png?width=256&height=256&format=webp" &
                    (if v.len > 0: "&v=" & v else: "")
    if hdri:
      # (the panorama, flat, as polyhaven.com shows it)
      it.previewUrl = polyHavenCdn & "/asset_img/primary/" & id & ".png?width=1280&format=webp" &
                      (if v.len > 0: "&v=" & v else: "")
    let mr = a.getOrDefault("max_resolution")
    if mr != nil and mr.kind == JArray and mr.len >= 2:
      it.width = mr[0].getInt
      it.height = mr[1].getInt
    var names: seq[string]
    let au = a.getOrDefault("authors")
    if au != nil and au.kind == JObject:
      for name, _ in au: names.add name
    it.author = names.join(", ")
    it.pageUrl = "https://polyhaven.com/a/" & id
    it.license = "CC0"
    it.licenseUrl = cc0Url
    found.add (a.int0("download_count"), it)
  # the most downloaded first
  found.sort(proc (x, y: (int, AssetItem)): int = cmp(y[0], x[0]))
  var all: seq[AssetItem]
  for f in found: all.add f[1]
  result = slicePage(all, q)

# ---- ambientCG ----------------------------------------------------------------------

proc pickZip(downloads: JsonNode; side: int): JsonNode =
  ## The zip of JPG maps closest to `side` pixels (not above it when a
  ## smaller one is there).
  var best: JsonNode = nil
  var bestRes = 0
  for d in downloads:
    let attr = d.str("attribute").toUpperAscii       # "2K-JPG"
    if not attr.endsWith("-JPG"): continue
    let k = attr.find('K')
    let res = try: parseInt(attr[0 ..< k]) * 1024 except ValueError: 0
    if res <= 0: continue
    let better = if best == nil: true
                 elif res <= side: bestRes > side or res > bestRes
                 else: bestRes > side and res < bestRes
    if better:
      best = d
      bestRes = res
  best

proc parseAmbient(q: AssetQuery; j: JsonNode): AssetPage =
  if j.kind != JObject or not j.hasKey("foundAssets"):
    result.error = "ambientCG gave no results list"
    return
  result.total = j.int0("numberOfResults")
  let n = perPageOf(q)
  result.hasMore = j.str("nextPageHttp").len > 0 or pageNo(q) * n < result.total
  for a in j["foundAssets"]:
    let id = a.str("assetId")
    var it = AssetItem(source: asAmbientCG, kind: q.kind, id: id, category: q.category)
    it.title = a.str("displayName")
    if it.title.len == 0: it.title = id
    let prev = a.getOrDefault("previewImage")
    proc pv(keys: openArray[string]): string =
      if prev == nil or prev.kind != JObject: return ""
      for k in keys:
        let u = prev.str(k)
        if u.len > 0: return u
    it.thumbUrl = pv(["256-JPG-FFFFFF", "256-PNG", "512-JPG-FFFFFF", "512-PNG", "128-PNG"])
    it.previewUrl = pv(["1024-JPG-FFFFFF", "1024-PNG", "512-JPG-FFFFFF", "512-PNG"])
    if it.thumbUrl.len == 0 and prev != nil and prev.kind == JObject:
      for _, u in prev:
        it.thumbUrl = u.getStr
        break
    let folders = a.getOrDefault("downloadFolders")
    var downloads = newJArray()
    if folders != nil and folders.kind == JObject:
      for _, f in folders:
        let z = f{"downloadFiletypeCategories", "zip", "downloads"}
        if z != nil and z.kind == JArray:
          for d in z: downloads.add d
    let d = pickZip(downloads, 2048)
    if d != nil:
      it.fullUrl = d.str("downloadLink")
      if it.fullUrl.len == 0: it.fullUrl = d.str("fullDownloadPath")
      if it.fullUrl.len == 0: it.fullUrl = d.str("rawLink")
      it.ext = "zip"
      let attr = d.str("attribute").toUpperAscii
      let side = try: parseInt(attr[0 ..< attr.find('K')]) * 1024 except ValueError: 0
      let dx = a.int0("dimensionX")
      let dy = a.int0("dimensionY")
      it.width = side
      it.height = if dx > 0 and dy > 0: side * dy div dx else: side
    let tags = a.getOrDefault("tags")
    if tags != nil and tags.kind == JArray:
      for t in tags: it.tags.addTag t.getStr
    it.tags.addTag a.str("displayCategory")
    it.author = "ambientCG"
    it.authorUrl = "https://ambientcg.com"
    it.pageUrl = a.str("shortLink")
    if it.pageUrl.len == 0: it.pageUrl = "https://ambientcg.com/view?id=" & id
    it.license = "CC0"
    it.licenseUrl = cc0Url
    if it.thumbUrl.len > 0: result.items.add it

proc textureFromZip*(zipData: string): tuple[name: string; data: string] =
  ## The color (albedo, diffuse) map in a zip of texture maps -- what
  ## ambientCG gives -- as its file name and bytes; ("", "") when there is
  ## none or the zip cannot be read.
  type E = tuple[name: string; meth, crc, packed, size, offset: int]
  proc rd16(s: string; i: int): int = ord(s[i]) or (ord(s[i+1]) shl 8)
  proc rd32(s: string; i: int): int =
    ord(s[i]) or (ord(s[i+1]) shl 8) or (ord(s[i+2]) shl 16) or (ord(s[i+3]) shl 24)
  var entries: seq[E]
  try:
    let z = zipData
    var e = -1
    var i = z.len - 22
    while i >= 0 and i >= z.len - 22 - 65535:
      if z.rd32(i) == 0x06054b50:
        e = i
        break
      dec i
    if e < 0: return
    let n = z.rd16(e + 10)
    var p = z.rd32(e + 16)
    for _ in 0 ..< n:
      if p < 0 or p + 46 > z.len or z.rd32(p) != 0x02014b50: return
      let nameLen = z.rd16(p + 28)
      if p + 46 + nameLen > z.len: return
      entries.add (z[p + 46 ..< p + 46 + nameLen], z.rd16(p + 10), z.rd32(p + 16),
                   z.rd32(p + 20), z.rd32(p + 24), z.rd32(p + 42))
      p += 46 + nameLen + z.rd16(p + 30) + z.rd16(p + 32)
    # the color map: by its name, else the largest picture that is no other map
    const other = ["normal", "rough", "disp", "height", "ambientocclusion", "_ao", "metal", "opacity",
                   "mask", "spec", "gloss", "emission", "bump", "_arm", "alpha", "idmap"]
    const color = ["_color", "basecolor", "albedo", "diffuse", "_diff", "_col_", "_col."]
    var best = -1
    var bestScore = 0
    for k, en in entries:
      let l = en.name.toLowerAscii
      let ext = l.splitFile.ext
      if ext notin [".jpg", ".jpeg", ".png", ".webp", ".tif", ".tiff"] or l.endsWith("/"): continue
      let base = l.extractFilename
      var score = 0
      for c in color:
        if c in base: score = 1_000_000_000
      if score == 0:
        var isOther = false
        for o in other:
          if o in base: isOther = true
        if isOther: continue
        score = 1 + en.size div 16                  # (a preview render is small)
      if score > bestScore:
        best = k
        bestScore = score
    if best < 0: return
    let en = entries[best]
    let o = en.offset
    if o < 0 or o + 30 > z.len or z.rd32(o) != 0x04034b50: return
    let start = o + 30 + z.rd16(o + 26) + z.rd16(o + 28)
    if en.packed < 0 or start + en.packed > z.len: return
    var data: string
    case en.meth
    of 0: data = z[start ..< start + en.packed]
    of 8:
      let b = inflate(z.toOpenArrayByte(start, start + en.packed - 1), maxOut = en.size)
      data = newString(b.len)
      if b.len > 0: copyMem(addr data[0], unsafeAddr b[0], b.len)
    else: return
    if data.len != en.size: return
    if en.size > 0 and crc32(data.toOpenArrayByte(0, data.high)) != uint32(en.crc): return
    result = (en.name.extractFilename, data)
  except CatchableError, Defect:
    result = ("", "")

proc textureFromZipFile*(path: string): tuple[name: string; data: string] =
  ## `textureFromZip` of a zip file (only the color map is read from it).
  try:
    var best: ZipEntry
    var found = false
    var bestScore = 0
    for e in zipEntries(path):
      let l = e.name.toLowerAscii
      if e.isDir or l.splitFile.ext notin [".jpg", ".jpeg", ".png", ".webp", ".tif", ".tiff"]: continue
      let base = l.extractFilename
      var score = 0
      for c in ["_color", "basecolor", "albedo", "diffuse", "_diff", "_col_", "_col."]:
        if c in base: score = 1_000_000_000
      if score == 0:
        var isOther = false
        for o in ["normal", "rough", "disp", "height", "ambientocclusion", "_ao", "metal", "opacity",
                  "mask", "spec", "gloss", "emission", "bump", "_arm", "alpha", "idmap"]:
          if o in base: isOther = true
        if isOther: continue
        score = 1 + e.size div 16
      if score > bestScore:
        best = e
        bestScore = score
        found = true
    if found: result = (best.name.extractFilename, readEntry(path, best))
  except CatchableError, Defect:
    result = ("", "")

# ---- the Retro Photo Library ------------------------------------------------------

proc kindOfName(s: string): (bool, AssetKind) =
  case s.toLowerAscii
  of "brush", "brushes": (true, akBrush)
  of "pattern", "patterns": (true, akPattern)
  of "gradient", "gradients": (true, akGradient)
  of "swatches", "swatch", "palette": (true, akSwatches)
  of "style", "styles": (true, akStyle)
  of "design", "designs", "template": (true, akDesign)
  of "texture", "textures": (true, akTexture)
  of "photo", "photos": (true, akPhoto)
  of "vector", "vectors", "svg": (true, akVector)
  of "illustration", "illustrations": (true, akIllustration)
  of "icon", "icons": (true, akIcon)
  of "background", "backgrounds": (true, akBackground)
  else: (false, akPhoto)

proc resolveRef(folder, rel: string): string =
  ## `rel` against the catalog's folder (absolute addresses and paths stay).
  let r = rel.strip
  if r.len == 0: return ""
  let l = r.toLowerAscii
  if l.startsWith("http://") or l.startsWith("https://") or l.startsWith("file:") or
     l.startsWith("data:") or r.startsWith("/") or (r.len > 2 and r[1] == ':'):
    return r
  var f = folder
  var x = r
  while true:
    if x.startsWith("./"): x = x[2 .. ^1]
    elif x.startsWith("../"):
      x = x[3 .. ^1]
      let cut = f.strip(leading = false, chars = {'/'}).rfind('/')
      if cut > 0 and not f[0 .. cut].endsWith("//"): f = f[0 .. cut]
    else: break
  f & x

proc parseLibrary*(body: string; baseUrl: string): seq[AssetItem] =
  ## The items of a Retro Photo Library catalog:
  ## `{"version":1,"items":[{"id","title","kind","thumb","file","ext",
  ## "author","license","tags":[...],"category"}]}` (also, when given:
  ## "preview", "width", "height", "authorUrl", "pageUrl", "licenseUrl",
  ## "attribution"). `kind` is brush, pattern, gradient, swatches, style,
  ## design, texture, photo or vector; addresses are relative to the folder
  ## of `baseUrl` (the catalog's address or path). Items without an id or a
  ## known kind are left out; a damaged catalog gives none.
  let folder = if baseUrl.len == 0 or baseUrl.endsWith("/"): baseUrl
               elif baseUrl.rfind('/') >= 0: baseUrl[0 .. baseUrl.rfind('/')]
               else: ""
  try:
    let j = parseJson(body)
    let items = if j.kind == JObject: j.getOrDefault("items") elif j.kind == JArray: j else: nil
    if items == nil or items.kind != JArray: return
    for e in items:
      let (known, k) = kindOfName(e.str("kind"))
      let id = e.str("id")
      if not known or id.len == 0: continue
      var it = AssetItem(source: asLibrary, kind: k, id: id, title: e.str("title"),
                         category: e.str("category"))
      if it.title.len == 0: it.title = id
      it.thumbUrl = resolveRef(folder, e.str("thumb"))
      it.previewUrl = resolveRef(folder, e.str("preview"))
      it.fullUrl = resolveRef(folder, e.str("file"))
      it.ext = e.str("ext").toLowerAscii.strip(chars = {'.'})
      if it.ext.len == 0: it.ext = extOfUrl(it.fullUrl)
      it.width = e.int0("width")
      it.height = e.int0("height")
      it.author = e.str("author")
      it.authorUrl = e.str("authorUrl")
      it.pageUrl = e.str("pageUrl")
      it.license = e.str("license")
      it.licenseUrl = e.str("licenseUrl")
      it.attribution = e.str("attribution")
      if it.attribution.len == 0 and it.license.toUpperAscii.startsWith("CC BY"):
        it.attribution = "\"" & it.title & "\"" & (if it.author.len > 0: " by " & it.author else: "") &
                         ", " & it.license
      let tags = e.getOrDefault("tags")
      if tags != nil and tags.kind == JArray:
        for t in tags: it.tags.addTag t.getStr
      result.add it
  except CatchableError:
    result.setLen(0)

proc setLibrary*(items: seq[AssetItem]) =
  ## The library's catalog to browse (`parseLibrary` of the online one, or
  ## of the copy the app carries).
  libraryItems = items

proc filterLibrary(items: seq[AssetItem]; q: AssetQuery): AssetPage =
  let ws = words(q.text)
  var all: seq[AssetItem]
  for it in items:
    if it.kind != q.kind: continue
    if q.category.len > 0 and cmpIgnoreCase(it.category, q.category) != 0: continue
    if ws.len > 0 and not matchesAll(ws, it.title & " " & it.tags.join(" ") & " " & it.category &
                                         " " & it.author): continue
    all.add it
  slicePage(all, q)

proc libraryPage*(q: AssetQuery): AssetPage =
  ## A page of the library (`setLibrary`) for `q`: its kind, category and
  ## words (all found in an item's title, tags, category or author).
  filterLibrary(libraryItems, q)

# ---- answers ------------------------------------------------------------------------

proc parsePage*(q: AssetQuery; body: string): AssetPage =
  ## The answer to `queryUrl(q)` read (for the library: a catalog, filtered
  ## as `libraryPage`). Never raises: `error` says what went wrong.
  try:
    let t = body.strip
    if t.len == 0 or t[0] notin {'{', '['} or (t[0] == '[' and t.len > 1 and t[1] in {'A'..'Z'}):
      # (an error in words: Pixabay's "[ERROR 400] ...", a proxy's page)
      return AssetPage(error: firstLine(body), total: -1)
    if q.source == asLibrary:
      return filterLibrary(parseLibrary(body, libraryCatalogUrl), q)
    let j = parseJson(t)
    case q.source
    of asOpenverse: result = parseOpenverse(q, j)
    of asWikimedia: result = parseCommons(q, j)
    of asPixabay: result = parsePixabay(q, j)
    of asPexels: result = parsePexels(q, j)
    of asUnsplash: result = parseUnsplash(q, j)
    of asIconify: result = parseIconify(q, j)
    of asPolyHaven: result = parsePolyHaven(q, j)
    of asAmbientCG: result = parseAmbient(q, j)
    of asLibrary: discard
  except CatchableError as e:
    result = AssetPage(error: "the answer cannot be read (" & e.msg & ")", total: -1)
  except Defect as e:
    result = AssetPage(error: "the answer cannot be read (" & e.msg & ")", total: -1)

proc resolveUrl*(it: AssetItem): string =
  ## The request that gives an item's file (Poly Haven: its file list);
  ## "" when none is needed.
  if it.source == asPolyHaven and it.id.len > 0: polyHavenApi & "/files/" & enc(it.id)
  else: ""

proc needsResolve*(it: AssetItem): bool =
  ## A second request (`resolveUrl`, then `applyResolve`) is needed before
  ## the item's file can be downloaded.
  it.fullUrl.len == 0 and resolveUrl(it).len > 0

proc applyResolve*(it: var AssetItem; body: string; maxSide = 4096) =
  ## Sets `fullUrl`, `ext` and the size from the answer to `resolveUrl`.
  ## A Poly Haven texture: its diffuse (color) map as JPG, the largest no
  ## bigger than `maxSide` (2K, 4K...); an HDRI: its tonemapped panorama
  ## as a Background (the 8K JPG when `maxSide` allows, else the same
  ## picture at `maxSide` wide from Poly Haven's image server). `fullUrl`
  ## stays "" when the answer has no such file.
  if it.source != asPolyHaven: return
  let j = try: parseJson(body) except CatchableError: return
  if j.kind != JObject: return
  if j.hasKey("hdri") or j.hasKey("tonemapped") or it.kind == akBackground:
    let tm = j.getOrDefault("tonemapped").str("url")
    let full = if it.width > 0: min(it.width, 8192) else: 8192
    if maxSide >= 8192 and tm.len > 0:
      it.fullUrl = tm
      it.ext = "jpg"
      it.width = full
      it.height = full div 2
    else:
      let w = clamp(maxSide, 256, 8192)
      it.fullUrl = polyHavenCdn & "/asset_img/primary/" & it.id & ".png?width=" & $w & "&format=webp"
      it.ext = "webp"
      it.width = w
      it.height = w div 2
    return
  var maps: JsonNode = nil
  for key in ["Diffuse", "diff", "Color", "color", "albedo", "Albedo", "col"]:
    let m = j.getOrDefault(key)
    if m != nil and m.kind == JObject:
      maps = m
      break
  if maps == nil: return
  var bestUrl, smallUrl, previewUrl = ""
  var bestRes, smallRes = 0
  for res, fmts in maps:
    let r = try: parseInt(res.strip(chars = {'k', 'K'})) * 1024 except ValueError: 0
    if r <= 0 or fmts.kind != JObject: continue
    var u = fmts.getOrDefault("jpg").str("url")
    if u.len == 0: u = fmts.getOrDefault("png").str("url")
    if u.len == 0: continue
    if r == 1024 and fmts.getOrDefault("jpg").str("url").len > 0: previewUrl = u
    if r <= maxSide and r > bestRes:
      bestRes = r
      bestUrl = u
    if smallRes == 0 or r < smallRes:
      smallRes = r
      smallUrl = u
  if bestUrl.len == 0:
    bestUrl = smallUrl
    bestRes = smallRes
  if bestUrl.len == 0: return
  let (w0, h0) = (it.width, it.height)
  it.fullUrl = bestUrl
  it.ext = extOfUrl(bestUrl)
  it.width = bestRes
  it.height = if w0 > 0 and h0 > 0: bestRes * h0 div w0 else: bestRes
  if previewUrl.len > 0: it.previewUrl = previewUrl

proc licenseNote*(it: AssetItem): string =
  ## One line for File Info or a status bar: title, author, license, source
  ## ("Powered by Poly Haven" for Poly Haven's).
  result = "\"" & it.title & "\""
  if it.source == asIconify:
    let i = iconSetOf(it.category)
    if i >= 0: result.add " from " & iconSets[i].name
  if it.author.len > 0 and not (it.source == asAmbientCG and it.author == "ambientCG"):
    result.add " by " & it.author
  if it.license.len > 0: result.add " · " & it.license
  result.add " · " & (case it.source
    of asPolyHaven: "Poly Haven (Powered by Poly Haven)"
    of asAmbientCG: "ambientCG.com"
    else: $it.source)
