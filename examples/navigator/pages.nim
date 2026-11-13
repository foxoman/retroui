## Retro Navigator's own pages: the welcome page (about:welcome, the home
## page at first) and the handbook (about:handbook). Plain HTML and CSS, the
## pictures drawn by the style sheet: nothing to fetch.
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

const style = """
<style>
body { margin: 0; background: #c0c0c0; color: #000; font: 16px/1.5 "Times New Roman", Times, serif; }
.page { padding: 12px 18px 28px; max-width: 860px; }
.banner { position: relative; height: 150px; max-width: 640px; overflow: hidden;
  background: radial-gradient(circle at 18% 30%, #fff 0 1px, transparent 2px),
              radial-gradient(circle at 72% 18%, #fff 0 1px, transparent 2px),
              radial-gradient(circle at 46% 78%, #ffd 0 1px, transparent 2px),
              radial-gradient(circle at 88% 64%, #fff 0 1px, transparent 2px),
              radial-gradient(circle at 30% 88%, #cdf 0 1px, transparent 2px),
              linear-gradient(135deg, #000040, #000010 60%, #200030); }
.planet { position: absolute; left: 42px; top: 34px; width: 82px; height: 82px; border-radius: 50%;
  background: radial-gradient(circle at 35% 35%, #7fd4ff, #0080c0 55%, #003060); }
.ring { position: absolute; left: 22px; top: 66px; width: 122px; height: 18px; border-radius: 50%;
  border: 3px solid #ffd040; transform: rotate(-14deg); }
.comet { position: absolute; left: 250px; top: 26px; width: 120px; height: 4px; border-radius: 2px;
  background: linear-gradient(90deg, transparent, #ffe680); transform: rotate(18deg); }
.banner h1 { position: absolute; left: 170px; top: 52px; margin: 0; color: #5ff;
  font: bold 34px/1.1 Arial, Helvetica, sans-serif; letter-spacing: 1px; text-shadow: 2px 2px 0 #004; }
.banner small { display: block; color: #ffd040; font-size: 15px; letter-spacing: 3px; }
h2 { font-size: 30px; margin: 18px 0 8px; }
h3 { font-size: 21px; margin: 18px 0 4px; }
a { color: #0000ee; } a:visited { color: #551a8b; }
hr { border: 0; border-top: 2px groove #fff; margin: 18px 0; }
table { border-collapse: collapse; } td { padding: 2px 16px 2px 0; vertical-align: top; }
kbd { font: 14px "Courier New", monospace; }
</style>
"""

const banner = """
<div class="banner"><div class="ring"></div><div class="planet"></div><div class="comet"></div>
<h1><small>WELCOME TO</small>Retro Navigator</h1></div>
"""

const welcomeHtml* = "<!doctype html><html><head><meta charset=\"utf-8\">" &
  "<title>Welcome to Retro Navigator</title>" & style & "</head><body><div class=\"page\">" &
  banner & """
<h2>Welcome to Retro Navigator</h2>
<p>You are on the web with a browser in the manner of 1995's, made with Retro
Nim UI. The pages are drawn by your system's own engine, so today's web works
in it: sign-ins, maps, video.</p>
<p>To get around, type an address or a few words in the <b>Location</b> box and
press Enter: words are searched for. Click the blue words on a page to follow
them, and <b>Back</b> and <b>Forward</b> take you through the pages you saw.
<b>Home</b> brings you here. Keep a page you like with <i>Add Bookmark</i> in
the <i>Bookmarks</i> menu (Ctrl+D).</p>
<hr>
<h3>Places to start</h3>
<ul>
<li><a href="https://www.wikipedia.org">Wikipedia</a>, the free encyclopedia</li>
<li><a href="https://news.ycombinator.com">Hacker News</a></li>
<li><a href="https://nim-lang.org">Nim</a>, the language Retro Navigator is written in</li>
<li><a href="https://github.com/foxoman/retroui">Retro Nim UI</a>, the toolkit it is made with</li>
</ul>
<p>The <i>Handbook</i> button tells the rest: tabs, the shield that keeps ads
and trackers off, pages in 1995's look, screenshots, the keys, the
bookmarks, the preferences.</p>
</div></body></html>
"""

const handbookHtml* = "<!doctype html><html><head><meta charset=\"utf-8\">" &
  "<title>Retro Navigator Handbook</title>" & style & "</head><body><div class=\"page\">" & """
<h2>Retro Navigator Handbook</h2>
<h3>Going places</h3>
<p>Type in the <b>Location</b> box and press Enter. An address goes there
(<i>nim-lang.org</i> is <i>https://nim-lang.org</i>), a file on your computer
opens, and anything else is searched for with the search engine of
<i>Options &gt; General Preferences</i>. As you type, the box lists the pages
you visited and your bookmarks that have those letters: Down and Enter, or a
click, go to one. The logo at the right moves while a page loads; click it to
go home.</p>
<h3>How pages look</h3>
<p>The switch on the tool bar (and <i>View &gt; Page Look</i>) chooses:
<b>Modern</b>, the page as its site made it; <b>Classic</b>, the site's
layout and its scripts (sign-ins, menus and forms work) but 1995's type on
white paper, flat buttons and fields, no shadows, rounded corners or
animation; or <b>Plain</b>, the HTML alone, as a browser of 1995 showed it:
none of the site's style sheets or scripts, its pictures, links and forms
still there. Plain pages are the quickest and the lightest. <i>View &gt; 3.1
Scroll Bars on Pages</i> gives every page the window's own scroll bar beside
it, and Windows 3.1's to the boxes inside it, in the window's colors.</p>
<h3>Tabs</h3>
<p><i>File &gt; New Tab</i> (Ctrl+T) opens another page beside this one, and
the tabs show above the page while there are two or more. A link clicked with
Ctrl (Cmd on a Mac) or the middle button opens in a tab behind, which loads
when you go to it; a link for a new window opens in a new tab. Close a tab
with its x or Ctrl+W, and bring the last one closed back with Ctrl+Shift+T.
Drag a tab to move it; right-click it for its menu.</p>
<h3>The key in the status bar</h3>
<p>The key: the page came over an encrypted connection (https). A warning
sign: it did not, so what you type there can be read on its way.</p>
<h3>The shield</h3>
<p>Retro Navigator keeps ads and trackers off the pages, so they load faster
and fewer sites follow you from one to the next: the engine never fetches
what comes from more than 250 ad and tracker sites, the usual ad boxes are
hidden, and YouTube's ads are skipped. The status bar counts what it kept off
this page. In <i>Options &gt; Security Preferences</i> you can add a list of
your own: a hosts file, or an ad blocker's list of <i>||site^</i> lines. If a
site does not work without its ads, choose <i>Options &gt; Allow Ads on This
Site</i>. It also asks sites not to track
you, and goes to the secure (https) address of a link to an insecure one: to
go to one that has no secure address, type <i>http://</i> before it. All of
this is in <i>Options &gt; Security Preferences</i>.</p>
<h3>Faster</h3>
<p>A link of this site is loaded ahead while the pointer rests on it, so it
opens at once when you click. In <i>Options &gt; Network Preferences</i> you
can also keep videos and sounds from playing until you click. Tabs you have
not looked at for five minutes sleep: they free their memory and load their
page again when you go back to them (and a tab behind is paused at once,
where the engine can).</p>
<h3>Size, full screen, video</h3>
<p>The <b>Zoom</b> slider in the status bar makes the page larger or smaller
(Ctrl and +, Ctrl and -, Ctrl+0 too). A video's full-screen button fills the
screen with it, and Esc brings the window back; <i>View &gt; Full Screen</i>
(F11) gives the page the whole screen with the menus still there.
<i>View &gt; Pop Out Video</i> puts the page's video in a window of its own,
where the system's engine has one.</p>
<h3>Screenshots</h3>
<p><b>Picture</b> on the tool bar (Ctrl+Shift+S) takes a picture of the page
and opens it with Retro Board's tools: the pen, the highlighter, boxes, ovals,
arrows and words, in its colors and sizes. <i>Copy</i> puts it on the
clipboard for any program; <i>Save Picture</i> keeps it as PNG, and <i>Save
as Board</i> as a board Retro Board opens.</p>
<h3>Clear Browsing Data</h3>
<p><i>Options &gt; Clear Browsing Data</i> (Ctrl+Shift+Delete) forgets the
pages you visited (the Go menu, and Back in every tab) and what sites keep:
cookies, so you are signed out, their stored data and the cache.</p>
<h3>Keys</h3>
<table>
<tr><td><kbd>Ctrl+L</kbd></td><td>the Location box</td></tr>
<tr><td><kbd>Ctrl+T</kbd>, <kbd>Ctrl+W</kbd></td><td>New Tab, Close Tab</td></tr>
<tr><td><kbd>Ctrl+Tab</kbd>, <kbd>Ctrl+Shift+Tab</kbd></td><td>the next tab, the one before</td></tr>
<tr><td><kbd>Ctrl+Shift+T</kbd></td><td>Reopen Closed Tab</td></tr>
<tr><td><kbd>Alt+Left</kbd>, <kbd>Alt+Right</kbd></td><td>Back, Forward</td></tr>
<tr><td><kbd>Alt+Home</kbd></td><td>Home</td></tr>
<tr><td><kbd>F5</kbd>, <kbd>Esc</kbd></td><td>Reload, Stop</td></tr>
<tr><td><kbd>Ctrl+D</kbd></td><td>Add Bookmark</td></tr>
<tr><td><kbd>Ctrl+F</kbd>, <kbd>F3</kbd></td><td>Find, Find Again</td></tr>
<tr><td><kbd>Ctrl+O</kbd>, <kbd>Ctrl+P</kbd></td><td>Open a file, Print</td></tr>
<tr><td><kbd>Ctrl+Shift+Delete</kbd></td><td>Clear Browsing Data</td></tr>
<tr><td><kbd>Ctrl++</kbd>, <kbd>Ctrl+-</kbd>, <kbd>Ctrl+0</kbd></td><td>Larger, Smaller, Actual Size</td></tr>
<tr><td><kbd>Ctrl+Shift+S</kbd></td><td>a screenshot to mark up</td></tr>
<tr><td><kbd>F11</kbd></td><td>Full Screen</td></tr>
</table>
<p>While a page has the keyboard, its own keys come first: click the tool bar
or the Location box for these.</p>
<h3>Bookmarks and the Go menu</h3>
<p><i>Bookmarks &gt; View Bookmarks</i> lists them: go to one, or remove it.
The <i>Go</i> menu lists the pages of this session, the last first; the
Location box remembers the last 400 pages you visited, until you clear
them (<i>Clear Browsing Data</i>).</p>
<h3>Where the pages come from</h3>
<p>Retro Navigator draws its window itself and leaves the pages to the
system: WebView2 on Windows, WebKit on macOS and iOS, WebKitGTK on Linux
(<i>libwebkit2gtk-4.1</i>), Android's WebView. Where there is none, it shows
its own pages and offers to open the others in your browser.</p>
</div></body></html>
"""
