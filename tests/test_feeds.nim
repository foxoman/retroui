## Tests of retroui/feeds: RSS with the iTunes and Podcasting 2.0 tags,
## Atom, OPML both ways, the dates and lengths feeds write, show notes as
## text.

import retroui/feeds
const rss = """<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd" xmlns:content="http://purl.org/rss/1.0/modules/content/" xmlns:podcast="https://podcastindex.org/namespace/1.0">
<channel>
  <title>Retro Talk</title>
  <link>https://example.com</link>
  <description><![CDATA[A show about <b>old</b> computers &amp; new ones]]></description>
  <itunes:author>Sultan</itunes:author>
  <itunes:image href="https://example.com/art.jpg"/>
  <item>
    <title>Episode 2: Windows 3.1</title>
    <guid isPermaLink="false">ep2</guid>
    <pubDate>Wed, 02 Oct 2024 13:00:00 GMT</pubDate>
    <enclosure url="https://example.com/ep2.mp3" length="12345678" type="audio/mpeg"/>
    <itunes:duration>1:02:03</itunes:duration>
    <itunes:episode>2</itunes:episode>
    <content:encoded><![CDATA[<p>Show notes &amp; links:</p><ul><li>One</li><li>Two &#8211; three</li></ul>]]></content:encoded>
    <podcast:transcript url="https://example.com/ep2.vtt" type="text/vtt"/>
  </item>
  <item>
    <title>Episode 1</title>
    <pubDate>Tue, 1 Oct 2024 08:30 +0400</pubDate>
    <enclosure url="https://example.com/ep1.mp3" length="99" type="audio/mpeg"/>
    <itunes:duration>2723</itunes:duration>
    <description>Plain &lt;i&gt;notes&lt;/i&gt;</description>
  </item>
</channel></rss>"""
let f = parseFeed(rss, "https://example.com/feed.xml")
doAssert f.title == "Retro Talk", f.title
doAssert f.author == "Sultan"
doAssert f.image == "https://example.com/art.jpg"
doAssert f.description == "A show about <b>old</b> computers &amp; new ones", f.description
doAssert f.episodes.len == 2
let e = f.episodes[0]
doAssert e.audio == "https://example.com/ep2.mp3" and e.bytes == 12345678 and e.mime == "audio/mpeg"
doAssert e.seconds == 3723, $e.seconds
doAssert e.published == 1727874000, $e.published
doAssert e.number == 2 and e.guid == "ep2"
doAssert e.transcript == "https://example.com/ep2.vtt"
doAssert plainText(e.notes) == "Show notes & links:\n- One\n- Two – three", plainText(e.notes)
let e1 = f.episodes[1]
doAssert e1.guid == "https://example.com/ep1.mp3"
doAssert e1.seconds == 2723
doAssert e1.published == 1727757000, $e1.published   # (08:30 at +04:00: 04:30 UTC)
doAssert plainText(e1.notes) == "Plain notes", plainText(e1.notes)
doAssert clockText(3723) == "1:02:03" and clockText(65) == "1:05" and clockText(0) == ""
doAssert parseDuration("62:03") == 3723 and parseDuration("abc") == 0 and parseDuration("3600.7") == 3600
doAssert parseFeedDate("2024-10-02T13:00:00Z") == 1727874000
doAssert parseFeedDate("2024-10-02T17:00:00+04:00") == 1727874000
doAssert parseFeedDate("2024-10-02T13:00:00.123Z") == 1727874000
doAssert parseFeedDate("Wed, 02 Oct 2024 09:00:00 EDT") == 1727874000
doAssert parseFeedDate("nonsense") == 0
const atom = """<?xml version="1.0" encoding="utf-8"?>
<feed xmlns="http://www.w3.org/2005/Atom"><title>Atom Show</title><author><name>Ann</name></author>
<link href="https://a.example/"/>
<entry><title>First</title><id>urn:1</id><updated>2024-10-02T13:00:00Z</updated>
<link rel="alternate" href="https://a.example/1"/><link rel="enclosure" href="https://a.example/1.m4a" type="audio/mp4" length="5"/>
<summary>Hi</summary></entry></feed>"""
let a = parseFeed(atom)
doAssert a.title == "Atom Show" and a.author == "Ann" and a.link == "https://a.example/"
doAssert a.episodes.len == 1 and a.episodes[0].audio == "https://a.example/1.m4a" and a.episodes[0].link == "https://a.example/1"
doAssert a.episodes[0].published == 1727874000
let opml = toOpml([("Retro Talk", "https://example.com/feed.xml"), ("A & B", "https://b.example/rss?x=1&y=2")])
let back = parseOpml(opml)
doAssert back.len == 2 and back[1].title == "A & B" and back[1].url == "https://b.example/rss?x=1&y=2", $back
doAssertRaises(ValueError): discard parseFeed("<html><body>no</body></html>")
doAssertRaises(ValueError): discard parseFeed("not xml at all")
# (a feed with an entity XML does not know: read anyway)
let loose = parseFeed("""<rss><channel><title>Caf&eacute; &nbsp;Talk</title><item><title>x</title></item></channel></rss>""")
doAssert loose.episodes.len == 1
echo "feeds OK"
