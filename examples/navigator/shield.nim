## Retro Navigator's shield: the script it puts in every page before the
## page's own (`webStartScript`) -- ads and trackers blocked, sites asked
## not to track, links made secure, videos kept from playing by themselves,
## links loaded ahead when the pointer rests on them, links opened in a new
## tab -- and the hosts it blocks.
##
## The engine itself never fetches what comes from those hosts (and the
## addresses of `AdPatterns`, and a list the user imports: `parseBlockList`):
## Retro Navigator gives them to `webBlockList`. The page's script does the
## rest: requests its scripts make to an ad or tracker host (fetch,
## XMLHttpRequest, beacons) fail, scripts, frames and pictures from one are
## taken out as they are put in, the usual ad boxes are hidden, and
## YouTube's ads in its player are skipped.
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[json, strutils, sets]

type
  Shield* = enum
    ## What the script does (`startScript`), each a setting.
    shBlockAds = "blockAds"       ## ads and trackers blocked
    shNoTrack = "noTrack"         ## sites asked not to track (Global Privacy Control)
    shHttps = "httpsOnly"         ## links to "http://" go to "https://" (not on this
                                  ## computer or the local network)
    shNoAutoplay = "noAutoplay"   ## videos and sounds do not start by themselves
    shPreload = "preload"         ## a link is loaded ahead when the pointer rests on it

const
  AdHosts* = [
    # ad networks and ad exchanges
    "doubleclick.net", "googlesyndication.com", "googleadservices.com", "adservice.google.com",
    "googletagservices.com", "imasdk.googleapis.com", "adnxs.com", "appnexus.com", "adsrvr.org",
    "amazon-adsystem.com", "criteo.com", "criteo.net", "taboola.com", "taboolasyndication.com",
    "outbrain.com", "outbrainimg.com", "pubmatic.com", "rubiconproject.com", "openx.net",
    "casalemedia.com", "indexww.com", "smartadserver.com", "adform.net", "media.net",
    "3lift.com", "sharethrough.com", "teads.tv", "yieldmo.com", "bidswitch.net",
    "contextweb.com", "advertising.com", "adroll.com", "revcontent.com", "mgid.com",
    "zedo.com", "propellerads.com", "popads.net", "popcash.net", "adcolony.com", "applovin.com",
    "unityads.unity3d.com", "moatads.com", "serving-sys.com", "spotxchange.com", "spotx.tv",
    "springserve.com", "lijit.com", "sovrn.com", "gumgum.com", "33across.com",
    "adsafeprotected.com", "doubleverify.com", "ads.yahoo.com", "ads.linkedin.com",
    "ads-twitter.com", "ads.reddit.com", "ads.tiktok.com", "adsystem.com", "yieldlab.net",
    "adition.com", "adtechus.com", "adblade.com", "adkernel.com", "admixer.net", "adocean.pl",
    "adotmob.com", "adpushup.com", "adthrive.com", "adzerk.net", "aniview.com", "bidr.io",
    "betweendigital.com", "buysellads.com", "carbonads.net", "clickadu.com",
    "conversantmedia.com", "cpmstar.com", "districtm.io", "dotomi.com", "e-planning.net",
    "emxdgt.com", "exoclick.com", "ezoic.net", "ezojs.com", "flashtalking.com", "fwmrm.net",
    "inmobi.com", "innovid.com", "juicyads.com", "kargo.com", "lkqd.net", "mathtag.com",
    "mediavine.com", "mopub.com", "nativo.com", "onetag-sys.com", "primis.tech",
    "pubnative.net", "quantcast.com", "rhythmone.com", "richaudience.com", "rtbhouse.com",
    "seedtag.com", "smaato.net", "smartclip.net", "sonobi.com", "stickyadstv.com",
    "tremorhub.com", "tribalfusion.com", "trafficjunky.net", "undertone.com",
    "unrulymedia.com", "vidazoo.com", "viglink.com", "zemanta.com", "adskeeper.co.uk",
    "adsterra.com", "hilltopads.net", "a-ads.com", "adcash.com", "mfadsrvr.com",
    "mediaplex.com", "adhigh.net", "adlightning.com", "confiant-integrations.net",
    "adlooxtracking.com", "zergnet.com", "dianomi.com", "ligatus.com", "plista.com",
    "content.ad", "yieldlove.com", "adsnative.com", "adspirit.de", "avocet.io", "brealtime.com",
    "gemius.pl", "smilewanted.com", "sascdn.com", "teads.com", "connatix.com", "playwire.com",
    "freewheel.tv", "adition.net", "improvedigital.com", "360yield.com", "adscale.de",
    "yandexadexchange.net", "an.yandex.ru", "ad.mail.ru", "adriver.ru", "begun.ru",
    "pagead2.googlesyndication.com", "tpc.googlesyndication.com", "securepubads.g.doubleclick.net",
    # trackers and analytics
    "google-analytics.com", "googletagmanager.com", "analytics.google.com", "googleoptimize.com",
    "scorecardresearch.com", "quantserve.com", "quantcount.com", "hotjar.com", "hotjar.io",
    "mixpanel.com", "mxpnl.com", "fullstory.com", "mouseflow.com", "crazyegg.com", "clarity.ms",
    "chartbeat.com", "chartbeat.net", "nr-data.net", "js-agent.newrelic.com", "bat.bing.com",
    "connect.facebook.net", "analytics.twitter.com", "analytics.tiktok.com", "api2.branch.io",
    "app-measurement.com", "segment.io", "cdn.segment.com", "kissmetrics.com", "parsely.com",
    "optimizely.com", "omtrdc.net", "2o7.net", "demdex.net", "everesttech.net", "krxd.net",
    "bluekai.com", "exelator.com", "rlcdn.com", "agkn.com", "tapad.com", "adsymptotic.com",
    "imrworldwide.com", "mc.yandex.ru", "api.amplitude.com", "api2.amplitude.com",
    "heapanalytics.com", "statcounter.com", "histats.com", "addthis.com", "sharethis.com",
    "smartlook.com", "inspectlet.com", "luckyorange.com", "luckyorange.net",
    "contentsquare.net", "clicktale.net", "sessioncam.com", "top-fwz1.mail.ru",
    "tns-counter.ru", "counter.yadro.ru", "hm.baidu.com", "cnzz.com", "snap.licdn.com",
    "ct.pinterest.com", "analytics.pinterest.com", "tr.snapchat.com", "bounceexchange.com",
    "bouncex.net", "cquotient.com", "hs-analytics.net", "hsadspixel.net",
    "munchkin.marketo.net", "assets.adobedtm.com", "tealiumiq.com", "ensighten.com",
    "permutive.com", "permutive.app", "zeotap.com", "crwdcntrl.net", "id5-sync.com",
    "browser-intake-datadoghq.com", "lr-ingest.io", "wzrkt.com", "onesignal.com",
    "adobe-analytics.com", "sitescout.com", "mookie1.com", "bidtheatre.com", "w55c.net",
    "turn.com", "eyeota.net", "liadm.com", "pippio.com", "addthisedge.com", "outbrain.org",
    "doubleclick.com", "pixel.wp.com", "stats.wp.com", "pixel.facebook.com",
    "an.facebook.com"]
    ## The hosts of ads and trackers blocked (a host under one too:
    ## "securepubads.g.doubleclick.net").

  AdPatterns* = [
    "*://*.youtube.com/api/stats/ads*", "*://*.youtube.com/pagead/*",
    "*://*.youtube.com/ptracking*", "*://*.youtube.com/get_midroll_info*",
    "*://www.google.com/pagead/*", "*://www.google.com/adsense/*",
    "*://*.facebook.com/tr/*", "*://*.facebook.com/tr?*", "*://*.twitter.com/i/adsct*",
    "*://*.x.com/i/adsct*", "*://*/gampad/ads*", "*://*/pubads_impl*", "*://*/prebid*.js*"]
    ## The addresses of ads on sites that serve their pages too (`*` any
    ## run of letters).

  AdBoxes = "ins.adsbygoogle,[id^=\"google_ads\"],[id^=\"div-gpt-ad\"],[id^=\"taboola-\"]," &
    "[class^=\"taboola\"],.OUTBRAIN,.ob-widget,.trc_rbox_container,[data-ad-slot],[data-ad-unit]," &
    "iframe[src*=\"doubleclick\"],iframe[src*=\"googlesyndication\"],.adsbox,.ad-banner," &
    ".ad-container,.advert,#ad-banner,.ad-slot,.ad-wrapper,.ad-unit,.adunit,.ad-placeholder," &
    ".dfp-ad,.gpt-ad,amp-ad,amp-embed,[data-google-query-id],[aria-label=\"Advertisement\"]," &
    "[data-testid=\"ad\"],ytd-ad-slot-renderer,ytd-promoted-sparkles-web-renderer," &
    "ytd-display-ad-renderer,ytd-in-feed-ad-layout-renderer,ytd-banner-promo-renderer," &
    "ytd-companion-slot-renderer,ytd-action-companion-ad-renderer,#player-ads,#masthead-ad," &
    ".ytp-ad-overlay-container,shreddit-ad-post,.promotedlink"
    ## (the usual ad boxes, hidden)

  DefaultShields* = {shBlockAds, shNoTrack, shHttps, shPreload}
    ## What the shield does at first.
  LocalHosts = "/^(localhost|127\\.\\d+\\.\\d+\\.\\d+|10\\.\\d+\\.\\d+\\.\\d+|192\\.168\\.\\d+\\.\\d+|" &
    "172\\.(1[6-9]|2\\d|3[01])\\.\\d+\\.\\d+|\\[::1\\])$|\\.(local|localhost)$/"
    ## (this computer and the local network: `isLocalHost` in JavaScript)

proc isLocalHost*(host: string): bool =
  ## This computer or the local network ("localhost", "printer.local",
  ## "192.168.1.1"): there `shHttps` leaves "http://" as it is.
  let h = host.toLowerAscii
  if h in ["localhost", "[::1]", "::1"] or h.endsWith(".local") or h.endsWith(".localhost"):
    return true
  let p = h.split('.')
  if p.len != 4: return false
  var n: array[4, int]
  for i, x in p:
    if x.len notin 1 .. 3 or not x.allCharsInSet(Digits): return false
    n[i] = parseInt(x)
  n[0] == 127 or n[0] == 10 or (n[0] == 192 and n[1] == 168) or (n[0] == 172 and n[1] in 16 .. 31)

proc isAdHost*(host: string; hosts: openArray[string] = AdHosts): bool =
  ## `host` is one of `hosts` or under one ("www.google-analytics.com").
  let h = host.toLowerAscii
  for d in hosts:
    if h == d or h.endsWith("." & d): return true
  false

proc parseBlockList*(text: string): seq[string] =
  ## The hosts of a block list -- a hosts file's lines ("0.0.0.0
  ## ads.example.com"), an ad blocker's ("||ads.example.com^"), or a host a
  ## line -- each once. Comments ("#", "!"), sections ("[...]"), this
  ## computer's names and the ad blocker's rules of other kinds are passed
  ## over.
  var seen: HashSet[string]
  for raw in text.splitLines:
    var l = raw.strip
    let hash = l.find('#')
    if hash >= 0: l = l[0 ..< hash].strip
    if l.len == 0 or l[0] in {'!', '['}: continue
    var found: seq[string]
    if l.startsWith("||"):
      let e = l.find({'^', '/', '$', '*'}, 2)
      if e >= 0 and l[e] != '^': continue        # (a path or a pattern: not a whole site)
      found.add l[2 ..< (if e < 0: l.len else: e)]
    else:
      let parts = l.splitWhitespace
      if parts.len >= 2 and parts[0] in ["0.0.0.0", "127.0.0.1", "::", "::1", "0"]:
        found.add parts[1 .. ^1]
      elif parts.len == 1: found.add parts[0]
    for x in found:
      let h = x.toLowerAscii.strip(chars = {'.'})
      if h in ["localhost", "localhost.localdomain", "broadcasthost", "local", "ip6-localhost",
               "ip6-loopback", "0.0.0.0"]: continue
      if h.len < 4 or '.' notin h or not h.allCharsInSet({'a'..'z', '0'..'9', '-', '.', '_'}):
        continue
      if not seen.containsOrIncl(h): result.add h

proc startScript*(on: set[Shield]; adsAllowed: openArray[string] = []): string =
  ## The script for every page: what `on` asks for, the blocking left out on
  ## the sites of `adsAllowed` (and those under them). Links into a new tab
  ## are always told to the app, not followed: with Ctrl, Cmd or the middle
  ## button `retro.post("tab:" & address)` (a tab behind), a link to a new
  ## window `retro.post("newtab:" & address)`. The number blocked so far on a
  ## page: `retro.post("blocked:" & n)`.
  var allowed: seq[string]
  for a in adsAllowed:
    if a.strip.len > 0: allowed.add a.strip.toLowerAscii
  result = "(function(){if(window.__retroShield)return;window.__retroShield=1;" &
    "var post=function(m){try{window.retro&&window.retro.post(m)}catch(e){}};" &
    "var here=(location.hostname||'').toLowerCase();" &
    "var under=function(h,l){for(var i=0;i<l.length;i++){var d=l[i];" &
    "if(h===d||h.slice(-d.length-1)==='.'+d)return true}return false};" &
    # links: made secure, and into a new tab (with Ctrl or Cmd, the middle
    # button, or one for a new window)
    "var up=" & (if shHttps in on: "1" else: "0") & ",local=" & LocalHosts & ";" &
    "var click=function(e){var a=e.target&&e.target.closest&&e.target.closest('a[href]');" &
    "if(!a||!/^https?:$/.test(a.protocol))return;" &
    "if(up&&a.protocol==='http:'&&!local.test(a.hostname))a.href='https:'+a.href.slice(5);" &
    "var back=e.ctrlKey||e.metaKey||e.button===1;" &
    "if(!back&&!(e.type==='click'&&a.target==='_blank'))return;" &
    "e.preventDefault();e.stopPropagation();post((back?'tab:':'newtab:')+a.href)};" &
    "document.addEventListener('click',click,true);document.addEventListener('auxclick',click,true);"
  if shNoTrack in on:
    result.add "try{Object.defineProperty(navigator,'globalPrivacyControl',{get:function(){return true}});" &
      "Object.defineProperty(navigator,'doNotTrack',{get:function(){return '1'}})}catch(e){}"
  if shBlockAds in on:
    result.add "var hosts=" & $(%AdHosts) & ",allowed=" & $(%allowed) & ";" &
      "if(!under(here,allowed)){" &
      "var n=0,told=0,later=null;" &
      "var count=function(){n++;if(!later)later=setTimeout(function(){later=null;" &
      "if(n!==told){told=n;post('blocked:'+n)}},400)};" &
      "var bad=function(u){try{var h=new URL(String(u),location.href).hostname.toLowerCase();" &
      "return h!==here&&under(h,hosts)}catch(e){return false}};" &
      # the page's own requests
      "var f=window.fetch;if(f)window.fetch=function(i,o){var u=i&&i.url?i.url:i;" &
      "if(bad(u)){count();return Promise.reject(new TypeError('blocked'))}return f.apply(this,arguments)};" &
      "var xo=XMLHttpRequest.prototype.open,xs=XMLHttpRequest.prototype.send;" &
      "XMLHttpRequest.prototype.open=function(m,u){this.__no=bad(u);return xo.apply(this,arguments)};" &
      "XMLHttpRequest.prototype.send=function(){if(this.__no){count();return}return xs.apply(this,arguments)};" &
      "if(navigator.sendBeacon){var sb=navigator.sendBeacon.bind(navigator);" &
      "navigator.sendBeacon=function(u,d){if(bad(u)){count();return true}return sb(u,d)}};" &
      # scripts, frames and pictures from them: never given their address
      "[['HTMLScriptElement','src'],['HTMLIFrameElement','src'],['HTMLImageElement','src']].forEach(function(p){" &
      "var c=window[p[0]];if(!c)return;var d=Object.getOwnPropertyDescriptor(c.prototype,p[1]);" &
      "if(!d||!d.set)return;Object.defineProperty(c.prototype,p[1],{get:d.get,configurable:true," &
      "set:function(v){if(bad(v)){count();return}d.set.call(this,v)}})});" &
      "var sa=Element.prototype.setAttribute;Element.prototype.setAttribute=function(k,v){" &
      "if((k==='src'||k==='href')&&/^(SCRIPT|IFRAME|IMG|LINK)$/.test(this.tagName)&&bad(v)){count();return}" &
      "return sa.apply(this,arguments)};" &
      # and taken out when the HTML puts them in
      "var sweep=function(n){if(n.nodeType!==1)return;" &
      "if(/^(SCRIPT|IFRAME|IMG|EMBED|OBJECT)$/.test(n.tagName)&&bad(n.src||n.data||'')){n.remove();count();return}" &
      "if(n.querySelectorAll)n.querySelectorAll('script[src],iframe[src],img[src]').forEach(function(c){" &
      "if(bad(c.src)){c.remove();count()}})};" &
      "new MutationObserver(function(ms){ms.forEach(function(m){m.addedNodes.forEach(sweep)})})" &
      ".observe(document,{childList:true,subtree:true});" &
      # the usual ad boxes, hidden
      "var css=document.createElement('style');css.textContent=" & $(%(AdBoxes & "{display:none!important}")) & ";" &
      "var put=function(){(document.head||document.documentElement).appendChild(css)};" &
      "if(document.documentElement)put();else document.addEventListener('DOMContentLoaded',put);" &
      # YouTube's ads in the player (from the site itself): run to their end
      # and skipped
      "if(/(^|\\.)youtube\\.com$/.test(here)){var gone=null;setInterval(function(){" &
      "var p=document.querySelector('.html5-video-player.ad-showing');if(!p){gone=null;return}" &
      "var v=p.querySelector('video');if(v&&isFinite(v.duration)&&v.duration>0){v.muted=true;v.currentTime=v.duration}" &
      "var b=document.querySelector('.ytp-ad-skip-button,.ytp-ad-skip-button-modern,.ytp-skip-ad-button');" &
      "if(b)b.click();if(v&&v!==gone){gone=v;count()}},300)}}"
  if shNoAutoplay in on:
    # (a sound or a video starts once the user has done something on the page)
    result.add "var play=HTMLMediaElement.prototype.play,did=false;" &
      "['pointerdown','keydown','touchstart'].forEach(function(t){" &
      "document.addEventListener(t,function(){did=true},{capture:true,passive:true})});" &
      "var woke=function(){return did||!!(navigator.userActivation&&navigator.userActivation.hasBeenActive)};" &
      "HTMLMediaElement.prototype.play=function(){if(!woke()){try{this.pause()}catch(e){}" &
      "return Promise.reject(new DOMException('Not played by itself','NotAllowedError'))}" &
      "return play.apply(this,arguments)};" &
      "document.addEventListener('play',function(e){if(!woke()&&e.target&&e.target.pause)e.target.pause()},true);"
  if shPreload in on:
    # (a link of this site the pointer rests on 80 ms: loaded ahead, once;
    # not one with a query, a download, or one that signs out or deletes)
    result.add "var ahead={},rest=null,risky=/log.?out|sign.?out|delete|remove|unsubscribe/i;" &
      "document.addEventListener('mouseover',function(e){var a=e.target&&e.target.closest&&e.target.closest('a[href]');" &
      "if(!a||a.origin!==location.origin||a.search||a.hasAttribute('download')||risky.test(a.href)||" &
      "ahead[a.href]||a.href.split('#')[0]===location.href.split('#')[0])return;" &
      "clearTimeout(rest);rest=setTimeout(function(){ahead[a.href]=1;var l=document.createElement('link');" &
      "l.rel='prefetch';l.href=a.href;(document.head||document.documentElement).appendChild(l)},80)},{capture:true,passive:true});" &
      "document.addEventListener('mouseout',function(){clearTimeout(rest)},{capture:true,passive:true});"
  result.add "})();"
