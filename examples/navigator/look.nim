## Retro Navigator's looks for pages: as the site made them (Modern), the
## site's layout in 1995's type and colors (Classic), or the HTML alone, as
## a browser of 1995 showed it -- no design of the site's, no scripts
## (Plain). And the 3.1 scroll bars, in the window's colors, on any of
## them. Each is a script for the start of every page (`lookScript`).
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[json, strutils]

type
  PageLook* = enum
    ## How pages look (the setting's strings).
    lkModern = "modern"    ## as the site made it
    lkClassic = "classic"  ## the site's layout and scripts; 1995's fonts, colors and
                           ## controls; no shadows, rounding, gradients or animation
    lkPlain = "plain"      ## the HTML alone: no style sheets or scripts of the site's
                           ## (its <noscript> shown, its pictures loaded), 1995's look

  LookColors* = object
    ## The window's colors the pages are drawn in (CSS colors: "#c0c0c0").
    face*, light*, shadow*, frame*, text*: string  ## a button's face, edges, outline, words
    field*, fieldText*, scroll*, link*: string     ## a field's, the scroll bar's track, links
    select*, selectText*: string                   ## text selected
    dark*: bool                                    ## a dark theme (the page's controls dark)

const
  LookNames* = [lkModern: "&Modern (as the site made it)",
                lkClassic: "&Classic (1995's fonts and colors)",
                lkPlain: "&Plain (the HTML alone, no scripts)"]
    ## The looks, as the menus and Preferences say them.
  LookShort* = ["Modern", "Classic", "Plain"]
    ## The looks, as the tool bar's switch says them.
  ClassicColors* = LookColors(face: "#c0c0c0", light: "#ffffff", shadow: "#808080",
    frame: "#000000", text: "#000000", field: "#ffffff", fieldText: "#000000",
    scroll: "#c0c0c0", link: "#0000ee", select: "#000080", selectText: "#ffffff")
    ## Windows 3.1's colors.

proc svgUrl(svg: string): string =
  ## (a picture of SVG as a CSS address)
  "url(\"data:image/svg+xml," & svg.multiReplace(("#", "%23"), ("<", "%3C"), (">", "%3E"),
                                                ("\"", "'")) & "\")"

proc arrowSvg(points, color: string): string =
  svgUrl("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"16\" height=\"16\">" &
         "<polygon points=\"" & points & "\" fill=\"" & color & "\"/></svg>")

proc scrollBarCss*(c: LookColors): string =
  ## Windows 3.1's scroll bars for every page (WebKit's and Chromium's
  ## `::-webkit-scrollbar`): the track dithered, arrows on raised buttons
  ## at its ends, a raised thumb.
  let raised = "background-color:" & c.face & ";border:1px solid " & c.frame &
    ";box-shadow:inset 1px 1px " & c.light & ",inset -1px -1px " & c.shadow
  let dither = svgUrl("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"2\" height=\"2\">" &
    "<rect width=\"2\" height=\"2\" fill=\"" & c.scroll & "\"/><rect width=\"1\" height=\"1\" fill=\"" &
    c.light & "\"/><rect x=\"1\" y=\"1\" width=\"1\" height=\"1\" fill=\"" & c.light & "\"/></svg>")
  # (a site's `scrollbar-color` or `scrollbar-width` would turn these off in
  # Chromium and Safari: back to auto)
  "*,html{scrollbar-color:auto!important;scrollbar-width:auto!important}" &
    "::-webkit-scrollbar{width:17px;height:17px}" &
    "::-webkit-scrollbar-track{background:" & dither & ";border:1px solid " & c.frame & "}" &
    "::-webkit-scrollbar-thumb{" & raised & ";min-height:17px;min-width:17px}" &
    "::-webkit-scrollbar-corner{background:" & c.face & "}" &
    "::-webkit-scrollbar-button{display:block;width:17px;height:17px;" & raised &
    ";background-repeat:no-repeat;background-position:center}" &
    "::-webkit-scrollbar-button:active{box-shadow:inset 1px 1px " & c.shadow & "}" &
    "::-webkit-scrollbar-button:vertical:start:increment,::-webkit-scrollbar-button:vertical:end:decrement," &
    "::-webkit-scrollbar-button:horizontal:start:increment,::-webkit-scrollbar-button:horizontal:end:decrement" &
    "{display:none}" &
    "::-webkit-scrollbar-button:vertical:decrement{background-image:" & arrowSvg("8,5 4,9 12,9", c.frame) & "}" &
    "::-webkit-scrollbar-button:vertical:increment{background-image:" & arrowSvg("4,6 12,6 8,10", c.frame) & "}" &
    "::-webkit-scrollbar-button:horizontal:decrement{background-image:" & arrowSvg("5,8 9,4 9,12", c.frame) & "}" &
    "::-webkit-scrollbar-button:horizontal:increment{background-image:" & arrowSvg("6,4 10,8 6,12", c.frame) & "}"

proc controlsCss(c: LookColors): string =
  ## (buttons and fields as 3.1's; check boxes, text selected and the
  ## engine's own pickers in the window's colors)
  "html{accent-color:" & c.select & ";color-scheme:" & (if c.dark: "dark" else: "light") & "}" &
    "::selection{background:" & c.select & ";color:" & c.selectText & "}" &
    "button,input[type=button],input[type=submit],input[type=reset],select{background:" & c.face &
    "!important;color:" & c.text & "!important;border:1px solid " & c.frame &
    "!important;border-radius:0!important;box-shadow:inset 1px 1px " & c.light &
    ",inset -1px -1px " & c.shadow & "!important;font:bold 12px Arial,Helvetica,sans-serif!important;" &
    "padding:2px 8px!important;background-image:none!important}" &
    "button:active,input[type=submit]:active,input[type=button]:active{box-shadow:inset 1px 1px " &
    c.shadow & "!important}" &
    "input:not([type]),input[type=text],input[type=search],input[type=email],input[type=password]," &
    "input[type=url],input[type=number],input[type=tel],textarea{background:" & c.field &
    "!important;color:" & c.fieldText & "!important;border:1px solid " & c.shadow &
    "!important;border-radius:0!important;box-shadow:inset 1px 1px " & c.frame &
    "!important;font:13px Arial,Helvetica,sans-serif!important;padding:2px 3px!important}"

proc classicCss*(c: LookColors): string =
  ## The Classic look: over the site's own style sheets.
  # (the type: Times, as 1995's browsers had it, but not for the icon fonts
  # -- `:where` weighs nothing, so the controls' rules come first)
  ":where(*:not([class*=icon i]):not([class*=fa-]):not(.fa):not(.fas):not(.far):not(.fab)" &
    ":not([class*=material-]):not([class*=glyph i]):not(i)){font-family:\"Times New Roman\",Times,serif!important}" &
    "pre,code,kbd,samp,tt{font-family:\"Courier New\",Courier,monospace!important}" &
    "*,*::before,*::after{text-shadow:none!important;box-shadow:none!important;border-radius:0!important;" &
    "animation:none!important;transition:none!important;backdrop-filter:none!important;" &
    "filter:none!important;background-image:none!important;border-color:" & c.shadow & "!important}" &
    # (every box on the paper of a field, white for reading: a bar that stays
    # at the top over what scrolls, a menu over the page, are not see-through)
    "*{background-color:" & c.field & "!important;color:" & c.fieldText & "!important}" &
    "a:link,a:link *{color:" & c.link & "!important;text-decoration:underline!important}" &
    "a:visited,a:visited *{color:#551a8b!important}" &
    "img,video,canvas,svg{filter:none!important}" &
    "dialog,[role=dialog],[role=menu],[role=listbox]{border:1px solid " & c.frame & "!important}" &
    controlsCss(c)

proc plainCss*(c: LookColors): string =
  ## The Plain look: the page's only style sheet.
  "html{background:" & c.face & "}body:not([bgcolor]){background:" & c.face & "}" &
    "body{color:" & c.text & ";font:16px \"Times New Roman\",Times,serif;margin:8px}" &
    "a:link{color:" & c.link & "}a:visited{color:#551a8b}a:active{color:#ff0000}" &
    "img,video{max-width:100%;height:auto}svg:not([width]){width:1.2em;height:1.2em}" &
    "pre,code,kbd,samp,tt{font-family:\"Courier New\",Courier,monospace}" &
    "[hidden],template{display:none}" &
    controlsCss(c)

proc lookScript*(look: PageLook; c: LookColors; scrollBars: bool): string =
  ## The script for the start of every page that gives it `look` (and the
  ## 3.1 scroll bars when `scrollBars`), in the colors `c`. "" for Modern
  ## without the scroll bars.
  var css = ""
  if scrollBars: css.add scrollBarCss(c)
  case look
  of lkModern: discard
  of lkClassic: css.add classicCss(c)
  of lkPlain: css.add plainCss(c)
  if css.len == 0: return ""
  result = "(function(){if(window.__retroLook)return;window.__retroLook=1;" &
    "var css=document.createElement('style');css.id='__retro_look';css.textContent=" & $(%css) & ";" &
    "var put=function(){var r=document.head||document.documentElement;" &
    "if(r&&css.parentNode!==r)r.appendChild(css)};put();" &
    "document.addEventListener('DOMContentLoaded',put);"
  if look == lkPlain:
    # the site's style sheets and scripts taken out as the HTML puts them in
    # (a script's type changed before it runs: not run), its <noscript>
    # shown instead, its pictures that wait for a script loaded
    result.add "var lazy=function(n){var s=n.getAttribute('data-src')||n.getAttribute('data-lazy-src');" &
      "if(s&&(!n.getAttribute('src')||/^data:|blank|placeholder|spacer/i.test(n.getAttribute('src'))))n.src=s;" &
      "var ss=n.getAttribute('data-srcset');if(ss&&!n.getAttribute('srcset'))n.srcset=ss};" &
      "var strip=function(n){if(n.nodeType!==1||n===css||/^__retro/.test(n.id))return;var t=n.tagName;" &
      "if(t==='SCRIPT'){n.type='text/plain';n.removeAttribute('src');n.remove();return}" &
      "if(t==='STYLE'||(t==='LINK'&&/stylesheet|preload|modulepreload/i.test(n.rel))){n.remove();return}" &
      "if(t==='NOSCRIPT'){var d=document.createElement('div');d.innerHTML=n.textContent;n.replaceWith(d);" &
      "strip(d);return}" &
      "n.removeAttribute('style');for(var i=n.attributes.length-1;i>=0;i--){var a=n.attributes[i].name;" &
      "if(a.slice(0,2)==='on')n.removeAttribute(a)}" &
      "if(t==='IMG'||t==='SOURCE')lazy(n);" &
      "if(t==='A'&&/^\\s*javascript:/i.test(n.getAttribute('href')||''))n.removeAttribute('href');" &
      "for(var c=n.firstElementChild;c;){var x=c.nextElementSibling;strip(c);c=x}};" &
      "new MutationObserver(function(ms){ms.forEach(function(m){m.addedNodes.forEach(strip);" &
      "if(m.type==='attributes'&&m.target!==css)m.target.removeAttribute('style')})})" &
      ".observe(document,{childList:true,subtree:true,attributes:true,attributeFilter:['style']});" &
      "document.addEventListener('DOMContentLoaded',function(){if(document.documentElement)strip(document.documentElement)});"
  result.add "})();"
