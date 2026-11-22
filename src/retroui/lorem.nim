## Placeholder text -- the Latin of Lorem Ipsum, Arabic of its own kind, or the two in turn -- for a
## page, a form or a test before its real words come: as many paragraphs as asked, each of three
## to five sentences, no two together alike, the same each time.
##
## ```nim
## echo lorem(3)                          # three paragraphs of Lorem Ipsum
## echo lorem(2, loremArabic)             # two in Arabic
## echo lorem(4, loremBoth)               # Arabic, Latin, Arabic, Latin
## echo loremWords(5, loremArabic)        # a title's few words
## ```
##
## Paragraphs are joined by "\n" (a new paragraph in the text engine). The Arabic is written for
## this kit: plain sentences about a page being laid out, with a few numbers in Arabic-Indic
## digits, so it reads as text does.
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/strutils
from std/unicode import runes

type
  LoremLanguage* = enum
    ## Which placeholder text.
    loremLatin = "Latin"              ## Lorem Ipsum (for English and the languages written so)
    loremArabic = "Arabic"            ## Arabic (right to left)
    loremBoth = "Arabic and Latin"    ## paragraphs in turn, Arabic first: text of both directions

const
  latinSentences = [
    "Lorem ipsum dolor sit amet, consectetur adipiscing elit.",
    "Sed do eiusmod tempor incididunt ut labore et dolore magna aliqua.",
    "Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris nisi ut aliquip ex ea commodo consequat.",
    "Duis aute irure dolor in reprehenderit in voluptate velit esse cillum dolore eu fugiat nulla pariatur.",
    "Excepteur sint occaecat cupidatat non proident, sunt in culpa qui officia deserunt mollit anim id est laborum.",
    "Curabitur pretium tincidunt lacus, nulla gravida orci a odio.",
    "Nullam varius, turpis et commodo pharetra, est eros bibendum elit, nec luctus magna felis sollicitudin mauris.",
    "Integer in mauris eu nibh euismod gravida.",
    "Duis ac tellus et risus vulputate vehicula.",
    "Donec lobortis risus a elit.",
    "Etiam tempor, ut ullamcorper, ligula eu tempor congue, eros est euismod turpis, id tincidunt sapien risus a quam.",
    "Maecenas fermentum consequat mi.",
    "Donec fermentum, pellentesque malesuada nulla a mi.",
    "Duis sapien sem, aliquet nec, commodo eget, consequat quis, neque.",
    "Aliquam faucibus, elit ut dictum aliquet, felis nisl adipiscing sapien, sed malesuada diam lacus eget erat.",
    "Cras mollis scelerisque nunc.",
    "Nullam arcu, aliquam consequat, curabitur augue lorem, dapibus quis, laoreet et, pretium ac, nisi.",
    "Aenean magna nisl, mollis quis, molestie eu, feugiat in, orci.",
    "In hac habitasse platea dictumst."]
  arabicSentences = [
    "هذا نص تجريبي يوضع في مكان النص الحقيقي إلى أن يصل، ليرى المصمم شكل الصفحة وتوزيع الكلام فيها.",
    "يساعد هذا النص على الحكم على حجم الخط والمسافات بين الأسطر قبل كتابة المحتوى الأخير.",
    "تختلف أطوال الجمل هنا عن قصد، فبعضها قصير وبعضها أطول، لتبدو الفقرة قريبة من نص حقيقي.",
    "لا يحمل هذا الكلام معنى خاصًا، وإنما وضع ليملأ المساحة ويظهر الخط واتجاه الكتابة من اليمين إلى اليسار.",
    "عند مراجعة التصميم يستبدل هذا النص بالمحتوى الأخير، وتبقى الصور والعناوين والألوان في أماكنها.",
    "يفضل أن يكون طول السطر مريحًا للعين، فلا يطول حتى يتعب القارئ ولا يقصر حتى تكثر الأسطر.",
    "وتفيد الفقرات المتعددة في رؤية المسافة بين فقرة وأخرى، وفي ضبط بداية كل فقرة ونهايتها.",
    "قد يمتد النص على أكثر من عمود أو صفحة، فيظهر كيف ينتقل الكلام من إطار إلى الإطار الذي يليه.",
    "يمكن تغيير الخط واللون والحجم في أي وقت، وسيتبع هذا النص الإعدادات الجديدة كما يتبعها أي نص آخر.",
    "تظهر بعض الأرقام هنا مثل ١٢ و٣٤٥ و٢٠٢٦ لتجربة شكلها بجانب الحروف.",
    "إن كنت تحتاج إلى عدد أكبر من الفقرات، فاختر العدد الذي تريده وسيضاف النص كله مرة واحدة.",
    "تبدو الصفحة المتوازنة مريحة من النظرة الأولى، لأن البياض فيها موزع بين الكتل بعناية.",
    "يقرأ الناس العناوين أولًا، ثم ينتقلون إلى الفقرة الأولى، فإذا أعجبتهم تابعوا القراءة حتى النهاية.",
    "ويختار المصمم المحاذاة المناسبة، فالضبط من الجهتين يناسب الصحف والكتب، والمحاذاة إلى اليمين تناسب الفقرات القصيرة.",
    "كل كلمة في هذه الفقرة يمكن حذفها أو تغييرها دون أن يتأثر التصميم الذي وضعت فيه.",
    "ومع الوقت يتعلم المصمم أن النص الجيد لا يرى وحده، بل يرى مع كل ما حوله في الصفحة."]

proc paragraphOf(sentences: openArray[string]; i: int; opening: bool): string =
  ## (the `i`th paragraph: three to five sentences on from where the one before began; the first
  ## one's first sentence the text's opening one)
  let n = 3 + (i * 2) mod 3
  let start = if i == 0 and opening: 0 else: (i * 5 + 1) mod sentences.len
  for k in 0 ..< n:
    if k > 0: result.add ' '
    result.add sentences[(start + k) mod sentences.len]

proc loremParagraph*(i: int; language = loremLatin): string =
  ## The `i`th paragraph (0 the first) of `lorem`'s text in `language`.
  let i = max(0, i)
  case language
  of loremLatin: paragraphOf(latinSentences, i, true)
  of loremArabic: paragraphOf(arabicSentences, i, true)
  of loremBoth:
    if i mod 2 == 0: paragraphOf(arabicSentences, i div 2, true)
    else: paragraphOf(latinSentences, i div 2, true)

proc lorem*(paragraphs = 1; language = loremLatin): string =
  ## `paragraphs` paragraphs of placeholder text (at least one), joined by "\n": Lorem Ipsum's Latin,
  ## Arabic, or the two in turn (`loremBoth`, Arabic first). The same text each time.
  for i in 0 ..< max(1, paragraphs):
    if i > 0: result.add '\n'
    result.add loremParagraph(i, language)

proc loremWords*(count: int; language = loremLatin): string =
  ## `count` words of placeholder text (a title, a label, a name), no full stop: the start of
  ## `lorem`'s text in `language` (`loremBoth`: Arabic).
  let text = if language == loremLatin: lorem(4, loremLatin) else: lorem(4, loremArabic)
  var words = 0
  for w in text.splitWhitespace:
    if words >= count: break
    if words > 0: result.add ' '
    result.add w.strip(chars = {'.', ',', ';', ':'}).replace("،", "").replace("؛", "")
    inc words

proc loremSentenceEnd*(text: string; before: int): int =
  ## Where the last sentence of placeholder text that ends before rune `before` of `text` ends (the
  ## rune after its stop), or -1: to cut text that was too long for its box at a full sentence.
  var i = 0
  result = -1
  for r in text.runes:
    if i >= before: break
    inc i
    if int32(r) in [int32('.'), int32('!'), int32('?'), 0x061F'i32, 0x06D4'i32]:
      result = i
