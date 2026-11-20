# Changes

## 0.67.0 (in progress)

- **Fonts with PostScript outlines** (`retroui/cff`, new): .otf fonts whose
  outlines are CFF -- most Arabic fonts sold today, Adobe's and Google's CJK
  fonts, .otc collections -- read, drawn, shaped and put in PDFs as
  TrueType ones are: each glyph's cubic curves cut into quadratic ones
  within a thousandth of an em as the font is first drawn (`otfToTtf`;
  65,535 CJK glyphs in about a second, an Arabic font in milliseconds),
  every other table as it was. `faceInfo` names their faces; font folders,
  the system's fonts, Get Google Fonts and every font picker take them.
  The PDF reader's CFF code is this module's now (`parseCff`, `cffGlyph`),
  and no longer copies the whole font at every charstring it runs. CFF2
  (variable PostScript outlines) is not read.
- **Font folders looked through as the app runs** (`retroui/fontfolders`):
  every folder inside a font folder, to the last (on Android there was a
  limit of 4,000 files and folders), a few milliseconds each frame
  instead of all at once as the app started; `fontScan` says how far it
  has got (files and folders looked at, fonts found, the folder it is in)
  for a progress bar, `stopFontScan` stops it, `waitFontScan` finishes it
  at once (tools, tests). A desktop's folder's fonts are kept in the index
  beside the list too, by their size and time, and not opened again at the
  next start. The Font Folders panel shows the progress with Stop.
- **"Open with" on Android** (`retroapk --opens:TYPES`, new): an app in a
  file manager's "Open with" for the kinds named (VIEW and EDIT); the file
  comes through `sharedIn` as a shared one does, with `origins` -- the
  document it came from when the other app let it be written --, and
  `adoptSystemFile` (`retroui/systemfiles`, new) writes the copy's changes
  back to it as a picked document's are.
- **Retro Atelier**: a font folder's progress in the status line while
  it is looked through; .otf fonts in every font list. On Android,
  Preferences > General > Open and Save: the system's file picker or
  Retro Atelier's own dialog -- your folders, PSD, IDML, PDF and the rest
  with their previews, with the access to all your files (asked for when
  it is chosen). In a file manager's "Open with" and in the share sheets
  for pictures, PSD, PDF, AI, EPS and IDML; a file opened so is written
  back when that app allows it, else Save asks where.

## 0.66.0

Models trained for pictures, run by the app itself. `retroui/nnet` runs
ONNX models in Nim -- convolutions, attention, normalizations, resizing,
the shape operations models are full of -- on the device's own cores, with
the compilers' vectors; `retroui/vision` puts pictures through them: how
near each place is (Depth Anything), a picture's subject (U-2-Net), the
text in it (PaddleOCR's detector and readers, Arabic too). The model store
offers them, downloaded when you ask, as the language models of 0.65 are.
Retro Atelier 5.11 uses them: Select Subject and Remove Background with
U-2-Net, Depth Blur, Lens Blur and Relight with the photo's own depth, and
Type > Text in Picture. Without them, each works as it did.

- **ONNX models in Nim** (`retroui/onnx`: `readOnnx`, `metaOf`;
  `retroui/nnet`: `loadNet`, `run`, `Tensor`, `floats`, `matmul`, `conv`):
  the file read by hand (protobuf, the weights in it or beside it), 88
  operations of ONNX's own domain (opsets 11 to 21: Conv grouped, strided,
  dilated and transposed, MatMul and Gemm, BatchNormalization,
  LayerNormalization, InstanceNormalization, GroupNormalization, Softmax,
  the pools with `ceil_mode`, Resize nearest, linear and cubic with every
  coordinate transformation, DFT, Reshape, Transpose, Slice, Gather, Pad,
  Where and the rest), floats and whole numbers. The matrix products four
  rows by sixteen columns at a time (`simdnet.h`: AVX2 with FMA picked at
  run time, SSE2, NEON, SIMD128), b's blocks packed side by side;
  convolutions in strips of places gathered as columns, 1 x 1 ones read as
  they are, depthwise ones directly, a Relu after a Conv in the same pass,
  a BatchNormalization after one folded into its weights as it loads;
  softmax, exp and erf several at a time; the operations' inputs moved,
  not copied, at their last use; the model's own threads (the kit's pool
  belongs to the drawing thread: models run in jobs). `netProfile` adds up
  each operation's time. `test_nnet`: four graphs of random weights
  against onnxruntime (`tools/gennet.py`); `tools/netcheck.py` and
  `tools/netcheck.nim` compare any model with onnxruntime -- Depth
  Anything V2 Small, both U-2-Nets and PP-OCRv3's detector and reader
  agree within 1e-4 of their outputs' size.
- **Pictures understood** (`retroui/vision`): `depthOf` (0 .. 1 a pixel,
  1 the nearest, as Depth Anything sees it), `subjectOf` (0 .. 255, as
  U-2-Net finds it), `readText` (each line's words, its corners and how
  sure: DB's boxes found -- the places joined, the smallest rectangle,
  grown as the detector was taught -- each line made upright and read,
  CTC; a reader's characters its own or a dictionary, `arabicChars` for
  the Arabic one; Arabic put in the order it is written, `logicalOrder`).
  `test_vision`, with stand-in models.
- **The store's models of pictures** (`retroui/modelstore`: `muDepth`,
  `muSubject`, `muText`; `ModelFile`, `filesOf`, `modelFilePath`): a
  model of several files, and files taken out of an archive (a Python
  wheel) once its checksum is right. Depth Anything V2 Small (99 MB),
  U-2-Net small (4.6 MB) and U-2-Net (176 MB), PP-OCRv3 for English and
  Chinese (RapidOCR's, 12 MB), PP-OCRv3 Arabic (11 MB: Arabic, Persian,
  Urdu) -- each Apache 2.0.
- **A prompt read together** (`retroui/llm`: `readMany`, `readChunk`): a
  language model reads a prompt's tokens 32 at a time, each matrix's rows
  read from memory once for all of them -- the very numbers of reading
  them one by one (`test_llm` checks it), and the first answer sooner
  where the cores wait on memory, as a phone's do. `generate` and `embed`
  read so.
- `photosmart.subjectHook` and `photoneural.depthHook`: Select Subject and
  the depth of Depth Blur, Lens Blur and Relight ask a model first when an
  app sets them.
- **Retro Atelier 5.11**: Edit > Models on This Device has the models of
  pictures too; Select Subject and Remove Background use U-2-Net when it
  is on the device (the larger first), Depth Blur, Lens Blur's Estimated
  Depth and Relight use Depth Anything's depth; Type > Text in Picture:
  the selection, else the whole picture, read by the reader chosen --
  the text to change, Copy All, or Add as Type: each line a type layer
  over the line it was read from, as wide as it, in the type tool's
  font, one step to undo.

## 0.65.0

An AI of the device's own. `retroui/llm` runs language models in Nim, in
the app itself: BitNet b1.58's ternary ones (their weights -1, 0 or 1: a
2B model in 1.2 GB) and Llama's, Qwen 2's and 3's, from their GGUF files.
`retroui/modelstore` downloads one when you ask -- the size, the license,
Cancel, the checksum checked, Delete -- into a folder outside the app, and
`retroui/devicemodel` makes it one more AI service (`akDevice`: "This
device"), so the assistant, a summary or a text made shorter work offline
and send nothing anywhere. `retroui/meaning` finds texts by what they mean
with an embedding model. Retro Atelier 5.10 works offline with it and
shortens overset text to fit its box; Retro Mail 1.4 sums up and
translates with any service and finds mail by meaning; Retro Files 3.7
finds files by what they say; Retro Navigator 0.6 sums up a page.

- **A language model in Nim** (`retroui/llm`: `loadLlm`, `newLlmState`,
  `step`, `pick`, `generate`, `chat`, `chatPrompt`, `embed`,
  `similarity`; `retroui/gguf`, `retroui/llmtokens`): the architectures
  llama (and mistral), qwen2, qwen3, bitnet, bitnet-25 and bitnet-b1.58
  (the norms inside attention and the feed-forward, ReLU squared), the
  weights F32, F16, BF16, Q8_0, Q4_0 and the ternary TQ1_0, TQ2_0 and
  I2_S (bitnet.cpp's, as it packs it on x86), mapped from the file, not
  read into memory. Byte-pair tokenizers as Llama 3 and Qwen cut text,
  SentencePiece as Llama 2's, the control tokens kept whole; the
  conversation in the form each was taught (Llama 3's headers, ChatML,
  BitNet's roles), Qwen 3 without its thinking; a conversation kept
  between answers (only what is new is read); sampling by temperature,
  top-k, top-p and a repeat penalty; the text given as it comes, in whole
  letters. The rows go sixteen weights at a time (`simdllm.h`: SSE2, AVX2
  where it is, NEON, SIMD128), the ternary rows -- and Q8_0's and
  Q4_0's -- with the input as whole numbers, as BitNet was taught and
  llama.cpp does, so their sums are exact; on the model's own lasting
  threads. Measured on one core of the test machine, a model of BitNet
  b1.58 2B's shape reads a token in 0.22 s and writes one in 0.30 s (its
  2560 x 128256 F16 scores the rest) -- bitnet.cpp's 29 ms is on eight
  cores with its own assembly. `test_llm`: five small models of random
  weights (`tools/genllm.py`), each kind's rows, the scores token by token
  and the greedy answers against numpy's own reference, the tokens
  against Hugging Face's tokenizer.
- **Models when you ask for them** (`retroui/modelstore`:
  `storeModels`, `getModel`, `stopModel`, `deleteModel`, `isInstalled`,
  `modelStoreDialog`, `deviceModelPicker`, `aiServiceForm`): BitNet b1.58
  2B (Microsoft, MIT), Qwen3 1.7B (Apache 2.0) and Qwen3 Embedding 0.6B
  (Apache 2.0), each license letting any app use it; downloaded on a
  worker into "Retro Models" in the system's place for an app's data
  ($RETRO_MODELS), one copy for every app of the kit on a computer;
  Cancel keeps what came and Download goes on from there (a Range
  request: `downloadFile(resume = true)`, `stopDownload`, on Android too);
  the SHA-256 checked before it is used. `aiServiceForm` is the AI
  Connector's form any app shows: the kind of service, its address,
  model and key -- or which model on this device.
- **This device as an AI service** (`retroui/devicemodel`: `akDevice`,
  `deviceAnswer`, `deviceFetch`, `deviceAsk`, `deviceEmbed`): an OpenAI
  request in, an OpenAI answer out, so `retroui/aichat` and
  `assistantPanel` use it as any service -- the tools offered as Qwen 3
  was taught them (`<tool_call>`), its calls read back; the model kept
  loaded; the answer shown as it is written. `askOnce`/`onceAnswer` in
  `retroui/aichat`: one question to any service, no conversation.
  `test_devicemodel`.
- **Search by meaning** (`retroui/meaning`: `openMeaningIndex`,
  `update`, `find`, `rank`): texts made vectors by the embedding model on
  a worker, kept in a file, read again only when they change; a question's
  nearest first.
- **Retro Atelier 5.10**: Edit > Models on This Device; Edit > AI
  Connector > This device: the Assistant offline (fewer tools for it, the
  commands matched as it writes them -- what it reads first, it reads
  slowly); Type > Shorten to Fit (AI): an overset box's text made as short
  as fits by the AI service, asked again shorter when it still does not,
  one step to undo. A swatch, the foreground color, a library's color or
  the eyedropper chosen while the Type tool is on a type layer colors the
  text (the selection while editing, else the whole layer), as the layout
  program does.
- **Retro Mail 1.4**: Summarize and Translate use the Assistant's service
  (this device's own sends nothing anywhere; with none set, Claude with the
  older key); the Assistant finds mail by meaning (`find_by_meaning`) when
  an embedding model is on the device; Tools > Options > Assistant:
  This device, and its models.
- **Retro Files 3.7**: Tools > Find > By Meaning: the folder's files and
  its subfolders' found by what they say, read on the device (2000 files
  at most; text files' first 1500 letters, the others' names), kept for
  the next time. `showFound` (`retroui/filewidgets`) shows files found by
  other means as a search's results.
- **Retro Navigator 0.6**: View > Summary: the page's article summed up
  by the AI service of Options > AI Connector -- this device's own too.
- `tools/warncheck.sh` checks the vector kernels too: no vector of 32
  bytes or more handed to or from a function by value, which a function of
  AVX2 and one without pass two ways -- a build without optimizing (the
  tests') called one, and the model's rows read from the wrong place.
  `test_hardening`: no glob where an Android app runs (Android's libc has
  none before Android 9; the store first listed its folder with one).

## 0.64.0

AI in any app, with the service you choose. `retroui/aichat` is a
conversation with your own AI service that can use the app: the app gives
it tools -- Nim procs with their arguments --, the service calls them,
sees what they did and goes on; a tool that changes something asks you
first. `retroui/assistant` draws it beside the app's work, as a copilot
does in an office program, and `uiTools` lets it work any app's own
controls by their names. Every app can be worked by an AI agent outside it
too: `retrokit mcp` makes it an MCP server. `retroui/aiimage` makes
pictures from words and changes a picture where a mask says. In Retro
Atelier 5.9: the Assistant, Generate Image, Generative Fill and
Generative Expand; in Retro Mail 1.3: the Assistant pane, which finds and
reads your mail and drafts replies for you to send. Nothing is sent
anywhere until you set a service.

- **A conversation that uses the app** (`retroui/aichat`: `newAiChat`,
  `aiTool`, `aiToolLater`, `param`, `send`, `allow`, `deny`, `stop`,
  `clear`): any service that speaks OpenAI's chat completions with tools
  (OpenAI, a local Ollama or LM Studio, many more) or Anthropic's Messages
  with tool use -- the same tools for both. The request goes on a worker;
  the tools run on the UI thread at the start of a frame and may touch
  anything; a tool that finishes some frames later says so through
  `done` (`aiToolLater`); one that `confirm`s waits for the user (Allow,
  Allow All for the conversation, Don't -- the service is told it was not
  done). Several calls in one answer go in order, their results back
  together; the rounds are limited (8). A picture goes with what is
  written to services that see them (`send(text, png)`, or `attach` each
  time); `context` tells it what the app shows. `commandTool` runs the
  app's menu commands by name, the AI Connector's Ask in one tool.
  `chatRequest`/`chatReply` are the two kinds' requests and answers.
  `test_aichat` (against `tests/aimock.py`, a service of the test's own).
- **An assistant in any app** (`retroui/assistant`: `assistantPanel`,
  `uiTools`): the messages (Markdown, Arabic right to left), what each
  tool did, a tool waiting with Allow and Don't, Thinking..., the box to
  write in (Enter sends), Stop and New. `uiTools`: the app's own window
  as tools -- its controls listed, a control clicked, typed into, a key,
  a value set -- by the names a screen reader reads, so an app with no
  tools of its own has an assistant too.
- **Any app worked by AI agents** (`retroui/mcpserver`, `retrokit mcp
  PORT`): the app started with RETRO_DRIVE, `retrokit mcp` speaks the
  Model Context Protocol on its standard input and output -- what an
  agent's program (Claude's desktop app, an editor's agent) starts --
  with the window's tools (`ui_controls`, `ui_click`, `ui_type`, `ui_key`,
  `ui_set`, `ui_wait`, `ui_screenshot`, a picture) and the app's own
  (`publishTools`). The driver has three commands more: `shot` (the
  window's picture as a PNG), `tools` and `tool` (the app's own tools,
  listed and run), and `driveAsk` runs a driver's command from inside the
  app. `test_mcp`.
- **Pictures from words, and a picture changed through a mask**
  (`retroui/aiimage`: `generateImage`, `editImage`): any service that
  speaks OpenAI's images API (gpt-image-1, dall-e-2, a server on your
  computer that takes the same requests); asked at the nearest of its
  sizes, the picture comes back at the size asked; the key in the
  keyring (`saveAiImageSettings`).
- **Retro Atelier 5.9**: the Assistant (Window > Assistant; Edit > Ask AI
  opens it) -- a conversation with the AI Connector's service that works
  the image with the app's tools: the document described, type added (in
  Dastkhat, Arabic as Arabic), shapes added, a layer set (made current,
  renamed, shown or hidden, its opacity, moved, deleted), a selection
  made, any menu command run, a picture made, the selection filled; each
  change asked first and one step to undo; the image shown to it with
  each message if you like (Show it the image). **Generate Image**,
  **Generative Fill** (the selection made again as you describe it, or
  -- said nothing -- filled from what is round it, to take something
  away) and **Generative Expand** (the canvas grown, what is new made to
  carry the picture on) in the Edit menu, each a new layer (masked to
  where it is new), through the image service: Edit > AI Connector,
  Pictures. Its tools are published to agents outside it too.
- **Retro Mail 1.3**: the Assistant pane (View > Assistant): ask it what
  came from the bank this week, to sum up a thread, to answer someone --
  it lists, finds and reads messages (without what they quote) and opens
  a reply or a new message for you to read and send, never sending; it
  marks messages read or flagged when asked. Any service (Tools > Options
  > Assistant: OpenAI-compatible or Anthropic); an older version's
  Anthropic key is used until one is set. `test_mailassist`.
- `markdown` keeps 48 laid-out texts (6): a conversation's messages are
  laid out once, not every frame.
- **Retro DNS grew 1.5 MB a minute** under random input where `pkexec`
  was there (not on GitHub's runners): `retroui/admin` started a thread
  for each command run as the administrator, and a thread that ends leaves
  behind what Nim's cycle collector began for it (`docs/nim-bugs.md` 6,
  ready to report). One thread runs them all now, for the program's life;
  the soak is flat (15 MB). `test_system` checks twenty asks start no
  thread more.
- `retroapk` refuses a library linked as a program (its compiler not given
  `-shared`, or given its own start files: a compiler wrapper did that to
  Retro Atelier 5.8.0's first APK): Android cannot load one, and the app
  would not start at all.

## 0.63.0

Movement and graphs in the kit -- springs that keep their speed, boxes
that come and go, rows that glide, a box thrown to a point, a graph that
lays itself out (Retro Board tidies a mind map by its arrows, Retro DNS
shows what the phone reached) -- and UI steps that wait written one after
another (`retroui/flows`: Retro Atelier's close asks, saves and closes in
one go). Any app scripted and pictured from the command line. In Retro
Atelier 5.8: new text in Dastkhat (Arabic, Persian and Latin, nine
weights), font folders of your own on every system, every Google Fonts
family, Arabic in fonts that build letters from dots drawn right, a report
when a PSD opens, the AI key in the keyring, the GPU's results read back
while it works. A label stays with its field when a row wraps.

- **Arabic in fonts that build their letters from dots** (Reem Kufi and
  the other fonts that make ب ت ي ق from a dotless letter and dot glyphs):
  the tashkeel's own color, its raise and "without tashkeel" took those
  dots for tashkeel -- raised, the dots under ي and ب went into the
  letter's ink and those over ق floated with the marks. Tashkeel is now
  what a combining mark made (`ShapedGlyph.fromMark`, from the character
  the glyph came from, as HarfBuzz keeps it), the dots stay with their
  letter. Reem Kufi's shaping checked against HarfBuzz: 209 runs more in
  `test_otshape` (the test lines, letters and tashkeel at random), all the
  same glyph for glyph.
- **Retro Atelier**: new text that starts in Arabic takes Arabic as its
  language (it was English: USA); a language chosen is kept.
- **The AI service's key in the system's keyring** (`retroui/aiconnect`:
  `saveAiSettings`, `loadAiSettings`): Retro Atelier's AI Connector wrote
  the key into its settings file in plain text. The settings keep the
  service, its address and model; the key is in `retroui/secrets` (the
  keychain, the desktop's keyring, DPAPI, sealed on a phone and in a web
  page), asked for only when it is wanted, and a key an older version
  left in the file is moved over then. `toJson` leaves the key out.
- **Any app scripted and pictured from the command line**
  (`retroui/drive`): `RETRO_SCRIPT="click:Add;type:Milk;key:ctrl+s;wait:Saved"`
  runs the steps as the app starts -- no port, unlike `RETRO_DRIVE` --;
  `RETRO_SNAPSHOT=out.png` keeps the window in memory and writes its
  picture once they are done and the app is at rest, then ends it (1: a
  step failed, saying which; 2: not a script); `RETRO_PLAY` plays them in
  the window at a person's pace, a dot where each click lands, letters
  typed one at a time -- for films and GIFs of a feature. After nanoui's
  `--nanoui-script`, `--nanoui-snapshot`, `--nanoui-play`. `test_script`.
- **Flows that wait** (`retroui/flows`): UI steps that wait -- a question
  (`ask`), a file picked (`pickFile`), a job on a worker (`onWorker`), a
  condition (`waitUntil`), a pause, the next frame -- written one after
  another as a plain proc reads (`flow(name): ...`), not as state kept
  across frames: a closure iterator taken on at the end of a frame once
  what it waits for has come; `return` ends it; `ownedFlow(owner, ...)` and
  `cancelFlows(owner)` drop a closed window's; a flow that fails is ended
  and its fault logged. The shape of Nimony's `.passive` procs on Nim 2.
  **Retro Atelier**'s closing with changes not saved is one: asked, saved
  -- Save As waited for, the document closing once it is saved (it stayed
  open before: a second Close was needed) --, closed; quitting asks each
  document in turn, Cancel stops it. `test_flows` (Nim 2.2 and 2.4).
- **Font folders of your own** (`retroui/fontfolders`: `useFontFolders`,
  `fontFoldersPanel`): a folder of fonts the user keeps, its fonts in every
  font list -- on a desktop by its path, looked through again when it
  changes; on Android picked through the system's folder picker, the right
  kept for good, its fonts listed once and read through the documents
  provider the first time they draw; on iOS a bookmark of the folder picked
  in Files; in a web page font files chosen, kept in the page's storage.
  Retro Atelier: Preferences > Type > Your Font Folders (Add, Remove,
  Refresh). The text engine takes font files one by one, read when first
  drawn (`addFontFile`, `fontReader`, `dropFontFiles`, `removeFontDir`);
  `faceInfo` reads an open file. `test_fontfolders`.
- **Dastkhat, new text's font in Retro Atelier** (`retroui/dastkhat`:
  `carryDastkhat`): Arabic -- its kaf and yeh --, Persian and Latin in one
  font (from Vazirmatn, its Latin from Roboto; SIL Open Font License), nine
  weights from Thin to Black in one variable font, 160 KB packed; scripts
  it has not are drawn in the kit's fonts. Its shaping checked against
  HarfBuzz. **A variable font's weights are styles of its family**
  (`fontStyles`: its named instances; `fontFace(family, "SemiBold")` drawn
  at that weight by its axis, not made bold from Regular; `styleWeight`),
  and a PDF gets such a weight's own outlines, not the file's default ones
  (`canEmbed`, `isInstance`).
- **Graphs that lay themselves out** (`retroui/forcelayout`,
  `retroui/forcegraph`): `ForceGraph` -- nodes push each other away and
  keep out of each other's room, links pull their ends to a length, a
  gentle pull to the middle, cooling until it settles (as d3-force does);
  the push among neighbours only, in a grid, so 1,500 nodes settle in a
  moment; a node linked to one there is starts a link's length from it, so
  a tree starts unfolded; the same layout every time. `graphView` shows one
  -- dots with labels or boxes (a mind map) -- a fixed step at a time while
  it moves; a node clicked is selected, dragged it stays where it is held
  while the others make room; each node a list item for a screen reader.
  **Retro Board**: Arrange > Tidy Up by Arrows lays out the shapes arrows
  join, gliding there, one step to undo (`linkedLayout`). **Retro DNS**: on
  Android, what the phone reached -- each app joined to the sites it looked
  up in the last two minutes, live (the VPN notes each lookup's name and,
  from Android 10, its app). The gallery's Forms & Code > Graph page;
  `test_forcegraph`, `test_board`.
- **Motion** (`retroui/motion`): `sprung` -- a spring that, sent somewhere
  else half way, turns with the speed it has (`springSmooth`,
  `springSnappy`, `springBouncy`), the same at any frame rate; `presence`
  -- a box that comes in and goes out, drawn until it is out; `glided` --
  a box the layout moved glides to its new place (a scroll moves it at
  once); `dragSnap` -- a box dragged follows the pointer and, let go,
  springs with its throw to the nearest point; `staggered` -- rows one
  after another; `fixedSteps` -- a simulation's whole steps whatever the
  frame rate. Each keeps its state by where it is in the code; frames are
  asked for only while something moves; with less movement asked each is
  at its end at once (`reducedMotion`). The gallery's Forms & Code >
  Motion page; `test_motion`. After nanoui's `ui.motion`.
- **The GPU's layers read back while it goes on** (`retroui/photogpu`):
  each tile of a big image's composite went back to the processor with a
  plain readPixels, the processor idle while the GPU worked and the GPU
  idle while it copied -- once for each tile. Each tile now goes into a
  pixel buffer with a fence after it and is taken while the GPU makes the
  next: one wait, for the last tile (OpenGL ES 3 and OpenGL 3.2; WebGL and
  ES 2 read back as before; `RETRO_GPU_ASYNC=0` turns it off). The same
  pixels either way (`test_gpucomposite`, which also times both). Retro
  Atelier's Preferences > Performance says how often the GPU mixed the
  layers and how long the last one waited.
- **What a Photoshop document kept, said when it opens** (`Doc.opened`,
  `openReportText`): Retro Atelier said nothing -- only a layer's name
  took "not kept". Now a box, when something needs saying: the type layers
  whose fonts are not on this device (as Photoshop warns -- named as
  people know them, "Arial", not "Arial MT"), what became pixels (type
  whose text could not be read, a placed file not in the document, a group
  with a style mixed into one layer), what was not kept (an adjustment not
  done here, a Duotone's inks); else the status bar says what was kept to
  change (type layers, shapes, Smart Objects, adjustment layers, groups,
  styles).
- **Every Google Fonts family** (`googleFontCatalog`, made by
  `tools/gengooglefonts.py` from Google Fonts' list): Retro Atelier's Type >
  Get Google Fonts showed about 130 picked families -- Kufam was not
  there. It shows all 1,908, the 53 with Arabic letters first (Kufam,
  Vazirmatn, Qahiri, Reem Kufi Fun and Ink, Beiruti, Ruwudu among them);
  the list is made once, not every frame. Kufam's shaping checked against
  HarfBuzz.
- **A label stays with its field** (`keepWithNext`): in a row that wraps,
  a label that ends in ':' goes to the next line with the control after
  it -- Retro Atelier's Properties on a tablet left "Y:" at the end of the
  X line and its box on the next. Any other pair: `keepWithNext()`.
- **What GitHub's runs of 0.62.0 found**: on macOS Retro Mail (1.2.2) asked the
  keyring ten times a second while it waited, which the smoke run takes
  for an app busy with nothing (four times a second for the first second
  now, then once a second); Android's emulator run left a picker or a frozen app
  holding the driver's port, and every app after Retro Atelier had no
  answer (each app its own port now, stopped before it is taken off, the
  pickers closed); the Nim setup's download cut off in three jobs (tried
  once more now, in every workflow). Under the sanitizers: two of Retro
  Mail's tests stopped their mock servers through an object already freed
  (the exit proc keeps its own reference now, as the other mail tests'
  do); Retro Designer's box selection left its first list behind
  (`bandPicks`: a `result` filled in a loop, then given another -- Nim's
  leak, `docs/nim-bugs.md` 5), which `tools/writecheck.py` missed because
  of a proc declared inside it: it reads past those now, and found one
  more (the text of a PDF line written right to left, `pageText`); the
  GPU tests' leaks are Mesa's own (`tests/lsan.supp`). A soak that fails
  prints the end of the app's own log -- a fault's trace, Retro Atelier's
  memory log -- in the run's log as well. Retro Atelier's asset browser
  kept every picture it had ever shown (with GitHub's seed the random
  input browses it for most of the hour, online there): they are let go
  when it closes and on a new search. Its random input keeps its images
  under 256 MB of layers (four of forty big layers are 1.6 GB: how many
  stood open at the end, not a leak, would make the hour's memory).

## 0.62.0

Retro Atelier picks several layers at once as each of the three programs
does -- a photo shows one box with handles round all of them, a drawing
each object's outline in its layer's color with its anchor points, a page
each frame's edge -- and transforms, deletes, duplicates and sets them
together, picked by touch too; layers have the drawing and layout
programs' colors. File > Open on a phone starts where you were. And what
GitHub's checks found: the Windows programs build again, Retro Mail no
longer waits for a keychain before its window shows, Retro Atelier lets
go of the images it closes, Retro Files no longer stops at a file it
cannot read to its end, a zip with impossible sizes is refused instead
of crashing, and Retro Podcast's History keeps what changed, not copies
of the whole library.

- **Several layers picked, seen** (Retro Atelier 5.7, `examples/photo/picking.nim`):
  shown as the program the document is for shows them -- a photo as the
  photo editor (one box with handles round all of them, Show Transform
  Controls; View > Show > Layer Edges outlines each, with any tool), a
  drawing (SVG, AI, EPS) as the drawing program (each object's outline in
  its layer's color, its anchor points, and one box in that color; View >
  Hide Edges), a page of a book as the layout program (each frame's edge in
  its layer's color, one box; View > Extras > Hide Frame Edges). The layer
  under the pointer is outlined and its row in Layers framed; the row the
  pointer is over in Layers outlines its layer on the image.
- **Picked** with the Move tool: a box dragged from where nothing is --
  from the gray round the image too -- picks what it touches, each outlined
  as the box goes (Shift: added to those picked); Shift+click adds a layer
  and, on one picked, takes it out; a click on one of those picked keeps
  them all. On a phone or a tablet a long press on a layer (or Pick Several
  in its menu) picks by taps -- here and on the image, a tick on each row --
  until Done in the bar under the image (or Esc).
- **Worked together**: Free Transform (Ctrl+T, the bar's Transform) and
  the box's handles change all of them in one box, one step -- pixels
  warped once at the end (each only where it has something: three layers of
  6000 x 4000 put down in 0.2 s, a frame of them shown live in 18 ms), shapes
  still shapes, type still type (scaled; turned, slanted or in perspective,
  set flat and drawn through its corners), Smart Objects drawn again from
  what they hold (`retroui/photowarp`: `LayerShot`, `shotsOf`, `shotsBox`,
  `carryShots`, `liveShots`, `putDownShots`, `squareQuad`). Moving them
  moves type and shapes as what they are. Delete (the key, the bin, the
  menus), Duplicate, the blend mode, Opacity, Fill and the four locks take
  all of them (`deleteLayers`, `duplicateLayers`); Properties shows them
  together -- how many, W, H, X, Y (set: all of them scaled or moved),
  Align, Distribute, Group, Merge.
- **Layer colors** (`Layer.label`, `LayerColors`, `labelColorOf`,
  `nextLabel`): Layer Options > Color, the drawing and layout programs'
  twenty-seven (Light Blue, Red, Green...); a layer without one has its
  group's; a new group in a drawing or a layout gets the next, as those
  programs give their new layers one. The Layers panel marks it in the
  eye's column; PSD keeps it ('lclr', Photoshop's seven).
- **Open on a phone** (`tools/android/RetroActivity.java`): the system's
  picker starts in the folder of the file last opened or saved (else
  Downloads), not in Recent -- which lists pictures and PDFs only, never a
  PSD, an AI or an IDML. A web page's file chooser on a phone offers them
  too (`application/octet-stream` asked with the names it has no type for).
- **SIMD**: where a layer has something, a row four pixels at a time
  (`retroui/simdkit`: `firstAlpha`, `lastAlpha`; 2.7 times sooner: the
  Move tool's box, Align, Properties); the place left by a transform filled
  as fast as memory. A warp of the transform four pixels at a time was
  tried and dropped: its sixteen reads a pixel cost as much as it saved.
  The layers' boxes are kept while they are the same (the Move tool's box
  is drawn each frame).
- **What GitHub's checks found**: a `return` after `result` in
  `retroui/dnsquery` and three variables given twice (`tools/returncheck.py`,
  `tools/writecheck.py`); the Windows programs (built on Linux) not
  building since 0.58 -- the SIMD headers' paths were turned into Windows'
  (`os./` with Windows the target): cut from the module's own path now;
  Retro Mail on macOS waiting for a keychain that never answered before its
  first frame -- the store's key is asked on a thread of its own now, *Opening
  the mail kept on this device...* shown meanwhile, asked once and kept
  (`storeKey`), and `retroui/secrets`' tools stopped after two minutes and
  not asked again (Retro Mail 1.2.1); macOS's own openssl, which will not act
  as a time-stamping authority, skipped in `test_store`; the gradient mesh's
  colors kept in a ring the leak checker sees held; `test_bigpicture`'s
  memory bound not asked of the sanitizers' build.
- **What the nightly runs found**: Retro Atelier kept every image closed
  once Save As had been begun for it -- the Save As dialog held its window
  (800 MB of closed images in an hour of random input); it, the question
  asked on closing and Lighting Effects let go of it now, as do the
  caches, sources and dialogs that held an image or its layers
  (`forgetDoc`), and the memory log says how many documents are still
  alive (`docsAlive`). Retro Files stopped at a file that gives an error
  partway through reading it (Linux's own under /sys; a disk failing, a
  share gone would too): `retroui/textfile` shows what was read and keeps
  why (`TextFile.error`, `HexFile.error`; the status says *could not be
  read further*; Retro Files 3.6.1, which also lets go of a font it showed
  once its sheet is drawn: `dropFontData` in `retroui/textengine`; each
  was kept for as long as it ran). The store's fuzzer found a zip whose
  zip64 numbers, near the largest there is, overflowed a sum in
  `retroui/zip` (a crash, not *damaged*): each limit is asked by taking
  away now (`zipEntries`, `readEntry`). Retro Podcast's History kept two
  copies of every show for each Unfollow and of every episode's state for
  each Mark Played (`UndoStack.record`), up to 200 steps: on GitHub, where
  the hour of random input reads real feeds, Retro Podcast's memory still
  grew in the second half (+17 MB, up to 380 MB); it keeps the one show
  and the one episode now (`did`; 120 steps on a library of 8 shows of 300
  episodes: 89 MB more before, nothing now; Retro Podcast 1.2.1). The
  photo fuzzer, once it took Quit, drew each frame over the last until it
  ran out of memory: it goes on as if started again -- and then found a
  floating palette dragged onto the dock by its title faulting
  (`retroui/dock`: it left the list of floating palettes in the middle of
  their loop; `dockPanels` walks copies of its lists now).

## 0.61.0

Retro Mail made safe, and for any mail: who a
message is from checked -- its provider's own checks, believed only from its
own servers, and its DKIM signature verified here -- the senders, domains
and links made to fool told over the message, tracking pictures and codes
taken out, the mail kept on the device encrypted; new mail the moment it
comes (IMAP IDLE), and POP3, JMAP and a company's own Exchange besides IMAP,
Microsoft 365 and Gmail. The kit got each piece: DNS, domain names as people
read them, DKIM and DMARC, an encrypted SQLite, POP3, JMAP, EWS with NTLM,
mail's text sixteen bytes at a time. And Retro Designer chooses several
controls at once, with a box.

- **Who a message is from** (`retroui/mailauth`: `checkSender`,
  `checkHeaders`, `verifyDkim`, `dmarcPolicy`, `parseAuthResults`,
  `providerAuthservs`, `topAuthserv`; `SenderCheck`, `DkimResult`): DKIM
  verified here, RSA and Ed25519 (RFC 6376, 8463), in each
  canonicalization, the key asked of DNS; a signature counts only for the
  From address's own domain or its organization's, and one that proves
  nothing (SHA-1, a body signed in part, a testing key, a short key) is not
  counted as proof. The provider's Authentication-Results (DMARC, DKIM,
  SPF; Microsoft's compauth) believed only from its own servers -- Gmail's,
  Microsoft's, iCloud's, Yahoo's, Fastmail's, Zoho's, or one learned from
  the account's mail -- and only the topmost. A domain's DMARC policy makes
  an unproven message unproven. Tested with RFC 8463's own example and
  messages dkimpy signed.
- **DNS** (`retroui/dnsquery`: `dnsQuery`, `dnsLookup`): TXT, MX, SRV, A,
  AAAA from the system's own resolver over UDP and TCP (resolv.conf,
  Windows' list), DNS over HTTPS where there is none; answers kept as long
  as they say; names kept for examples never asked. Retro Mail's setup
  asks it too, rather than Google's DNS over HTTPS.
- **Domain names as people read them** (`retroui/domains`:
  `registrableDomain`, `publicSuffix`, `sameOrganization`, `toAsciiHost`,
  `toUnicodeHost`, `punyEncode`, `punyDecode`, `skeleton`, `looksLike`,
  `mixedScripts`, `editDistance`): the Public Suffix List (10,000 rules,
  packed), IDNA's Punycode both ways, and Unicode's look-alike letters
  (UTS #39).
- **What is there to fool** (`retroui/mailsafety`: `cleanMail`,
  `isTracker`, `stripTracking`, `linkWarning`, `senderWarnings`;
  `MailSafety`, `LinkProblem`): tracking pictures taken out (a pixel or
  two, hidden, a tracking service's), tracking codes taken off links (utm_*,
  fbclid, gclid, mc_eid and seventy more), links whose words name another
  site or that hide where they go (a name before an @, an IP address,
  letters of two alphabets, a well-known site's look-alike), a sender whose
  name says a company the mail is not from, an address in the name that is
  not theirs, a domain like a contact's.
- **An encrypted database** (`openDb(path, key = ...)`, `encryptDb`,
  `decryptDb`, `isPlainDb`; `src/retroui/cryptvfs.c`): every page of the
  file and its WAL sealed with XChaCha20-Poly1305 where it is (a fresh
  nonce each write, its place bound in), a byte changed on disk found when
  it is read (code 8202), SQLite's journal and temporary files encrypted
  too; a file made without a key made encrypted and back, a crash part way
  put right. A writer killed five times (kill -9) leaves every transaction
  it finished. Writing takes about twice as long (20,000 rows in 120 ms,
  65 without); reading is as quick once a page is in the cache (16 MB for
  an encrypted file). Monocypher is now always compiled with -O2.
- **POP3** (`retroui/pop3`: `pop3Connect`, `login`, `loginOAuth`, `stat`,
  `uidl`, `list`, `top`, `retr`, `dele`, `rset`, `quit`; CAPA, STLS,
  SASL), **JMAP** (`retroui/jmap`: `jmapConnect`, `jmapBearer`,
  `jmapBasic`, `call`, `mailboxes`, `queryEmails`, `getEmails`,
  `emailChanges`, `setKeyword`, `setMailboxes`, `destroyEmails`,
  `download`, `upload`, `importEmail`, `identities`, `sendRaw`) and
  **Exchange Web Services** (`retroui/ews`: `ewsConnect`, `folders`,
  `syncItems`, `getItems`, `mimeOf`, `setRead`, `setFlag`, `setCategories`,
  `moveItems`, `deleteItems`, `sendMime`, `findItems`; Exchange 2010 and
  later), signed in with Basic or **NTLM** (`retroui/ntlm`: NTLMv2, with
  MD4, MD5 and HMAC-MD5 of its own, checked against MS-NLMP's numbers).
- **IMAP IDLE** (`idle(c, seconds, stop)`) and `waitRead` on a connection
  (`retroui/netconn`): the server says when mail comes.
- **SMTP never writes the Bcc header** (`withoutBcc`): a message sent
  through SMTP with Bcc showed it to everyone it went to.
- **Mail's text sixteen bytes at a time** (`simdtext.h`, in
  `retroui/mime`): base64 2x as fast, quoted-printable 9x, UTF-8 checked
  3.6x, an 8-bit charset made UTF-8 8x -- the plain loops' very bytes
  (`test_mimefast`).
- `retroui/mailsetup`: each big provider's POP3 server and how to make its
  app password (`MailServers.pop3`, `jmap`, `appPassword`); a domain's
  JMAP server from DNS; Proton Mail Bridge, Mail.ru.
- `retroui/rsa`'s SHA-256 is `retroui/sha2`'s (it was a slow one of its own).
- **Retro Mail 1.2.0:** POP3, JMAP and Exchange accounts in the Add Account
  Wizard (*Read with:*), with the provider's app-password steps; new mail
  at once on IMAP; who a message is from checked as its body comes, a red
  or yellow banner over one that is not, or may not be, from who it says,
  with Block Sender and Move to Junk; a sender's name or domain, or a link,
  made to fool, told; a link that is not what it looks like asked about
  before it opens, tracking codes taken off the links opened, tracking
  pictures taken out; the mail on the device encrypted (Tools > Options >
  Security), an older version's encrypted as it starts; *Search the
  server* said each server's way (IMAP SEARCH, Gmail's q, Microsoft's KQL,
  JMAP's filter, Exchange's AQS). 50,000 messages: a folder of 3,000 in
  9 ms, a search in 6 ms, 28,000 headers stored a second
  (`tools/mailbench.nim`).
- **Retro Designer** chooses several controls at once: a box dragged on the
  window (Ctrl or Shift to add), Ctrl+A, Ctrl+click and Shift+click; a
  property set on all of them of the same kind, moved, grouped and deleted
  together, one Undo each.
- The docs: `docs/retromail.md` (the new accounts, Safety), `docs/designer.md`,
  `THIRD-PARTY-NOTICES.md` (the Public Suffix List, Unicode's
  confusables).

## 0.60.0

The rest of what the four programs have that Retro Atelier had not, in one
release (animation and version history left for another): the layout
program's print and output -- Separations Preview, Overprint Preview, spot
inks and the Ink Manager, tagged PDF with alt text, Flex Layout, paragraph
shading and borders, conditional text, track changes and notes, PDF forms,
buttons and page transitions, EPUB, equations; the drawing program's Global
Edit, Envelope Distort, Live Paint, Intertwine and Pattern Options; the photo
editor's Relight with its lights on the canvas, Remove with its shadow,
Upscale, each layer's size and your own placeholder text; the quick-design
programs' Mockups, Styles and font pairs, Tidy Up, Lift Subject, remixable
templates with photo placeholders, Publish as a web page and an AI service of
your own driving the app's commands. And the kit eight or sixteen pixels at a
time where the processor can (AVX2 found at run time, NEON, WebAssembly's
SIMD128) -- the same pixels to the last bit.

- **SIMD in the kit** (`retroui/simdkit`, `simdkit.h`: GCC and Clang
  vector extensions; AVX2 found at run time, NEON on ARM, SIMD128 in a web
  page; `-d:retroNoSimd` for none): the UI renderer's fills, blends, masks
  and the opaque runs it copies (`blendMaskRow`, `overRow`, `widenRow`,
  `gatherOpaque`); JPEG's inverse DCT (`idctBlock`: whole numbers, a block
  with only its DC filled at once, the plain loop where a value could
  overflow), its colors (`yccRow`) and 4:2:0 upsampling (`fancyRow`), its
  Huffman codes read with their run and value at once; PNG's filters
  (`pngFilterSums`, `pngFilterRow`) and zlib's Adler-32 (`adlerUpdate`)
  and CRC-32 (`crcUpdate`, a table of slices); the camera's YUYV
  (`yuyvRow`) and video's luma (`lumaRow`); the CMYK planes of a PSD on all
  the cores. Each kernel tested against the plain loop (`test_simdkit`), on
  x86 with and without AVX2, 32-bit and ARM64. 12 megapixels on two cores:
  a JPEG decoded in 185 ms (301 before), 4:2:0 in 101 ms (149), at 1/8 in
  89 ms (113); a PNG saved in 1.13 s (1.57).
- **Spot inks and separations** (`retroui/inks`: `SpotInk`, `InkSettings`
  -- aliases, all spots to process --, `plates`, `inkAmounts`, `coverage`,
  `separationPx`, `overprinted`; `retroui/photoseps`: `docPlates`,
  `spotPlanes`, `inkAmountsAt`, `overprintPicture`, `sepContext`,
  `sepPixel`; `Doc.spotInks`, `inkSettings`, `sepView`, `overprintView`;
  `ShapePaint.spot`, `tint`): a shape filled with a spot ink prints on a
  plate of its own; View > Separations Preview shows the plates, each on
  or off (alone in black), and the ink at the pointer; View > Overprint
  Preview shows what overprints printed over what is under it; the Ink
  Manager aliases inks and sends spots to process.
- **The PDF for a press and for readers** (`retroui/pdf`: `spotInk`,
  `fillSpot`, `strokeSpot`, `overprint`, `beginTag`, `endTag`, `PdfDoc.tagged`,
  `displayTitle`; `retroui/photopdf`: `PdfOptions.tagged`, `interactive`,
  `noSpots`, `tagFor`; the Save PDF dialog's Accessibility and
  Interactivity): spot inks as Separation color spaces with their
  tints, overprint as the press wants it (`OPM 1`); a tagged PDF -- its
  parts in reading order in a structure tree, headings by their paragraph
  styles, each picture's alt text, decorations left out, its language.
- **Interactive PDF** (`PdfField`, `PdfFieldKind`, `formField`,
  `PageTransition`; `LayerAttrs.field`, `FieldSpec`, `pdfFieldOf`,
  `addFields`; Window > Buttons and Forms, Layout > Page Transitions): text
  fields, check boxes, radio buttons, combo and list boxes, signature
  fields and buttons that go to a page, a web address, show or hide a field,
  print, clear or submit -- each drawn as its layer looks; transitions when
  the PDF is shown full screen (Split, Blinds, Box, Wipe, Dissolve,
  Glitter, Fly, Push, Cover, Uncover, Fade).
- **What a layer is in print and for readers** (`LayerAttrs`: overprint
  fill and stroke, nonprinting, alt text, a decoration, its tag, a form
  field, a photo placeholder; `attrsToJson`, `attrsFrom`; Window >
  Attributes, Layer > Object Export Options), saved in the document.
- **Conditional text, track changes and notes** (`retroui/textengine`:
  `CharStyle.condition`, `added`, `deleted`, `memo`; `withConditions`,
  `applyCondition`, `trackedInsert`, `trackedDelete`, `withoutDeleted`,
  `showingChanges`, `changesOf`, `acceptChanges`, `rejectChanges`,
  `addMemo`, `memosOf`; `Doc.conditions`): text under a hidden condition
  left out as the document shows, prints and exports; what is typed and
  deleted kept as changes, by who and when, shown in color, accepted or
  rejected; notes on the words (Window > Conditional Text, Track Changes
  and Notes).
- **Paragraph shading and borders** (`ParaStyle.shading`, `shadeToText`,
  `shadeOffsets`, `border`, `borderWidths`): a color behind a paragraph,
  as wide as its column or its text, and lines round it.
- **Equations** (`retroui/mathtype`: `setMath`, `mathPolys`): math as TeX
  writes it -- fractions, roots, sub- and superscripts, sums, integrals,
  Greek letters, brackets that grow, words -- set as a shape, its source its
  alt text, tagged a formula (Type > Insert Equation).
- **Flex Layout** (`retroui/flexlayout`: `FlexBox`, `flexArrange`;
  `retroui/vectormake`: `flexOf`, `setFlex`, `arrangeFlex`): a group's
  frames in a row or a column, justified, aligned, wrapping, with a gap and
  padding, hugging what they hold; change one -- a text frame that grows
  -- and the others move, in the same step.
- **`stepEndHook`** (`retroui/photo`): an app's work as each step ends,
  while it is open still -- what follows a change done in that step and
  undone with it (Flex Layout's frames, Global Edit's shapes).
- **E-books and web pages** (`retroui/publish`: `PubDoc`, `epubOf`,
  `webPage`, `publishSite`; `retroui/photopublish`: `pubDocOf` of
  documents and books): EPUB 3, reflowable or fixed layout, its text text,
  its headings headings, each picture with its alt text, its cover, its
  table of contents, right to left for Arabic; a web page that keeps the
  layout on a computer and puts the text and pictures one under another on
  a phone (File > Export > EPUB, Publish as Web Page).
- **The drawing program's makers** (`retroui/vectormake`): Global Edit
  (`similarLayers`, `globalEdit`: the shapes like the one picked follow
  what is done to it); Live Paint (`LivePaint`, `faceMask`, `paintFaces`,
  `fillFace`: the faces where shapes overlap filled with the bucket, kept
  as the shapes move); Intertwine (`crossing`: where two cross, the one
  under brought over); Pattern Options (`PatternSpec`, `patternTile`: grid,
  bricks by row or column, hexagons, spacing, which overlaps in front);
  Tidy Up (`tidyUp`: a row, a column or a grid, the room between even).
- **Envelope Distort** (`retroui/liveeffects`: `leEnvelope`,
  `envelopeMesh`, `envelopeTop`): a shape bent by a mesh whose points are
  dragged, or fitted into the outline of the object over it (a Coons patch
  between its sides) -- live, released at any time.
- **Relight, without AI** (`retroui/photorelight`: `RelightLight` -- point,
  spot, sun --, `relight`): lights put on a photo by its own relief (its
  depth map, smoothed in proportion to the picture), their color, reach,
  height, angle and cone -- a spot's pool of light an ellipse where it
  points --, dragged on the image; Lighting Effects' light dragged on the
  image too.
- **Upscale and Remove with its shadow** (`upscaleDetail`, `upscaleDoc`,
  `shadowOf`): a picture two to four times as big, its edges kept sharp
  along their lines and its detail made again from the picture itself;
  the shadow an object casts found and removed with it.
- **Mockups** (`retroui/mockups`: `MockupKind`, `scene`, `makeMockup`): a
  design on a T-shirt, a mug, a phone, a laptop, a poster on a wall, a book
  cover, business cards, a tote bag -- a new document, the design a Smart
  Object in its place, the light and shade over it.
- **Styles and font pairs** (`retroui/designstyles`: `DesignStyle`,
  `builtInStyles`, `applyStyle`, `fontPairs`, `paletteMap`): a palette and
  a heading and body font on a whole design at once, each color to the
  palette's of its lightness (photo placeholders left as they are).
- **An AI service of your own** (`retroui/aiconnect`: `AiSettings`,
  `askAi`, `commandsOf`, `requestOf`): one that speaks OpenAI's chat
  completions (a local Ollama or LM Studio too) or Anthropic's Messages
  turns what you ask into the app's own commands, shown before they run;
  off until you set one, nothing sent before.
- **Liquify's preview on the GPU** (`gpuWarpMesh`; `liquifyImg`'s
  `preview`): the picture moved by the mesh as it is brushed, within a
  level of the CPU's; the picture itself always the CPU's.
- **Templates** (`retroui/phototemplates`): ten more (Product Launch, Real
  Estate Listing, Sale Post, Team Member, Photo Story, Travel Postcard,
  Magazine Cover, Recipe Card, Wedding Invitation, Portfolio Page), in the
  Assets store too; every template's frames photo placeholders
  (`LayerAttrs.placeholder`) -- a double-click puts a photo in.
- **`layerBytes`, `bytesText`**: how much memory a layer takes, as people
  read it.
- **Retro Atelier 5.6.0** (code 45): all of the above in its menus and
  panels (View, Window > Separations Preview, Attributes, Buttons and
  Forms, Conditional Text, Track Changes and Notes, Styles and Fonts,
  Pattern Options; Type > Track Changes, Insert Equation, Paragraph
  Shading and Borders; Layout > Flex Layout, Tidy Up, Page Transitions;
  Layer > Envelope Distort, Live Paint, Intertwine, Make Photo Placeholder;
  Select > Start Global Edit; Filter > Render > Relight; Image > Upscale;
  Edit > Remove with Its Shadow, Ink Manager, AI Connector, Ask AI; File >
  Mockups, Export > EPUB, Publish as Web Page), in Arabic too; previews
  while a dialog's slider is dragged made at the size shown and without
  the proof's colors, the picture itself when it is let go; Preferences:
  your own placeholder text, each layer's size in the Layers panel.

## 0.59.0

What was still missing from the three programs, all in one: nested line
styles, type on a perspective plane, the phone's own spell checker,
graphic styles, Round Corners and Scribble, Replace Spine, the Shape
Builder tool, artboard options, Gradient Feather, tangent and
perpendicular Smart Guides, layers renamed by what they hold, Data Merge
into files, hanging punctuation and Optical Margin Alignment, hyphenation
in six more languages, Find/Change for glyphs and objects with saved
queries, masters based on masters, the Hijri date, Check Document's
Arabic checks, IDML keeping styles, links and bookmarks; and the speed
work's rest -- the hot loops eight lanes at a time where the processor
has AVX2, the layers under the one painted on kept mixed, idle layers
kept small, Blend If and Box Blur on the GPU, threads in a web page by
default, an Android app that stays open when the phone changes its look.

- **Nested Line Styles** (`retroui/textengine`: `NestedLine`,
  `ParaStyle.lineStyles`, `repeatLast`): a paragraph's first lines in
  character styles of their own (small caps for the first line, as a
  chapter opens), the last ones repeated; laid out again until the lines
  stand still, a nested style over them as the layout program has it.
  IDML writes and reads them (`AllLineStyles`), with the nested and GREP
  styles (`AllNestedStyles`, `AllGREPStyles`) and the character and
  object styles they name, in `Styles.xml`.
- **Type on a perspective plane** (`TextData.persp`, `perspBox`,
  `perspOn`; `retroui/perspectivegrid`: `textOntoPlane`, `textOffPlane`;
  `flatTextLayer`): the text set flat and drawn through the plane, still
  text -- typed in flat, put back on the plane when done; Release with
  Perspective lets it go.
- **The phone's own spell checker** (`retroui/spell`,
  `tools/android/RetroSpell.java`): Android's (its keyboard's:
  Gboard's, Samsung's) and iOS's `UITextChecker`, words checked and
  suggestions, in the text's language.
- **Graphic Styles** (`GraphicStyleDef`, `Doc.graphicStyles`,
  `graphicStyleIndex`, `graphicStyleOf`, `applyGraphicStyle`,
  `graphicStyleToJson`, `graphicStyleFromJson`): all of how a shape looks
  -- its fills and strokes, brush, widths, live effects, the layer's
  style, opacity and mode -- kept by name and given to other shapes,
  their outlines kept; saved in the document.
- **Live effects** (`retroui/liveeffects`: `roundCorners`, `scribble`;
  `leRoundCorners`, `leScribble`): Stylize > Round Corners (each corner
  cut back and curved, smooth points as they are) and Scribble (the
  inside as lines drawn back and forth, their spacing, width, angle and
  looseness).
- **Replace Spine** (`retroui/photovector`: `alongSpine`): a
  blend's shapes along a path, evenly apart, turned with it when asked
  (Align to Path).
- **Smart Guides for lines** (`retroui/pathtools`: `snapTangentPerp`):
  the end of a line drawn snaps where it would meet a shape's outline at
  a right angle, or just touch it.
- **Artboards** (`retroui/photocc`: `artboardColor`, `setArtboardColor`,
  `lockArtboard`): an artboard's color (transparent: none) and its lock.
- **Gradient Feather** (`GradientFeather`, `Layer.gradFeather`): a layer
  fading across itself, linear at an angle or radial, from one opacity
  to another, with its mask if it has one; saved; the GPU leaves such a
  layer to the CPU.
- **Layers renamed by what they hold** (`retroui/photocc`: `autoRename`;
  `contentName` knows more): a shape by its color and kind ("Red
  Rectangle"), a small thing by where it is ("Red Shape, Bottom Right"),
  a band of blue at the top "Sky", of green at the bottom "Grass", a
  group by its layers ("Title and 2 more").
- **Data Merge into files** (`retroui/datamerge`: `exportRows`,
  `fileNameFor`): a PNG or JPEG a row, each named by a column (made safe
  for a file name, made unique) or numbered -- for a single picture, as
  Photoshop's Data Sets as Files.
- **Hanging punctuation** (`ParaStyle.hanging`, `ignoreOptical`;
  `TextData.opticalMargin`; `hangOf`): Roman Hanging Punctuation (quotes,
  periods, commas, hyphens all out of the line; dashes, colons,
  semicolons, ellipses half) and Optical Margin Alignment (some letters'
  edges too: A, T, V, W, Y); the room they leave counted when the lines
  are broken, by both composers; Arabic's comma and full stop hang too.
  PSD keeps Roman Hanging Punctuation; IDML Optical Margin Alignment
  (`StoryPreference`) and Ignore Optical Margin (`IgnoreEdgeAlignment`).
- **Hyphenation in its language** (`retroui/hyphenate`:
  `hyphenLanguages`, `hasPatterns`, `hyphenPoints(..., lang)`,
  `hyphenated(..., lang)`; `CharStyle.lang`): French, German (the reformed
  spelling, 2006), Spanish, Italian, Portuguese and Dutch besides English --
  hyph-utf8's patterns, each with its notice (`vendor/hyph-*.tex`; the
  programs carry them packed with LZMA, `tools/packlzma.py`: 175 KB for
  all seven, each unpacked the first time its language is hyphenated) --
  accented letters, an apostrophe in a French or Italian word, each
  language's own least letters at a word's ends; the five-letter least
  word of the layout program. IDML keeps each word's language
  (`AppliedLanguage`).
- **Find/Change** (`retroui/textsearch`: `glyphOf`, `findGlyph`,
  `changeGlyph`, `QueryKind`, `SavedQuery`, `builtInQueries`,
  `queriesToJson`, `queriesFrom`; `retroui/photo`: `ObjectKind`,
  `ObjectQuery`, `ObjectChange`, `matchesObject`, `findObjects`,
  `changeObjects`): a glyph in a font (or any) changed to another in a
  font of its own; frames by their fill, stroke, weight, opacity, Object
  Style, kind and name, changed to others in a step; searches kept by
  name, and the ones it comes with (spaces and returns made single,
  whitespace at the ends of lines, dashes, quotes, phone numbers; Arabic's
  tatweel taken away, its comma and question mark).
- **Masters based on masters** (`retroui/photobook`: `Master.basedOn`,
  `masterChain`, `setBasedOn`): a master's pages show the master it is
  based on too, under its own -- and so does the master, as it is edited;
  never round; saved with the book; IDML as the layout program writes it
  (the master's pages with the other applied).
- **The Hijri calendar** (new `retroui/hijri`: `toHijri`, `fromHijri`,
  `hijriMonthName`, `arabicMonthName`, `arabicDayName`, `arabicDigits`,
  `hijriDate`, `arabicDate`): Umm al-Qura's (1924 to 2077; its months'
  first days from the hijridate package's table, MIT -- checked against
  its 840 dates both ways), the arithmetical calendar outside it; dates in
  Arabic, the Gulf's and Egypt's month names or the Levant's, Arabic-Indic
  digits. **Text Variables** (`dayIn`, `withVariables`): `<hijri>`,
  `<hijri:en>`, `<hijri:num>`, `<hijri:full>`, `<date:ar>`,
  `<date:ar-sy>`, `<date:ar-full>`, `<date:dd/MM/yyyy>` (any format), and
  `<modified:...>` the same.
- **Check Document's Arabic** (`retroui/preflight`): Arabic in a font
  picked for it that has no Arabic letters, set left to right, slanted, tracked apart, typed as
  presentation forms (copied from a PDF), lengthened by tatweel typed by
  hand in justified text, its digits of two kinds.
- **IDML** (`retroui/idml`): hyperlinks (`HyperlinkTextSource`, to an
  address, a destination, a page), destinations and bookmarks, written
  and read; Object Styles on frames and shapes.
- **Eight lanes, and fewer passes** (`retroui/simd`, `simdkern.h`,
  `simdmix.h`: `mixOpt`, `lutAdj`, `lutInk`, `preRow`, `hasAvx2`,
  `forceAvx2`): the layers mixed four or eight pixels at a time over any
  pixels now -- masks, clipping, Blend If, opacity, fill -- AVX2 picked
  when the processor has it, the same pixels either way; Hue/Saturation,
  Curves and the other tables, and a CMYK proof, looked up with exact
  arithmetic four at a time; a gaussian blur's strips sized to the cache.
  **The layers under the one painted on kept mixed** (`compositeBelow`):
  in tiles, the painted layer and those over it mixed on them -- the same
  pixels, six times sooner over nine layers. **Idle layers kept small**
  (`Layer.pxRaw`, `px`, `parked`; `canPark`, `parkLayer`, `parkHidden`,
  `parkAll`, `parkedBytes`): their pixels deflated in tiles, or on the
  scratch disk, until they are next read -- the app parks, after a
  minute unchanged, the layers of the documents not shown and the hidden
  ones of those shown, and all it can when the system is short of memory.
  At 4000 x 3000 on two cores (best of three, `-d:useMalloc`):

  | | 0.58.0 | now | |
  |---|---|---|---|
  | 300 dabs painted over nine layers | 95.3 ms | 15.7 ms | 6.1x |
  | three masked layers mixed | 198.8 ms | 35.0 ms | 5.7x |
  | two clipped layers | 150.3 ms | 33.7 ms | 4.5x |
  | two Blend If layers | 242.0 ms | 74.9 ms | 3.2x |
  | five layers mixed | 121.2 ms | 64.5 ms | 1.9x |
  | Hue, Color, Luminosity layers | 1491.1 ms | 762.0 ms | 2.0x |
  | two Hue/Saturation adjustment layers | 500.1 ms | 278.9 ms | 1.8x |
  | a CMYK proof (one core) | 499.9 ms | 291.3 ms | 1.7x |
  | Gaussian Blur 5 px | 308.3 ms | 181.7 ms | 1.7x |
  | Gaussian Blur 8 px | 436.7 ms | 232.8 ms | 1.9x |
  | bicubic to 6000 x 4500 | 280.9 ms | 194.5 ms | 1.4x |

- **On the GPU** (`retroui/photogpu`, `retroui/gfxgpu`: `gpuBoxBlur`):
  Blend If mixed on the GPU (the same pixels as the CPU's), Box Blur
  there for big pictures.
- **Web pages** (`retroweb`, `retro.js`): built with threads by default
  (`--no-threads` for one build without), the page falling back to the
  build without them where the browser will not give the memory; SIMD128
  was already on.
- **Android** (`uirelays/drivers/android_glue.c`): an app stays open when
  the phone changes its look (a new theme, its fonts): the activity made
  again is taken over, nothing lost; the mock tests drive it.
- **Tests**: `test_simd`, `test_photospeed`, `test_gpucomposite`,
  `test_textcompose`, `test_idml`, `test_perspectivegrid`,
  `test_photocc`, `test_pathtools`, `test_datamerge`, `test_textsearch`,
  `test_textengine`, `test_photobook`, `test_hyperlinks` grow; the
  Android mock tests a relaunch.

Retro Atelier 5.5.0: Paragraph > **Drop Caps and Nested Styles** with
Nested Line Styles; **Layer > Perspective > Release with Perspective**,
type staying type on a plane; the phone's spell checker; **Window >
Graphic Styles**; **Layer > Live Effects > Stylize > Round Corners,
Scribble**; the **Shape Builder tool** (drag across the parts of
overlapping shapes; Alt+drag takes them away); **Layer > Path Operations
> Replace Spine**; **Artboard Options** (the options bar); **Layer >
Gradient Feather**; tangent and perpendicular Smart Guides; **Recolor
Design** from another open picture's colors; **Layer > Rename Layers by
Content** (and in the Layers palette's menu); **Data Merge: Export a File
a Row**; the Paragraph panel's **Roman Hanging Punctuation**, **Optical
Margin Alignment**, **Ignore Optical Margin**; the Character panel's
**Language**; **Find/Change** with Text, GREP, Glyph and Object searches
and its Query menu; **Layout > Masters > Master Options** (Based on
Master); **Type > Text Variables > Insert Date As** (the Hijri date, the
Arabic date); Check Document's Arabic checks; painting over many layers
much sooner; idle layers kept small; every new word in Arabic.

## 0.58.0

The three programs side by side: the photo program's missing filters and
looks, the drawing program's tools on shapes and paths, and the layout
program's text -- paragraphs in formats of their own set by the
Paragraph Composer, kept together, across or split in columns, nested
and GREP styles, object styles, spelling, hyperlinks, cross-references,
text variables, bookmarks, linked pictures and packaging; the layers
mixed, blurs and resizing four pixels at a time; the phone's own folder
picker.

- **Filters** (`retroui/photoblurs`: `averageBlur`, `boxBlur`,
  `shapeBlur`, `smartBlur`, `lensBlur`, `LensBlur`, `runsOf`,
  `irisRuns`): Average; Box Blur (running sums: any radius the same
  cost); Shape Blur (any shape as the kernel); Smart Blur (Normal, Edge
  Only, Overlay Edge, its threshold and quality); Lens Blur (a depth map
  from the transparency, a layer mask or a channel, the iris's shape,
  blade curvature and rotation, specular highlights, noise). The Filter
  Gallery's own (`retroui/photoartistic`): Fresco, Neon Glow, Palette
  Knife, Rough Pastels, Smudge Stick, Underpainting, Dark Strokes,
  Sprayed Strokes, Diffuse Glow, Glass (its textures), Ocean Ripple,
  Chalk & Charcoal, Conté Crayon, Note Paper, Plaster, Water Paper,
  Glowing Edges, and HSB/HSL. `filterOrigin`: where the part filtered is.
- **Light** (`retroui/photodevelop`: `lightLut`, `lightFn`): an
  adjustment layer of exposure, contrast, highlights, shadows, whites and
  blacks; PSD keeps it as Curves.
- **Pattern Overlay** (`fxPatternOverlay`, `Effect.pattern`, `scale`;
  `retroui/photostyles`: `patternTile`, `PatternNames`): a layer style of
  a tile repeated from the layer's corner, scaled and turned; PSD reads and writes it and its
  patterns (`PsdPattern`). Gradients drawn dithered (no bands).
- **Matting** (`removeMatte`, `defringe`): Defringe, Remove Black Matte,
  Remove White Matte.
- **Pattern Preview** (`Doc.patternPreview`, `PaintOpts.wrap`): the image
  shown tiled round itself; a dab past an edge goes on at the other.
- **The drawing program's tools** (`retroui/pathtools`: `erasePath`,
  `smoothPath`, `cutAt`, `knifeCut`, `joinEnds`, `openEnds`, `eraseShape`,
  `blobMerge`, `similarShapes`, `groupOfLayer`, `anchorsIn`, `arcPath`,
  `rectGridPath`, `polarGridPath`, `flareShapes`, `meshAddLines`,
  `meshNearest`, `meshRemoveAt`): Group Selection, the Magic Wand and the
  Lasso for shapes and points, Smooth, Path Eraser, Join, Eraser,
  Scissors, Knife, Blob Brush, Arc, Rectangular and Polar Grids, Flare,
  Mesh; Ellipse and Polygon frames.
- **Strokes drawn with a brush** (`StrokeBrush`: Calligraphic, Art,
  Pattern, Scatter; `retroui/pathbrush`: `strokeBrushOf`) and **variable
  widths** (`WidthPoint`, `widthAt`, `varStrokeOutline`): the Paintbrush's
  strokes stay paths; the Width tool's points and profiles.
- **Appearance** (`Appearance`, `ShapeData.appearance`, `expanded`,
  `exportParts`, `isPlain`): more fills and strokes on a shape, each with
  its opacity, blend mode, effects, above or below; SVG and PDF draw each
  part.
- **Live effects** (`retroui/liveeffects`: `LiveEffect`, `puckerBloat`,
  `roughen`, `transformEffect`, `tweak`, `twist`, `zigZag`, `freeDistort`,
  `warpEffect`, `offsetEffect`, `repeatRadial`, `repeatGrid`,
  `repeatMirror`, `applyEffects`): Distort & Transform, Warp, Offset Path,
  and Repeat (radial, grid, mirror) done to the path each time it is
  drawn; Expand Appearance makes them real.
- **Three-point perspective** (`pkThreePoint`, `vertY`, `threePoint`).
- **The layout program's text** (`retroui/textengine`): each paragraph a
  format of its own (`CharStyle.para`, `TextData.paraFmts`, `tailFmt`,
  `fmtOf`, `paraFmtAt`, `paraBounds`, `setParaFmt`, `changeParas`) --
  joined, a paragraph takes the first's; split, both halves keep it. The
  **Paragraph Composer** (`ParaStyle.composer`, `Composer`: every way of
  breaking a paragraph weighed at once, Knuth and Plass's; Auto for
  justified text, the Single-line Composer for the rest).
  **Justification** (`wordSpacing`, `letterSpacing`, `glyphScaling`: the
  least, wanted and most). **Keep Options** (`keepWithNext`,
  `keepTogether`, `keepStart`, `keepEnd`, `startAt`: in the next column,
  frame or page). **Span Columns** (`spanAll`: a heading across the
  columns, the columns above it balanced; `splitColumns`). **Balance
  Columns**, **Inset Spacing** and **Vertical Justification**
  (`TextData.balance`, `inset`, `vjust`, `VertJust`). **Nested and GREP
  styles** (`NestedStyle`, `NestedUnit`, `GrepStyle`, `grepHook` -- set
  by `retroui/textsearch`). **Next Style** (`nextStyle`). Saved in the
  document; IDML writes and reads each paragraph's range with its keeps,
  spans, composer and spacing, and the frame's inset, vertical
  justification and balance. A table of contents finds each paragraph in
  its style.
- **Hyperlinks, destinations and cross-references**
  (`CharStyle.link`: a web or mail address, `#name`, `page:N`, `=name`;
  `linkRuns`): text variables shown in place (`withVariables`:
  `<file>`, `<date>`, `<modified>`, `<head:Style>` -- `runningHead` --
  and `<ref:name>`, the page a destination is on: `Doc.refPages`, a book
  keeping where each is). The PDF (`retroui/photopdf`: `linkRects`,
  `docDests`, `addBookmarks`; `PdfOptions.noLinks`, `noBookmarks`,
  `dests`, `pageMap`) makes them links -- to an address, a page, a
  destination -- and **bookmarks** (`DocBookmark`, `Doc.bookmarks`;
  `retroui/pdf`: `PdfBookmark`, `PdfDoc.bookmarks`, `linkToPage`) its
  outline, entries under entries.
- **Object Styles** (`ObjectStyleDef`, `Doc.objectStyles`,
  `Layer.objectStyle`, `objectStyleOf`, `applyObjectStyle`,
  `redefineObjectStyle`, `renameObjectStyle`, `deleteObjectStyle`,
  `objectStyleOverridden`): a shape's fill and stroke, the layer's
  effects, a text frame's options and its paragraph style, kept by name;
  each layer that has one changes when it is redefined. Paragraph styles
  go to the paragraphs picked (`applyParaStyle(..., a, b)`); a character
  style redefined changes the nested and GREP styles that use it.
- **Linked pictures** (`SmartData.link`, `linkStamp`) and
  `fontFileOf`: what Package needs.
- **The phone's own folder picker** (`retroui/systemfiles`:
  `systemFolderDialog`, `systemFoldersOn`, `hasSystemFolders`,
  `flushSystemFolders`; `SystemFilesBackend.askFolder`, `folderPicked`,
  `putInto`): `fileDialog` and `filePicker` picking a folder show
  Android's; what the app writes into the folder it is given goes into
  the one picked, its folders as folders.
- **Four pixels at a time** (`retroui/simd`, `simdkern.h`: the compilers'
  own vectors -- SSE2 or AVX on x86, NEON on ARM, SIMD128 in a web page
  built with it, lane by lane elsewhere; `-d:retroNoSimd` for the plain
  loops): the layers mixed over opaque pixels (Normal and the separable
  modes, exactly as before), a gaussian blur's passes, Box Blur, and
  resampling across then down. At 4000 x 3000 on two cores (best of
  three, `-d:useMalloc`):

  | | before | now | |
  |---|---|---|---|
  | five layers mixed | 212 ms | 117 ms | 1.81x |
  | Gaussian Blur 5 px | 390 ms | 320 ms | 1.22x |
  | Gaussian Blur 10 px | 267 ms | 181 ms | 1.47x |
  | Gaussian Blur 40 px | 126 ms | 68 ms | 1.86x |
  | Box Blur 10 px | 305 ms | 135 ms | 2.26x |
  | bicubic to 6000 x 4500 | 654 ms | 246 ms | 2.67x |

- **Google Fonts** (`FontFetchHooks.progress`, `stop`): a download says
  how far it has come and can be stopped.
- **Tests**: `test_photoparity` (every new filter, tool, panel and dialog
  of Retro Atelier through its menus and its window's input),
  `test_textcompose`, `test_hyperlinks`, `test_simd`, `test_photoblurs`,
  `test_pathtools`; the IDML, system files, book and perspective tests
  grow.

Retro Atelier 5.4.0: **Filter > Blur > Average, Box Blur, Shape Blur,
Smart Blur, Lens Blur** and the new Filter Gallery filters;
**Layer > New Adjustment Layer > Light**; **Layer Style > Pattern
Overlay**; **Layer > Matting**; **View > Pattern Preview** and **Pixel
Grid**; the drawing program's tools in the toolbar's Vector group (with
their options in the bar), **Window > Brushes (Vector)** and
**Appearance**, **Effect > Distort & Transform, Warp, Repeat**, **Object
> Transform Each**, the Eyedropper taking a shape's whole look, the
three-point perspective grid and the Perspective Selection tool; the
Paragraph panel's **Composer**, **Justification**, **Keep Options**,
**Span Columns**, **Nested Styles** and **GREP Styles** for the
paragraphs the selection is in; **Type > Text Frame Options** with
Balance Columns, Inset Spacing and Vertical Justification; **Paragraph
Style Options** (a double-click on a style: its name, Next Style, keeps,
justification, drop caps and nested styles, GREP styles); **Window >
Object Styles**; **Edit > Spelling > Check Spelling, Dynamic Spelling**
(the system's checker, English and Arabic); **Type > Text Variables**
and **Hyperlinks & Cross-References**; **Window > Bookmarks** and
**Links**; **File > Place Linked** and **Package** (the document or the
book, its linked pictures and fonts, IDML, PDF and a report, in a folder
-- on a phone, the system's folder picker); Google Fonts' progress and
Cancel; every new word in Arabic.

## 0.57.0

Layout and drawing as the layout and drawing programs work them:
footnotes and endnotes, a table of contents and an index, English
hyphenation, objects anchored in text, Find/Change with patterns and the
Story Editor, Data Merge, text frames threaded by their ports and sized by
Auto-Size, a perspective grid, brushes along a path, a real gradient mesh,
ligatures as the Arabic edition sets them; IDML with real tables, notes and
threads; a program run without a window; and painted layers that take
memory only where they are painted.

- **Footnotes and endnotes** (`retroui/textengine`: `Footnote`,
  `NoteOptions`, `insertNote`, `noteMarks`, `tidyNotes`, `noteNumber`,
  `notesAsText`): a reference in the text, numbered (digits, Arabic-Indic,
  Roman, letters, abjad; a first number, before and after it, its size),
  its note at the foot of the box -- the text kept above them, a rule over
  them (its width, length and color) -- or after the text under a heading
  ("Notes", "الحواشي"). A note whose reference is deleted goes with it.
  PSD and SVG carry them as text; IDML as the layout program's own
  footnotes, both ways.
- **A table of contents and an index** (`retroui/booklists`: `tocEntries`,
  `indexEntries`, `tocText`, `indexText`): the headings of a book -- the
  paragraph styles picked, each a level, or the type at a size and over --
  in the pages' order with their page numbers; the words and phrases
  asked for found on their pages as whole words, in any case, Arabic with
  or without its marks, sorted, a heading for each first letter if asked;
  each as a text box (a table of two columns, the numbers at the edge),
  made again when the pages change.
- **Hyphenation** (`retroui/hyphenate`: `hyphenPoints`, `hyphenated`;
  `ParaStyle.hyphenate`): English words broken at a line's end in a box,
  by Liang's patterns (the TeX patterns for American English, Gerard D. C.
  Kuiken's, vendored as `vendor/hyph-en-us.tex`). PSD and IDML keep it.
- **Paragraph styles carry drop caps and the baseline grid**
  (`ParaStyle.gridAlign`): a style put on a paragraph sets them too.
- **Objects anchored in text** (`Layer.anchorTo`, `anchorAt`,
  `anchorToText`, `releaseAnchor`, `anchorOrigin`, `anchorPlaces`): a
  shape, a picture or a frame keeps its place by a character of a text
  and moves with its line as the text changes; kept in the file.
- **Find and change** (`retroui/textsearch`: `compilePattern`, `find`,
  `findAll`, `expand`, `findIn`, `changeIn`): words, or patterns as GREP
  writes them -- digits (Arabic-Indic too), letters, spaces, classes,
  groups, either-or, counts, the fewest, a line's start and end, word
  edges -- found in characters, not bytes; the change with the groups
  ($1), each text keeping its styles. `editPlain`: a text's words changed
  as plain text, the styles kept for what did not change (a story editor).
- **Data Merge** (`retroui/datamerge`: `fieldsOf`, `merged`): a design
  whose text says «Field» (or <<Field>>) and whose frames are named for a
  column with an @ (@Photo), and a table (CSV): each row a copy with the
  fields filled and the pictures the row names placed to fill their
  frames.
- **Text frames as the layout program has them**: text in a box keeps to
  it -- what does not fit is overset, not drawn below it, a line too tall
  for the box too (`TextLayout.overflow`). **Auto-Size**
  (`TextData.autoSize`, `autoRef`, `TextAutoSize`, `autoSized`): the box
  as tall as its text, as wide as its longest line, both, or both in
  proportion, the reference point picked staying; drawn so by `drawText`.
  **Threads** (`followerOf`, `storyHead`, `canThread`, `threadText`,
  `unthreadText`; a book: `storyStart`, `threadPages`, `unlinkPages(...,
  keepText = false)`): a box threaded after another, its own words added
  to the story's end, one put in between; the thread broken, the boxes
  after it empty and the text overset in the box before -- on one page or
  from page to page.
- **IDML**: real tables both ways; footnotes; ligatures, OpenType features
  and hyphenation; columns and Auto-Size read; threaded frames written as
  one story (each frame's previous and next) and read back threaded, on a
  page and from page to page.
- **A perspective grid** (`retroui/perspectivegrid`: `PerspectiveGrid`,
  `defaultGrid`, `onePoint`, `planeQuad`, `gridLines`, `ontoPlane`,
  `pixelsOntoPlane`, `gridToJson`, `gridFrom`; `Doc.perspective`): one or
  two vanishing points, the walls and the floor; a path or a painted
  layer laid on a plane where it is (the corners of its box stay, the
  rest follows the plane). `retroui/photovp`: `onFront`.
- **Brushes along a path** (`retroui/pathbrush`: `PathBrush`,
  `brushedPath`, `builtinBrush`, `BuiltinBrushes`): artwork laid along a
  path -- Art (stretched and bent along all of it), Pattern (copies one
  after another, each bent), Scatter (copies turned with it) -- as
  outlines to fill; eight brushes come with it, any shape's outline is one.
- **A gradient mesh** (`ShapePaint` style 6, `meshCols`, `meshPaint`,
  `meshAt`): a grid of colored points over a shape, each point movable --
  the colors bend with it; in SVG as a picture.
- **Ligatures as the Arabic edition sets them** (`ligaturesOn`,
  `withLigatures`, `featureOn`, `withFeature`, `OpenTypeMenu`): standard
  ligatures on or off (Arabic's required ones stay), and the OpenType
  features a font has; PSD and IDML both ways.
- **A program without a window** (`retroui/headless`: `useHeadless`,
  `headlessInput`, `headlessShot`, `headlessPixels`): its frames drawn in
  memory, the input it is given used -- for a command line, a server,
  tests.
- **Memory**: a painted layer, its copies (Duplicate Layer, a page
  copied) and a layer read back from its file take memory only where
  something is painted (`sparseCopy`; `zeroPixels` gets pages never used);
  the undo history's room shared by the open documents; a closed
  document's last references let go; the heap trimmed while input keeps
  coming; `RETRO_DEVICE_MB` sets the memory a program takes the device to
  have.
- **Tests**: `test_handpass` uses every tool of Retro Atelier's toolbar
  as a person would -- a click, a drag, Shift, Alt and Ctrl, a double
  click, the arrows, a finger's tap, drag and long press, a pen and its
  eraser end -- and undoes it all to the picture it began with; and
  `test_booklists`, `test_datamerge`, `test_textsearch`, `test_headless`,
  `test_perspectivegrid`, `test_pathbrush`.

Retro Atelier 5.3.0: **Type > Insert Footnote, Insert Endnote, Footnotes
and Endnotes**; **Layout > Table of Contents, Index** (and Update);
**Paragraph > Hyphenate**; **Layer > Anchor to Text, Release Anchor**;
**Edit > Find/Change** (patterns, this text, the page or the book) and
**Type > Story Editor**; **Layout > Data Merge** (a preview row, Create
Merged Document); **Type > Text Frame Options** (columns, gutter,
Auto-Size and its reference point) -- the template's titles and headings
grow with their size; a text box picked with the Move tool shows its **in
and out ports** (a triangle when threaded, a red plus when overset): the
out port clicked loads the text, a box clicked takes it, a click or drag
where there is none makes one (on another page of a book too), the port
of a threaded box then the box at the thread's other end -- or a
double-click on the port -- breaks it, Esc lets the text go; the
thread's lines show (View > Show > Text Threads); **View > Perspective
Grid** (Show, Lock, One and Two Point, Define Grid, the planes) with the
plane widget at the view's corner and handles to move the points, the
horizon, the ground, the height and the depth -- the Shape tools draw on
the active plane, **Layer > Perspective > Attach to Active Plane**;
**Path Operations > Apply Brush to Path** and **Gradient Mesh**; the
Character panel's menu **Ligatures** and **Type > OpenType**; **Check
Document** counts the notes; `--headless` (with `--shot OUT.png` for the
window's picture), `--help`; every new word in Arabic. Fixed: the
Channels panel of a page-shaped picture (it failed); the memory of long
sessions (a closed document's pictures kept, each document's undo room
taken as all of the device's).

## 0.56.0

Drawing and layout nearer the photo side: pictures made vectors, type
made shapes, blends, Shape Builder, live shapes, tables, charts and maps,
pictures in shapes and type, a font for Arabic and one for Latin, drop
caps, a baseline grid, export by pages or spreads, IDML, Check Document,
new drawings and books from templates -- and shape and type layers that
take memory only where they draw.

- **Tables** (`retroui/textengine`, `TextData.table`, `TableStyle`): text
  in a box as a table -- each paragraph a row, tabs between its cells,
  each cell's text set in its column (wrapped, aligned, Arabic from the
  right, numbers at the right if asked), the rows as tall as their
  tallest cell; header rows (fill, text color, bold), the rows' fill and
  stripes, lines round it, under the header, between the rows or round
  every cell, their color and width, padding, the columns' widths as
  parts; nine themes (`tableTheme`, `tableThemes`). Fills go under the
  letters (`TextLayout.backs`); a click lands in the cell under it. In a
  PDF with live text, and in SVG (as outlines).
- **A font for Arabic and one for Latin** (`CharStyle.arabicFont`,
  `latinFont`: `ScriptFont`): each script's letters -- and the spaces and
  digits between them -- in a font, style, size, raise, color and
  tracking of their own, as Arabic and English are set together.
  `scriptFontsApplied` gives the text as runs of one font each (the PSD
  writer and IDML use it).
- **Charts and maps for pages** (`retroui/infographics`): `chartSvg` --
  columns, bars, stacked, lines, areas, pies, donuts, radar -- in nine
  themes, every part set (title, subtitle, legend, grid, axes' names,
  value labels, decimals, before and after the numbers, Arabic digits,
  fonts and sizes, corners, gaps, line widths, dots, smooth lines, a
  donut's hole, a card behind, right to left); `mapSvg` -- the world or a
  part of it (ten regions, or the countries named) in three projections
  (Equal Earth, Mercator, Plate Carrée), countries colored on a scale by
  their values or as chosen, names, numbers, cities, a scale, a
  graticule, in seven themes. Placed (`placeSvg`), their parts are shape
  and type layers. Their settings as JSON (`toJson`, `chartFrom`,
  `mapFrom`); the numbers from a table (`chartData`, `mapValues`).
  `retroui/mapview`: `countryRings`, `countryLabelAt`, `countryCodeAt`.
- **Pictures in shapes and type** (`retroui/photowarp`, `contentQuad`,
  `FrameFit`): a placed picture fitted to its frame -- Fill Frame
  Proportionally, Fit Content Proportionally, Fit Content to Frame,
  Center Content, Original Size -- then scaled, turned, moved, flipped.
- **Live shapes** (`retroui/liveshapes`): twenty shapes drawn from a few
  numbers that can be changed again (arrows, chevrons, speech and thought
  bubbles, badges, ribbons, hearts, gears, polygons and stars with round
  corners, rectangles with each corner its own, crosses, rings,
  triangles, parallelograms, trapezoids, tags, pies, blobs):
  `liveShapePath`, `paramsOf`, `defaultParams`.
- **Shape Builder** (`shapeRegions`, `buildShapes`): where shapes overlap,
  each a region; the regions picked made one shape, others taken away,
  each shape what is left (traced and fitted with curves).
- **Freeform gradients** (`ShapePaint.points`, style 5, `freeformPaint`,
  `freeformAt`): colors at points of a shape, blended smoothly between --
  the look of a gradient mesh (the points do not bend a grid).
- **Blends** ease their steps and their colors apart (`BlendEase`,
  `eased`).
- **Export by pages or spreads** (`retroui/photobook`, `exportBook`,
  `BookExport`, `pageList`, `exportSheets`): a book's pages, all or a
  range ("1-3, 5, 8-"), as pages or as spreads (facing pages one sheet),
  into one PDF -- `retroui/photopdf`'s `addSpreadPage` puts pages side by
  side, the marks round the spread, each page's bleed only past its outer
  edges -- or a JPEG or PNG a sheet, at a resolution of its own.
- **IDML** (`retroui/idml`): a book as the exchange package the page
  layout program opens -- spreads, masters (the page number as its own),
  text frames and their stories (fonts, sizes, colors, alignment,
  indents, direction, drop caps), rectangles, ovals and polygons, a layer
  of one color as a filled frame (white paper left out), the rest as
  linked pictures (`saveBookIdml`, `saveDocIdml`) -- and read back
  as a book (`readIdml`: pages, text frames, shapes, linked pictures).
- **Check Document** (`retroui/preflight`): text that does not fit and
  goes nowhere, fonts not here, pictures too coarse as placed, empty
  frames, type too near the edge, hidden and empty layers, a resolution
  under the print's -- for a document or every page of a book.
- `Layer.meta`: what an app keeps with a layer (kept by undo and in the
  file).
- Vibrance takes Temperature and Tint (`vibranceFn`; the adjustment
  layer's third and fourth numbers).

- **Image Trace** (`retroui/imagetrace`): a picture made filled vector
  shapes that look like it -- `traceImage(px, w, h, options)`, one shape
  a color, from the biggest up, each with its holes; in color (k-means++
  colors), grays or black and white; stacked (no gaps between shapes) or
  side by side; specks under `noise` pixels left out, the outlines
  fitted with curves (`paths`, `corners`), white left out (`ignoreWhite`)
  or softened first (`blur`). Ten presets (`tracePreset`: 3, 6 and 16
  colors, photos, grays, a logo, sketched art, silhouettes). A big
  picture is traced smaller and the shapes scaled back (`maxSide`).
  `tracedSvg` writes them as SVG. A 1080 x 1350 flat illustration in 6
  colors: 0.14 s.
- **Pencil Sketch** (`retroui/photoartistic`, `pencilSketch`): a photo
  as pencil lines on paper (its edges drawn, its flat parts paper), its
  colors kept as much as asked.
- **Type made shapes** (`retroui/photovector`, `textShapes`): Convert to
  Shape / Create Outlines -- one shape a color, its letters outlines of
  curves fitted within a fifth of a pixel, placed as drawn (on a path,
  warped, vertical); faux bold a stroke.
- **Blends** (`blendShapes`, `colorSteps`): the shapes between two --
  outlines, fills, strokes and their widths in even steps; outlines of
  the same points mixed point by point (their curves kept), others
  walked along at even distances, a hole shrinking away; Smooth Color
  works out the steps the colors need.
- **Drop caps** (`ParaStyle.dropLines`, `dropChars`): the first
  paragraph's first letters as tall as so many lines, from the first
  line's capitals to the last one's baseline, the lines beside them
  standing in -- at the right for Arabic. Not where the text goes on in
  another box.
- **The baseline grid** (`TextData.gridStep`, `gridStart`): Align to
  Baseline Grid puts every line of a text on the next grid line down.
  A book has one (`BookSetup.baseline`, `baselineStart`; `gridLines`,
  `alignToGrid`); Document Setup changing it moves the text on it.
- **Snapping in a book** (`snapLines`): boxes snap to a page's margins,
  its columns' edges and its baseline grid.
- **New drawings and books from templates** (`retroui/layouttemplates`):
  blank presets by kind (icons, logos, web, social, print, illustration;
  books, magazines, brochures, social cards) and ready-made ones --
  `drawingTemplates` (a badge logo, a flat landscape, an app icon, an
  event poster, a business card, a quote post: SVG whose parts open as
  layers) and `bookTemplates` (a novel, an Arabic book, a magazine with
  a band across a spread and text through its pages, infographic cards
  in English and Arabic: each a book with masters and page numbers).
- **Shape and type layers are light** (`retroui/photo`): a new layer's
  pixels are memory the system gives as zeros, and drawing a shape or
  text clears only what is not zero already (`clearSet`) -- so a layer
  takes memory only where it draws. Twenty shapes and ten captions on an
  A4 page at 300 ppi: 700 and 1,030 MB before, 59 and 63 MB now. The
  composite mixes such a layer only in the box it drew
  (`compositeSpans`): 330 ms before, 52 ms now for twenty small shapes;
  the same picture, every way a layer is mixed (modes, opacity, masks,
  clipping, groups, effects, the sampled view; `tests/test_photospeed`).
  A shape or type layer just made is known to be all zeros
  (`addLayer(fresh = true)`, `freshPixels`): its first drawing clears
  nothing and is mixed again only where it drew -- a chart of 45 shape
  and type layers placed on that page in 24 ms instead of 458.
- Books: a new layer goes over the master's layers and the facing
  page's parts, not under them.
- Retro Atelier 5.2.0: Image > Image Trace (presets, a preview that
  follows the settings, the colors, Save as SVG; the shapes in a group,
  the picture hidden under them, one step). Filter > Sketch > Pencil
  Sketch. File > New Drawing (SVG) and File > New Book as today's New
  dialog: tabs by kind, presets, templates with their pictures. Type >
  Convert to Shape (Layer > Rasterize > Type to Shapes; its opacity,
  mode, style and mask kept). Layer > Path Operations > Make Blend
  (between two picked shape layers, or the current one and the shape
  under it; Smooth Color or so many steps; in a group with them).
  Paragraph: drop cap lines and letters; Align to baseline grid (on a
  book's page). Document Setup: the baseline grid. Layout > Baseline
  Grid shows it. Boxes drawn on a page snap to its margins, columns and
  grid. Shortcuts as the usual apps have them: Ctrl+Shift+O Convert to
  Shape, Ctrl+Alt+B Make Blend, Ctrl+7 Create Clipping Mask,
  Ctrl+Shift+P Add Page, Ctrl+Alt+Shift+N Insert Page Number. The new
  words in Arabic.
- Retro Atelier 5.2.0, more: Layout > Export (PDF, JPEG or PNG; all or a
  range; pages or spreads; the PDF's General, Compression, Marks and
  Bleeds, Output and Summary under a preset), Save Book as IDML, Open an
  .idml; Save As .ai (a PDF its drawing program edits) and .idml; Type >
  Insert Table, Table Options (a theme gallery, header, fills, stripes,
  lines, padding, widths), Convert Text to Table and back, Tab from cell
  to cell (a new row after the last); Character: fonts for Arabic and
  Latin; Layout > Insert Chart and Insert Map (a dialog with a preview;
  Edit Chart or Map makes them again); Layer > Fitting (and Frame
  Options); Layer > More Shapes and Shape Options (live); Path Operations
  > Shape Builder and Freeform Gradient; Blend Options' easing; Layout >
  Photo Grid, Resize for (a design at many sizes, each a document),
  Brand Kit (colors, fonts, logo), Recolor Design (eight palettes), Check
  Document; Type > Text Effects (shadow, lift, hollow, outline, neon,
  echo, glow, curve); Vibrance: Temperature and Tint. The command line:
  `--run "Command"`, `--script file.rs`, `--list-commands` -- the same list
  of commands as the menus, Edit > Search and scripts (`app.commands`).
- `tools/benchphoto.nim` times the new work too. On a 12-megapixel
  image, two cores: sixty small shape and type layers take 86 MB (a
  layer of all of it would be 48 MB each) and are mixed in 12.5 ms;
  Image Trace of a 1200 x 900 picture, 0.13 s in 6 colors, 0.18 s in
  16; Pencil Sketch of a layer, 0.33 s; a line of type made shapes,
  0.5 ms; a blend of 64 steps, 0.2 ms.

## 0.55.0

Objects across the spine of a book, and Retro Photo's new name.

- **Objects across the spine** (`retroui/photobook`): type, a shape or a
  placed picture (a Smart Object) of a page that reaches past the spine
  goes on, on the facing page -- as one object does on a spread.
  `syncSpread(i)` keeps the two pages one spread: the object's other
  part is made on the facing page (a copy the book keeps there, locked,
  under that page's own layers: `Layer.fromSpan`), and made again when
  the object moves or changes; an object moved wholly past the spine is
  the facing page's own from then on. Each page, and each page of the
  PDF, has its half; a text box across the spine has the same lines on
  both. `fullBox(d, L)` (`retroui/photo`): where all of a layer's object
  is, past the image's edges too. A layer of pixels has nothing past its
  page's edge: place the picture (File > Place) to have it across.
  `bookSmartFilter`: how a placed picture's Smart Filters are done there.
- **Lists** (`retroui/textengine`): text in a box as a list
  (`ParaStyle.list`): a mark before every paragraph that says something,
  its lines standing in from it, at the right for right-to-left text.
  Bullets of any letters the font has (`listMark`: "•", "–", "▪", "◆",
  "★", "✓"), or numbers in any `NumberStyle` (digits, Arabic-Indic,
  Persian, Roman, letters, abjad: `listNumbers`, `listStart`,
  `listSuffix`), in a color of their own (`listColor`), kept with the
  text, in columns and round holes, in the PDF. `NumberStyle` and
  `formatNumber` are the type engine's now (`retroui/photobook` still
  gives them).
- **A text that ignores Text Wrap** (`Layer.ignoreWrap`): a caption on a
  picture, a pull quote on its panel.
- Fixed: a text of no spans in a box (a box that takes what did not fit
  another, when all of it fit) stopped the type engine.
- **Retro Photo is Retro Atelier** (5.1.0): photo, drawing and layout in
  one. The app's name, its window, its package's label and its files'
  names (`RetroAtelier.apk`, `RetroAtelier.exe`) change; its package id
  (`org.retro.photo`: it installs over Retro Photo), its settings'
  folder, its documents (.rpd, .rpb) and the kit's modules
  (`retroui/photo...`) do not.
- Retro Atelier: Paragraph > List (None, Bullets, Numbers; the mark, the
  numbers' style, the first number, what follows it, the marks in the
  foreground color); Layout > Text Wrap > This text ignores Text Wrap.
- Retro Atelier: the spread is kept as you work (the part on the facing
  page appears when the mouse is let go; the status bar says when an
  object became the facing page's); the facing page beside the canvas
  is drawn sharper; a click on a part or on a master's layer says where
  it is from.
- `examples/book.nim`: a band across a spread.
- **Nim 2.4** builds the apps: it refuses a loop variable kept by a
  nested proc, which Nim 2.2 allowed (Retro Atelier's web build stopped
  at it; Retro Board had five). Each such loop has a copy of its own
  now. `tools/lentfix.py` finds and fixes them: only a real build says
  so, not `nim check`. Every example, tool and test is built to C with
  Nim 2.4.2 as well as 2.2.6.

## 0.54.0

Layout: books and magazines in Retro Photo, with the engine for them in
the kit -- pages, facing pages bound on either side, master pages, page
numbers, text that goes on from page to page and keeps out of pictures.
Arabic set finer. And on a phone, the system's own file picker.

- **Books** (`retroui/photobook`, new): a `Book` is its pages, each a
  `Doc` of the image editor's engine, and what makes them a book.
  - Pages added, taken out, moved, copied (`insertPage`, `deletePage`,
    `movePage`, `duplicatePage`); single or **facing** (`sideOf`,
    `partner`, `spreadOf`), bound on the left or, for Arabic and Hebrew,
    on the right (`bindRight`: the first page is a left page, a spread
    reads from the right). Margins, inside and outside swapping on facing
    pages (`marginBox`, `columnBoxes`); `bookSetup` from millimeters,
    `BookPapers`.
  - **Master pages** (`addMaster`, `masterDoc`, `setMaster`): what is on
    a master is on every page that has it, locked, under the page's own;
    a left and a right one for facing pages; change the master and the
    pages follow when they are next turned to.
  - **Page numbers**: `<#>` in any text is the page's number, `<##>` the
    number of pages (`Doc.pageLabel`, `pageTotal`; shown as written while
    typed: `Doc.rawText`). From a first number, started again at a page
    (`restart`), as digits, Arabic-Indic or Persian digits, Roman
    numerals, letters or abjad (`formatNumber`, `label`).
  - **Text from page to page**: `flowOnto` makes a box on another page
    that takes what does not fit a box; `autoflow` adds pages until a
    long text is all set; `reflow` sets it again through the book;
    `unlinkPages`.
  - Only the pages looked at are in memory; the others are parked as
    files (`park`), so a book may be long. `thumb`, `pagePicture`,
    `spreadPicture` for pictures of pages.
  - One file (".rpb", `saveBook`, `loadBook`: a zip of the pages as
    ".rpd" documents; a damaged one is refused) and a PDF of all pages,
    type as type (`saveBookPdf`; `newPressPdf` in `retroui/photopdf` for
    documents made a PDF one after another).
- **Text Wrap** (`retroui/textengine`, `retroui/photo`): text in a box
  keeps out of what is in its way. `TextData.holes` (rectangles its
  lines keep out of): a line beside a hole goes on at its other side on
  the same baseline, a word is not broken to fit beside one, columns keep
  out too. A layer has `wrap` (round its box, round its shape row by row,
  or jumped over), `wrapSide` (both sides, its left, its right, the side
  with more room) and `wrapGap`; `wrapHoles`, `rewrap` (after a step, an
  undo). A layer at Opacity 0 still wraps: a shape drawn with the Pen is
  a wrap of any outline.
- **Arabic set finer** (`retroui/textengine`), after what Tasmeem gave
  InDesign: the room between words (`CharStyle.wordSpace`); the tashkeel
  in a color of its own, raised or lowered, or left out (`markColor`,
  `markRaise`, `noMarks`); and `alternatesFor(word, style)`: the shapes a
  font has for a word -- its stylistic sets, swashes, the other forms of
  a letter and of its joins -- each to turn on. (Kashida lengths, digits
  and OpenType features were there.)
- **The system's own file picker on Android and iOS**
  (`retroui/systemfiles`, new): after `systemFiles(true)` the kit's
  `fileDialog` and `filePicker` show the phone's picker to open a file
  and to name one to save -- the storage, an SD card, Drive, any app
  that offers its files -- and an app's code stays as it is. The
  document picked is given as a copy in the app's cache; what the app
  writes there is written back into the document by itself (Android: a
  later Save goes to the same document without asking; iOS: Files asks
  where). No access to the storage is asked for. Nothing changes on a
  desktop, in a web page (the browser's chooser was there) or for an app
  that does not ask for it.
- **Retro Photo 5.0.0**
  - **File > New Book**, the **Layout** menu and the **Pages** panel: a
    book in one window, its pages turned (Shift+Page Down and Up, a click
    on a page in the panel or on the facing page beside the canvas),
    added, copied, moved, taken out; Document Setup; masters worked on
    like pages; Insert Page Number; Start Page Numbers Again Here; Flow
    Onto the Next Page and Autoflow Through New Pages; the margins and
    columns drawn over the page. Save writes the book (".rpb"), Export
    Book as PDF all its pages; File > Open opens one.
  - **Layout > Text Wrap** for any layer.
  - **Window > Workspace: Photo, Drawing, Layout**: the panels and the
    toolbar set out for the work (the tools not needed are under "...").
  - **The Move tool dragged from where nothing is** draws a box: the
    layers it touches are picked, to move, align and group together
    (Shift: with those picked before).
  - **Character**: Word space, Tashkeel (as the letters, in the
    foreground color, hidden; raised). **Type > Word Shapes**: the font's
    other shapes of the word selected, each drawn, a click to have it.
  - On Android and iOS, Open and Save As are the system's picker.
  - The caret of text beside a wrapped picture is where the letters are.

## 0.53.0

SVG, the rest of it: filters, patterns, masks, blending, every way of
placing type -- read, drawn, made layers, written back; and what an SVG
has no word for kept in it for Retro Photo. A window that never waits for
a disk, and says where it waited when it does.

- **The window never asks a disk anything itself** (Retro Files stuck in
  some folders on Windows, and on Exit). The file widgets asked the disk
  on the window's own thread, again and again: every drive letter probed
  every five seconds, the free space every three, the folder's date every
  second and a half, each folder of the tree looked into, the start of a
  text and a picture's size read for the details pane. A disk that is
  slow to answer -- a mapped network drive that is not connected, a cloud
  folder, a card being read -- held the window for as long as it took,
  Exit with it. Now:
  - `later(what, path)` (`retroui/background`): what the file system says
    -- has a folder folders, which, a disk's free space, a folder's date,
    is a path there, the start of a file, a picture's size (`AskKind`) --
    answered at once with what is known and asked on a thread; a frame is
    drawn when the answer comes. `askNow` for what the user asked for (a
    folder to go to): waited for a second and a half at most. `tellLater`,
    `forgetLater`.
  - Folders are listed and questions answered on threads of their own
    (two; more, up to eight, when those are held up), not on the ones
    that decode pictures: a folder shows while thumbnails are still being
    made, and a question no disk answers holds up nothing else.
  - `folderTree`, `driveBar`, `placesView`, `pathBar`, `filePreview`,
    `diskSpaceCached` and the folder model (`fileList`, `filePicker`) ask
    so. On Windows the drives are those Windows lists
    (`GetLogicalDrives`): none is probed.
  - **Cloud files that are not on the disk** (OneDrive's Files On-Demand)
    are known (`FileItem.offline`, `offlineFile`): no thumbnail, no
    preview fetches one; opened, it goes to the system, which fetches it
    and opens its program. A Windows folder is listed without opening
    each file (`GetFileAttributesEx`): faster, and nothing is fetched.
  - Retro Files goes to a folder, and opens its saved tabs at the start,
    without waiting on a disk longer than a second and a half.
- **A window that does not answer says where it waited** (Windows,
  `retroui/hangwatch`, started with every app): when the window has not
  taken its messages for five seconds, the procs its thread is in go to
  the fault log -- by name: `nimble exe` puts the table of the program's
  procs at its end (tools/winsym.py) -- and the next start's "Report a
  Problem" box shows them, to copy or send. A program still there thirty
  seconds after its window closed is ended.

- **Drawn as other programs draw it.** `rasterizeSvg` is compared with
  resvg on 53 new drawings (tests/data/svg/fx-*.svg: each with a .png of
  it as resvg draws it), beside the 12 icons and flags it was compared on.
  - **Filters**: every step of them -- feGaussianBlur, feOffset, feFlood,
    feComposite (arithmetic too), feMerge, feBlend, feColorMatrix,
    feComponentTransfer, feDropShadow, feMorphology, feTile, feImage (a
    picture, or something else in the drawing), feConvolveMatrix,
    feTurbulence (the specification's own noise, stitched too),
    feDisplacementMap, feDiffuseLighting and feSpecularLighting (a far
    light, a point of light, a spot) -- in linear light as a filter is
    unless it says sRGB (`color-interpolation-filters`, on the filter or a
    step), each step in its own rectangle (x, y, width, height), a filter
    that goes on from another (href); CSS's `blur()` and `drop-shadow()`.
    A blur is the specification's three box blurs, or the bell itself when
    it is small.
  - **Patterns** (units, patternTransform, viewBox, href; a pattern in a
    pattern), as a fill or a line; a turned one drawn between its tile's
    pixels.
  - **Blending modes** (`mix-blend-mode`, feBlend): the sixteen, hue,
    saturation, color and luminosity among them.
  - **Type**: a letter where the file puts it -- x, y, dx, dy and rotate
    as lists, on the text or its tspans; `textLength`; `word-spacing`; an
    outline (stroke) over its fill, or alone (fill: none); a gradient or a
    pattern as its fill; `direction: rtl`; `writing-mode` running down,
    the letters on their side about the middle of their height;
    `font-variant: small-caps`, `text-transform`. Text is set on any
    thread now (a thread other than the first has the kit's three fonts):
    **an SVG's thumbnail in Retro Files has its text**.
  - Pictures that are SVGs themselves; `display: none` and `visibility:
    hidden`.
- **Retro Photo 4.12.0: an SVG opens as it looks, and as layers.**
  - A filter that is a plain drop shadow (feDropShadow, or the blur,
    offset, flood and merge drawing programs write for one) is the layer's
    **Drop Shadow**; any other filter makes its layer pixels, drawn as the
    filter draws it. A pattern is a **pattern fill** (a turned one on a
    tile the size of its shape). A mask or a clip path is the **layer's
    mask**. A blending mode is the layer's. A group with a name, or of
    several things under one opacity, mask or mode, is a **group** with
    them. What is hidden is a layer that is off.
  - Type: an outline is the layer's **Stroke**, outlined alone it is the
    Stroke with Fill at 0; a gradient is a **Gradient Overlay**; letters
    with places of their own are one text spaced to fit; a turned letter
    is a text of its own; running down is vertical type.
  - **File > Save** writes all of it back: masks and clipping masks as
    masks, Drop Shadow and Outer Glow as a filter, a type layer's Stroke
    and Gradient Overlay as its stroke and fill, pattern fills as
    patterns, layers that are off as hidden. **What an SVG has no word
    for is kept in it for Retro Photo** -- every layer effect (Bevel and
    Emboss, Inner Shadow, Satin...) with the layer's Fill, the blending
    modes CSS has no name for, adjustment layers -- in attributes of its
    own (`data-retro-fx`, `data-retro-mode`, `data-retro-adjust`): Retro
    Photo opens them again as they were; other programs do not show them,
    and the status bar says which those are (`svgOwn`).
  - **File > Export > SVG, Type as Outlines**: the letters as paths, for
    where the fonts are not (`svgOf(outlines = true)`).
  - `retroui/svgimport`: `SvgDoc.patterns`, `filters`, `groups` (their
    opacity, mask, filter, blending, name); `SvgFilterPrim`; `SvgText`'s
    `places`, `hollow`, `stroke`, `fitChars`, `vertical`, `rtl`;
    `svgShadow`, `svgRaster`, `svgMask`; `parseSvg(data, base, hidden =
    true)` and `placeSvg(..., hidden = true)` keep what is not shown.
    `retroui/photosvg`: `svgOwn`. `retroui/textengine`: `typeWorker()`.
- **Retro Files 3.6.0**: it no longer waits on a disk (above); cloud
  files that are not on the disk are left there until they are opened;
  an SVG's thumbnail and preview show its text, patterns and filters. A
  device or a pipe (`/dev/...`, a FIFO) is said to be one and is not
  opened: reading it would never end (`FileItem.special`, `specialFile`).
- **The nightly soak** (0.51.0's failed for three apps): Retro Task
  Manager no longer ends or reprioritizes a process under random input
  (it ended the soak's own shell); Retro Files does not read devices and
  pipes; Retro Podcast keeps eight shows at most under random input.

## 0.52.0

A look of your own, by the controls' options; ten colour schemes for
phones; SVG as a format of Retro Photo, read and written.

- **Controls that take a look** (docs/customizing.md, new: changing a
  control by its options, putting controls together, drawing one, changing
  the kit):
  - `button(..., accent = true)`: the button that matters, in the scheme's
    accent (`Theme.accent`, `accentText`; the highlight's where a scheme
    names none; `accentColor()`, `accentInk()`, `accentTheme()`).
  - A text style and a height: `button(..., style = style(bold = true,
    size = 1.3), h = 42)`, and `h`, `style` on `edit`, `spin`, `intEdit`
    and `numberEdit` -- large digits in a tall box, the spin's arrows
    grown with it. `labelWidth(label, st)` and `drawLabel(x, y, label, c,
    st)` measure and draw a label with its underlined letter at any size.
  - `withTheme(t): ...` draws a part in another scheme's colours;
    `withTextStyle(st): ...` sets the text of everything drawn in it
    (styles multiply; both put back what was, after an error too).
  - `group "Title", glCaption: ...`: a raised panel under a title strip in
    the highlight's colour (`GroupLook`; `groupLook = glCaption` for every
    group and card; `beginGroup(title, look)`, `raisedPanel`,
    `captionStrip`).
  - `radio(label, v, value, boxed = true)`: the option in a box that takes
    the press anywhere, tinted when it is the one chosen.
  - `gauge(title, value, lo, hi, bands)`: a dial in bands of your own
    (`Band`: where it ends, its name, its colour, its share of the dial),
    the number in a style of your own; `rangeBar(bands, value, lo)`: the
    bands as a bar of cells, a marker over the value's; `bandOf`.
  - **State colours in every scheme**: `goodColor()`, `warnColor()`,
    `badColor()`, `infoColor()` and `goodBack()`... behind text
    (`Theme.good`... where a scheme names its own). `banner`, `usageBar`,
    the gauge's bands and the range bar are drawn in them, so they follow
    Dark and the rest.
  - The 3.1 title bar: `app(..., captionIcon = true, captionAlign = caLeft,
    captionStyle = style(bold = true, serif = true, size = 1.35))` -- the
    app's icon in it, the title large at its left; the bar as tall as its
    title.
  - `pill(text, colour, glyph)`: a tag with an icon; it follows
    `withTextStyle`. `nfCalculator` in the icon font.
- **The tool bar**: `toolSeparator(line = true)` is an etched line between
  groups (plain: the gap it was), `toolSpace(20)` room of your own, and
  `toolSpace()` all the room the bar has left: what follows it is at the
  bar's right end (a Help button, a search box). Too narrow a bar puts
  them in its "more" menu as before.
- **Ten colour schemes for a phone's screen**, from white to dark, in
  `builtinThemes` (28 now) and so in `appearanceSettings` and every app's
  theme menu: Notes (a notepad's cream paper, an amber marker), Snow,
  Mint, Sky, Blossom, Lavender, Sunset, and the dark Graphite, Dusk and
  Night Notes. Every scheme's text is tested readable (4.5 to 1) on its
  window, fields, buttons, highlight and accent button.
- **BMI Studio** (`examples/bmi.nim`, `nimble bmi`, `RETRO_APP=bmi nimble
  appapk`): a body mass index calculator whose window has a look of its
  own -- the title bar with its icon, panels with title strips, options in
  boxes, large digits, the navy accent button, a dial in four bands, the
  classes as a range bar -- made of the kit's controls by their options,
  in its own colours or any of the kit's schemes (View > Colours). The
  worked example of docs/customizing.md.
- **Retro Photo 4.11.0: SVG, read and written.**
  - An .svg opens as layers: its shapes as shape layers (as before), **its
    text as type that can be typed in** -- font family (the one there is,
    else FreeSans, FreeSerif or FreeMono by its kind), size, bold and
    italic, colour, letter spacing, underline, each run in its own look;
    lines one under another as one text with its leading; text-anchor;
    turned text and `textPath` as text on a path -- **its pictures as
    layers of pixels** (PNG, JPEG, WebP in the file, or a file beside it),
    and **its named groups as groups** (a `<g>` with a `data-name` or an
    `inkscape:label`). A drawing opens at its own size (an icon, 1024
    pixels across, as before).
  - **File > New SVG Drawing** starts one; **File > Save** writes an SVG
    back (File > Save As has .svg): shapes as paths (a stroke inside or
    outside its outline kept as one), type as text with a tspan a run, text
    on a path as a `textPath`, groups as `<g>`, layers under their names,
    opacity and the blending modes CSS has, a one-colour Background as a
    rectangle. What an SVG does not hold -- adjustment layers, layer
    effects, masks on shapes and type, clipping masks -- is said in the
    status bar (`svgLosses`). What is written opens again as the same
    layers.
  - For a picture or for print: File > Export As (PNG, JPEG, WebP...),
    File > Save as PDF (the shapes vectors, the type type) and File > Print,
    as for any document.
  - `retroui/svgimport`: `parseSvg(data, base)` gives `texts`, `images` and
    `groupNames` beside the items; `svgPieces` (shapes, texts and pictures
    in their order), `svgTextData`, `svgFont`, `drawImageInto`;
    `rasterizeSvg` draws pictures, and text on the thread that draws (a
    thumbnail decoded on a worker has an SVG's shapes and pictures, not its
    text). `retroui/photosvg`: `svgLosses`.
- **0.50.0's CI** (fixed in 0.51.0, which this release carries): the test
  APK is in the commit, retroapk compiles as a 32-bit program.

## 0.51.0

- **The focus ring of today's Windows, in 3.1's colours**: while the
  keyboard moves about (Tab, Shift+Tab, F6, the arrows) the control with
  the focus wears an outline two pixels wide in the scheme's highlight
  colour -- navy in the classic one -- with 3.1's dotted rectangle still
  inside it. A click takes the focus without a ring, and any press of the
  mouse takes the ring away; an arrow pressed after it (a list clicked,
  then walked) brings it back; the arrows in a text box move its caret
  and bring none, nor do those in an open menu. It is drawn once, at the
  frame's end, round whatever control has the focus -- buttons, text
  boxes, lists, check boxes, radios, sliders, spin boxes, tabs, the grid,
  an app's own (`tabStop`, `focusAt`) -- clipped as the control is, and on
  the control's own edge where a panel would cut it off. Not in a window
  that is not the active one. `focusRing = false` keeps 3.1's focus alone;
  `ui.focusCues` says whether the keyboard is moving about. A list, a grid
  or a text area with a scroll bar has it round the whole of it
  (`focusFrame`).
- **0.50.0's CI, fixed**: the APK the new tests read (`tests/data/apk/notes.apk`)
  was not in the commit -- `.gitignore` leaves every `*.apk` out -- so
  `test_apkinfo` and `test_filesapp` failed on Linux, Windows, macOS and
  as 32-bit programs; it is in now (`!tests/data/apk/*.apk`). `retroapk`
  did not compile where an `int` has 32 bits: the widget's colours
  (#FFDFDFDF) do not fit one (`colorAttr`). A release is checked from a
  clean clone from now on (AGENTS.md).

## 0.50.0

Android, all the way: apps on the home screen (widgets) and in the quick
settings, in the other apps' share sheets, with buttons on their
notifications; a camera that stands up and takes full-size photos with
the zoom, the flash and the focus; Retro Files opening and installing
APKs and much more inside; Retro Photo laid out for a phone.

- **Retro Files 3.5.0 opens much more inside**: an app's package (.apk)
  shows its icon, name, version, package, the Android versions it runs on,
  its permissions, activities and services -- and on Android **Install**
  hands it to the system's installer (the first time Android asks to allow
  it: its setting opens); tar archives (.tar, .tar.gz, .tgz) open as zip
  files do and Extract all; web pages, fonts (a sample sheet), 3D models
  (glTF, GLB, OBJ, STL), spreadsheets (.xlsx, .csv, .tsv, a sheet at a
  time) and mail (.eml: its header, text and attachments) open in the
  viewer. **One details pane** (Alt+P) in place of the preview pane and
  View as Web Page, which showed the same thing twice. Files shared from
  another app wait in a bar until **Save here** copies them into the
  folder open.
- **`retroui/apkinfo`**: `readApk(path)` reads an APK without installing it
  -- its binary manifest and resource table, the label in the user's
  language, the densest icon (an adaptive one's foreground) -- every read
  bounds-checked, no sum of sizes past a 32-bit int (`tests/test_apkinfo.nim`:
  an APK made by aapt2, and 3,000 damaged copies of it, as a 32-bit program
  too). **`retroui/tar`**: ustar, GNU long names and pax
  headers, gzip members; `jkUnzip` extracts them, links left out.
- **Home-screen widgets** (`retroapk --widget`, `homeWidget(title, text,
  buttons)`): the app's icon, a title, a line or two and two buttons, in
  3.1's colours, kept while the app is closed; a button's press comes as
  `notificationActions()` with the tag "widget". retroapk writes the
  layout, the ids and the widget's info into resources.arsc and, for
  Google Play, into resources.pb (checked with aapt2 both ways). **Retro
  DNS 1.3** turns the VPN on and off from it, **Retro Podcast 1.2.0**
  plays, pauses and skips ahead.
- **Retro DNS 1.3: a tile in the quick settings** that turns the VPN on
  and off with the server last used, in the VPN's own process (the app
  opens when Android's consent is still to give), and **a graph** of each
  server's speed over its last 30 tests, and of the lookups while the VPN
  is on.
- **Notifications with buttons**: `notify(..., actions = ["Mark as
  read"])` (Android: up to three) and `notificationActions()` for the
  presses; Retro Mail 1.1.6 marks the new mail read from its notification.
- **In the other apps' share sheets**: Retro Files (anything), Retro Photo
  (pictures: "Edit in Retro Photo"), Retro Board 1.5.1 (a text comes as a
  note, a picture as a picture) and Notepad (text: a new document, or at
  the caret).
- **The camera on Android** stands up as the phone is held (the
  pictures came as the sensor lies, on their side in portrait); a photo is
  a JPEG at the sensor's whole size; two fingers on `cameraView` zoom and
  a tap focuses there; `cameraCaps`, `cameraZoom` (under 1: the wide lens
  on Android 11+), `cameraFlash` (off, auto, on, the torch),
  `cameraFocus`, `cameraExposure`; `cameras()` names each lens with its
  focal length. Retro Gallery's camera card has them.
- **Retro Photo 4.10.0 on a phone held upright**: the picture fills the
  screen between a bar (the menus behind one button, Undo, Redo, Open,
  Save, the pictures open) and the tools in rows at the bottom (held, a
  group's others); the panels slide up under the picture; two fingers zoom
  and move it (`photoView`); the phone may turn (a tablet, or the phone
  turned, keeps the workspace).
- **The menu bar goes onto a second row** when its menus do not fit the
  window's width (they ran off its edge on a phone).
- **A web page at rest costs a frame a second**, not four (`webView` with
  the system's engine: four a second for ten seconds after the page last
  changed, then one): Retro Navigator 0.5.1. Under the soak's random input
  Navigator keeps eight tabs at most and Retro Board starts a new board
  past 400 shapes, and both are soaked every night again, ten apps in all.
  Navigator is soaked on the kit's engine (it follows `RETRO_WEB=kit` now):
  on WebKitGTK its memory grows by some 20 MB a minute under random input,
  the same with the GPU's compositing off, and levels off at 90 MB on the
  kit's. A page closed on WebKitGTK no longer keeps its script and its
  content manager (each was held once more than WebKit needs).
- **Firebase Test Lab, step by step** (BUILDING.md): the project, the
  service account and its role, the secret and the variable the real
  phones' workflow needs -- and that Google ends Test Lab in September 2027.
- **Tests**: `test_apkinfo`; `test_apk` builds the widget's resources both
  ways and has aapt2 read them; `test_filesapp` opens each new kind of
  file in its viewer (an APK, a tar.gz extracted, a page, a font, a model,
  a CSV, an .xlsx, a message); the Android script shares text only with
  apps that take it.

## 0.49.0

Faster and steadier: the tests as many at once as there are cores (a
flaky one named), apps soaked under random input every night (the soaks
found a fault each in Retro Files and Retro Board), the fonts 12 %
smaller, Retro Board moving zoomed in on thousands of notes, and JSON
from outside that never stops a program.

- **Retro Board 1.5.0 zoomed in on thousands of readable shapes**: making their
  drawings takes 8 ms of a frame at most (`startDrawing`, `drawingFor`,
  `behind`); the rest are drawn in brief for a frame or two and made in the
  next ones -- 972 notes in view: the first frame in 28 ms, not 173, all of
  them drawn in full by the 8th frame. A shape's brief drawing goes once its
  full one is made (both kept could pass `drawingBudget` and be made again
  each frame); a note's brief drawing no longer measures its words. Next
  step (Ctrl+Right, Ctrl+Down) pressed while a text left empty was typed in
  no longer stops the app (the soak found it).
- **The fonts 12 % smaller, packed with LZMA** (`retroui/lzma`, the kit's
  own decoder from the LZMA specification; `tools/packlzma.py`): every app
  118 KB smaller (Hello 2.23 MB -> 2.11 MB). The faces every program
  unpacks as it starts (the UI's text, its bold, the icons) stay zlib,
  five times as fast to unpack, and so do Retro Board's handwriting fonts:
  the apps start as fast as before, Retro Board 10 ms later (its Text
  panel draws the serif and mono faces at once: `useHandFonts` has them
  unpacked on a thread as the window opens). Packed files of either kind are read.
- **Retro Files 3.4.1: the folder tree no longer stops the app** -- a
  folder opened or closed below another while the tree was drawn moved
  the lists the tree keeps, and the folder above went on reading its list
  where it no longer was ("the length of the seq changed while iterating
  over it"). The soak found it, in its first six minutes of random input.
- **JSON from outside never stops a program**: a list or an object read
  from a server or a file (a podcast's chapters -- Retro Podcast 1.1.1 --
  the photo and icon services, GeoJSON, brush presets, saved settings)
  that is missing or of another kind is skipped -- Nim's json stopped the
  program with a nil read or a failed assertion (libFuzzer found it in the
  chapters reader in its first minute).
- **Fuzzed every night**: LZMA, podcast feeds, chapters, transcripts and
  board files (drawn too) join the libFuzzer targets, with seeds.
- **The CI**: Retro Files' test of jobs that wait starts from no job and
  copies files of its own (random input before it could leave a job asking
  "replace?", or move the files it copied) -- it failed 0.48.0's CI and
  its 32-bit run.
- **The tests, as many at once as there are cores** (`sh tests/runall.sh`,
  what `nimble test` runs now but on Windows): each in a temporary folder
  of its own, a log each in `build/tests`, the slowest named; one that
  fails among the others runs again alone, and is named "flaky" when it
  passes then (a warning on GitHub, not a red run). `RETRO_REPEAT=5`: every
  test five times over, to find the flaky ones. The CI keeps the C
  compiler's work between runs (ccache: four fifths of a test's build;
  87 % of it found again after this release's changes). The 152 tests on
  two cores: 34 minutes, where the CI took 45 one at a time on four.
- **A flaky test**: `test_drawalloc` failed one time in six with other
  tests running (0.48.0's too): one allocation in sixty frames, from a
  thread of the kit. It measures up to three times now.
- **The faces unpacked under one lock on every thread**: a worker thread
  asking for a face's bytes and the window's thread loading it could
  unpack it at the same moment.
- **Nightly**: the tests three times over (a flaky one fails the night),
  eight apps soaked for an hour each (`tools/soak.sh`: the kit's random
  input, `RETRO_SMOKE_STAY=1` so an Exit clicked does not end it, the
  memory sampled -- one that keeps growing once warm, or faults, fails),
  and the sanitizers' run four tests at once.
- **The smoke run opens no other program** (`RETRO_SMOKE`: `openUrl` and
  `openFile` say false): its clicks opened the files and links they
  reached in the system's programs, a word processor among them, and an
  hour's soak left 5 GB of them running after the apps had ended.
- **`RETRO_DEVICE_MB=2048`**: the device taken to have 2 GB, the program
  alone on it (`retroui/memwatch`): the caches' budgets and the memory
  pressure as on a small phone, on any computer. The soak runs so.
- **Android's emulator**: the 3D view on Android's GPU against the CPU
  (`tests/gpu3d/gpu3dcheck.nim` as an APK, its results fetched like the
  live check's), Retro Podcast and Grow driven too, and a link shared
  with an app in the share sheet, running and stopped; the desktop tour
  drives Podcast and Grow too.

## 0.48.0

Sixteen tutorials, step by step with pictures; Grow, a phone app made with
the kit alone, and what it had to build itself now in the kit; Retro
Navigator 0.5.0, Retro Board with thousands of shapes, Retro Podcast's
sounds on Android; the 3D view on the GPU without materials.

- **Tutorials** (`tutorials/`): sixteen lessons, step by step, each step a
  whole program with a picture of what it draws -- easy (hello, a to-do
  list, a tip calculator, Notepad), intermediate (contacts from a type, a
  news reader on a worker, a dashboard, other languages), mobile (phone
  layouts, Android and iOS), the web, and advanced (your own control,
  your own loop and threads, the system's APIs, testing, shipping).
  `nimble tutorials` makes the pictures again from the steps and builds
  every step for every system; CI checks each lesson shows its steps' code.
- **`spring()` in a column**: what follows it goes to the bottom of the
  room there is -- a button at a page's foot -- in the window, a pane, a
  `col` or a group (it did nothing outside a row).
- **`animated(..., start = x)`**: the first time, the value glides from
  `start` to its target -- a score counting up as its page opens (it was
  the target at once).
- **Grow** (`examples/grow.nim`), a savings goal planner for phones: the
  plan, then its result -- the total counted up, a ring, a 3D bar for each
  year rising one after another, a gold coin over the last; tap a bar,
  turn them with a finger, share the plan. Made with the kit alone; what
  it had to build itself is in the kit now:
- **`easedSince(start, ms, delay)`** and **`easeOut(t)`**: a page's own
  timeline, things that follow one another each with its delay (a bar a
  year), frames asked for while it runs; at once when the user asked for
  less movement.
- **`material3(name, color, metallic, roughness, glow)`**: a 3D material
  of one color, in a line.
- **The 3D view on the GPU without materials**: a scene of plain meshes
  (3D bar charts, shapes of one color, a color a triangle) is drawn by the
  GPU where frames are, shaded as the CPU shades it, with its outlines;
  before, only scenes with materials were.
- **Retro Board with thousands of shapes**: a shape too small to read at
  the zoom (`briefAt`: letters under 6 pixels) is drawn in brief -- its
  box, fill and colors, its words as bars (`drawingOf(s, brief = true)`,
  `renderBitmap(..., brief = true)`) -- so 5,000 shapes zoomed out take 9 ms
  a frame instead of 1.2 s; the drawings kept past `drawingBudget` lose the
  half asked for longest ago instead of all (they were all made again each
  frame). Presenting the frames as slides (F5), and pictures dropped on the
  board.
- **The simple charts' height scales**: `barChart`, `lineChart` and
  `pieChart` are 170 design pixels high when `h` is not given (they were
  170 screen pixels: half as high at 200 %).
- **Android's sounds say why they do not play**: when the system's player
  cannot play an `audioView`'s sound (the network, the server, a kind of
  sound Android does not play), the error is the `VideoEvent`'s `error`
  and is shown under the player, Play tries again from where it was, and a
  web address it is still getting reads "Loading..." instead of 0:00 / 0:00.
  Before, the player kept its pause button and never started.
- **Plain http on Android and iOS**: `retroapk --cleartext` and
  `retroios --cleartext` let the app use `http://` addresses, which
  Android 9 and later and iOS refuse by default. Without it, the kit's
  downloads, web requests and Android's sound player ask for the https
  address instead of an http one, also when a redirect goes to http.
- **Shared in** (`sharedIn()` in `retroui/system`, `retroapk
  --share-target:TYPES`): an Android app in the other apps' share sheets
  for the kinds it names; a text, a link or files shared to it come to
  `sharedIn()` (the files copied into its cache).
- **Retro Podcast 1.1.0**: made with `--cleartext` (many feeds still send
  their episodes from http addresses); a sound that cannot be played says
  why in the status line; a link shared to it from another app (a
  browser's Share) is followed.
- **Retro Navigator 0.5.0**: private tabs (New Private Tab, Ctrl+Shift+N:
  kept out of the history, the session and the closed tabs); History
  (Ctrl+H: find, go to, remove, clear), Downloads (Ctrl+J: open, show in
  the folder, clear the finished) and Reader (Ctrl+Alt+R: the page's
  article alone); made with `--cleartext`, so pages on plain http open in
  its Android app; no letter underlined twice.
- **Retro Files 3.4.0**: a copy, move or trash asked for while another
  runs waits for it and starts after (it was refused).
- **Retro DNS 1.2**, **Retro Podcast**: no letter underlined twice (two
  controls answered one Alt key).
- **`chips` as tall as a finger** on a touch screen (they were 26 design
  pixels: under the kit's own finger sizes).
- **The tour** (`tests/drive/tour.nim`): an editable drop-down (a text box
  with a list: a browser's Location box) is opened with Alt+Down -- Enter
  takes what was typed, as on Windows -- and the on-screen keyboard check
  taps a text box that takes the focus, not one under a dialog.
- **The apps measured** (`tools/appbench.sh`, docs/benchmarks.md): each
  app's size, first frame, memory at rest and at most, and the processor
  at rest, under the kit's smoke run.
- **The CI**: the live check in Android's emulator is started by its
  launcher activity and waited for, as the apps are, and once more when no
  results come, with what the system says of the app printed (the monkey's
  one event stopped the emulator's system UI now and then: no pictures, no
  results). Retro Mail's search box under its account wizard is no longer
  a finding of the tour. `writecheck` reads the tutorials too, and none of
  a build's own files.

## 0.47.0

What most apps build for themselves is in the kit now -- work on worker
threads, undo, pages, forms from your types, translations, a code editor,
the system's tray -- and Retro Podcast, a podcast player for every system
and the web, is built from them.

- **Work off the screen's thread** (`retroui/jobs`): `job(proc (c: JobCtl): T)`
  runs on a worker and returns a `Job` at once; the frames read its
  `progress`, its `value` once `done`, its `error` when it `failed`, and
  can `cancel` it; `onDone` runs on the screen's thread. `fetch(url)` is a
  web request as a job. The kit draws a frame when one ends; in a web page
  (no threads) a job runs between frames.
- **Undo** (`UndoStack`): `record` keeps a value before and after a change,
  `did` takes the procs that undo and redo one; typing in a row is one
  step (`merge`); `undoMenuItems` names what Undo takes back ("Undo
  Typing"), `undoKeys` reads Ctrl+Z, Ctrl+Y and Ctrl+Shift+Z; `changed`,
  `markClean` and `revision` for work not saved.
- **Pages** (`pageView`, `pageHeader`, `PageStack`): pages over pages, as
  phones go through an app, sliding in; Back is the header's button, Esc,
  Alt+Left and the phone's. `listDetail` puts a list beside the details of
  what is picked, and one over the other on a phone.
- **Forms and grids from your types** (`formOf`, `gridOf`): a field for
  each field of an object -- text, numbers, a bool, an enum's values, a
  date, a color -- captioned from its name, the rules in pragmas
  (`caption`, `help`, `required`, `limits`, `maxLen`, `multiline`,
  `decimals`, `readonly`, `noForm`), what breaks one said under the field;
  `formValid`, `formErrors`. `gridOf` shows a seq of them, sorted by a
  header's click.
- **`animated(target, ms)`:** a number that glides to where it is asked to
  be, a frame at a time; at once when the user asked for less movement.
- **Translations:** `retrokit strings app.nim --lang:ar` writes every text
  the app shows (labels, buttons, menus, titles, `tr`, `trn`) into
  app-ar.txt for a translator, and keeps the translations when run again;
  `loadUiStrings` reads it for `setUiLanguage`. `trn(n, "{n} file", "{n}
  files")` takes the number's form in each language (`pluralForm`:
  Arabic's six, Russian's and Polish's three, French's, one for Chinese
  and Japanese...).
- **`codeEdit`:** a code editor -- Nim, Python, C, JSON and shell colored
  as typed (the colors follow the scheme), line numbers, Tab and Shift+Tab
  indent, Enter keeps the indent, Ctrl+/ comments lines, its own undo,
  find with F3, read only.
- **The system's tray** (`retroui/tray`): `trayIcon(png, tip, menu)` -- the
  notification area on Windows, StatusNotifierItem with its menu on Linux
  (KDE, XFCE, Cinnamon, GNOME with AppIndicator), the menu bar on macOS --
  its clicks and its menu's picks as events. uirelays' X11 and Wayland
  drivers wait on the descriptors of `addWaitSource` too.
- **Feeds** (`retroui/feeds`): RSS with the iTunes and Podcasting 2.0
  tags, Atom, OPML read and written, the dates and lengths feeds write.
- **Sound:** `audioView` and `videoView` play at any `speed` (0.5 to 3, a
  voice keeping its pitch: GStreamer's scaletempo, Media Foundation,
  AVFoundation, Android's MediaPlayer, the browser) and take a `title`;
  `seekVideo` and `playVideo` move and start them from the app. A sound
  plays on when the app stops drawing it; in an Android app it plays its
  own MediaPlayer, on with the app in the background, with a foreground
  service of the media playback kind (retroapk declares it and its
  permissions for apps that use `audioView`); on iOS with the audio
  session's playback category and `UIBackgroundModes` audio (retroios
  adds it for such apps).
- **Retro Podcast 1.0.0** (`examples/podcast.nim`): shows found by name
  (Apple's podcast directory) or by feed, OPML in and out, any speed, where
  you left off, downloads, a queue, a sleep timer, the system's media
  controls, the sound on in the background, a tray icon, Undo; on every
  system, as an APK, and as a web page (a feed proxy in Settings: CORS).
  Released with the apps.
- **The Gallery** has a Forms & Code page (forms and grids from a type,
  Undo in the Edit menu, the code editor, pages, a job, `animated`, the
  tray icon), and View, This Page's Code (Ctrl+U) shows how the page in
  front is made, from its own source.
- **Docs:** the guide shows the new parts with pictures (397 controls);
  the syntax study has work off the screen's thread, pages, a form from a
  type, Undo, words in other languages and `animated`.
- **Tests:** `test_jobs`, `test_undo`, `test_pages`, `test_typeforms`,
  `test_uistrings`, `test_codeedit`, `test_feeds`, `test_tray` (on a D-Bus
  of its own) and `test_podcast`; the portable ones under Node too.

## 0.46.0

Nine more color schemes, 7GUIs as an app of its own, and fixes from using
Retro Navigator on an Android tablet.

- **Nine more color schemes** (eighteen in all, in every app's Appearance):
  High Contrast and High Contrast White, for people who need every edge
  clear; Midnight, a dark one in night blues; Emerald, Rose, Slate and
  Mahogany; and two terminals of the 1980s, Amber and Green Screen. New
  schemes go at the end of `builtinThemes`: the number a setting keeps
  still names the same scheme.
- **7GUIs is an app:** its own icon, a menu (the seven tasks, Ctrl+1 to
  Ctrl+7; Appearance; About), its look kept; built with the released apps
  (Linux, Windows, Android, macOS).
- **Android apps have a folder for temporary files.** Android gives none
  and `getTempDir()` said /tmp, which is not there: a page's picture in
  Retro Navigator, downloads, Retro Photo's scratch files and pictures the
  system decodes could not be written. The app's cache folder is
  `$TMPDIR` now.
- **Retro Navigator 0.4.1:**
  - **Fixed: it stopped on Android** (HUAWEI's WebView, Android 12): the
    page's window was taken away while the engine's handles of selected
    text were over it, and the engine moved them after. A page hidden
    under a menu or a list is now only out of sight (no touch reaches it),
    and its window is let go a few seconds later if it stays hidden (a tab
    behind) or a frame later when it is closed.
  - **Classic:** a site's dark code box kept its background under
    Classic's black letters (the site's `!important` won over Classic's).
    Classic's rules are in a cascade layer now, which wins over the site's
    `!important` whatever its selectors: the box is white with black text.
  - **Picture works on Android** (the folder above).
- **A fault's report says the app's version** at the next start too:
  `app`'s and `openApp`'s `version` (Retro Navigator, 7GUIs, Retro DNS, HR
  Book; Retro Files, Photo, Board and Task Manager set `reportedVersion`).
  It said "Version: -" until an About box had been drawn.
- **The smoke run** takes `RETRO_SMOKE_SEED`: the same app driven another
  way (other clicks, other keys). `tests/smoke/run.sh` starts each app in
  its own home folder, so what its clicks save or delete stays there (Ledger
  saved a CSV into the repository's folder). Retro Files, Photo, Board,
  Mail, the Gallery, Task Manager, Notepad and Ledger were each driven
  with four more seeds, 20 seconds each: no fault.

## 0.45.0

Retro Navigator 0.4.0, from using it: the page's look on the tool bar, the
window's own scroll bars on pages, white Classic pages, and three fixes.

- **Retro Navigator 0.4.0:**
  - **The page's look is a switch on the tool bar** (Modern, Classic,
    Plain), as well as in View > Page Look.
  - **The zoom is a slider** in the status bar, 50 to 300 %, with the
    percent beside it.
  - **The page's scroll bar is the window's own**, drawn by the kit beside
    the page, not a style the page is given: it follows the page and
    scrolls it. Boxes inside pages keep Windows 3.1's.
  - **Classic pages are white** for reading; the buttons and fields stay
    3.1's.
  - **Fixed:** the Location box's suggestions were under the page.
  - **Fixed:** Picture took no picture on some Linux desktops.
- **The web view:**
  - `webScrollBars(key)`: the page's scroll bars drawn by the kit beside
    the view (the arrows, the track, the thumb, the wheel), the engine's
    hidden; the page's inner boxes keep theirs.
  - A drop-down over the view (a combo box's list, the Location box's
    suggestions) hides it, as menus and dialogs did: the list was under the
    page.
  - The page's picture on Linux is WebKit's own (it was read from the X
    server: nothing on some desktops, and the program could end on a
    window partly off the screen). A picture the engine refuses no longer
    stops the next ones (WebView2).
  - The picture under a menu is drawn at its own size, not stretched.
  - **Less work at rest:** a page that does nothing is looked at 4 times a
    second (10 before), and its picture is taken again only when it changed
    (every 10 seconds at most otherwise).
- **Tool bars:** a control in one (a switch, a box) is a stop of Tab but
  not where the window's focus starts: that stays on the content.
- **7GUIs:** its timer wakes the window only while its tab is shown (20
  times a second before, whatever the tab). Every example was run for real
  (the kit's smoke run): the others do nothing at rest.
- **CI:** the WebAssembly tests build again (the updates' pieces looked for
  older downloads with a pattern; the web's C library has none), and
  uirelays' own Cocoa test links Carbon (the hot keys).

## 0.44.0

Retro Navigator 0.3.0 grows up, and the kit gets what it needed for it and
what other toolkits have that it did not: typed calls from pages, the
clipboard's pictures, the desktop's shortcuts, packages and smaller updates.

- **Retro Navigator 0.3.0:**
  - **Ads blocked by the engine**: more than 250 ad and tracker sites and
    the ad addresses of sites that serve their pages too are never fetched,
    a list of the user's own can be imported (a hosts file, `||site^`
    lines), more ad boxes are hidden, and YouTube's ads in its player are
    skipped.
  - **Page looks** (View > Page Look): Modern; Classic, the site's layout
    and scripts in 1995's type and colors; Plain, the HTML alone, none of
    the site's style sheets or scripts, its `<noscript>` shown. And Windows
    3.1's scroll bars on every page, in the window's colors.
  - **Video full screen**: the bars and the window's frame go, the window
    fills the screen, Esc brings them back; Pop Out Video, and F11.
  - **The Location box suggests** the pages visited (the last 400, kept)
    and the bookmarks as it is typed in.
  - **The zoom in the status bar** (Ctrl and +, -, 0 too).
  - **Screenshots marked up** with Retro Board's tools -- pen, highlighter,
    boxes, ovals, arrows, words, its colors and sizes, undo -- copied, or
    saved as PNG or as a board.
  - **Less memory**: a tab behind is paused at once (WebView2), and tabs
    sleep after five minutes, on at first.
- **The web view:**
  - `webBlockList(hosts, patterns, spared)`: the engine never fetches what
    an ad blocker's list names (WebKit's content rules, WebView2's resource
    filter, Android's WebView); `WebEvent.kept` counts it.
  - `WebEvent.fullscreen`, told by the engine, not by the page (a page
    cannot make the window full screen by pretending); `fullScreenWindow`
    for the window (a new relay in every driver).
  - `webSnapshot`, `webSnapshotNow`: the page's picture.
  - **Typed calls from the app's pages** (`retroui/webbind`): `webBind
    addNote` makes a proc a function the pages call (`await
    retro.call("addNote", note)`), its arguments and answer as JSON, its
    errors a rejected promise, streams (`retro.stream`), events
    (`webEmit`, `retro.on`); `webClientTs()` writes the pages' TypeScript.
    Only the app's own pages may call, and sites `webTrust` names; never a
    frame of another site.
- **The system** (`retroui/system`, docs/system.md):
  - pictures on the clipboard: `copyPicture`, `pastePicture` (Windows' DIB
    and PNG, X11, Wayland, macOS, GTK 4, SDL 3; copy in a page);
  - shortcuts of the whole desktop: `globalHotkey` (Windows, X11, macOS);
  - `metered()`, `systemWoke()`, `systemPrefs()` (less movement, high
    contrast, the text's size: the kit's glides and text follow them as an
    app starts), `keepScreenOn` on Linux and macOS too;
  - a folder watched: `watchFolder`, `changes` (`retroui/files`).
- **Shipping:**
  - `retrokit linux PROGRAM`: a .deb, an .rpm, Arch's PKGBUILD and a
    .tar.gz with an `install.sh` that needs no administrator, made here
    with nothing installed (`retroui/linuxpkg`).
  - `retroui/install`: the app installs itself for the user alone
    (Windows' Start menu and Settings > Apps, Linux's menu, a Mac's
    ~/Applications), so its updates replace it with no question.
  - **Smaller updates:** `update-sign` lists each file's pieces, and
    `downloadUpdate` fetches only the pieces the app's own file does not
    hold.
- **Benchmarks:** `python3 tools/bench.py` measures the kit at rest and
  busy, and writes docs/benchmarks.md.
- **A pseudo language:** `RETRO_LANG=pseudo` shows every text stretched
  and marked, to find layouts too tight for other languages and words not
  translated.
- The gallery and the small examples 0.44.0.

## 0.43.1

The night's tests after 0.43.0, both green again.

- **`retroapk --java`: a manifest.txt line it refuses no longer leaks**
  the attribute it had half made (the nightly's LeakSanitizer, on
  test_apk's bad lines): its id is looked up before anything is made.
- **The WebAssembly tests under Node** no longer copy `tests/build/` into
  each test's files: the other tests' builds write there at the same time,
  and a file gone between the listing and the reading stopped
  test_mapview. Files that go away meanwhile are passed over too, and each
  test's files no longer hold every build's C.
- The gallery and the small examples 0.43.1.

## 0.43.0

Retro DNS joins the examples, on every system, and the kit gets what it
needed: an Android app's own Java, and a command run as the computer's
administrator.

- **Retro DNS 1.1** (`examples/retrodns.nim`, `nimble dns`): a DNS changer
  with 47 public servers, what each is good for, speed tests, favourites
  and servers of your own (CSV).
  - **Android:** a VPN of its own Java that stays on the device and
    carries DNS only, encrypted (DNS over HTTPS or TLS), in a process of
    its own, with a notification while it is on.
  - **Windows, Linux, macOS:** Use on This Computer gives the computer the
    server's addresses as its administrator: every adapter on Windows (with
    DNS over HTTPS where Windows 11 has it), NetworkManager's connections
    on Linux (DNS over TLS where systemd-resolved does it; else
    systemd-resolved alone), every network service on a Mac. Back to
    Automatic gives back the network's own. The scripts are made of checked
    addresses only, whatever a CSV file holds.
  - **macOS, iOS:** a server with encrypted DNS comes as a profile that
    Settings installs.
  - In the release builds with Retro Navigator: an AppImage, an .exe, an
    APK and the macOS app.
  - `test_retrodns` checks its servers, the CSV, the VPN's settings, the
    scripts and the profile.
- **`retroapk --java:DIR`**: an app's own Java. DIR's `classes.dex` goes
  in as `classes2.dex` and the entries of its `manifest.txt` (an element a
  line, `name=value` attributes, two spaces of indent inside) into the
  manifest, of an APK or a bundle; `--manifest:FILE` adds entries alone.
  Android starts a service, a receiver or a VPN only from a class its
  manifest declares: now an app can bring one, and call it by reflection
  (`retroui/native`).
- **`retroui/admin`**: `runAsAdmin(key, exe, args, why)` runs a short
  command as the computer's administrator, the system asking first --
  Windows' UAC, macOS's password dialog, polkit's pkexec -- on a thread of
  its own, asked each frame until it is done; `canRunAsAdmin()`; `adNone`
  on phones and pages. In docs/system.md.
- **A run of tool buttons in a 32-bit program** (and WebAssembly): the one
  lit could be -1, and the buttons past the 30th were counted with a shift
  past an int's bits. The nightly 32-bit tests (under UBSan) failed on it
  in test_report, test_photoapp and test_channelspanel.
- **CI:** the actions on Node 24 (checkout 5, setup-node 5, upload-artifact
  6, download-artifact 7, action-gh-release 3, Google's auth and gcloud 3):
  GitHub said Node 20's were going away. The release builds Retro
  Navigator and Retro DNS too. `nimble apps` builds every app of the
  table, not a list of its own that had fallen behind.
- The gallery and the small examples 0.43.0.

## 0.42.0

Retro Navigator gets what a browser has now -- tabs, ads and trackers kept
off the pages, secure connections, links loaded ahead, Clear Browsing Data
-- in its 1995 window, and the web view gets the calls it needs for them.

- **Retro Navigator 0.2.0** (`examples/navigator.nim`):
  - **Tabs**, shown above the page while there are two or more, in Windows
    3.1's document style (`tabStrip` with `tlDocument`): New Tab (Ctrl+T),
    Close Tab (Ctrl+W), Reopen Closed Tab (Ctrl+Shift+T), Ctrl+Tab, a
    tab's menu (Duplicate, Close Other Tabs), dragged into order. A link
    with Ctrl, Cmd or the middle button opens in a tab behind (loaded when
    it is first shown), a link for a new window in a new tab. Each tab is a
    `webView` of its own.
  - **The shield** (`examples/navigator/shield.nim`), a script put in every
    page before the page's own: ads and trackers blocked (the page's
    requests to about 80 of their hosts, their scripts, frames and
    pictures, the usual ad boxes), with the number kept off the page in
    the status bar and Allow Ads on This Site; sites asked not to track
    (Global Privacy Control); links to `http://` taken to `https://`, not
    on this computer or the local network (an address typed with `http://`
    goes as it is).
  - **Faster:** a link of the site is loaded ahead while the pointer rests
    on it (not one with a query, a download, or one that signs out or
    deletes); videos and sounds kept from playing by themselves, and tabs
    not looked at for ten minutes put to sleep to free their memory (both
    settings, off at first).
  - **Clear Browsing Data** (Ctrl+Shift+Delete): the pages visited (the Go
    menu, Back in every tab), and cookies, cache and site data.
  - **Preferences** as Netscape had them: one tabbed dialog, opened at its
    tab by General, Appearance, Security and Network Preferences in the
    Options menu. Appearance has the colors, the frame and the title bars'
    buttons.
  - The handbook tells all of it; `test_navigator` checks the secure
    addresses, the ad and tracker hosts, the shield's settings and its
    script.
- **`webStartScript(key, js)`**: a script of the app's in every page of a
  view, before the page's own, on every engine (WebKitGTK's user script,
  WebView2's script on document creation, WKWebView's user script,
  Android's at the page's start: `web.script`). A view takes it when it is
  made: to change it, set it and `webClose` the view.
- **`webClearData()`**: the engine's cookies, storage and cache cleared
  (WebKitGTK's website data manager, WebView2's DevTools protocol,
  WKWebView's data store, Android's cookie manager, web storage and cache:
  `web.clear`).
- **A system web view under a menu or dialog** comes back a frame after
  they let it go, so a dialog opened from a menu no longer has the page
  flash over it; and its picture is not taken in the moment after it is
  shown, before the engine drew it (on X11 the picture held a piece of the
  menu that had been there).
- **A menu's letter is not typed** into the box with the focus: choosing
  an item with its letter (Options, then I) left the letter in the
  Location box after the menu closed.
- **Windows: the busy box after a resize.** While the app worked in a
  frame, a resize read meanwhile made the window's buffer anew, and the
  busy box was then drawn into the one let go. It now waits for the next
  frame; so does `framePicture`.
- The gallery and the small examples 0.42.0.

## 0.41.0

Retro Navigator, a web browser in the manner of 1995's around the
system's engine, and the three title bar pieces 0.40.0 left out.

- **Retro Navigator** (`examples/navigator.nim`, `nimble navigator`; one
  of the apps the packages are made of): a 1995 browser window
  around `webView` with `weSystem` -- WebView2, WKWebView, WebKitGTK,
  Android's WebView -- so today's web works in it.
  - The tool bar with its labels and, at its right, a logo of its own (a
    planet in the night) with a comet going round it while a page loads;
    a click on it goes home.
  - The Location box: an address, a host (`https://` before it), a file
    that is there, or words, searched for with DuckDuckGo, Google, Bing or
    Wikipedia (General Preferences).
  - The directory buttons, the status bar (what happens, the key for
    https or a warning sign, how much is loaded, downloads), bookmarks
    (Ctrl+D, View Bookmarks), the Go menu with this session's pages, find
    on the page, print, the document's source, larger and smaller pages.
  - Its own pages, `about:welcome` (the home page at first) and
    `about:handbook`, in HTML and CSS; Back goes back to them too, which
    the engine keeps no history of.
  - Where the system has no engine it shows its own pages and opens the
    others in the browser.
  - `tests/test_navigator.nim` (on every system too): the Location box's
    addresses, the key, the bookmarks kept, the session's pages. Its icon
    (`tools/gennavigatoricon.py`) and its picture in the examples' guide.
- **Snap layouts on Windows 11** over the 3.1 frame's maximize button, as
  over Windows' own. uirelays' `WindowPart` gains `wpMaxButton`, which the
  frame answers for the button (`windowPartAt`). The WinAPI driver tells
  Windows it is the maximize button (WM_NCHITTEST, HTMAXBUTTON), and gives
  the app the mouse over it as its own (the non-client moves, the press
  and the release), so the kit still draws the button and takes its
  clicks. SDL's hit test answers it as the app's.
- **The title bars' buttons in the window menu:** the 3.1 frame's control
  menu has "Windows 3.1 Buttons" (with Windows 95's: "Windows 95
  Buttons"), kept with the look as Appearance's choice is.
- **A grayed X on a question:** a message box whose last button is not
  Cancel, Close or OK (Yes and No; Abort, Retry and Ignore) has its close
  button grayed and doing nothing, as Windows has it. Esc still counts as
  its last button.
- Tests: `test_frame` (the window menu's item, `wpMaxButton` for the
  maximize button), `test_desktop` (a message box's X: Cancel, and grayed
  on Yes and No), `test_navigator`.
- The gallery and the small examples 0.41.0.

## 0.40.0

Windows 95's title bar buttons, _ □ X, are the default: every window and
dialog the kit draws has a close button. Windows 3.1's two are a setting
away.

- **The title bars the kit draws** -- the 3.1 frame's, a dialog's, a
  window's in an `mdiArea`, and the caption bar of a window besides the
  app's where the system draws no frame round it -- have minimize,
  maximize (restore) and close at their right, the close button two
  pixels apart so a slip off maximize doesn't close. The marks are
  Windows 95's: _, □, two windows, X. The control-menu box stays at the
  left, with its menu, its double click and Alt+Space.
  - The 3.1 frame: X asks the app to close, as Alt+F4 does
    (`closeRequested`: it can still ask "Save changes?"); a press that
    leaves the button does nothing; the buttons have tooltips.
    `frameLayout().close`; `framePartAt` gives `fpClose`.
  - A dialog: X does what Esc does (a message box: its last button).
  - A window in an `mdiArea`: X closes that window only, as Ctrl+F4; its
    pin stays left of the buttons.
  - A window besides the app's with no frame of the system's (Wayland
    without one): X closes it.
  - A phone's caption bar has no close button (Back closes the app);
    Android's minimize button has the _ mark. iOS and a screen without a
    desktop keep the box only.
- **Windows 3.1's buttons:** `captionButtons = cbWin31` (before
  `startApp`: the app's default) gives every title bar the two triangles
  and no close button: the control-menu box closes, as in 3.1. The user
  picks either as "Title bar buttons" in `appearanceSettings`; it is kept
  with the look (`storeAppearance`, `look.buttons`) and wins over the
  app's. A title bar the system draws keeps the system's buttons.
- `captionMark(r, mark, pressed, enabled)` draws a title bar button's mark
  in either style, for a title bar of your own.
- Tests: `test_frame` (the layout, the parts, the close button, 3.1's
  buttons, the setting kept), `test_desktop` (an inner window's and a
  dialog's close button, and 3.1's), `test_windows` (a window's caption
  bar).
- The guide's pictures of the frame, dialogs, boxes and inner windows, the
  syntax guide's and the examples' pictures.
- The gallery and the small examples 0.40.0.

## 0.39.2

Scrolling areas inside one another pass a swipe on at their ends, as on
Android.

- **A list in a scrolling panel on a phone** took every swipe that began
  on it, even at its top or bottom: the page around it could hardly be
  scrolled (a phone's layout with a list of 47 over half the screen).
  Now:
  - a gesture goes along the axis of its first move; a scroller that
    scrolls only the other way leaves it (a swipe up and down over a
    sideways carousel scrolls the page);
  - a scroller at its end that way leaves it (a list at its top, swiped
    down: the panel moves);
  - the first scroller that takes a gesture keeps it until the finger
    lifts, the way back too (a swipe that began moving the page keeps
    moving it when it turns back over the list);
  - one that reaches its end in the middle of a gesture hands the rest of
    it, and the gesture from then on, to the nearest scroller around it
    that can move that way -- never back inward;
  - a flick flies on in the scroller that had the gesture when the finger
    lifted (its leftover speed is not handed on);
  - unchanged: a tap picks, a drag does not; a finger that lands on a
    flying list stops only that list (`scrollCaught`); scroll thumbs,
    sliders, a long press; the map views and the business grids, which
    take the finger themselves.

  One rule in `retroui/core`, `panShare(id, area, vx, hiX, vy, hiY)`,
  used by `scrollPan`, `scrollPan2`, `takePan` and `takePanX` (which take
  an `id` now, their place by default): every list, tree, grid, table,
  text box, panel, pane, dialog and the page behave the same; a scroller
  of your own calls it.
- **The wheel** does the same at a list's end: a notch over a list at its
  bottom scrolls the panel or the page around it. Notches that keep
  coming stay with the scroller they began in (400 ms, the pointer still,
  as a browser latches them), so scrolling a list to its end does not run
  on into the page (`wheelLatched`, `noteWheel` for a wheel of your own).
- `tests/test_nestedscroll.nim`: the list at its top swiped up and down,
  at its bottom swiped up, an end reached mid-swipe, a swipe that turns
  back, a tap and a drag, a carousel in a panel, a caught flick, the
  wheel at a list's end and its latch.
- The rich text box's keystroke and Page Up limits allow for a debug
  build on GitHub's Windows runner (70 ms where 60 were asked).
- The gallery and the small examples 0.39.2.

## 0.39.1

The CI steadier, and what running every test under the sanitizers found:
the chat's encryption and a failed TLS connection keeping memory, a link
that could not be read keeping a little each time, and the script
engine's stack guard blind there.

- **The CI's packages:** every job that installs Ubuntu packages goes
  through `tools/apt.sh`, which tries again (six times, some 7 minutes)
  when a mirror does not answer and stops a try that hangs (Playwright's
  browser install: three times). 0.39.0's runs went red for one: a GitHub
  runner's name lookups failed for a few minutes, and the tests, the
  WebAssembly build and the Windows packages of the release never
  started. On another runner apt's own retries spun ("Tried to start
  delayed item", twelve million lines) for nearly two hours before it
  gave up; `tools/apt.sh` turns them off and tries again itself. Every
  job has a time limit now (some three times its usual time), not
  GitHub's six hours.
- **retroui/rscript's stack guard** measures the machine's stack from the
  frame itself (`__builtin_frame_address`), not from a local's address:
  under AddressSanitizer a local may live on its fake stack, on the heap,
  and a script that recursed deep went past the guard and took the
  program down instead of getting "Maximum call stack size exceeded".
  (A WebAssembly or MSVC build measures as before.) Under the sanitizers
  (`-d:retroSanitized`) its recursion test, and the HTML view's hostile
  pages, allow for frames many times larger and code 7 times slower.
- **retroui/omemo** (Retro Communicator's encryption): a message changed
  on its way, or sent with the wrong key, left what was opened of it in
  memory, never freed (Nim 2.2's second leak, `docs/nim-bugs.md`); so did
  a weak or bad key, and a wrong padding. AES-GCM and AES-CBC open, the
  key agreement, the signature and the digests now fill a local and give
  `result` at the end.
- **A connection that failed:** a TLS connection whose certificate was
  refused (or that timed out in its handshake) kept OpenSSL's state, some
  80 KB, never freed; an IMAP or SMTP server that did not greet, refused
  STARTTLS or broke during it left the socket open. `netOpen`,
  `imapConnect` and `smtpConnect` close what they opened before they
  raise. (Retro Mail 1.1.5 tries again and again when a server is down.)
- **A link that cannot be read:** Nim's `expandSymlink` raises with its
  string already made, never freed -- once for every process Retro Task
  Manager (1.0.6) could not look into, every link a file's Properties
  showed broken. `linkTarget` (retroui/files) reads a link and never
  raises; the system monitor and the file views use it.
- **The spelling's dictionaries** (Hunspell's), opened once, are kept to
  the program's very end, as the workers' queues are: as the program
  ended they seemed lost (16 MB under LeakSanitizer).
- **The sanitizer run** (all the tests under ASan, UBSan and LSan, here):
  the HTML view's and the HTML mail's hostile pages, the rich text box's
  Page Up and the spelling's second look allow for the sanitizers;
  GStreamer's libav decoders' own buffers are suppressed in
  `tests/lsan.supp` (the video test reads its file back through them).
- **uirelays upstream** is looked at before every release now (AGENTS.md,
  5: `tools/uirelays.sh merge`, and upstream's open pull requests):
  nim-lang/uirelays has nothing new since cb82378, which the branch has.
- Retro Task Manager 1.0.6, Retro Mail 1.1.5; the gallery and the small
  examples 0.39.1.

## 0.39.0

Memory that was never freed, a crash as a program ends, Up twice in Retro
Files, and the CI green again: some 70 places where Nim 2.2 kept a value
it should have freed, found by a new check that GitHub runs on every
push; the background workers' queues kept to the program's very end.

- **Nim 2.2's third leak** (`docs/nim-bugs.md`, 5, ready to report: it is
  in Nim's devel too): `var x: T` declared without a value, given one in
  an `if` or filled in a loop, then given another -- the first is never
  freed; `result` the same. It was in a chart's areas and treemaps (their
  points, every frame), the names a screen reader or the inspector is
  given (every frame), Retro Board's smooth lines, the font's hinting of
  stems, numbers grouped in a report's templates, an SVG's dash lists,
  Retro Photo's layer from a file (the whole file kept), Content-Aware
  Scale's masks, a smart object's contents, the edge tracer's small copy,
  Retro Mail's calendar and sync, HR Book's importer. Each now has its
  value where it is declared (`result` one at the proc's start).
  `python3 tools/writecheck.py` finds the shape (0 now; your own files:
  `python3 path/to/retroui/tools/writecheck.py app.nim src/`); the CI runs
  it with `returncheck.py`.
- **A program's end:** a worker that finished a picture, a listing, a
  download, a map tile, a place's address or a font as the program ended
  wrote into a queue Nim had already freed (AddressSanitizer: a use after
  free in `test_memcache`, now and then). The queues of
  `retroui/background`, `assetfetch`, `tilemap`, `geo` and `unpacking`
  are kept to the very end.
- **An SVG's dash list** of an odd count read freed memory as it doubled
  itself.
- **Retro Files 3.3.10, the column view:** Left pressed twice (or Up
  twice) before the folder above was listed went up one folder only; it
  goes up two now, from the folder on its way, and Back comes back the
  same way. (Seen on the CI's 32-bit run, where the listing came late.)
- **The CI:** the docs check took `docs/api` -- made by `nimble docs`,
  not kept in git -- for missing, and failed every push since 0.37.0
  (what git ignores is made by a build: not looked for). The nightly run's
  sanitizers, which make a program 7 times slower and keep freed memory a
  while, no longer fail the memory soak's ceiling, the fuzzers' and a
  keystroke's time limits (`-d:retroSanitized`).
- Retro Photo 4.9.12, Retro Files 3.3.10, Retro Board 1.3.10, Retro Mail
  1.1.4, HR Book 0.2.5; the gallery and the small examples 0.39.0.

## 0.38.0

The keyboard, a finger and the start of every app: a tool bar one stop of
Tab, F6 from part to part of a window, `tabIndex`, no letter underlined
twice; a tour as fingers find the apps and the on-screen keyboard
checked; apps that open in a third of the time; HTML grids by areas and
positioned boxes; the iOS input method in the box; Retro Designer's Tab
order dragged, its windows exported as tests; Retro Files' Paste
Shortcut.

- **A run of tool buttons is one stop of Tab**, as Windows' tool bars
  are: the arrows go along it (right to left too), Home and End to its
  ends, Space or Enter presses the one lit, a disabled one is passed
  over; a tool bar's buttons between its boxes, a palette's tools, the
  "More" button of a narrow bar. A window starts at its first box or
  list, not at its tool bar (`tabStop(..., first = false)`). A click on a
  tool button leaves the focus where it was. A screen reader is told the
  lit one.
- **F6 and Shift+F6** go from one part of a window to the next: its tool
  bars, the panes of a split, the docked panels, the MDI windows and
  palettes, the menu bar (its first menu opened; F6 again closes it and
  goes on) -- each part back at the control that had the focus last. In
  an app whose keys are its canvas's when nothing is focused (`autoFocus
  = false`: Retro Photo, Retro Board) the canvas is one of the parts.
  `area "key": ...` (`beginArea`, `endArea`) makes a part of your own
  layout one. Retro Files' and Retro Mail's own F6 stay theirs.
- **`tabIndex n`** before a control puts it first in Tab's order, as
  HTML's tabindex: 1 before 2, then the others as they are drawn.
- **The tour** (`tests/drive/tour.nim`) also finds a letter underlined
  twice where one Alt reaches both -- the window, each dialog: only the
  first was reached. It found the gallery's eighteen tabs taking letters
  its pages' controls had (the tabs have none now: Ctrl+Tab goes through
  them), the kit's find bar's Find and Next, Previous and Replace (Next
  and Previous are Enter and F3, Shift+Enter and Shift+F3), Retro Photo's
  Layer and Filter menus, Retro Board's File menu and Free Memory and its
  Export dialog's PNG and The page, PDF and Dark, Retro Mail's Edit menu
  and a contact's E-mail, Name and New Message, the Find Message dialog's
  To and attachments, Ledger's File and Find, Invoice's Address and Add a
  line. The CI's Linux job tours with `TOUR_STRICT=1`: a finding fails it.
  The driver gives each node its underlined `letter`.
- **Menus: a letter two items share lights the next of them** (Enter then
  chooses it), as Windows' menus do -- before, the second could not be
  reached by its letter; a letter one item has still chooses it, and a
  submenu opens by its letter, its first item lit. Digits count too ("&1
  notes.txt"). Retro Task Manager's View, the gallery's View, Retro
  Files' item menu have a letter for each item now anyway; in the rich
  text box's menu Select all is S (A adds a word to the dictionary).
- **As a finger finds them:** `tour --touch` starts the apps as on a touch
  screen (`RETRO_TOUCH=1`) and clicks with a finger; on every page it
  finds what is too small for one (`--min-dp`, 28 design pixels by
  default: under the kit's own finger sizes, 31 to 35 -- Apple asks 44,
  Google 48), what shows only with the mouse over a control (a finger has
  no hover), and a control whose right click opens a menu a long press
  does not. `--keyboard` (on a phone: the emulator job) taps a text box
  and checks that the on-screen keyboard comes, the box is above it, and
  the keyboard goes when the focus leaves. The driver: `click ... --hold
  MS` (a finger held: a long press), `focused NAME` (it has the focus),
  `info`'s `dp`, `touch`, `fingers`, `keyboard` and `below`.
- **A finger's size** wherever the tour found less, on a touch screen: the
  stars of `rating` a finger high, `rangeSlider`'s thumbs and a
  `splitButton`'s arrow a finger wide, `tagInput`'s tags, `stepper`'s
  steps, the tab strip's + button, `pathBar`'s short folders ("/"), the
  strip at the top of the docked columns (`panelHeaderH`, its arrows), the
  gallery's palette. It finds nothing now in the gallery, Retro Photo,
  Retro Board, Retro Files, Retro Mail and Notepad.
- **The on-screen keyboard:** a text box with the focus when the
  keyboard comes up is scrolled above it in every view that scrolls
  (before, only a box Tab had just moved to). `keyboardWanted()`.
- **Apps open sooner.** What the kit carries packed is unpacked on a
  thread from the start (`retroui/unpacking`: `unpackSoon`, `unpacked`):
  the UI's bold and the icons' font, the pixel icons (indexed when the
  first is shown), the fonts an app offers packed (`addFontData`). A font
  the program has is found without looking through the system's font
  folders (Retro Board looked through them at its start); `scanFontsSoon()`
  looks through them on a thread for an app that will list them (Retro
  Photo, once its window shows). A face's kerning of every two ASCII
  letters is made a subtable at a time (`kerningTable`, 16 times
  quicker); zlib's tables are made when the program is built, OpenEXR's
  half floats when the first EXR is read. `framesShown()` for work the
  first frame can do without. The first frame on the screen, release
  builds: Retro Photo 30 ms (55 to 95 before), Retro Board 25-30 (127),
  Mail 22 (26), Files 21 (34), HR Book 17 (34), Communicator 15 (32),
  Chart Viewer 10 (32), the gallery 17 (18).
- **A frame after an input that nothing asked to draw again** -- a letter
  typed into a box -- is shown at once, and the next one only if it
  differs: what is typed is on the screen a frame sooner.
- **HTML** (`htmlView`): grids by `grid-template-areas` and `grid-area`,
  `grid-template-rows`, `grid-row` and `grid-column` by lines (`1 / 3`,
  `-1`, `span`), the boxes placed first, the rest in the next cells free;
  `position: relative` (moved by `top`, `left`...), `absolute` (out of the
  flow, in the positioned box around it, by its `top`, `right`, `bottom`,
  `left`, or where it would have been), `fixed` (in the page); `inset`.
- **iOS: the input method in the box.** The view is a UITextInput: what an
  input method composes (Chinese, Japanese, Korean, a swiped word) is
  drawn underlined at the box's caret and typed when it is settled, its
  suggestions by the caret (`setTextCaret`).
- **Retro Designer:** View > Names and Tab Order -- drag a number onto
  another and that control takes its place in Tab's order: `tabIndex`
  written before as few controls as it takes, the old ones taken away.
  File > Export Driver Test: the window as a test for `retrokit drive
  PORT - < app.drive` -- each control found by its name and role, then
  Tab through the stops, each one checked. `tabIndex` and `area` are in
  its Widget Box.
- **Retro Files 3.3.9: Edit > Paste Shortcut** -- a link here to each item
  copied ("Shortcut to notes.txt"; on Windows an Internet shortcut, .url,
  that Explorer opens too, followed by Retro Files), taken back by Undo
  (`makeShortcuts`, `shortcutTarget`). And a fault fixed: emptying the
  trash went through a link to a folder in it and deleted what was in the
  folder it led to (`deleteForever`).
- **Retro Photo 4.9.11** opens in a third of the time: its brushes' tips
  are filled a row of samples at a time (the same pixels, thirty times
  quicker), its opening picture painted once the window shows.
- **Retro Board 1.3.9:** its hands unpacked while the window opens, the
  Text panel's samples made once.
- Retro Task Manager 1.0.5; the gallery and the small examples 0.38.0.

## 0.37.0

Every app walked with the keyboard alone and driven by its controls'
names until nothing was left to find; Thai and Vietnamese in the fonts
built in; flexible boxes and grids in HTML; Retro Photo's Multichannel
images, Retro Files' List view, a model's shadow on the ground; and Retro
Designer shows what screen readers and drivers know of a window.

- **The keyboard alone, in every app.** The driven tour
  (`tests/drive/tour.nim`) now walks each page with Tab as a person
  without a mouse would: every control reached once, the focus never
  stuck, Shift+Tab back the same way, a drop-down opened by Enter and
  Alt+Down and closed by Esc with the focus kept, a check box ticked by
  Space, every control with a name; and each "..." of the menus opened
  and closed by Esc. It walked the 15 apps; what it found is fixed, and
  it now finds nothing in them:
  - a control whose screen reader's node had an id of its own (a second
    `idOf` of its label is another id): the gallery's palette tabs, menu
    buttons, split buttons, the tag box's ×, accordion headers, a snack
    bar's action, color wells, docked panels' menus, Retro Board's
    buttons -- their focus was not shown to a reader and a reader's press
    did not reach them. One id each now; `tests/test_hardening.nim`
    (`oneIdPerWidget`) keeps it so.
  - which controls take the focus is known at the frame's end, from the
    stops of Tab: a tool button, a row of chips, a drawing named for
    readers no longer say they do.
  - `rangeSlider`: its right end could not be reached by Tab (only by
    Shift+arrows): the two ends are two stops now, each read as its own
    slider ("From", "To").
  - names: `timePicker`'s hours and minutes, `rating` ("Rating"); the
    gallery's city box and settings, Retro Invoice's line boxes, 7GUIs'
    list, a report's zoom, a record's range, Retro Task Manager's three
    tables, Retro Photo's library box and the 19 drop-downs of its
    options bar (Arabic too). A name is read without the kit's icons in
    it (private-use letters, which a reader cannot say: "Notify", not
    "🔔 Notify"), so an icon alone is no name.
  - the tab strip's "New tab" button said it was the strip's stop of Tab
    (it had the strip's id): it has its own now.
  - Retro Photo and Retro Board hid their panels with Tab even when one
    of their controls had the keyboard, so Tab could not go through them:
    Tab hides the panels now only when no control has the keyboard
    (`focusInControls`); clicking the picture or the board gives it the
    keys again, and they start with the keys their canvas's (`autoFocus
    = false`).
  - On Android the emulator job drives every APK the same way:
    `RETRO_DRIVE` given with its start, the port through `adb forward`,
    `build/tour --port`. Through `adb forward` the port takes a
    connection before the app on the phone listens, then drops it: the
    tour and `retrokit drive` ask the app once before they count it as
    there (`driveConnect(..., probe = true)`).
- **Screen readers:** an open drop-down's items are read and pressed
  (`combo`, the editable drop-down, every popup list), the editable
  drop-down and the date box say whether they are open, as `combo` did; a control a reader asks to see is
  scrolled to in every view that scrolls, not only the page (`wantSeen()`
  for a view of your own). The driver finds a node by its id (`"node"`),
  and a name alone prefers a control to a label of the same text.
- **Thai and Vietnamese** in the fonts built in: FreeSerif's Thai (in its
  regular and bold: every face draws Thai with it) and the 90 Vietnamese
  letters in all twelve faces -- 56 KB more in every app (0.94 MB to
  1.0). `tools/genfreefont.py --add` adds letters to the subsets from any
  FreeFont release and keeps the rest of each face as it is (Debian's
  2021 FreeFont, cut whole, would have been 230 KB more for the same
  letters). Thai's vowels and tone marks are stacked by the kit
  (`thaiPlace`): a tone mark over a vowel above (กี่), over sara am's
  circle (น้ำ), left of a tall letter's stem (ปั้น), a vowel under a
  letter's tail (ฎุ) -- in labels and boxes and in documents
  (`textengine`, where a font without Thai tables is not shaped for
  Thai). A letter and its marks are one step of the caret and one word.
- **A bug of Nim's, worked round:** `unicode.strip` -- the `strip` a
  module that imports `std/unicode` calls -- cuts the last byte of a line
  ending in a letter whose last byte is 0x85 or 0xA0: Thai ภ, †, one
  Chinese character in 32, the kit's own pixel icons. Found when the
  driver's tree of the gallery was not UTF-8 (an icon's label, cut).
  Every module of the kit and the examples that strips imports
  `std/unicode except strip`; `test_hardening` (`noRuneStrip`) keeps it
  so; the report is ready in `docs/nim-bugs.md`.
- **HTML: flexible boxes and grids.** `htmlView` lays out `display:
  flex` -- rows wrapped or not, columns, the room shared by `flex-grow`
  and `-shrink` from each box's `flex-basis`, width or content,
  `justify-content`, `align-items` and `-self`, `gap`, `order`, right to
  left -- and `display: grid` with `grid-template-columns` (pixels,
  percents, `fr`, `repeat`, `minmax`, `auto-fill`) and `grid-column:
  span`.
- **Retro Photo 4.9.10: Image > Mode > Multichannel.** Each channel an
  ink of its own -- RGB's red, green and blue become cyan, magenta and
  yellow, CMYK's four inks stay, a gray image is one black; the layers
  flattened. Deleting a channel in Channels takes its ink out (an RGB
  image becomes Multichannel first). Saved as Photoshop's Multichannel
  documents (mode 7: the plates and their names) and opened from them, as
  any Multichannel file is (four inks printed as CMYK, three as cyan,
  magenta, yellow); `.rpd` keeps them. A Multichannel image made from
  CMYK keeps its four inks: the kit keeps CMYK as the picture it prints,
  and a black taken out would come back when separated again.
- **Retro Files 3.3.8: View > List** -- small icons in columns that go on
  to the right, scrolled sideways, as Explorer's List. `iconView`'s
  `columnWise`; `FileView.fvList`.
- **3D: shadows on the ground.** `addShadow` lays a soft shadow under
  the scene's meshes (on the floor when there is one); called again after
  a pose changes, it replaces the old one. A mesh can be `ghost`: seen,
  not picked; glTF export leaves it out. The gallery's car and model have
  theirs.
- **Input methods with SDL 2 and SDL 3** are drawn in the text box, as on
  the other systems: what is composing (`TEXTEDITING`), its candidates
  under the caret (`setTextCaret`). And a word an input method gives at
  once was cut to its first letter there: every letter comes now.
- **Retro Designer: View > Names and Tab Order** numbers the window's
  stops of Tab in their order and outlines in red the controls a screen
  reader cannot name; Properties says how the chosen control is read
  (`Read as: button "Save"`), **Name It...** writes `accessName "..."`
  before one without a name, **Driver Command** copies the command that
  clicks it. The designer draws `accessName` and `accessNameOr` (they
  are in its registry now).
- **Frames, measured.** Release builds of the big apps, a smoke run each
  with `RETRO_STATS=1`: a frame takes 0.3 to 0.4 ms on average (the
  gallery, Retro Photo, Retro Mail...), and an input runs two of them --
  the second rule stays: cheap, and some 170 places read a press
  directly. `RETRO_STATS` now names every frame of 250 ms or more (where
  the mouse was, the key, the control with the focus with
  `RETRO_ACCESS=1`), and found one: the gallery's System page asked the
  system's dark look of `gsettings` in the frame -- 400 ms the first time
  on a desktop without a session bus, 5 to 15 ms every 5 seconds after.
  `systemDarkMode` waits for it the first time only; then it asks in the
  background and keeps the last answer. The SDL 2 and GTK 4 drivers wait
  for an event without waking every few milliseconds to look.
- **The docs against the code:** `tools/docscheck.py` (in CI) checks
  that what the pages name is there -- every `RETRO_` setting read and
  documented, `nimble` tasks, `retrokit` commands, files, the calls the
  examples show, README's tests. BUILDING.md lists every `RETRO_`
  setting; README's Limits say what is left. `nim jsondoc` reads the kit
  again (a doc comment and the driver's sockets stopped it).
- The smoke run fails an app that draws more than 10 frames in 3 seconds
  untouched (was 30): a driver that draws twice is caught.
- New: `tabStops`, `focusInControls`, `wantSeen` (core); `thaiPlace`
  (typeset); `placesMark` (otshape); `addShadow`, `Mesh3.ghost`
  (view3d); `SpotChannel`, `toMultichannel`, `deleteSpot`,
  `canDeleteSpot`, `channelGrayOf`, `hasComposite` (photo); `spots`,
  `spotNames` (psd); `BoxFlow`, `FlexJustify`, `FlexAlign`, `GridTrack`
  and the style's flex and grid fields (htmlcss).
- The kit, Retro Gallery and the small examples 0.37.0; Retro Photo
  4.9.10, Retro Files 3.3.8, Retro Board 1.3.8, Retro Task Manager
  1.0.4, HR Book 0.2.4, Retro Communicator 1.3.1.

## 0.36.0

Enter opens a drop-down past a default button, an inspector says why
each frame ran, a driver uses any app by its controls' names, and 7GUIs
is among the examples.

- **Enter belongs to the focused control that acts on it** (#9). A
  default button drawn before a drop-down took Enter, so the gallery's
  pickers could not be opened from the keyboard. Every control that does
  something with Enter -- the drop-down, the date picker, the editable
  drop-down, the grid while it edits or on a list cell, the property
  grid and its edit, links, color wells, avatars, the floating button,
  MDI icons, drive tiles, accordion headers, KPI tiles, stat cards, the
  tag box, the path bar, find's box, a chart's points, a list of
  suggestions, a banner's close box, the number box's slider -- now says
  so (`ui.takesEnter = true`), and the default button leaves Enter to it.
  A control of your own does the same. `tests/test_keys.nim` opens two
  drop-downs and a date picker past a default button with Enter;
  `tests/test_hardening.nim` checks the kit's source: every Enter it
  reads has the claim before it.
- **The inspector: F12** in a debug build, or `RETRO_INSPECT=1` in any
  (shown from the start). A panel at the side of the window says how long
  the frame took and how many ran in the last second, **why it ran** --
  the input, or the line of the program that asked for it, `ui.redraw =
  true` or `wakeIn` -- and what the next one waits for; outlines the
  control under the mouse with its kind, name, value, id, place and
  states, and the one with the focus; and lists the frame's controls as
  a screen reader gets them. Shift+F12 moves it to the other side; it
  takes no click. `retroui/inspect`: `showInspector`, `findNode`,
  `nodeAt`, `nodeRect`, `nodeLine`; `accessKeep` keeps the last frame's
  whole tree in `accessLast` (tests find controls by name with it);
  `whyFrames` and `frameCause` in the core. `ui.redraw` is read and set
  as before (it is a template now, which notes where it was set).
- **X11: one frame where there were two.** The inspector's first find:
  every frame shown woke the program again -- the server's NoExpose
  answer to the copy of the picture -- so every caret blink and every
  timer ran two frames. The copies ask for no such answer now, and the
  wait goes on through the server's own traffic until an event of the
  program's or the time asked for.
- **The driver: `RETRO_DRIVE=PORT`.** An app started with it takes
  commands on 127.0.0.1 -- a JSON object a line, an answer a line -- and
  does them as a person would: finds a control by its name, clicks it
  (or a point), moves the pointer, scrolls, presses or focuses it or sets
  its value as a screen reader does, presses keys (`ctrl+s`), types any
  text, waits for frames, for a time or for a control to come or go, and
  closes the window by its close box. An action is answered once the app
  has taken it and drawn the frames after it. While it waits it draws
  nothing (`idlePollers`, asked every 50 ms). `retroui/drive`,
  `retroui/driveclient` (the other end, for tests and tools, without a
  window), `retrokit drive PORT COMMAND...` (or a command a line from
  stdin). On Android the start's `--es RETRO_...` extras are the app's
  environment (`adb shell am start -n ... --es RETRO_DRIVE 7000`). Every
  app carries it for about 40 KB: it reads its commands itself and
  speaks to the system's sockets directly (Nim's JSON and `net` would be
  70 KB); "hello" is 2.1 MB with `retrokit small` (the README said 1.9,
  from before the last releases).
- **The apps driven by their controls' names:** `tests/drive/run.sh`
  clicks every tab of the gallery, Notepad, Retro Task Manager, HR Book
  and 7GUIs, opens and closes every menu, asks after each step that the
  app is still there, then closes it by its close box; the systems
  workflow runs it on Linux, Windows and macOS. `tests/test_drive.nim`
  drives an app from the same program (Arabic typed, a drop-down opened
  by Enter past a default button).
- **7GUIs** (`examples/sevenguis.nim`, `nimble sevenguis`): the seven
  tasks of the GUI benchmark -- counter, temperature converter, flight
  booker, timer, CRUD, circle drawer with undo, and a spreadsheet with
  formulas that reach every cell that reads them, cycles said.
  `tests/test_sevenguis.nim` uses each task by its controls' names; its
  picture in examples/README.md was taken by driving it to its last tab.
  What it asked of the kit: the grid's `editText` (an edit starts from
  the formula, not the value shown) and its event's `curCol`, and
  `edit(..., invalid = true)` -- a box drawn red while what is in it is
  wrong (`InvalidRed`).
- **The red runs of 0.35.0's systems workflow:**
  - Android 11 and 15: Retro Photo closed at its first start. The
    emulator job's new report named it: its opening picture was painted
    before the window had a size (a width below zero), an index out of
    range. The splash waits for a window now. **Retro Photo 4.9.9.**
  - Android 15: the emulator went offline after it, and the six apps
    after it "did not install": the job waits up to a minute for the
    emulator before each app, and installs once more.
  - Windows: a check of the Android glue in `test_hardening` read the
    file with Windows' line ends (CR LF): read with LF now.
  - macOS: `test_richedit`'s F7 jumped past "mornin", which the Mac's
    spell checker knows: the test takes words every checker flags, and
    the system's own first suggestion.
- New in the core: `feedEvent` (an event as if from the system),
  `eventsWaiting`, `idlePollers`.
- The kit, Retro Gallery and the small examples 0.36.0; Retro 7GUIs 0.36.0
  among the apps `nimble` builds for every system; Retro Photo 4.9.9.

## 0.35.0

Lists drawn by hand cost what is on the screen, every example has a page
with its picture, and the CI's red runs are fixed.

- **`visibleRows`**: a list you draw yourself in a `panel`, `scrollPanel`,
  `pane` or the page draws only the rows in view; the others keep their
  room, so the scroll bar and what comes after are where they would be.
  Rows of one height (measured as drawn) or, `varying = true`, each of
  its own, kept from the last time it was drawn (text that wraps). 3,000
  labels, a release build: 1.5 ms a frame drawn all, under 0.1 ms so
  (`tests/test_rows.nim` measures it). New in the layout, for lists of
  your own: `layoutY`, `layoutWidth`, `inColumn`, `skipDown`.
- **Retro Communicator 1.3** draws only the lines of a talk in view, so a
  long talk stays quick to type in; it still opens at the newest line.
- The README's "How it works" says what a frame costs: the code you run
  each frame, a list in your own loop each row (a key or a click runs the
  frame twice, so what it changed shows at once -- kept: some 170 places
  in the kit and the examples read a press directly, and would show a
  stale screen without the second run).
- **examples/README.md**: every example with its picture, what it is and
  how to run it; `tools/exampleshots.sh` takes the pictures no other page
  has (hello, the gallery, Chart Viewer, Native, HR Book's demo book, the
  magazine).
- **Android: a second activity takes the app over.** Retro Photo no
  longer crashed on the emulator with 0.34.0, but still closed at its
  first start, without a crash: most likely an activity Android made a
  second time, which 0.34.0 closed. Now the app goes on in an activity
  Android makes beside it or in its place: the old one's window and
  input are let go, then it finishes. And the emulator job says why an
  app's process ended when one closes (Android's exit record, the crash
  log, the activity's events, on a 16 MB log), so the next run tells.
- **The systems workflow on Windows:** the smoke runs read the processor
  time from `GetProcessTimes` (the C library's `clock()`, `cpuTime`'s, is
  the time on the wall there: every app was "busy").
- **The nightly runs:**
  - 32-bit programs and WebAssembly (UBSan): the JPEG decoder's IDCT, the
    WebP encoder's scores, a JPEG XL tree's limits, OpenEXR's B44 and its
    offsets, and the grain of Develop went past 32 bits, which C
    leaves undefined -- 64 bits or wrapping now, the same results as
    before on 64-bit systems. The job installs the 32-bit OpenSSL (the
    XMPP, OMEMO and IMAP tests need it).
  - Fuzzing: a Gantt task's progress of NaN drawn as a whole number
    (undefined): drawn as 0 now.
  - Sanitizers: LeakSanitizer's suppressions given by full path (two
    tests change folder), and the SVG blow-up check given more time
    under ASan.
  - WebAssembly: a test that did not build (four big builds at once can
    run out of memory) is built again once, and its log's end shown.
- Retro Communicator 1.3; the kit, Retro Gallery and the small examples
  0.35.0.

## 0.34.0

The kit checks itself as people use it: every app started for real on
every system, measured at rest, its crashes named -- and the fault this
found in Retro Photo on Android.

- **Retro Photo stopped on Android's emulator, in its start** (Android 11
  and 15, since 0.32): a second activity in the same process ran the
  app's start (NimMain) again on a new thread while Photo's table of
  filters still held the first run's closures -- counted by Nim's cycle
  collector as roots of the first app thread -- and the new thread's empty
  list of roots was read at -1 (`SIGSEGV` at `-16`, in `rememberCycle`, from
  `defFilter`; the stripped 0.32 APKs said only addresses, the 0.33.1 run
  named it). Now the activity is its task's only one (`singleTask`:
  started again by its icon, an intent or `am start`, it comes back as it
  was); an activity made while the app runs closes, every callback of an
  activity no longer the app's is let go, and when NimMain returns its
  thread's cycles are collected (uirelays, `uirelays_main_ended`), so an
  app started again in the same process never reads the first thread's
  list. `tests/test_hardening.nim` checks all four.
- **Every app started for real** (`RETRO_SMOKE=14`; `tests/smoke/run.sh`,
  in the systems workflow on Linux, Windows and macOS): its own window and
  the system's driver, in a home of its own; the kit times the first frame
  (`firstFrameMs`), measures 3 seconds untouched -- the frames run and the
  processor's time -- then clicks, presses keys, turns the wheel and types
  until the time is up (on X, xdotool's real input too). It ends 0, 1 on a
  fault, 2 when the app was busy while untouched; a line for each app goes
  to `build/smoke/results.txt`. Its first run found Retro Mail drawing 17
  frames a second at rest (it set its tool bar's look every frame:
  `setToolbarLook` and `setTabLook` now draw again only on a change, as
  `setUiScale`, `setTextScale`, `setBaseTextSize` and `setResizable` do),
  and that a caret blinked for ever.
- **A caret rests:** it blinks for `CaretBlinkFor` (10 seconds) after it
  last moved, then stays shown, as Windows' does -- a window left with a
  text box focused runs no frames (the text box, the masked one, the rich
  text editor).
- **A covered window draws nothing**, as a minimized one: X11's
  `VisibilityNotify` (fully obscured), macOS' occlusion state, Wayland's
  suspended state (xdg-shell 6); `ui.hidden` meanwhile.
- **No crash loop:** the "stopped" screen's Start marks the start; when the
  app stops again within seconds, the next screen says it stopped right
  after it started, and its box "Start without what was open the last
  time" is ticked (`lastStartMark`, `markStarting`). A start mark is kept
  for the first 20 seconds of every run.
- **A crash report with its functions' names:** `retroapk` strips the
  APK's library with llvm-strip and keeps a copy with its names beside it,
  `APP-symbols/ABI/libmain.so` (the Release has `APP-symbols.zip`);
  `retrokit symbolize report.txt build/RetroPhoto-symbols` (or
  `retroui/symbolize`) names each frame of the "stopped" screen's report
  or of logcat's. A `--debuggable` APK keeps its names and exports them.
- **Android's emulator job** turns each app both ways, puts it away and
  brings it back (as its icon does) before the monkey, and prints the
  app's own log lines and its activity's starts with a crash.
- **Retro Task Manager on a Mac:** the connections with their programs
  (`proc_pidfdinfo`: TCP with its state, UDP) and the disks' reads and
  writes (IOKit's statistics of each disk, loaded at run time).
- Retro Files 3.3.7, Retro Photo 4.9.8, Retro Board 1.3.7, Retro Mail
  1.1.3, HR Book 0.2.3, Retro Task Manager 1.0.3; Retro Gallery and the
  small examples 0.34.0.

## 0.33.1

One branch: `main`.

- **GitHub's workflows run on a push to `main` only.** "Every system" ran on
  `next` and on `main`, so pushing both at once ran it twice on the same
  commit; "Real devices" ran only on `next`. Both now run on `main` (and by
  hand from the Actions tab), with CI as before -- there is no `next` to
  push to any more. AGENTS.md and the README say so.
- Retro Gallery and the small examples 0.33.1.

## 0.33.0

What GitHub's runs of 0.32 showed -- above all, every Mac app stopped at its
first event -- and a minimized window that draws nothing.

- **macOS: every app stopped at its first click or key** (since 0.29): the
  Cocoa backend's `sendOne`, which keeps the window an event is for while
  Cocoa handles it, called itself where it meant `[NSApp sendEvent:]`, and
  the first event ran the stack out. The live check's run under lldb (from
  0.31.1) showed it at once. `tests/test_hardening.nim` now fails when a C
  or Objective-C function of the drivers calls itself.
- **A minimized window draws nothing** (as Argus reads less often while
  nobody looks): uirelays has `WindowHiddenEvent` and `WindowShownEvent`
  (X11: unmapped or `_NET_WM_STATE_HIDDEN`; Windows: minimized; macOS: in
  the Dock); the kit's `ui.hidden` is true meanwhile -- the app's frames
  and timers go on, nothing is drawn or sent to the screen, and all of it
  is drawn when the window is back. Retro Task Manager reads the system
  every 5 seconds then. Tested on a real X server (Xvfb) and in
  `tests/test_frame.nim`.
- **Retro Designer builds on Windows and macOS again:**
  `mediaSessionBusName` is there on every system ("" without D-Bus), and
  its drawing of a page has no unused import there.
- **Windows:** a PMTiles archive that cannot be read is closed (a map's
  file could not be removed after), and an archive is opened for each
  read, so an offline map shown is never kept open; the IMAP test closes
  its database, the tile map test its archive, and the Authenticode test's
  time-stamp authority is given its paths with forward slashes (OpenSSL's
  configuration reads a backslash as an escape). The check for apps that
  ask Nim for the command line compares Windows' paths too.
- **A Mac's spell checker** takes the Arabic word the rich text test marks
  as wrong: the test asks the checker first.
- **Android's emulator job names a native crash's functions:**
  `retroapk --debuggable` leaves the library unstripped and turns Nim's
  stack traces on, and `tests/android/apps.sh` looks the crash's frames
  up in it (the NDK's `llvm-addr2line`). Retro Photo stops on the emulator
  in a worker thread: the next run says where.
- Retro Files 3.3.6, Retro Photo 4.9.7, Retro Board 1.3.6, Retro Mail
  1.1.2, HR Book 0.2.2, Retro Task Manager 1.0.2; Retro Gallery and the
  small examples 0.33.0.

## 0.32.1

Retro Files opens as an Android app again.

- **Retro Files closed at its start as an APK** ("paramCount is not
  implemented on current platform"): it asked Nim for its command line (a
  folder to open), and an Android app has none -- Nim raises. The kit
  has `appArguments()` now: the words on the command line where there is
  one (a desktop, Termux), none in an Android or iOS app and in a web page.
  Retro Files, Retro Photo, Retro Board and the Chart Viewer ask it (the
  Chart Viewer had the same fault as an APK); Retro Photo and Retro Board
  now open what is named on Termux's command line too.
  `tests/test_hardening.nim` fails when an app or a module asks Nim for
  the command line itself; AGENTS.md and the skill say why.
- **The report of a fault says the app's version** (the "stopped" screen
  said "Version: -"): `reportedVersion`, set before the window opens (the
  "stopped" screen comes before any About box), and kept by `aboutBox`
  from its `version`; `problemBox` uses it unless given another. Retro
  Files, Photo, Board, Mail, HR Book and Task Manager set it.
- Retro Files 3.3.5, Retro Photo 4.9.6, Retro Board 1.3.5, Retro Mail
  1.1.1, HR Book 0.2.1, Retro Task Manager 1.0.1; Retro Gallery and the
  small examples 0.32.1.

## 0.32.0

Retro Task Manager -- what the computer is doing, on every system -- and
what Argus taught about doing that lightly, in the kit.

- **Retro Task Manager 1.0** (`examples/taskman.nim`, `nimble taskman`,
  `nimble taskmanapk`): the processes with their share of the processor,
  the memory and the disk (search, sort by any column, End task, End
  process tree, a priority, Open file location, Properties; Delete ends
  the one selected, after asking), the processor (and each core), the
  memory, the disks and the network as graphs that move, the programs
  that start with the system (turned off and on), the network's
  connections with their programs, and the last week's history; the
  update speed (twice a second, every second, every 4 seconds, paused);
  on a phone, a bottom bar. Linux, Windows, macOS, Termux (a BSD: what its
  Linux /proc shows); an
  Android app sees its own process, the memory, the storage, the network
  and the battery.
- **`retroui/sysmon`:** the system read on a thread of its own, every
  second or as often as asked (`setMonitorInterval`), never waited for
  (`latestSample`: the last good numbers, `stale` when a read failed);
  each process known by its id and its start time (an id is used again:
  `endProcess` leaves another program alone, and checks a process newer
  than the last sample with a read of its own), its rates from the real
  time between two reads, what does not change (its file, its command
  line, its user) read once and kept; `takeSample` (one read at a time,
  whichever thread asks), `monitorHistory`, `endProcess`,
  `endProcessTree` (a child is one that started after its parent: on
  Windows a parent's id may be another program's by now), `setPriority`,
  `startupItems`, `setStartupEnabled`, `connections`, `appendHistory`,
  `loadHistory`. /proc and /sys (Linux, Termux, Android; a BSD's linprocfs); one
  NtQuerySystemInformation for every process, each physical drive's
  counters, the connections' tables (Windows); host_statistics64 and
  proc_pidinfo, the memory as Activity Monitor counts it (macOS).
- **`liveGraph`** (charts): a task manager's graph -- black, a green grid
  that moves with the line -- kept as a picture that moves left a step for
  each new value, only the new part drawn: a frame costs a copy, whatever
  the number of values (Argus scrolls its chart layers so). Graphs no
  longer drawn let go of their pictures.
- No unused import in `retroui/mediaaudio` on the BSDs, nor in the guide's
  tool (`tools/shots.nim`). The guide shows `liveGraph`, and `popupSlider`'s
  whole description.
- `tests/test_sysmon.nim` (a sample's numbers, this program among the
  processes, the reading thread, a child given another priority and
  ended, an id that is another process's left alone, the autostart
  entries turned off and on, a socket of its own among the connections,
  the history on disk, the graph's frame), `tests/test_taskman.nim` (the
  app: the list, the selection kept on the same process as the samples
  come, search and sort, the graphs, the other pages, paused).
  Both run on Windows and macOS too, in the systems workflow.
- Retro Gallery and the small examples 0.32.0.

## 0.31.1

What GitHub's CI found in 0.30.1 and 0.31.0, fixed -- among it Retro
Photo's filters at 16 and 32 bits, which 0.30.1's cleanup of unused
imports had taken away.

- **Modules imported for what they set up are imported again.**
  `retroui/photodeep` fills in Retro Photo's filters, flattening and
  gradients at 16 and 32 bits when it is imported; nothing of it is called
  by name, so Nim called the import unused, and 0.30.1 took it out of
  Retro Photo (4.9.5 has it again). The same for the Magazine example
  (`photostyles`, `photodevelop`: layer styles and adjustment layers),
  `retroui/adobefiles` (`photoshapes`: a file's shape layers) and the
  tests of the blend tables, Photo's color adjustments, 16-bit pictures,
  SVG and the GPU's composite (the CI's crash in `test_blendfast`). Such
  an import now sits between `{.push warning[UnusedImport]: off.}` and
  `{.pop.}` with a word on what it sets up; `tests/test_photoapp.nim`
  checks that every hook of `retroui/photo` is filled in Retro Photo.
- **The tests' last unused imports** (a test built before, from the
  cache, showed none here): gone, the UI fuzzer's too. The fonts option
  test, built a second time with `-d:retroFonts=ui` as `nimble test`'s
  last step, had lost its `getEnv` to the same cleanup (only that build
  uses it): it imports it for that build alone. The whole suite ran from
  a clean cache, that step included.
- **On a Mac** the tests press Alt + a letter as everywhere else:
  `optionLetters` (false by default: Option types on a Mac) lets Option +
  a letter pick the underlined letter, and the tests' driver turns it on.
- **The live check on Linux** ended with SIGABRT after "all passed":
  WebKitGTK's own teardown at the program's end runs on the main thread,
  not on WebKit's, and aborts once a video played too. A program that
  showed a web page now ends before that teardown (its work done, its exit
  code kept); the live check's exit code follows its results. On a Mac the
  live check stops at its start: the systems workflow now builds it again
  with its stack trace and runs it under lldb, so the next run says where.
- **A fault as the program ends** (a signal during that teardown) went
  into a file named from freed memory, in the current folder, instead of
  the fault log: the log's path is now also kept where nothing frees it,
  and on Linux, macOS and Android it is written with the calls a signal
  handler may make. `tests/test_stopped.nim` scribbles over the path's
  string and checks the log.
- **The live check's pictures** have no pointer in them (the CI desktop's
  mouse lit a bar of the chart on Windows).
- **The pixel compare** leaves out a phone's pictures (a screen of its
  own shape, not the desktop's 800 x 600): they are kept to look at.
- **Windows:** the mail tests' stand-in server finds its time zones there
  too (Python without the tzdata package: the workflow installs it, and
  the server has the tests' zones at their November offsets).
- **The emulator job** tried only the first app: `adb shell` read the
  list of apps meant for the loop. Every adb call reads nothing now; an
  app is opened by its launcher activity and waited for (up to 30 s for a
  big library on an emulator), the system UI's own stops are not the
  app's, and a failure shows what the system said of the app's process.
- **The systems workflow** runs every portable test even after one
  fails, so a run shows them all.
- Retro Photo 4.9.5; Retro Gallery and the small examples 0.31.1.

## 0.31.0

Retro Mail reads and sends the mail of any provider -- IMAP and SMTP,
with a password -- and the kit has what that takes: connections with the
system's own TLS, IMAP, SMTP, and finding an address's servers.

- **IMAP accounts in Retro Mail (#2 on GitHub).** File > Add Account, an
  address Retro Mail does not know (or "Another provider (IMAP)"): type
  the password, and the servers are found by themselves (below); check
  them or change them, Next signs in to both and the mail comes. Folders
  with what they are for (Sent, Drafts, Trash, Junk, Archive: the
  server's special-use flags, else their names in English, German,
  French, Spanish, Italian, Dutch, Russian and Arabic), the newest mail
  first for the days kept, then only what is new (UIDs) and only the flags
  that changed (CONDSTORE); read, flag, tags (as IMAP keywords: what
  Thunderbird's five are, they are here), move, delete, Trash, Junk, all
  sent to the server; sending through SMTP with a copy in Sent (Gmail and
  Microsoft 365 keep one themselves); a reply marks what it answers;
  meeting invitations read from the message and answered by mail;
  searching the server's Inbox and Sent too. The password is kept
  encrypted with the account's sign-in (as the tokens are); when the
  server stops taking it, the account asks for it again (Tools > Options >
  Accounts > Servers... changes the servers). An IMAP account has no
  calendar and no automatic replies here (IMAP has neither).
- **`retroui/netconn`:** a connection to a server over TCP, encrypted
  with TLS from the start or after STARTTLS, read by lines and bytes with
  a timeout -- through each system's own TLS, with its certificate
  authorities: SChannel on Windows, Secure Transport on macOS and iOS,
  Java in an Android app, OpenSSL on Linux, the BSDs and Termux (loaded
  the first time a connection is encrypted, so a program without it still
  starts). `insecure` takes a server's own certificate (a server at home).
- **`retroui/imap`:** IMAP4rev1 / IMAP4rev2: sign in (PLAIN, LOGIN,
  XOAUTH2), folders and their special use, SELECT with CONDSTORE, SEARCH,
  FETCH of header fields, flags and whole messages (literals of any size),
  STORE, COPY, MOVE (or copy, then delete), EXPUNGE, APPEND, CREATE,
  DELETE, RENAME, STATUS, any other command (`command`); folder names in
  modified UTF-7 both ways.
- **`retroui/smtp`:** sending through a server: TLS or STARTTLS, AUTH
  PLAIN, LOGIN or XOAUTH2, SIZE, 8BITMIME, SMTPUTF8, dots doubled, each
  recipient refused said (`smtpSend`, or `smtpConnect`, `login`,
  `sendMail`, `quit`).
- **`retroui/mailsetup`:** where an address's mail is (`findMailServers`):
  the biggest providers known, then the provider's own autoconfig file,
  Thunderbird's list (ISPDB), DNS (SRV records, then the MX host's
  provider), and last the usual names.
- `retroapk` adds INTERNET for an app that opens connections.
- Tests: `tests/test_imap.nim` against a server of its own
  (`tests/imapmock.py`: IMAP and SMTP, plain, STARTTLS and TLS), with
  Retro Mail's engine and an IMAP account; on Windows and macOS too, so
  SChannel and Secure Transport are tried by the systems workflow (a step
  of its own, that does not fail the job until it has passed there).
- Retro Designer's registry builds without a warning (a module whose
  calls were all left out was imported; `tools/gendesigner.py` writes it
  so now).
- Retro Mail 1.1; Retro Gallery and the small examples 0.31.0.

## 0.30.1

Every CI failure fixed, builds that a phone or tablet finishes, no
warnings anywhere, an app's crash shown at its next start, the
permissions an app needs added by themselves, and the bugs people
reported on GitHub.

- **Builds on a phone or tablet.** In Termux, Android 12 and later stop a
  build that runs too many processes or uses much memory ("[Process
  completed (signal 9)]"). Every build -- `retrokit run`, `retrokit web`,
  `retroapk` -- now runs as many C compilers as the free memory allows,
  at most four in Termux (`--jobs:N`, `$RETRO_JOBS`; `retroui/buildjobs`),
  and the next build says when the last one was stopped, and that what it
  compiled is kept. `retrokit run --web --threads` builds once (with
  threads only: its server lets the page use them) instead of twice. A web
  page's link: `--lto:full` (as before, 1.5 GB for the Gallery), `thin`
  (in pieces: 0.9 GB, the default in Termux and with under 3 GB free) or
  `none` (the default of `run --web`: quick). BUILDING.md, "Building on a
  phone or tablet", says how to turn Android's limit off.
- **No warnings, on any system.** The kit's files had unused imports and
  code after a `return` that only some systems compile (the web, Windows,
  macOS, iOS, Android); all gone: an import used on some systems is
  imported under the same `when` as its use; the tests' own unused
  imports are gone too. `sh tools/warncheck.sh` checks every module, the
  tools and the examples as Linux, Termux, an Android app, Windows, macOS,
  iOS and the web (with threads and without) build them, and the tests. Retro Photo's saving, its undo's scratch disk and the asset
  downloads now build in a web page without threads (they did not).
- **CI.** The return check took `"oauth.result"` (a string) for a use of
  `result`, and the 3D view's picture had a real `return nil` after
  `result`: both fixed. The live check, the screen-reader check and the
  pixel compare did not find the kit (`tests/` and `tools/`' config named
  `$projectDir`: wrong for a program in a subfolder) -- they build now.
  `systemLanguage` gave "C" for `LANG=C.UTF-8` (English now). The tests
  that differ on a system say so: a Mac has no Alt+letter shortcuts; the
  spelling test types a word no dictionary has (Windows' took "Gud");
  `$RETRO_SCALE` wins over a kept size. The
  32-bit job installs its OpenSSL. **`sh tools/cicheck.sh`** runs what
  GitHub's CI runs, here.
- **MSIX packages as Windows' own packager writes them:** the sizes in the
  local headers, a data descriptor only past 4 GB (Windows did not verify
  the signature of the old layout; osslsigncode did). `retrokit msix
  --unsigned` makes one to sign elsewhere; when Windows still refuses one,
  the systems workflow signs the same package with signtool and prints the
  two signatures' digests side by side.
- **An app's crash, shown the next time it starts.** A crash of the native
  code on Android (a signal: `src/retroui/crashlog.c`, the addresses in
  the library) and of Java (any thread) is written to the app's fault log,
  as Nim's errors were. The next start shows it **before the app's own code
  runs** -- so a crash at the start shows too -- with Copy, Send by Email
  and Start (`stoppedScreen`; `app` does it, an app with its own frame
  loop calls `stoppedFrame`); "Start without what was open the last time"
  (`startFresh`) opens Files without its last folders, Photo without its
  last pictures, Board without its last board. `stoppedPending`,
  `showStoppedScreen`, `lastRunStopped`, `peekFaults`.
- **The permissions an Android app needs, by themselves.** `retroapk`
  reads the app's compiled code and adds the permissions of what it uses
  -- the camera, the microphone, notifications, the place, a buzz, the
  network -- and says which (`--no-auto-permissions` leaves them out); the
  hardware they imply is not required, so the app installs on a device
  without a camera or GPS. The app asks the user the first time the
  feature is used. The Gallery's System page now has all it asks for.
- **Every app on Android's emulator.** The systems workflow builds the
  main apps for the emulator (`nimble emuapks`) and opens each on Android
  11 and 15 with nothing allowed, then with every permission, drives it
  with the monkey, and fails on a crash (`tests/android/apps.sh`; the
  screens, the log and the app's own fault log are kept).
- **What people reported on GitHub:**
  - #1: Ctrl+Backspace takes the word before the caret, Ctrl+Delete the
    one after (Option on a Mac; Cmd+Backspace the line), in every text box
    and in Board's texts.
  - #3: the picture viewer (`imageView`: Retro Files' viewer) zooms about
    the mouse.
  - #4: Retro Photo's Move tool turns and sizes the layer from its box's
    handles and the corners' turning room before Auto-Select picks the
    layer under them.
  - #5: after Retro Files' viewer (Enter, then Esc) the keys go on from the
    file that was opened; the file list keeps the focus while it reads a
    folder or shows it empty (Backspace up a folder no longer sent the keys
    to the tree).
  - #6: a right click elsewhere while a menu is open closes it and opens
    the menu of what was clicked.
  - #7: a list (`listbox`) leaves Ctrl and Alt with the arrows to the app:
    Board's Ctrl+Shift+Up / Down make the next step and no longer change
    the page as well.
  - #8: letters typed on a drop-down list (`combo`) pick the item that
    starts with them: in the open list, and in the closed one when the
    keyboard brought the focus (Tab) -- a list clicked once leaves the
    letters, and Space, to the app's own keys (Retro Photo's tools, its
    Hand) (`ui.focusByKeys`).
  - #9: Enter opens a closed `combo`, a `datePicker`'s calendar
    and a `comboEdit`'s whole list (F4 and Alt+Down too); a date picked in
    the calendar shows in the box at once. And the round of keys its
    comments asked for -- the same keys for every drop-down: F4, Alt+Down
    and Enter open a grid's drop-down cells (the Records page's Store), a
    property list's choices, a `menuButton`'s menu (Space too) and a
    `splitButton`'s (Enter and Space do its default), a `popupSlider`'s
    slider; F4, Alt+Up and Alt+Down close an open one (a list on the item
    lit), Esc without picking (`dropKey`). docs/syntax.md has the table.
    A `splitButton`'s `ui.lastRect` is the whole button (it was its
    arrow).
- Retro Files 3.3.4, Retro Photo 4.9.4, Retro Board 1.3.4, HR Book 0.2,
  Retro Gallery and the small examples 0.30.1.

## 0.30.0

Web pages that do what apps do everywhere else -- threads, the camera,
the GPU, chat, signing in, Retro Mail itself -- smaller and faster; one
API for the system's features on every system; updates inside apps,
signed. Not 1.0 yet.

- **One API for the system's features: `retroui/system`.** Notifications
  and the badge, sharing (`share`: text, a link, files -- the share sheet
  of phones, macOS's menu, Web Share), a tap felt (`haptic`), the place
  (`location`, `stopLocation`), speech (`speak`, `stopSpeaking`,
  `speaking`), starting with the computer (`setOpenAtLogin`), asking for
  attention (`requestAttention`: the taskbar flashes, the Dock bounces, the
  tab blinks), `online`, `systemLanguage`, `battery`, `revealFile`,
  `deviceInfo` -- the same calls on Linux, Windows, macOS, Android, iOS and
  in a page; "not here" answers false, never an error, and nothing waits on
  the system. **`docs/system.md`** says what every call does on every
  system, what an app declares for it (Android permissions, Info.plist,
  https) and how to write it so it works everywhere. Android's part is
  `tools/android/RetroSystem.java`. The Gallery has a System page: the
  device, notifications, sharing, speech, the place, the camera, a
  recording, a secret, native code of each system.
- **Threads in web pages.** `retrokit web --threads` makes a second build
  with threads (`app-threads.wasm`) that the page takes where the browser
  lets it share memory with workers: the kit's drawing (`parallelFor`),
  pictures, maps and the app's own `createThread` run in Web Workers on one
  memory, each with its own stack and thread-local storage. The kit's C
  library has real locks (futexes: WebAssembly's atomic wait and notify;
  the page's own thread spins, and meanwhile does what the threads ask of
  the page), a heap behind a lock, `pthread_create` / `join` / `detach`,
  conditions, `sleep` in a thread. What a thread asks of the page -- its
  files, its console, the canvas -- the page does for it; its HTTP requests
  wait in the worker. The page is kept apart from other sites
  (crossOriginIsolated) on any server: its service worker adds the headers
  and the page loads once more the first time; without that (or with
  `?threads=0`) the build without threads runs. `--threads:N` starts N
  workers with the page; `--threads-only` builds only with them, for an app
  that cannot do without. `tests/web/threadcheck.nim` checks locks,
  atomics, channels, thread-local variables, files and memory from
  threads, conditions, `parallelFor`; the web checks run once more with
  threads.
- **Retro Mail as a web page.** `retrokit web examples/mail.nim
  --threads-only`: Microsoft 365 and Gmail through Graph and the Gmail API
  (HTTPS, from its sync thread), its SQLite database in the page's
  storage, signing in through a pop-up that comes back to `oauth.html`
  beside the page (`retrokit web` writes it; register its address).
  `retroui/oauth` signs in this way in any page.
- **The camera and the microphone in a page** (`retroui/capture`:
  getUserMedia; a recording is a 16-bit WAV), **the media keys and the lock
  screen** (`retroui/mediasession`: the browser's Media Session),
  **secrets** (`retroui/secrets`: sealed with AES-GCM by a WebCrypto key the
  browser keeps and never hands out), **screen readers** (the window's
  controls mirrored as ARIA elements over the canvas, the focus said as it
  moves, a screen reader's click a press), **chat** (`retroui/xmpp` over a
  WebSocket, RFC 7395: the server's host-meta says where), **the 3D view on
  the GPU** (WebGL 2, a context of its own, the picture read back),
  **printing** (the browser's print dialog), **files out and in** (what an
  app writes in `/downloads` is handed to the user -- the browser's Save
  As, or a download; Open is the browser's file chooser), **the end of the
  program** (File, Exit closes the window or says it ended, with Start
  again), **sound through an AudioWorklet**.
- **Smaller, faster pages.** WebAssembly SIMD, link-time optimization
  (`-flto`, the names section left out), `--small` with `-Oz`, the kit's
  fonts beside the page (fetched when a face is first used: 0.94 MB out of
  every app), a gzipped copy beside the wasm (`retrokit run --web` serves
  it), compiled while it downloads, frames shown through WebGL 2 (the
  changed rows uploaded straight from the program's memory; a 2D canvas
  where there is none). Character sets through the browser (`iconv`: every
  encoding the web knows), `getrandom`, file locks for SQLite in the page's
  C library: SQLite works in a page (Retro Mail's database, MBTiles maps).
  The app's data folder is made on demand there too (the fault log).
- **Updates inside apps: `retroui/update`.** The app reads the update file
  you publish (`update.json`: the newest version, its file for each
  system), checks its Ed25519 signature with the public key built into it,
  downloads the file for its system, checks its SHA-256, and installs it
  (an AppImage replaced, a Windows program or installer, a package handed
  to the system's installer, a page's newest build); `restartApp`.
  `retrokit update-key` makes the key (keep `update-key.secret` out of the
  repository: `.gitignore` has `*.secret`), `retrokit update-sign
  update.json` fills in the files' sizes and SHA-256s and signs it.
  Monocypher's Ed25519 (`vendor/monocypher-ed25519.c`); RFC 8032's test
  vectors in `tests/test_update.nim`.
- **Smaller programs: `-d:retroFonts`.** `all` (the twelve faces built in,
  as before), `sans` (FreeSans's four), `ui` (FreeSans and its bold: Hello
  goes from 2.2 MB to 1.4 MB), `none`; the faces left out are read from
  `fonts/` beside the program (or `$RETRO_FONTS`) when they are there, else
  drawn with FreeSans in the same style.
- **Tested further.** `.github/workflows/nightly.yml`: every night the
  headless tests under AddressSanitizer and UBSan, the mutation fuzzers
  for long runs, the decoders under libFuzzer (`tests/fuzz/libfuzz.nim`:
  PNG, BMP, JPEG, WebP, inflate, Markdown, HTML, PDF, glTF, vector tiles),
  the tests as 32-bit programs under UBSan (`RETRO32_UBSAN=1 sh
  tests/run32.sh`), and as WebAssembly under Node (`tests/web/node.sh`, on
  every push too). `.github/workflows/devices.yml`: the live check on real
  phones in Firebase Test Lab (with the `FIREBASE_SA_KEY` secret) and on a
  Raspberry Pi (a self-hosted runner). Screen readers on Windows: UI
  Automation finds the controls and presses a button
  (`tests/access/windows.ps1`). Chat over a WebSocket against a small
  server (`tests/web/xmppws.py`).
- **Before 1.0:** `docs/stability.md` says which APIs are settled, which
  still move, and how a change reaches you (deprecated before removed).
  `docs/nim-bugs.md` has two leaks of Nim 2.2's ORC and an overflow in
  its float parsing (libFuzzer found it in a glTF model), written up to
  report.
- **Fixed:** a shift by 32 of a 32-bit `uint` (undefined in C) that froze
  windows in web pages (Desktop's window ids); a program without windows
  in a page; the web builds of several apps in one folder at once (a
  cache each).

## 0.29.0

The kit on every system, on screens without a desktop and in the
browser, with maps, Blender's models, the system's media, more windows,
and the packages each store takes -- made in Nim. Not 1.0 yet: this
release is for trying in real apps.

- **Apps as web pages, without Emscripten.** `retrokit web app.nim` makes
  the app WebAssembly with clang and wasm-ld alone, with the kit's own C
  library (`src/retroui/web/libc`: memory, `printf` with exact floats,
  `strtod`, files, time, math through the browser) and its page side
  (`src/retroui/web/retro.js`), both carried inside the tool
  (`src/retroweb.nim`). The page installs (a manifest, icons) and works
  offline (a service worker: the app's files of 1 MB or less kept when it
  installs, bigger ones when first read); the app's files are at `/app`,
  its home folder kept in IndexedDB; input is the browser's (input methods,
  dead keys, paste, pens, touch); drops go to `/tmp/dropped`; sound through
  Web Audio, video through `<video>`; `httpRequest` through the browser
  (a short address is the page's own site); a web view is an iframe that
  talks with `retro.post`. The driver is
  `src/retroui/uirelays/drivers/web_driver.nim` (`-d:wasm`); the app runs
  frame by frame (`app` registers its frame; an uncaught error shows in a
  red box instead of stopping the page silently). `retrokit run --web
  [--watch]` serves it on localhost (ranges, no cache, reloaded on every
  save; `--port`, `--no-open`). `tests/web/run.sh` checks it in Chromium
  at 100 % and 200 %: clicks, typing, paste, the canvas against the
  frame, files kept across a reload, the server.
- **The screen driver: a screen with no desktop.** Kiosks, tills, panels,
  a Raspberry Pi with no X11 or Wayland:
  `src/retroui/uirelays/drivers/fb_driver.nim` draws to DRM/KMS (a dumb
  buffer in the connector's preferred mode; `RETRO_KMS_CARD`,
  `RETRO_KMS_MODE`) or the framebuffer (`RETRO_FBDEV`; 32, 24 and 16 bits),
  with a software cursor, and reads evdev itself: keyboards (the layout
  from `/etc/default/keyboard` or `vconsole.conf`), mice, touch screens,
  touch pads, pens with pressure, wheels, plugged in while it runs. The
  console is put in graphics mode; Ctrl+Alt+F1..F12 switch consoles (the
  screen given back and taken again), Ctrl+Alt+Backspace closes. The scale
  comes from the screen's millimetres. The default Linux build takes it
  when started on a console (or `RETRO_DRIVER=kms`, `fb`); `-d:kiosk`
  builds only it. `tests/kiosk/run.sh` checks it with a file as the screen
  (`RETRO_FB_FILE`) and pipes as the devices (`RETRO_FB_INPUT`).
- **The Wayland driver.** `src/retroui/uirelays/drivers/wayland_driver.nim`
  speaks Wayland's protocol itself (`wlwire.nim`: no libwayland), draws
  into shared memory (`pixbuf.nim`), finds fonts with fontconfig and
  FreeType loaded at run time (`ftfonts.nim`), keys with the compositor's
  keymap (`xkbload.nim`). Fractional scales (fractional-scale and
  viewporter), the system's frame (xdg-decoration) or the 3.1 frame by
  itself, cursor shapes or the classic cursors drawn, input methods
  (text-input-v3), activation, the clipboard and drops, touch, key repeat,
  compose. The default Linux build has X11 and Wayland and takes Wayland
  when there is no X11 (`RETRO_DRIVER=wayland`, `x11` to choose);
  `-d:wayland` builds only it; the BSDs too. `RETRO_WAYLAND_DEBUG=1` (or 2)
  says what goes on. `tests/wayland/run.sh` checks it on sway with no
  screen, at 100 % and 150 %. The system's web view needs X11: on Wayland's
  own driver the kit's engine shows pages.
- **More windows.** `window(open, title, w, h): body` opens a window of the
  system's own beside the app's -- a tool palette, a second view, a
  preview -- laid out and drawn as the app's is, with its own menus,
  dialogs and focus; its close button sets `open` to false, and it closes
  when it is no longer drawn. X11, Wayland, WinAPI and Cocoa open real
  windows; phones, the browser and the screen driver show a dialog.
  `beginWindow`, `endWindow`, `inWindow`; `Event.window` says which window
  an event is for (uirelays' `WindowsRelays`). `captionBar` draws the 3.1
  title bar where the system draws none (Wayland without server-side
  frames, the screen driver), as on phones.
- **Maps from every service.** `retroui/tilemap`: `tileMap(state, source)`
  is a street map of the whole world -- dragged, zoomed with the wheel,
  fingers, keys and its buttons -- from OpenStreetMap, OpenTopoMap, CARTO,
  Google (`googleTiles`, its session made for you), Azure Maps, Mapbox
  (raster and vector), HERE, MapTiler (raster and vector), Protomaps, Esri,
  TomTom, Stadia, AMap and Tencent (in GCJ-02, your GPS points moved to
  match), Tianditu, TileJSON, or your own maps: PMTiles (a file, or an
  address read in ranges), MBTiles, a folder. Markers, lines, areas with
  holes, circles; `fitBounds`, `fitPoints`, `centerOn`, `mapPointOf`,
  `metersPerPixel`; `keepArea` saves tiles for offline use (and refuses
  OpenStreetMap's servers, as their policy asks); the attribution of each
  source is shown. Tiles come on six worker threads (in the browser,
  fetched by it), are kept in memory (192 MB at most) and on the disk (a
  week), the tile above shown larger while one comes. `mapKitPage` and
  `googleMapsPage` make pages for `webView` of the maps that are not tiles.
  `retroui/mvt` decodes, draws (`classicStyle`, `darkStyle`, labels that
  never overlap) and writes Mapbox Vector Tiles; `retroui/pmtiles` reads and
  writes PMTiles. `retroui/geo`: places, reverse places and routes from 13
  services (Nominatim, Photon, OSRM, Valhalla, GraphHopper,
  OpenRouteService, Google, Mapbox, HERE, Azure Maps, TomTom, MapTiler,
  Esri), waiting or on a worker thread (`geocodeAsync`, `routeAsync`,
  `geoFinished`), the turns in words; distances, bearings, polylines
  (Google's, HERE's flexible), WGS 84 / GCJ-02 / BD-09, GeoJSON in and out;
  `routeShape`, `geoJsonShapes` put them on the map.
- **Blender's models in the 3D view.** `retroui/gltf` reads glTF 2.0
  (`.glb`, `.gltf` with its files or data: addresses): every accessor kind,
  normalized and sparse, triangles, strips and fans, the node tree, skins,
  morph targets, clips (linear, step, cubic spline), materials
  (metallic-roughness, pictures, alpha mask and blend, double-sided,
  KHR_materials_unlit, KHR_materials_emissive_strength,
  KHR_texture_transform, EXT_texture_webp); `toGlb` writes one;
  `loadModel3` takes a `.blend` through Blender when it is installed
  (`RETRO_BLENDER`), and `retrokit model car.blend` makes the `.glb` once,
  naming its parts and clips. The 3D view has nodes (`findNode`,
  `nodeNames`, `setVisible`, `tint`, `turnNode`, `moveNode`, `recolor`),
  clips (`play`, `stop`, `seekAnimation`, `animate`, `isPlaying`), bones
  and shapes, light that knows metal from paint and glass from chrome, a
  picked part's name (`View3DEvent.node`, `nodeName`), and draws lit
  triangles on all the cores. With the GPU (`RETRO_GPU=gpu`, or where the
  kit draws with it) it is drawn by OpenGL (`view3dgl.nim`: GLSL ES 1.00,
  a depth buffer of 24 bits where there is one), the same light, checked
  against the CPU's pixels (`tests/gpu3d`). `view3dOnGpu`, `view3dPicture`.
- **Store packages, made in Nim.** `retroapk --aab` (`retrokit aab`): an
  Android App Bundle for Google Play -- the manifest and resources in
  aapt2's proto formats, `BundleConfig.pb` (libraries uncompressed, 16 KB
  pages), JAR-signed with the upload key; it passes `bundletool validate`
  and makes APKs. `retrokit sign app.exe`: Windows' Authenticode signature
  (SHA-256, the checksum made again, an older signature replaced), with an
  RFC 3161 time stamp (`--timestamp:URL`). `retrokit msix app.exe`: an MSIX
  (its manifest for a desktop program, logos from the icon, the block map
  with each 64 KB block compressed on its own, the content types, ZIP64
  records, the signature over its four digests), the program inside signed
  too; the publisher is read from the certificate. `retrokit mac app`: a
  macOS `.app` (Info.plist, the `.icns` written in Nim, the files),
  signed ad hoc in Nim -- the code directory of each architecture, the
  sealed resources, as `codesign --sign -` makes them -- or on a Mac with
  your Developer ID (hardened runtime, secure time stamp), notarized and
  stapled (`--notarize`: `xcrun notarytool`, `stapler`), zipped.
  `retroios --ipa` and `retrokit ipa`: the `.ipa`. The modules:
  `retroui/sign` (DER, certificates, CMS, JAR, Authenticode, time stamps),
  `retroui/msix`, `retroui/macapp`; `src/retrostore.nim` the commands.
  Checked with `jarsigner`, `bundletool`, `osslsigncode` (every digest, and
  the time stamp of an authority made with OpenSSL) and `rcodesign`
  (`tests/store/linux.sh`); on GitHub by Windows itself
  (`Get-AuthenticodeSignature`, `signtool verify`, `makeappx unpack`, the
  MSIX installed and removed) and by macOS (`codesign --verify --deep
  --strict`, the app run, a universal build).
- **The system's media.** `videoView` plays in the window on Windows
  (Media Foundation) and macOS and iOS (AVFoundation) as on Linux and
  Android, files and web addresses (HLS where the system plays it), drawn
  by the kit under its menus and dialogs. `retroui/mediasession`
  (`setNowPlaying`, `endNowPlaying`, `mediaKeys`): what the app plays on the
  lock screen, the taskbar's flyout, Now Playing, the desktop's applet --
  MPRIS, the System Media Transport Controls, MPNowPlayingInfoCenter, a
  MediaSession -- and their buttons and the media keys back to the app.
  `retroui/capture`: the camera in the window (`cameraView`, `cameras`,
  `cameraPhoto`, `cameraRecord`, `cameraStop`, `cameraFrame`,
  `cameraClose`; Video4Linux, Media Foundation, AVFoundation, Camera2,
  Termux:API) and the microphone (`recordSound`, `stopRecordingSound`,
  `recordingSound`, `soundLevel`).
- **The web view inside the app.** Under the app's menus and dialogs the
  system's view steps aside and a picture of the page stands in (every
  engine). `webPermit` says what a page may use (camera, microphone,
  location, notifications), `WebEvent.asked` what it asked for and was
  refused; `WebEvent.downloads` the files it downloads (into Downloads);
  a page's file box opens the system's chooser; `webAppFolder` and
  `webAppUrl` give the app's own pages an address of their own
  (`app://local/`; `https://app.local/` on Windows; Android's asset
  loader); `webPrint` prints the page.
- **On every system, with its own drivers.** The live check
  (`tests/live/livecheck.nim`) runs on GitHub on Linux, Windows, macOS, the
  iOS Simulator and the Android emulator (`.github/workflows/systems.yml`),
  its frames compared with `tests/live/ref` (`tools/live/compare.nim`):
  the kit draws the same pixels everywhere. The same workflow runs the
  Wayland, screen driver, web, GPU 3D, 32-bit and store checks.
- **Touch sizes from the environment**: `RETRO_TOUCH=1`, `RETRO_CONTROLS`
  (`touch`, `desktop`, `auto`) and `retrokit run --touch`, `--controls`:
  finger-sized controls on a desktop screen to try a tablet's layout; they
  win over the sizes kept in the app's settings, as `RETRO_SCALE` does.
- **32-bit, and so WebAssembly.** `tests/run32.sh` runs the tests as
  32-bit programs. What only fitted in 64 bits now fits everywhere: PNG
  checksums, WAV sizes, photo merging's noise, PSD's 16-bit alpha and
  paths, the photo engine's look-up tables, warps and bilinear sums (a
  perspective crop came out wrong), 16-bit picture files, TrueType's
  32-bit numbers, a JPEG's EXIF offsets, the designer's numbers, the edge
  finder's key (it overflowed with many layers on 64-bit too). Floats are
  hashed with all their bits (`hashF`: Nim's own `hash(float)` drops half
  of them on 32-bit).
- **Found by the new fuzzers, fixed:** a glTF index into a missing array,
  a JSON node of another kind, sizes and offsets whose products overflow
  (`fuzz_models`); a PMTiles offset past `int64` (`fuzz_maps`); a macOS
  program's sections read past its load commands, a universal program
  whose alignment no number holds, a Windows program's signature inside
  its headers
  (`fuzz_store`).
- **A picture the system decodes no longer leaks.** `loadPicture` handed
  back a picture from the system's decoder (every picture on Android and
  iOS, and on macOS and Windows the kinds the kit does not decode) with
  `return` after `result` was set, which Nim 2.2 does not free: each
  picture's pixels stayed until the app ended. The same shape freed
  nothing in the HDR reader (a damaged file), the PDF reader (a picture it
  does not read), font tables, links in rich text, the media players, D-Bus
  and the script engine. `tools/returncheck.py` finds the shape (0 in the
  kit and the apps; GitHub runs it), and `test_hardening` keeps it fixed.
  Found under LeakSanitizer too: a glTF model that an error stopped half
  read kept its parts when read into a variable the caller had, and a PEM,
  a board's picture, a data: address or a token with a letter that is not
  base64 kept what Nim's `decode` had made; `codec.unbase64` decodes
  without that.
- **The column view** keeps its columns for each folder model: two folder
  windows in columns (Retro Files' View > Folders in Windows) drawn with
  one `key` listed each other's folders again every frame, and the
  memory grew until the app was stopped. A model's listings and
  thumbnails not started are dropped when the view lets it go.
- `retroui/zip` reads ZIP64 archives (MSIX, files over 4 GB) and marks
  programs as such when it writes (`addFile(..., executable = true)`).
  `codec.deflatePieces` compresses in pieces each on its own.
  `rsa.selfSignedCert` keeps the subject in the order it is written and can
  mark a certificate for signing code; `imaging.windowIconFromPng` takes
  any sizes.
- Docs: README (apps as web pages, screens without a desktop, shipping to
  the stores, more windows, camera and microphone, the street map, models
  from Blender, the platforms table, tests, safety, limits), SECURITY.md,
  THIRD-PARTY-NOTICES.md (and LICENSE, which named files the kit no longer
  has), BUILDING.md, the controls guide, the syntax study, the skill and
  llms.txt.
- Retro Gallery and the small examples are 0.29.0. The Gallery's map page
  has a Streets button (OpenStreetMap's tiles, from the network) and its 3D
  side a Car: a model with named parts and two clips -- the door opens and
  closes, the wheels turn, Paint changes its color, a click names the part.

## 0.28.0

- **`webView` with the system's browser engine, on every system.** Give a
  view `engine = weSystem` (or set `RETRO_WEB=system` for all of them) and
  the page is the system's own browser placed over the widget: WebView2 on
  Windows 10 and 11, WKWebView on macOS and iOS, WebKitGTK on Linux and BSD
  (and Termux:X11), Android's WebView in an APK, as before. Nothing is
  linked: the engine is loaded when the first page is shown, and where
  there is none the kit's own engine shows the page. `WebEngine` (`weAuto`,
  `weSystem`, `weKit`) and `webEngine` choose; `weAuto` stays the kit's on
  desktops and the system's in an Android app. `src/retroui/webnative.nim`
  and one file per system.
- **The page and the app talk both ways**, as Qt's web view does through its
  web channel, without a bridge object: `retro.post(text)` in the page's
  scripts comes in `WebEvent.messages`; `webPost(key, text)` sends a
  `retro` event to the page (`addEventListener("retro", e => e.detail)`);
  `webRun(key, js)` runs a script and its answer, as JSON, or the error it
  raised, comes in `WebEvent.results` with the number `webRun` returned.
  Also new: `webGoForward`, `webStop`, `webAllow(key, hosts)` (other hosts
  are kept from the page and listed in `WebEvent.blocked`, for the app to
  open in the browser if it wants), `webZoom(key, zoom)`, and
  `WebEvent.canGoForward` and `native`. Android's web view does all of it
  too (`tools/android/RetroWeb.java`). The engines' developer tools are off
  unless `RETRO_WEB_TOOLS=1`.
- The system's view hides under the app's menus and dialogs and shows again
  after them; the widget shows the page's title meanwhile. It is no longer
  loaded again when it only moves or is zoomed (Android's too). Relative,
  `./` and `~` paths are given to the engines as whole paths.
- **The keyboard comes back to the app** when its window is clicked while a
  window put inside it (the web view) has it: the X11 and WinAPI drivers,
  and UIKit, which no longer takes the keys back from such a view on every
  frame (uirelays; `winWindow` gives the WinAPI driver's window).
- **Retro Designer builds in Termux.** Termux's Nim 2.4 has `dist/checksums`
  but not `dist/nimony`; 0.27.1 fetched nimony into its copy of the
  compiler's sources but left checksums out of it, and stopped at
  `ast2nif.nim: cannot open file: ../dist/checksums/src/checksums/sha1`. Now
  the copy takes the `dist` folders the system has, fetches the ones it has
  not, and fetches a folder again when the parser still misses a file of it.
  A copy left by 0.27.1 is made again by itself. Retro Designer draws a web
  view the kit's way, whatever `RETRO_WEB` says.
- Docs: the controls guide had `webView` as a window of its own on
  desktops; it now has a `webView` section with all its commands and a
  picture. The syntax study has a new form, "A web page, and its scripts",
  and counts 303 controls. README "Web and HTML", BUILDING.md (what each
  system needs for the web view), the skill and llms.txt follow.
- Retro Gallery and the small examples are 0.28.0. The Gallery's HTML page
  has a System engine box, and its web page a button whose script says
  hello to the app.

## 0.27.1

- **Retro Designer builds with Nim 2.4 as Termux packages it.** Nim 2.4's
  compiler sources import two folders of its `dist` (nimony and checksums)
  that Termux's `nim` leaves out, so `retrokit designer` stopped at
  `cannot open file: ../dist/nimony/src/lib/nifpools`. `retrokit` now checks
  that Nim's parser builds from the sources it found before it builds the
  designer; when those folders are missing it copies the sources into its
  cache and fetches them with git at the commits that Nim version pins
  (its `koch.nim`), once. It looks for the sources only when it builds, so
  the designer starts as quickly as before. `retrokit doctor` says what the
  designer needs; `tests/test_designer.nims` finds the completed sources too.
- Retro Gallery and the small examples are 0.27.1.

## 0.27.0

- **Retro Designer.** `retrokit designer app.nim` opens your `.nim` file in
  the kit's visual designer, in the manner of Qt Designer: the file's
  windows drawn with the real controls; the Widget Box with every control of
  the guide (dropped with the variables and the imports it needs); the
  Object Tree; the chosen control's properties, its event, the file's
  variables. Drop controls, drag them, put them in rows, columns, groups,
  panels, cards and forms and take them out again, cut, copy, paste,
  duplicate, delete, undo; set properties, add events, rename variables;
  drag the window's corner to its size. Every change is written into the
  same file as Nim, touching only the lines that changed -- no form file, no
  generated code -- and the file is read again before a change is kept. The
  windows are found by themselves: `app` blocks, `while beginFrame()`
  windows, and every proc that draws (drawn where a window calls it);
  dialogs are listed under their window and shown open over it, a menu opens
  when one of its items is chosen, the tab or `case` arm of what is chosen is
  shown. F5 previews the window working, in each look (touch, dark, right to
  left). It is purely a designer: **Edit Code** gives the file to your editor
  at the control's code and takes it back when the editor closes, and only
  one of the two has the file at a time (a `.NAME.lock` beside it; the file
  read-only for others on Linux, macOS, BSD and Termux, held on Windows; a
  lock left by a designer that is gone is taken over). It builds itself the
  first time, for your computer and your Nim (the compiler's sources, or
  nimble's `compiler` package), on Windows, macOS, Linux/BSD and Termux.
  docs/designer.md; `src/retrodesigner/`; `tools/gendesigner.py` makes its
  registry from the API; `tests/test_designer.nim`.
- **A window in the window.** `windowBox(rect): body` lays `body` out as a
  window of its own at a rectangle -- its menu bar, tool bars and status bar
  along the rectangle's edges, its dialogs centred in it and its menus kept
  in it (`ui.winX`, `ui.winY`; `screenClip` / `setScreenClip` for what a
  pushed layer is clipped to). `inert: body` draws without input: its
  controls take no mouse, finger or key, and a dialog or menu in it does not
  take the window's input. `showMenu(["&File", "Sub"])` / `hideMenu` open a
  menu bar's menu (and a submenu) as if they were clicked: a tour, a guide's
  picture. `ui.measuring` with `notePlaced` tells where things were drawn
  (cells, bars, menus and their rows, dialogs, tree rows); `peekId` the id
  a widget will take.
- A list box scrolls to its selection when the app changes it, as the tree
  does.
- Retro Gallery and the small examples are 0.27.0.

## 0.26.1

- The Cocoa driver's backend builds on its own again (the uirelays tests
  compile it as plain Objective-C, without the Nim side): the two calls it
  makes into the program for VoiceOver have weak stand-ins that do nothing,
  and the program's own take their place when it is linked.
- Retro Gallery and the small examples are 0.26.1.

## 0.26.0

- **Screen readers, on every platform.** Orca on Linux and BSD (AT-SPI,
  spoken to over D-Bus by the kit itself: no library to link or install),
  NVDA, JAWS and Narrator on Windows (UI Automation), VoiceOver on macOS and
  iOS, TalkBack on Android read every control: what it is, its name (a
  label names the box after it: `label "&Name:"; edit name`), its value and
  state, where it is in its list, and the keyboard focus as it moves. They
  also do what their user asks: press a button, a menu, an item; check a
  box; put text in a box; move a slider or a spin box; move the focus.
  The grid is read as a table (its headers, the rows in view, their
  cells), the property grid as names and values, the tree and the tree grid
  with each item's depth and whether it is open, charts by their title,
  kind and series and the point the keys are on; the check list, the
  calendar's days, the icon view, the column view, document, palette and
  docked panels' tabs, switches, segmented buttons, chips, ratings, range
  sliders, knobs, menu and split buttons, the board's lanes and cards, the
  Gantt chart, the agenda, the org chart, KPI tiles, the drive and path
  bars, windows in the window, the About box; Markdown, HTML and the rich
  editor as their text; maps, 3D, PDF, reports, video and photo views as
  pictures. The tree is made only while a screen reader listens: without
  one nothing of it runs. For what an app draws itself: `accessNode`
  (`arImage`, `arLabel`, `arButton`...), `accessBegin` / `accessEnd`,
  `accessRange`, `accessItem`, `accessName` (an icon-only button);
  `accessible()`; `RETRO_ACCESS=1` makes the tree to try it.
  `uirelays/access` (generic), `uirelays/dbus`, `uirelays/atspi`, the WinAPI
  driver's `winuia`, the Cocoa and UIKit drivers, `RetroAccess.java`.
- **Input methods.** What a Chinese, Japanese or Korean input method (or a
  phone keyboard's word) is composing is drawn in the text box at the
  caret, underlined, and typed once it is settled: X11 (XIM, in place;
  else at the caret), Windows (IMM, in place), macOS (marked text), GTK 4
  (preedit), Android (an input connection of the kit's own,
  `RetroInput.java`). `TextEditingEvent` (`composing`; its caret in `x`)
  and `ui.composing`. SDL 2, SDL 3 and iOS show it in the input method's
  own window still.
- **Frames go straight to the screen.** X11 draws into memory it shares
  with the X server (MIT-SHM: libXext loaded when it is there; in Termux
  libandroid-shmem) and puts only the tiles that changed; Windows draws into
  a DIB section and paints only the rectangles that changed; macOS asks to
  draw only what changed. No copy of the frame is made: resizing a window at
  1080p costs less than half of what it did. For drivers: `SurfaceRelays`
  (`lockSurface`, `presentSurface`) in `uirelays/screen`; `RETRO_SURFACE=0`
  draws the old way.
- **A frame that changes nothing takes no memory.** No string, seq or
  closure is made while the controls are drawn (the gallery: 130
  allocations a frame before, none now; a grid page 277 before, 217 now;
  Retro Files 268 before, 152 now). Hello takes 7.1 MB (9.7 before), 14.6 MB
  at 1080p (17.5 before): half of what iced or Slint drawing on the CPU
  take, a sixth of their GPU paths (`tools/compare`). The 255 pixel icons are unpacked one by one when
  one is drawn (`setPixelIconSource`).
- **Fractional scaling follows the monitor.** On X11 the window takes the
  scale of the monitor it is on (RandR, every output), and again when it
  is moved to another, as on Windows and macOS. At 125 %, 150 %, 175 %...
  controls and text are the size the scale asks for; lines stay on whole
  pixels.
- **CPU, GPU or automatic**: automatic (the default) still draws with the
  GPU when it is a real one and on the CPU when OpenGL is a software one (a
  VM, a remote desktop, Termux:X11), now into the shared memory above.
- `tools/compare/`: the same Hello in egui, iced and Slint, and
  `compare.sh` measuring them and the kit the same way (memory, size,
  threads, CPU idle, resizing, hovering).
- Tests: `test_access` (the tree, the requests, every control),
  `test_atspi` (Orca's side on a real X server and AT-SPI bus),
  `test_uia` (Windows, under Wine), `test_scale`, `test_shm`; the Android
  mock checks composing and the keys.
- Retro Gallery, Retro Files and HR Book give their own drawings to screen
  readers (the canvas, the colors, the web view, the lock screen); the
  examples are 0.26.0.

## 0.25.0

- **`retrokit run --watch`: see each change as you save, on any desktop.**
  It builds the app again whenever a `.nim` file in its folder (or two
  levels below: hidden folders, caches and links to folders left out) is
  saved, starts the new one where the window was, then closes the one
  before, so the window never goes blank. The same on Windows, macOS, Linux
  (any window manager, or none) and Termux, where `--live` is `--window` and
  `--watch` together. Only what changed is compiled again (the compiler's
  usual cache): about 4 seconds from a save to the new window, most of it
  Nim reading the kit. Code that does not build leaves the window running
  what it had, with the compiler's message; an app that crashes starts again
  with the next save; closing the window ends it. The app's variables start
  fresh each time.
- **The window keeps its place between runs**: `RETRO_WINDOW_STATE` names a
  file where the driver keeps where the window's inside is and the size the
  user gave it (unless the app now asks for another size), and `--watch`
  gives each run the same one. X11 (with a window manager: said as the
  user's place, StaticGravity; without: on the desktop of `--window`),
  Windows, macOS, SDL 2 and SDL 3 do it; GTK 4 and Siwin cannot place a
  window. `keptWindowPlace` and `keepWindowPlace` in `uirelays/services`.
- **The window stays in view when the screen changes size** on the desktop
  of `--window` -- the tablet turns, Termux:X11's window is made floating or
  sized: it keeps its middle where it was in proportion, is made smaller
  while the screen is, gets its size again once there is room; maximized,
  it takes the new screen.
- `test_retrokit`: run's options, what `--watch` watches.
- Retro Gallery and the small examples are 0.25.0.

## 0.24.0

- **The syntax, studied: [docs/syntax.md](docs/syntax.md).** The whole way
  of writing an app, every form of it as a small program with a picture of
  what it draws: what each number in `row([50, -1, 0, -2])` gives (the
  pictures measure the widths in red), binding, events, containers, forms,
  menus, dialogs, message boxes, ids in loops, shortcuts, time; a frame step
  by step; how the syntax is built and why it is easy to follow; the rules
  that prevent most mistakes, shown; and a whole app that stays easy to
  read. The README links it first. Its pictures are made by
  `tools/syntaxshots` from the very programs the page shows (`sh
  tools/syntaxshots/make.sh`, which also checks the page's code is theirs).
- **`retrokit run --window`: an app as a desktop window on Termux:X11.**
  With no window manager the toolkit draws a desktop (the 3.1 teal) over the
  screen and opens the app on it at its own size, grown by the tablet's
  density, in the middle, in its 3.1 frame: moved by its title bar, sized by
  its border or its grip, maximized, its control menu; keys go to it, also
  after a tap on the desktop; the desktop follows the tablet when it turns.
  It is `RETRO_WINDOW=1` for any program built with the kit (on a bare X
  server too); with a window manager it gives the 3.1 frame. `retrokit run`
  also takes `--scale:N` (everything and the window N %), `--size:WxH` and
  `--theme:NAME`, before or after the file; the rest goes to the compiler.
- **The 3.1 frame has a size grip** in its bottom right corner (the bottom
  left right to left): drag it with the mouse or a finger to size the
  window, on every platform the frame is drawn. A status bar leaves it its
  end, the window's scroll bars stop short of it; `sizeGrip()` says where it
  is. The frame takes the theme's colors and follows the user's theme.
- **`resizable = false`** (`app`'s option; `setResizable`, `resizable()`):
  a window that keeps its size. The 3.1 frame has no sizing border to drag
  (the plain band of 3.1's dialogs), no maximize button and no grip; a double
  click on its title bar does not maximize it; its control menu has Size and
  Maximize grayed. The system's frame is told the same through the new
  `FrameRelays.setResizable`: Windows drops the sizing border and the
  maximize box, macOS the resize edges and the zoom button, X11 window
  managers get the same least and largest size, GTK 4 and SDL 2 / SDL 3
  make the window fixed.
- `RETRO_SCALE` (and `app`'s `scale`) make the window larger with
  everything in it, so it all still fits.
- `test_frame`: the grip (where it is, what a press on it does, its ridges)
  and a window that keeps its size.
- Retro Gallery and the small examples are 0.24.0.

## 0.23.0

- **`retroui/omemo`: end-to-end encryption for chat**, as Conversations,
  Monal, Gajim, Dino and Siskin do it: OMEMO 0.3
  (eu.siacs.conversations.axolotl), the Signal protocol underneath -- X3DH
  to begin a session from the keys a device published, then the double
  ratchet, a new key for every message, messages that come late or out of
  order opened. Each device has an identity (XEdDSA: its X25519 key
  published, its signatures Ed25519's), a signed key and 100 one-time keys,
  kept in one file readable by you alone; a one-time key used is replaced
  and published again. Its devices' list and keys go to the server (PEP),
  others' are fetched when needed; a message waits for them and goes to
  each device of the other one and your own others (`omemoSend`, then
  onSent or onFailed). Trust is blind until you verify a device
  (`omemoTrust`, the fingerprints with `omemoFingerprint` and
  `fingerprint`); a device whose key changes is not trusted. Files are
  locked as the apps do it (XEP-0454: `encryptFile`, `aesgcmUrl`,
  `decryptFile`). The cryptography is OpenSSL's libcrypto (1.1.1 or
  later), loaded when needed (`omemoAvailable`). Tested against
  python-omemo's oldmemo (the libsignal-compatible one) over a server:
  sessions begun from either side, answers, restarts.
- `retroui/xmpp`: `xeStanza` -- the answer to an iq whose id starts "q-",
  whole, and the server's pubsub notices; `raw`, an encrypted message's
  XML (live and from the archive); a message with no words but encrypted
  comes too; the disco answer says it follows OMEMO's device lists.
- **Retro Communicator 1.2: encrypted talks.** The lock button in a talk:
  on by itself when the other one's app has OMEMO (off again by a click,
  remembered), locked lines show a green lock, a message that could not go
  encrypted says so and is not sent in the clear. Files and voice messages
  in an encrypted talk are locked before they go (aesgcm://), and the ones
  that come are opened here. Info shows the other one's devices with their
  fingerprints (Verified, Don't Trust), My Profile this device's.
- `test_omemo`: the RFCs' vectors, XEdDSA, two devices talking, trust, files.
- Retro Gallery and the small examples are 0.23.0.

## 0.22.0

- **`retroui/xmpp`: the server's history (the message archive, XEP-0313).**
  xeServices says "archive" when the account's server keeps one;
  `askArchive` asks it for a page -- with someone or everyone, after or
  before a message, the latest, or since a time -- and the messages come
  as `xeArchived` (yours and theirs, in the order they were said, with
  `mine` and their `archiveId`), then `xeArchiveDone` with the last one's
  id for the next page and whether that was all. A message that comes as
  it is said carries its `archiveId` too (the server's stanza-id), so an
  app keeps each once. An archive's answer from anyone but the account's
  own server is left out.
- **Retro Communicator 1.1: the history synced, and voice messages.**
  Signing on brings in what was said while it was off -- from your phone,
  your other computer, or to them -- from the server's archive (the first
  time on a device, the last 30 days), a page at a time, each line once,
  in the order said; a new talk with nobody's log here starts with the
  last 50 of the archive, and **Earlier messages** at the top of a talk
  goes further back. The microphone button records a voice message
  (Termux:API's microphone on a phone; PulseAudio or ALSA on Linux, made
  AAC by ffmpeg where it is) and sends it as a file, as Conversations,
  Monal and the others do; a voice message that comes shows **Play**, is
  fetched once and played (the system's sound, or mpv or ffplay). It ends
  by itself after five minutes; Cancel lets it go. Times from the server
  show in this device's time zone.
- `test_xmpp`: a session with a small server of the test's own -- signing
  on, the archive found, a page taken in order, a forged answer left out.
- Retro Gallery and the small examples are 0.22.0.

## 0.21.2

- **Markdown in Arabic reads right to left:** a list item whose first words
  are Arabic (Hebrew...) has its bullet, number or task box at the right and
  its text from there; a quote in Arabic has its bar at the right; a table
  whose first words are Arabic has its first column at the right, its cells
  from the right (a `:---` column is the start side, `---:` the end), and,
  narrower than the page, sits at the right. The paragraphs were already
  right to left; now all of a help page in Arabic is.
- A table's Arabic header in bold no longer wraps where it fits: its cells
  are measured word by word, as its lines are made.
- Retro Gallery and the small examples are 0.21.2.

## 0.21.1

- **Retro Communicator's windows complete on tablets:** a room's window
  shows the talk and who is in the room side by side, with the message
  box and Send under them (the list went below the talk and pushed them off
  the window); the Friends window's state chooser (Available, Away, Busy,
  Invisible) and a talk's Send a file and Info buttons keep their room
  beside a long name or address instead of slipping off the side. The
  windows open at the interface's size (larger on a tablet), inside the
  area.
- The skill's common mistakes: a `col` in a plain `row` takes all the room
  left -- give the row its widths.
- Retro Gallery and the small examples are 0.21.1.

## 0.21.0

- **`retroui/xmpp`: chat on XMPP (Jabber).** An account on any public
  server -- nobody's to run -- with what a messenger needs: signing on
  (STARTTLS, SASL PLAIN), the contact list and its groups, presence and
  status notes, messages with typing notifications and delivery receipts,
  the messages you send from another device (carbons), asking to add
  someone and answering who asks, profiles (vCard, with a picture), chat
  rooms (MUC), files (HTTP upload) and making an account from inside the
  app where the server allows it (in-band registration). The server is
  found by its SRV record (DNS over HTTPS through `retroui/http`). The
  connection runs on a thread of its own; the app takes what came with
  `xmppEvents()` each frame. Build with `-d:ssl` (OpenSSL, loaded at run
  time). In Termux and on Android before 9, where bionic has no `glob`
  (std/net looks for the certificate authorities with it), the module
  brings its own (`androidglob.c`).
- **Retro Communicator** (`examples/communicator.nim`, `nimble
  communicator`): an instant messenger in the look of 1999 on it -- sign
  on or make an account, the friends list with groups (folded), who is
  there, away or busy and their notes, a search; a window for each talk
  with typing and Delivered; rooms with who is in them; away messages
  answered once per talk; your profile with a picture and a QR code to add
  you; files and pictures sent; requests to accept; the sounds of a door,
  a message in and out; notifications; history kept per friend; the
  password in the system's keyring when you ask.
- **Notepad prints to PDF** (File > Print to PDF, Ctrl+P), on A4 pages in
  FreeMono, through `retroui/report`. Ctrl+O and Ctrl+S work as keys too.
- The icons of minimized windows in the window (MDI) show their titles in
  the interface's language (`tr`), as their title bars do.
- Retro Gallery and the small examples are 0.21.0.

## 0.20.8

- **Retro Files opens the folder it is given**: `retro-files ~/Pictures`
  (or a file: its folder) starts there -- a desktop's "open this folder",
  Retro Desktop's Android Files.
- Retro Gallery and the small examples are 0.20.8.

## 0.20.7

- **Cursors at the screen's size on X11.** The X cursor font has one size,
  16 pixels -- a speck on a 2K tablet in Termux:X11 or on a 4K monitor.
  When the screen is at 150% or more, the X11 driver draws its cursors
  itself in the classic shapes (the arrow, the I-beam, the hourglass, the
  hand, the cross, the sizing arrows, the four-way arrow), each pixel a
  square of the screen's scale, and keeps one of each instead of making a
  new cursor at every change. `x11DrawnCursors` (1 always, 0 never, -1 the
  screen decides) and `x11ClassicCursor` for a window manager's own
  windows; `classicCursorArt` gives the drawings (Retro Desktop writes them
  as a cursor theme for other programs).
- Retro Gallery and the small examples are 0.20.7.

## 0.20.6

- **A window manager on the app's own X connection.** The X11 driver hands
  every event it takes off the queue to `x11EventHook` first (an `XEvent*`;
  true: it was the hook's), and gives the connection and its window
  (`x11Display`, `x11Window`); `x11Wake` runs a frame when the hook changed
  something the window shows. With them a Retro Nim UI program can manage
  other programs' windows -- I use them for
  [Retro Desktop](https://github.com/foxoman/retrodesktop), a 3.1 desktop
  for Termux and Linux.
- **`_NET_WM_PID` and `WM_CLIENT_MACHINE`** on every X11 window: a task
  list shows how much memory the program takes and can end one that hangs.
- **Termux:X11 in front only when it has to be:** with a window manager on
  the server (a desktop), a program started in Termux opens without
  bringing the Termux:X11 app forward again (`am start` takes Android about
  a second).
- **`MdiWindow.noPin`:** a window in the window with no pin in its title bar
  and no "Always on Top" in its menus -- Program Manager's groups, as 3.1
  had them.
- Retro Gallery and the small examples are 0.20.6.

## 0.20.5

- **Termux:X11 by itself.** A program run in Termux starts Termux:X11's
  server when none is running (`termux-x11 :0`, `DISPLAY=:0` when unset)
  and brings the Termux:X11 app to the front: `nim c -r app.nim` is all
  it takes. With no window manager there, the window fills the screen and
  follows it when the tablet turns, as an Android app does; with one
  (openbox, xfce...), windows are ordinary ones.
- Retro Gallery and the small examples are 0.20.5.

## 0.20.4

- **Termux:X11 at the screen's size.** An X server on Android draws on the
  device's own pixels and says 96 dpi, so apps came up tiny on a 2K or
  2.8K tablet. In Termux the X11 driver now takes Android's own density
  (`ro.sf.lcd_density`, 160 a plain screen's: 320 is 200 %), after
  `Xft.dpi`, `GDK_SCALE` and `QT_SCALE_FACTOR`; `RETRO_SCALE=150` (or Ctrl
  + / -) sets it by hand.
- Retro Gallery and the small examples are 0.20.4.

## 0.20.3

- **Apps run in Termux, on Termux:X11.** In Termux, Nim builds for
  Android, and the kit took every such build for an APK: a program run
  from the shell waited for an Android activity that never came, and
  nothing showed. Now an APK's library (`--app:lib`, what `retroapk`
  makes) gets Android's own driver, and a program run from the shell the
  X11 driver, with files, links and services as on Linux and drawing on
  the CPU (Android's own EGL knows no X11 windows, so it is not loaded
  there). `uirelays/target`: `androidApp` and `androidShell`. Steps in
  BUILDING.md, "A desktop app in Termux".
- **An editor's check passes:** the kit's own `=destroy` hooks
  (`mediaaudio`, `oauth`, `db`) take `var` under `--mm:refc`, as that mode
  asks -- `nim check` with refc (as some editors run it) failed on them.
  Checked with Nim 2.4.0 as well as 2.2.
- Retro Gallery and the small examples are 0.20.3.

## 0.20.2

- **Retro Board 1.3.3: bigger words.** The letters on the board are
  twice as big, as Excalidraw's beside the shapes: S, M, L and XL are 38,
  48, 68 and 86 page units (were 18, 24, 36, 44; a unit is a screen dot at
  100 % on a tablet). Boards saved before (`version` 1) keep their words as
  they were drawn (`Shape.scale`) until a size is chosen; labels of
  shapes and arrows follow `scale` as text does.
- **The kit's own text is 12 pixels per em again** (15 on phones), as in
  0.20.0: 0.20.1's bigger text (13.5) was meant for the board's words,
  not the controls. `DesktopTextEm` and `TouchTextEm` stay, with those
  values; `DesktopMetrics` and `TouchMetrics` match them.
- Retro Gallery and the small examples are 0.20.2.

## 0.20.1

- **GitHub releases carry the apps.** The Release workflow, on a `v...`
  tag or by hand (Actions > Release > Run workflow), builds Retro
  Gallery, Files, Photo, Board and Mail for Linux (AppImage), Windows
  (.exe), Android (APK) and macOS (.app) and puts them on the release.
- **uirelays brought up to date** with nim-lang/uirelays master
  (`cb82378`, merged on the `uirelays` branch): KeySlash on X11 (it was
  already there in the kit's translation, now one case), precise wheel
  lines for touchpads (`Event.preciseLines`, `wheelLines`), the figdraw
  driver's clips and scrolling. It stays inside the package: `nimble
  install retroui` brings it, nothing else to download.
- **Docked panels' tabs keep their labels whole** (less room around them,
  then a size smaller) before cutting them short.
- Fixed: CI's Android driver test (a fake Android) lacked
  `AMotionEvent_getMetaState`, which the driver now reads; it takes
  Android's headers from the sysroot `retroapk` carries, no NDK needed.
- The kit's text was 13.5 pixels per em in this release (back to 12 in
  0.20.2).

## 0.20.0

- **The package is `retroui`** (github.com/foxoman/retroui): `nimble install
  retroui`, `import retroui`, `import retroui/report`... (`retroui.nimble`,
  `src/retroui.nim`, `src/retroui/`). An app of before changes `retro` to
  `retroui` in its imports; the tools keep their names (`retroapk`,
  `retroios`, `retrokit`), and so do the settings folders (`~/.retro`).
- **The examples are built only when asked**, one at a time: `nimble
  photo`, `nimble photoexe`, or any app of the table with `RETRO_APP=...
  nimble exe` / `appapk` / `appimage` / `macapp`; CI compiles the
  examples only when run by hand. **HR Book** joins them: employee records of
  several hotels, sealed with a PIN, smart Excel import, letters, charts.
- **For AI agents and their users:** `skills/retroui/SKILL.md` (building
  apps with the kit), `AGENTS.md` and `CLAUDE.md` (rules for changing it),
  `llms.txt`.
- **Menus answer at once.** A row under the pointer takes over the moment
  the pointer moves down or up the menu; only on its way to an open
  submenu (inside the triangle from the pointer to the submenu's edge) do
  the rows it crosses wait, and a rest of 300 ms there gives the row the
  menu. Long menus (Retro Photo's) no longer feel slow.
- **CSV written as well as read:** `writeCsv(path, table)`, `toCsv`,
  `csvLine`, `csvField` (`retroui/charts`): quoted only where needed,
  CRLF lines; `parseCsv` reads them back to the same table.
- **`numberEdit` and `intEdit`:** clicking or tabbing into one selects its
  text, so typing replaces the number; a value the app changes while the
  box has the focus shows at once.
- **BUILDING.md** covers the desktop too: Windows from Windows, Linux or
  macOS (MinGW), its icon and version, macOS `.app`s, Linux AppImages.
- Fixed: `retrokit new` made apps that imported `retro` (now `retroui`).
- **The apps, with the new text, menus and frame:** Retro Photo 4.9.3,
  Retro Files 3.3.3, Retro Mail 1.0.4, Retro Board 1.3.2 (its About box
  no longer shows the credit twice), HR Book 0.1.

- **GNU FreeFont is the kit's text: FreeSans the default, FreeSerif and
  FreeMono beside it, each in its regular, bold, italic (oblique) and bold
  italic.** `UiFont` is now `ufSans` (the default), `ufSerif`, `ufMono`
  and `ufFile`; `TextStyle.italic` and bold italic draw the
  fonts' own italics (no slanted copies), `mono` text is FreeMono,
  `TextStyle.serif` (and serif families in HTML, the canvas and
  documents) FreeSerif. **Arabic everywhere:** FreeSans's Arabic is
  FreeSerif's (bold: FreeSerif Bold's), FreeMono draws its own in its
  regular, a font file without Arabic gets FreeSerif's; joined, lam-alef,
  bidi and mirroring as before -- in text boxes, the rich editor,
  `htmlView`, the canvas, PDF and reports. Documents (`retroui/textengine`)
  set Arabic by FreeSerif's OpenType tables instead of Amiri's; a document
  naming a font the kit had before is drawn in its FreeFont like (Amiri:
  FreeSerif, DejaVu Sans: FreeSans).
  - **Gone:** MS W98 UI (+HD), Retro Sans (+Arabic, HD, its bitmaps:
    `font.nim`, `unifontar.nim`), Kawkab Mono, Fixedsys Excelsior (+HD),
    Open Sans, DejaVu Sans and Mono, Amiri, their generators and licences,
    and `-d:retroNoW98`, `-d:retroNoKawkab`, `-d:retroNoFixedsys`,
    `-d:retroNoOpenSans`. The icon font and Retro Board's handwriting
    fonts stay. `ufW98`, `ufRetro`, `ufSmooth`, `ufOpenSans` (FreeSans) and
    `ufKawkab`, `ufFixedsys` (FreeMono) compile for this release as
    deprecated aliases; `setPixelFont` and `usesPixelFont` are deprecated;
    `setHdText` now only smooths pixel icons and small marks on HD screens.
    Retro Board's "Retro" font slot is FreeSerif Italic (the name kept for
    saved boards).
  - **The look of a font file of before:** the letters are drawn in gray
    as Retro Photo 4.9 drew FreeSans from a file -- the heights on whole
    pixels, the strokes as the font has them (not narrowed to a pixel:
    FreeSans keeps its weight), the font's line gap in every line, small
    text's light gamma (1.2); FreeMono's thin strokes darkened at small
    sizes. **Sharp text** is a choice (`setSubpixelText`, "Text edges" in
    `appearanceSettings`, `RETRO_TEXT=sharp`): the screen's red, green and
    blue strips, three times as fine across, as ClearType, the stems fitted
    to the pixels (CPU and GPU; off by default everywhere).
  - **Size:** `tools/genfreefont.py` cuts the twelve fonts to what an app
    needs (Latin, Greek, Cyrillic, Hebrew, Arabic, punctuation and
    symbols; no TrueType hinting): 0.94 MB compressed in every app, where
    the fonts before took 0.96 MB (a "hello" grows 16 KB); apps with
    `retroui/textengine` lose Amiri's 0.21 MB (Retro Board: 4.92 to 4.69 MB).
  - **Crisp at every scale:** the zones (baseline, x-height, cap height)
    on whole pixels for every face (stems fitted to the pixels too in
    Sharp text), thin faces darkened at small sizes (FreeMono), kerning
    read from GPOS (most fonts of today kern only there; FreeFont's legacy
    `kern` tables are dropped), a style a font lacks made bold or slanted
    as FreeType does (its outline emboldened, the letters wider). Line
    height, baseline and the controls' sizes come from FreeSans with its
    line gap (a 15-pixel line at 12).
  - Settings: "look.fontv" is 3; a font stored before (MS W98 UI, Kawkab
    Mono...) is FreeSans now, a font file stays one; `uiFontKey` words are
    "sans", "serif", "mono", "file" (the old ones still read).
    `RetroFontCredit` is the About box's credit for the fonts.
- **A font file of the user's, more kinds.** `appearanceSettings` offers
  FreeSans, FreeSerif, FreeMono and a font file. `.ttc` collections are
  read (`sfntOf` gives one face as a file), a font file's italic and bold
  italic are found beside it (`styleBeside`), `setUiFontFile` takes all
  four styles; documents draw variable fonts at the weight asked for.
- Fixed: `noKerning` in `retroui/textengine` turned off only the legacy
  kerning, not a font's GPOS kerning.
- **Right-to-left text, by the whole Unicode bidi algorithm.** The
  explicit embeddings, overrides and isolates (U+202A..202E,
  U+2066..2069) work, and every case of Unicode's conformance tests
  passes (BidiTest.txt, BidiCharacterTest.txt; 40 % and 99.7 % before);
  more of Unicode's classes, brackets and mirror images. The zero width
  non-joiner and joiner, the word joiner and the byte order mark no
  longer split a run (a Persian می‌خواهم in Latin text reads as one word),
  and joining follows Unicode (the direction marks let it through, the
  isolates break it). New: `plainLetters`, `joinsAt`, `shownRtl`.
  - **Text boxes and the rich editor:** the caret goes through a line as
    it reads (Left goes on in an Arabic line), a letter and its vowels are
    one step (Backspace takes a vowel off, Delete a letter with its
    vowels), and it sits where the next letter typed goes when Latin and
    Arabic meet; a selection of mixed text is drawn where its parts are;
    pasted joined shapes come in as letters; a word styled in its middle
    keeps its letters joined. `htmlView` keeps the joiners in its words.
  - **The Arabic interface** mirrors the frame, menus, lists and scroll
    bars, not the text being read or typed: text boxes, the rich editor,
    Markdown and HTML views keep their own directions, and charts, the
    map and the media controls their sides (they were mirrored: a caret
    at the wrong end, a chart's months backwards, a map's mouse across).
  - **PDF:** a line with right-to-left text carries its text as written
    (`/ActualText`: reading order, the letters, a zero width non-joiner
    kept), and every glyph maps to its letters, not their joined shapes;
    `lang` (BCP 47; "ar" by itself when the first text is Arabic) and
    right-to-left page order. `pageText` honours `/ActualText` and reads
    Arabic in reading order from other files too, whether they have its
    glyphs as they stand or as they read.
  - **Excel:** `XlsxSheet.direction` -- a sheet whose first letters are
    Arabic opens right to left (`sdAuto`), or as said; `readXlsx` gives a
    sheet's own.
- **The window's frame is always the user's choice.** In every app, with
  nothing to write: the Windows 3.1 frame's control menu has **Windows' Own
  Frame** (elsewhere **Desktop's Own Frame**), and on Windows the system's
  frame gets **Windows 3.1 Frame** in its system menu (Alt+Space, the title
  bar's icon). The choice is kept for the app (`window.ini` in its data
  folder) and wins over the frame it was built with. `chooseClassicFrame`,
  `keptFrame`, `userFrameChoice`, `appIdent`; `storeAppearance` no longer
  keeps the frame (a kept one is brought over once).
- **The 3.1 frame on every desktop, and the way back from the system's:**
  - macOS: **Windows 3.1 Frame** in the menu bar's **Window** menu (there
    with either frame); the control menu's Move and Size with the arrow
    keys (Return keeps, Esc puts back).
  - X11 (Linux, the BSDs, Wayland desktops through XWayland): with no
    window manager, or one without EWMH, the driver itself moves, sizes
    (the pointer or the arrow keys) and maximizes the window. The window
    manager keeps its own menu: `appearanceSettings` (**Window**) is the
    way back to the 3.1 frame there.
  - Wayland's own windows: the GTK 4 driver (undecorated; moved and sized
    by the compositor from the press; the arrow keys on X11 only) and the
    SDL 3 and SDL 2 drivers (borderless; SDL's hit test, from
    `windowPartAt`: no arrow keys, and a double click on the title bar
    maximizes on Windows only). Siwin too (not on macOS; on Windows the
    frame chosen is the next window's). Minimize for SDL and GTK 4.
  - The system menu's item is checked while the 3.1 frame is on; a window
    that cannot have the system's frame back keeps the 3.1 one;
    `appearanceSettings` leaves the choice out with `userFrame = false`.
  - X11: focus moving to a window inside the app's no longer draws its
    title bar inactive.
- **`app` takes every option by name:** `theme`, `frame` (`wfAsBuilt`,
  `wfSystem`, `wfClassic`), `userFrame`, `gpu`, `zoom`, `scale`, `font`,
  `id`, `icon`, `look` (the look the user picks kept in those settings:
  brought back at the start, kept as it changes). A misspelled option is a
  compile error that lists them. `openApp`, `closeApp`, `keepLook`,
  `noteLookChanged`, `lookChanged`.
- **Faster, the same pixels:**
  - Typing in a long `editArea` about 50 times faster (only the changed
    lines are wrapped again).
  - Charts on the GPU: 2.7 s to 28 ms a frame.
  - The GPU keeps the frame in a texture and redraws only what changed
    (hovering, typing); `RETRO_GPU_KEEP=0` turns it off.
  - About 60 % fewer allocations a frame; text measured without copies;
    shapes' buffers reused.
  - A fast wheel (a notch every frame) scrolls at once instead of stalling.
  - Small changes -- a lit button, a letter typed, a slider -- take half the
    time or less on the CPU (800 x 600: a hover 227 to 98 µs, a value 224 to
    94 µs; a whole frame 343 to 249 µs): each command's box is worked out
    once a frame, tiles are 64 pixels wide (were 256), and a change under
    96 K pixels is drawn on the app's own thread (waking the other cores
    cost more).
  - On the GPU, only what changed is drawn, in up to eight rectangles:
    straight onto the window where it keeps its pixels (EGL's buffer age 1:
    X11 with Mesa), through the kept frame where it holds an older one;
    the system is told what changed (`eglSwapBuffersWithDamage`). Hovering,
    typing, a value: 2.8 to 3.9 times faster with Mesa's software GPU.
  - No memory taken by a frame of the kit's own drawing: rows, labels with
    their `&`, text, fills, the tiles drawn and sent (`tests/test_drawalloc`);
    `idOfLabel` makes a widget's id from its kind and label without a string.
  - Apps built for size (`--opt:size`: `nimble apps`, the packages) compile
    the drawing for speed: their frames twice as fast, for about 50 KB.
- **Linux needs only libX11.** Xft and XRender are loaded when the system
  has them (the system's fonts for scripts the kit's lack, translucent
  fills); without them the app starts and draws as before.
- **Memory:** `dropDrawingCaches` lets go of the glyphs, magnified icons and
  frame buffers the drawing keeps (called when memory is critical and when
  the app goes to the background); glyphs of a size or font no longer used
  are let go of at once. `wakeInShown(rect, ms)`: an animation asks for
  frames only while it can be seen.
- **New in uirelays:** `GpuRelays.gpuBufferAge` and `swapGpuDamage` (X11's
  EGL gives both).
- **Fixed:** keys and letters typed while a frame worked (a picture decoded,
  anything calling `busyTick`) were lost; they are kept for the next
  frames until the busy box shows. The GPU's 3.1 dither (scroll bar
  tracks) could be a pixel off in a frame drawn into the kept texture.
- **Fixed, found with AddressSanitizer, UBSan and LeakSanitizer, the
  fuzzers and Wine:**
  - X11: every app crashed on exit (libXrandr was unloaded too early);
    fonts left open at exit; closing twice is safe.
  - Leaks in PNG reading, the funnel chart's labels and damaged zip
    entries (Nim 2.2.6 compiler issues, worked around).
  - Unaligned reads in deflate and the selection outline.
  - At 150-300 %: list columns, the message box's icon and width, the
    tree's boxes and icons now scale.
  - The Gray theme's back tabs readable; kanban initials fit their badge.
  - Alt+Space and Ctrl+Space no longer press the focused button (Alt+Space
    closed an app whose Quit button had the focus); Alt+Space opens
    Windows' system menu again.
  - A focused widget that is not a stop of Tab (a list taking the keys
    itself) keeps the focus.
  - A banner's buttons wrap instead of running out of the strip; its text
    starts after its icon at any scale.
  - `$RETRO_SCALE` wins over a kept size; `$RETRO_GPU` takes `auto`,
    `gpu`, `cpu` (and `1`, `0`).
- **Hardening** (the tests under AddressSanitizer, UBSan and
  LeakSanitizer again, before the release):
  - Retro Photo's engine: a picture of several layers kept its first
    layer when it was closed (`simpleLayer`, asked each frame: Nim 2.2's
    `return nil` over a `result` already set does not free it) -- the
    layer's pixels stayed in memory for good.
  - Retro Board: a flowchart's next shape (`addConnected`) read its
    arrow's look from memory already freed.
  - JPEG XL and OpenEXR: a damaged file left what was read before it
    failed in memory (readers' results going into fields).
  - The rich editor leaked the pieces of each right-to-left paragraph
    laid out; GIF: the bits after the end code shifted further than a
    number holds (undefined in C).
  - Tests: `test_hardening` keeps the leaks fixed; the mail tests' mock
    server is stopped at exit without touching what was freed;
    `tests/lsan.supp` holds what Nim's runtime keeps for each thread.
- **New:** `readOnly` for `edit` and `editArea` (selected and copied, not
  changed); `peekId` (a widget's id without counting a use). uirelays: an
  item of the app's in the system's menu (`setFrameMenuItem`,
  `frameMenuItemChosen`; Windows, macOS); `windowPartAt`, the app's frame
  for drivers whose system asks before a press (SDL's hit test);
  `frameRelays` for GTK 4, SDL 3, SDL 2 and Siwin.
- Tests: `test_widgetfixes`, `test_hardening`, `test_x11close`;
  `test_frame` (the hit test's parts, the menu item's check mark, a frame
  that cannot come back) and `test_scroll` cover the above.
- The examples are 0.20.0; the gallery keeps its look, its Drawing tab grows
  with the UI's scale, and its tabs' Alt letters no longer clash with the
  menus.

## 0.19.0

- **Retro Mail 1.0.3:**
  - **Print** (File, Print, Ctrl+P): the message as Outlook Express printed
    it -- From, Sent, To, Subject, a line, the text and its pictures --
    seen first, then printed or saved as a PDF.
  - **Properties** (Alt+Enter) with the message's Internet headers, and
    **Message Source** (View, Ctrl+F3), as in Outlook Express; Local Folders
    messages too.
  - **Find Message** (Edit, Ctrl+Shift+F): Outlook Express's dialog -- from,
    to, subject, words, received before and after, an attachment, flagged,
    unread, where to look.
  - **Search Folders:** a search kept in the folder list ("Save as Search
    Folder" over the results), run again each time it is opened.
  - **Newsletters:** Unsubscribe in one click (RFC 8058 one-click, else a
    message to the list's address, else its page), Block Sender (to Junk,
    now and from now on), **Ignore Conversation** (to Deleted Items, with
    its replies as they come).
  - **My Templates** while writing (Insert, or the Templates button): start
    from one, or keep the message being written as one.
  - View, Current View, **Hide Read Messages**; Options, **Read all messages
    in plain text**; pictures from the web: **Trust this sender**.
  - **The sound of new mail** (Options, General): a chime, a ding, the old
    beep or a sound file of your own.
  - Imported newsletters no longer show their style sheet as the preview.
  - **Events and meetings** made, changed and deleted in the calendar, in
    both Microsoft 365 and Gmail: New Event (or a double click on a time),
    a double click on an event to change it, a drag to move it; title,
    start and end or all day, location, attendees (invited by the services
    themselves), a Teams meeting or Google Meet (*Join*), repeat, reminder,
    notes; only this event or the whole series; a meeting you organize is
    cancelled for its attendees when deleted. Message, New Meeting invites
    the people of a message. Google asks for `calendar.events` now (in place
    of `calendar.readonly`): Gmail accounts sign in again once.
  - **New mail while it is closed** (Android): a check of the system every
    15 minutes or so tells it in a notification and keeps the count on the
    icon; mail is told once, by the window or by the check.
- `platform`: `-d:retroAppFont=path/X-Regular.ttf` builds a font into an
  app (its bold found beside it, or `-d:retroAppFontBold`); it is the UI's
  font unless the user picks another. The bold is found when building for
  Windows from Linux too.
- `typeset`: an Arabic letter in its isolated form that a font lacks is
  drawn with the font's plain letter (fonts that map only the plain one).
- **Files dragged out of the window** to the system's file manager, the
  desktop or another program (Windows: OLE; X11: XDND; macOS: a dragging
  session): `fileDragSource(r, paths)` (the files made only once dragged),
  `dragFilesOut`, and `startDrag(..., files = ...)` -- the toolkit's own drag
  becomes the system's when it leaves the window, and comes back.
  uirelays: `startFileDragOut`, `uriListOfFiles`, `hdropOfFiles`. Retro
  Mail: attachments and messages (as .eml files) dragged out.
- **New module** `bgcheck`: work an app does while it is closed -- a check
  the system runs every so often with no window (Android's JobScheduler:
  `onBackgroundCheck`, `scheduleBackgroundCheck`, `inBackgroundCheck`);
  `retroapk --background` adds the job to the APK.
- uirelays (Android): a process started by a job of the system, with no
  activity, runs the app's start for its check; an activity opened later
  carries on from there.

## 0.18.0

- **Retro Mail 1.0.2:**
  - **The list:** beside the reading pane each message takes three lines
    (who and when, the subject and its marks, the tags and the start of
    the text), as Outlook shows it there. Arrange by date, sender, subject,
    size, flag or unread (a click on a column's header; again: the other way
    round); columns as wide as you drag them; the panes keep their sizes.
  - **Many at once:** Ctrl+click, Shift+click, Shift+arrows, Ctrl+A; the
    reading pane then offers what to do with them all. On a phone, a long
    press starts choosing (check boxes, and a bar of actions).
  - **Undo:** a delete, an archive or a move can be taken back for a few
    seconds (the bar at the bottom, or Ctrl+Z); **Undo Send** holds a message
    back 10 seconds (Options: 0 to 30).
  - **Threads:** a message picked inside a thread opens in the conversation
    and comes to the top of the pane; Reply answers that one. A double click
    (or Enter) opens a message in a window of its own, with Previous and Next.
  - **Mouse:** buttons over the row under the mouse (flag, pin, delete); drag
    messages onto a folder (moved), a tag (tagged), Flagged or Pinned.
  - **Keys:** Ctrl+Enter sends, Ctrl+Shift+V moves, Ctrl+Y goes to a folder,
    Ctrl+. and Ctrl+, the next and previous message, F6 the next pane,
    letters jump to a sender, Alt+Q "Tell me what you want to do"
    (every command by name); Help, Keyboard Shortcuts lists them.
  - **Workflow:** Quick Steps (several actions in one: Message, Quick Steps),
    Sweep (everything from one sender, now and from now on), Follow Up (a
    flag with a day, and a reminder when it comes), Message Rules (as
    Outlook Express had them: applied to mail as it comes, every account),
    meeting invitations answered in the message (Accept, Tentative,
    Decline: Microsoft 365 and Gmail), Automatic Replies (out of office),
    Forward as Attachment, Save As (.eml) and Open a saved message.
  - **Local Folders,** as in Outlook Express: File, Import brings mail from
    Outlook Express 4 to 6 (.mbx, .dbx: found on the computer by itself),
    mbox files (Thunderbird, Apple Mail, a Gmail Takeout) and .eml files;
    File, Export writes the list as an mbox file.
  - **Assistant:** Summarize a conversation, Translate a message, with your
    own key (Options, Assistant; nothing is sent before it is on).
  - **Writing:** spelling as you type (red lines; the right button
    suggests), AutoCorrect in English and Arabic (Options, Spelling).
  - **Attachments:** one click opens a file in its program; pictures show
    small under the message; Preview (a picture, a PDF) before opening;
    Save As and Save All start in Downloads.
  - **Reading:** Ctrl+wheel, Ctrl +/- and a pinch make the text larger
    (kept); mail is read once opened ("Mark as Unread" stays); the system's
    notification for new mail and the unread count on the icon.
  - **Phone:** pull down to check for mail, swipe a message sideways to the
    next one, the round Compose button, a tap of the motor as a swipe acts.
  - Tags: changes made here (read, flags, tags, moves) are no longer undone
    by a sync that read the server before they went out; the Tags menu finds
    a tag as you type, or makes it.
  - The signature comes from the web: Gmail's settings, and what Outlook put
    under the mail you sent last (for new mail and for replies).
  - Customize Toolbar (right-click the tool bar, or View).
  - New permissions asked at sign-in: Microsoft `Calendars.ReadWrite` and
    `MailboxSettings.ReadWrite` (invitations, automatic replies), Google
    `gmail.settings.basic` (the vacation reply, the signature): accounts
    added before sign in again for those.
- **New modules:** `toolcustom` (Customize Toolbar for any app: the buttons
  there are, the bar's, their order, the labels' look), `spell` (spelling
  through the system's checker -- Windows' own, Hunspell, Enchant -- and
  AutoCorrect, English and Arabic; `RichDoc.spell`, `RichDoc.autoCorrect`
  in the rich text editor), `notify` (the system's notifications: D-Bus,
  the Windows tray balloon, macOS, Android; the badge), `mailimport`
  (Outlook Express .dbx and .mbx, mbox, .eml in; mbox and .eml out).
- **New in the widgets:** `showSnackbar` / `snackbar` (what was just done,
  and Undo), `revealInPanel` (a panel scrolled so a part of it comes to
  the top), `downloadsDir`, `htmlView`'s `zoom` (Ctrl+wheel, Ctrl +/-, a
  pinch; `htmlBlock` too).
- **Two more UI fonts:** `ufFixedsys`, **Fixedsys Excelsior** (Darien
  Valentine's 8 x 16 Fixedsys, public domain): its pixels traced into clean
  outlines (`tools/genfixedsys.py`), crisp on its grid at 100 % and whole
  multiples, smoothed (Fixedsys Excelsior HD) on HD screens and in large
  text, monospaced text in it too, bold as Windows drew it, Arabic from
  Unifont; and `ufOpenSans`, **Open Sans** (SIL OFL 1.1), smooth, its stems
  fitted at small sizes. In `appearanceSettings`, kept by
  `storeAppearance`, named "Fixedsys" and "Open Sans" on a canvas;
  `-d:retroNoFixedsys` / `-d:retroNoOpenSans` leave them out.
  `builtinUiFonts`, `uiFontKey` and `uiFontOfKey` for an app's own font
  menu; Ledger has one (View > Font).

## 0.17.0

- **Retro Mail 1.0** (`examples/mail.nim`, `nimble mail`): Outlook Express 4
  to look at and to use, with what the new Outlook does, for Microsoft 365,
  Outlook.com and Gmail. Signed in in the browser (the services' own pages:
  no password typed here, the tokens kept encrypted); Microsoft Graph and
  the Gmail API only. Adding an account is your address and Enter: Retro
  Mail finds the service (by name, by the domain's Microsoft tenant, by its
  MX records) and the browser opens its sign-in page, done (the app registrations
  are built in: `examples/mail/appids.nim` or CI secrets; `docs/retromail.md`
  says how to make them once). Everything is kept in a local SQLite store: the list opens at
  once, search answers offline in milliseconds (`from:`, `tag:`, `is:`,
  `has:attachment`, `before:`), and changes made offline go out later.
  The start page, the Outlook bar, the folder tree with sub-folders and
  unread counts, the contacts pane, threads with + and - boxes (your
  replies in Sent Items in them), Focused and Other, tags in their colors
  (Outlook categories, Gmail labels), flags, pin, snooze, quick replies,
  rich text writing with signatures for new mail and for replies (a reply
  written in Outlook's blue, as it used to be; Options turns it off), send
  later, attachments of any size (Graph's upload sessions), the calendar,
  people, to do, notes, Tools > Options in OE's tabs, a phone layout where
  a message swipes right to archive and left to delete. Pictures from the
  web wait until asked. `tests/test_mail.nim` runs the engine against
  `tests/mailmock.py`, a stand-in for both sign-ins, Graph and Gmail.
- **New modules** (imported on their own: `import retroui/http`):
  - `http`: requests from any thread -- WinHTTP on Windows, libcurl (or the
    curl command) elsewhere, Java's HTTP on Android (PATCH too).
  - `oauth`: OAuth 2.0 in the system browser with PKCE and a loopback
    redirect; Microsoft and Google ready; refresh; the id token's claims.
  - `secrets`: tokens kept safe -- DPAPI, the keychain, libsecret, else an
    encrypted file.
  - `sha2`: SHA-256 and HMAC.
  - `db`: SQLite 3.54 compiled in, with FTS5 and an Arabic-aware folding
    for search; prepared statements kept, transactions that nest.
  - `mime`: mail messages read and written -- multipart, charsets
    (Arabic's windows-1256 and ISO-8859-6 among them), encoded words,
    RFC 2231 file names, addresses, dates.
  - `richedit`: a rich text editor that reads and writes HTML -- bold,
    italic, colors, sizes, lists, quotes, links, undo, the clipboard,
    Arabic paragraphs, a ready tool bar; `base`, the look of what is typed
    on an empty line (a reply's blue).
- **The HTML view reads mail.** `htmlView` / `htmlBlock` have a layout
  engine of their own (`htmldom`, `htmlcss`, `htmllayout`): style sheets
  and inline styles, tables as newsletters nest them, hidden preheaders
  left hidden, quotes as mail clients draw them, right to left,
  pictures through the app (`images`: cid: and the web only when allowed),
  selection and copying, `htmlToText`. No script, no network; a 200 KB
  newsletter lays out in about 15 ms.
- `tools/android/build_dex.sh` writes the dex in groups (a single long
  chain made the compiler crash).

## 0.16.3

- **uirelays is the code of the `uirelays` branch.** That branch is
  nim-lang/uirelays with my commits on top, ready for a pull request, and
  `src/retro/uirelays` holds the same files: nothing in it knows about
  retro any more (the C side's `retro_*` names are `uirelays_*`, the
  activity's `retroCall` is `uirelaysCall`, the Termux place is Retro
  Files' own), and the phone drivers draw rectangles, lines and points
  too, so any uirelays program runs on them. `tools/uirelays.sh` keeps the
  two the same (`push`, `pull`, `diff`); the pull request's text is
  `docs/uirelays-pr.md`.
- **Every app for every system.** One table in `retro.nimble` (Photo,
  Files, Board, the gallery, Notepad, Ledger, Charts, Invoice, Native,
  Hello) drives `nimble apks`, `exes`, `appimages` and `macapps`
  (`tools/macapp.sh`: the .app, its icon and Info.plist, zipped). GitHub
  Actions: **CI** runs the tests, the fuzzers, the Android driver on a fake
  Android and builds every example on Linux, Windows and macOS; **Release**
  makes all the packages, and a GitHub release for a `v...` tag. The
  gallery's APK is 0.16.3, and smaller (LTO, built for size).
- Fixes: the rasterizer skips a line with a NaN or an infinite end (the
  UI fuzzer's charts of NaN wrote outside its buffer); a PSD's color mode
  read without an unsafe conversion; EGL's functions looked up without a
  copy of their name; Photo's scratch files let go of from a destructor
  that cannot raise; the Android mock test and the Photo fuzzer up to
  date (neither ran any more); the README's signing-key folder.

- **Retro Board 1.3.1.** A line drawn from a shape, or onto one, holds on
  to it: a connector (an arrow with no heads, straight, curved or elbow
  from the Arrow panel) that follows the shapes as they move; Alt draws a
  free line. 100% is a page unit to each dot of the screen: half the size
  it was on tablets and phones (and sharp desktop screens), as the zoom box
  says.
- **Retro Board 1.3: the panels as Retro Photo's.** The properties panel
  is now `retroui/dock`'s docked panels down the right, in tabs grouped by
  what they are about: Color, Stroke and Fill (how a shape looks); Text,
  Arrow and Shapes (what it is); Arrange, Board and Info (where it goes,
  the pages and the canvas, the memory). Dragged by their tabs into other
  groups or out as floating palettes, folded, collapsed to icons; a menu
  per panel (Reset Panels); View > Panels shows and hides each; Tab hides
  them all; kept as left between runs. On a phone, a strip of icons whose
  panels open beside it. The canvas leaves the panels' clicks to them.
- **Exit Zen and Edit (View mode) work again**: the canvas under the
  button took its press first.
- `Dock.coverRects`: where the dock covers its area (its columns, its
  floating palettes, a collapsed column's group shown) -- for a canvas
  drawn by hand under it. An edge-to-edge `beginMdi` stops above a status
  bar drawn before it.
- **Retro Board 1.2: Excalidraw's options.** A properties panel in
  sections -- stroke, background (a fill color of its own), fill
  (hachure, cross-hatch, zigzag, dots), stroke style, sloppiness
  (architect, artist, cartoonist), edges (sharp, round), arrow type
  (straight, curved, elbow), arrowheads, size, font, text align (and top,
  middle, bottom), opacity, layers, align and distribute, actions
  (duplicate, delete, link, group, lock, next step) and, with nothing
  selected, the canvas's color; it scrolls when taller than the window.
  Links on shapes (a badge opens them), Ctrl+Arrow (or Arrange > Next Step)
  adds a flowchart's next shape with an arrow, Edit > Find (Ctrl+F, F3),
  Arrange > Position and Size, View > Stats (the board, the memory used,
  Free Memory), Zen mode (Alt+Z) and View mode (Alt+R), export in the dark
  colors. The engine (`retroui/board`): `fillColor`, `roughness`, `round`,
  `elbow`, `link`, `Board.paper`; `fillLines`, `roundCorners`,
  `elbowPath`, `addConnected`, `findText`, `paperOf`.
- **Shapes stay in their clip when the GPU draws** (`gfxgpu`): a path was
  clipped to the whole screen, not to its clip -- a canvas's shapes were
  drawn over the title bar, the menus and the status bar (and a button's
  hatching out of the button), on phones and tablets.
- **Retro Board 1.1**: six handwriting fonts, a font picker that shows
  each in its own letters (Caveat by default); 12 more shapes (rounded
  rectangle, right triangle, cylinder, document, speech bubble, cross,
  double arrow, chevron, lightning, moon, cube, person); the **Sketch**
  line style (View > Sketch Style for new shapes); the navy 3.1 title bar
  on phones and tablets, a status bar with the memory used, View > Colors
  (every scheme) and Appearance... (kept); File > Exit on every system.
- **Lines no longer vanish when zoomed in on a phone** (`gfxgpu`): a shape
  bigger than the GPU's mask atlas (2048 pixels: a stroke across a phone's
  screen, zoomed in) was drawn as nothing -- the atlas said "too big" in a
  field the caller did not look at. It is now drawn with a texture of its
  own, what came before it drawn first.
- **Memory** (`retroui/board`): pictures are kept once per board
  (`assets`, `addAsset`, `assetOf`; files keep them once too, older ones
  are read) -- a 3 MB photo moved 60 times took 354 MB, now 3 MB; the
  steps to undo keep at most `undoBudget` bytes (16 MB), the drawings
  `drawingBudget`; Retro Board lets them go when memory is short.
- `addFontData(family, style, data, packed)` (`retroui/textengine`): a font
  the program carries, offered by name and read when first drawn.
- `fontSpans`: text set in a board font, letters it lacks in another.

- **Retro Board 1.0** (`examples/retroboard.nim`, `nimble board`,
  `nimble boardapk`): a whiteboard in the manner of tldraw. Tools: select,
  hand, draw (pen pressure), highlighter, eraser, laser pointer, 19
  shapes, arrow, line, text, sticky note, frame, picture. A style panel
  (twelve colors, opacity, fill, dash, size, font, alignment, arrowheads,
  smooth lines), pages, zoom; move, size, turn, snap, group, lock, align,
  distribute, flip, order, copy and paste, undo and redo; double click (or
  tap) to type in a shape; pinch and two-finger pan on phones, a long
  press for the menu; tldraw's keyboard shortcuts; a dark mode; saved as
  you go; `.board` files; PNG, SVG and PDF export, shared from a phone.
- **`retroui/board`**, the whiteboard's document: pages of shapes, styles,
  bound arrows, undo and redo of changes (`change`, `begin` / `commit` /
  `cancelChange`), hit-testing, snapping guides, groups, clipboard,
  align / distribute / flip, the drawing of each shape as outlines (kept
  till it changes), `.board` JSON, `renderBitmap`, `toSvg`, `toPdf`.
- **`retroui/freehand`**: the outline of a stroke drawn with a pen, a finger
  or the mouse -- thinner where it went fast or was pressed lightly,
  streamlined, tapered and capped -- as one polygon.
- **Two-finger gestures** on Android: a pinch and a two-finger drag come as
  `GestureEvent`s (`scale`, `dx`, `dy`, `phase`) and to apps as
  `ui.pinch`, `ui.pinchX` / `pinchY`, `ui.panDX` / `panDY` and
  `ui.gesturing`; the first finger's press is let go far away when the
  second comes down (nothing is clicked).
- `fillContours(contours, color, ox, oy, k)`: several outlines filled as
  one shape, panned and zoomed (a drawing kept in its own units).
- **Paths drawn in part are drawn right** (`gfx`, `raster`): when only
  some of the screen changed, a path crossing the edge of a part was
  drawn with its corners moved onto that edge (a wrong slant near it), a
  1-pixel gap at the part's right side, and -- a line ending on the left
  side a hair past it -- a faint tint across the rest of the row. Its
  edges are now cut where they cross (`Raster.edge`, which no longer
  allocates); `Raster.line` keeps a row's area whatever the rounding.

## 0.16.2

- **uirelays brought up to date** (upstream `f885a4f`, merged with retro's
  own changes): the `renderText` font relay -- a run of the platform's text
  as pixels -- in every driver, retro's Android one too; Windows opens a
  font file by the face it holds (a bold file no longer opens regular);
  fonts need no window; native font resources are released.
- **The platform's text drawn in its place**: text in scripts the built-in
  fonts lack (CJK, and others) is now made into pixels by the driver
  (`renderText`) and blended into the frame among the rest of the drawing
  -- before, the system drew it over the finished frame, so it showed
  through a menu or dialog opened over it; and with the GPU it is drawn at
  all (it was left out). Kept per text and size; a driver without
  `renderText` draws it as before.
- **The control gallery up to date**, and built for every system:
  `nimble galleryexe` (Windows), `galleryappimage` (Linux), `galleryapk`
  (now versioned). Its Windows page has docked panels (tabs, groups, a
  column of icons, the side panel sized from its edge), a window kept on
  top and size grips; its menu bar a Window menu (`mdiWindowMenu`) and
  Insert > Field, a long submenu; its folder tree room inside its frame
  and a menu on a right click.
- **Lines with arrowheads** (`retroui/photoshapes`): a shape's open lines
  get an end at their start and their end (`ShapeData.startEnd`,
  `endEnd`: `LineEnd` -- an arrow, an open arrow, a stealth arrow, a
  circle, a square, a diamond, a bar; `endW`, `endL` their size), drawn in
  the stroke's color and turned as the line goes (a curve's too), the line
  cut back under an arrowhead; kept in documents, in SVG and EPS as
  outlines (`endsPath`, `trimmedPath`). Retro Photo's Line tool makes such
  a line: it stays a line, its ends dragged with the Move tool.
- **Rows with own-width columns** (`row([-1, 0])`): a column of the
  widget's own width now takes its room from the shared ones (as wide as
  last frame) -- the shared column took all of it and pushed the rest out
  of the row (Retro Photo's Libraries panel: its New... button cut off).
- **The ink tables made once, by one thread** (`retroui/photoinks`): a CMYK
  or grayscale picture separated on all the cores asked for them at once
  -- each thread made them over the others' and freed tables still being
  read (a crash now and then saving a CMYK TIFF; AddressSanitizer found it).
- `Doc.stepsMade` counts the steps made (an operation's own: those since it
  began -- Retro Photo's Esc takes them back); `Layer.box`, `boxVer` keep a
  layer's measured box on the layer (a cache by its address gave a new
  layer a deleted one's).
- **Windows kept on top** (`MdiWindow.pinned`): a pin in a document
  window's title bar (latched in while on), "Always on Top" in its control
  menu and in `mdiWindowMenu`; a pinned window stays over the other
  documents (the palettes still over it), and clicking one under it makes
  that one the active window without hiding the pinned one.
- **The whole side panel sized from its edge** (`retroui/dock`): a split bar
  between the documents and the dock -- dragged, the first open column
  widens or narrows (up to what leaves the documents room); with every
  column collapsed to icons, dragged out it opens the main one again.
- **The About box's pages scroll inside their tab** (`beginScroll(...,
  framed = false)`: a scroll bar only when the page is taller), the
  buttons and the tabs staying put.
- **Tooltips beside the pointer on Windows**: placed under the cursor by
  its real size (the system's cursor size and the display's scale, new
  `WindowRelays.pointerHeight`), no longer under the arrow itself.
- **Retro Files 3.3**: View > Folders in Windows -- each folder in a
  window of its own, as the 3.1 File Manager had them (Window > New Window,
  Cascade Shift+F5, Tile Shift+F4, Always on Top, the windows' list;
  Ctrl+F6 the next, Ctrl+F4 closes), each with its address bar, search and
  preview -- or in tabs, as before (Folder Options > Folders).
- **Pointers for sizing and moving** (`CursorKind`): `curSizeNWSE`,
  `curSizeNESW` and `curMove` in every driver (X11, Windows, GTK, SDL,
  macOS; the others their nearest).
- **`retroui/edgetrace`** (new): the edges of a picture found (as Canny's
  detector: the color channel that changes most, alpha too) and linked
  into ordered lines -- `newEdgeMap`, `chainAt`, `chainPoints`,
  `chainPart`, `chainClosed`, `simplify`; pictures over 6 MP traced on a
  smaller copy (a 4000 x 3000 photo in about 0.3 s).
- **Retro Photo 4.8**:
  - the Move tool as Photoshop's: the transform box's handles take the
    pointer from further away (a side anywhere along it), the one under it
    lights up (filled blue, larger; the outline thicker inside; a curved
    arrow where it turns), the pointer shows what a drag does (slanted
    arrows at the corners, following a turned box; four arrows inside --
    the pointer was always an arrow before); a double-click on type edits
    it in the Type tool, the Move tool back when done; a right click lists
    the layers under the pointer (and Free Transform, Duplicate, Delete,
    Blending Options); Auto-Select by Layer or Group;
  - Smart Guides (View > Show > Smart Guides, Preferences): a move snaps
    to the other layers' edges and middles, the image's and the guides,
    magenta lines where it lines up, the room to the nearest layer on each
    side, how far it has gone; Ctrl held: free;
  - the Selection Brush (in the selection tools: Add or Subtract, its size
    and hardness, the red overlay), the Adjustment Brush (in the brushes:
    Brightness, Contrast, Exposure, Saturation, Vibrance, Warmth, Clarity,
    Dehaze, Black & White, Invert painted as an adjustment layer's mask;
    the amount changes it afterwards) and Content-Aware Tracing (in the
    pens: the edge under the pointer lit up, a click makes it a path,
    Shift+click goes on along an edge; Detail and Detailed / Normal /
    Simplified);
  - Window > Arrange > Always on Top for floating images; the panels'
    side sized by its edge.
  - the tools work on the image only: a press on the gray round it does
    nothing (the Hand and the Zoom anywhere; a box's handles, the crop's,
    a lasso being drawn still take it);
  - several layers picked: Group, Merge (new Layer > Merge Layers) in the
    bar under the image, a right click on the layers or the image; the
    Layers panel's folder button groups them;
  - no other program's names in the menus, dialogs and help ("PSD" for
    the format).
- **Always on Top waits while a window is maximized** (its pin grayed,
  its menu items off); `MdiWindow.gripSize` sizes a window's grip, and a
  window that is not flush gets the grip too.
- `beginTree`, `folderTree`: `padding`, room inside the frame.
- **The menu bar by the keyboard**: F10, or Alt pressed and let go alone
  (a tablet's keyboard has no F10), opens the first menu -- again closes
  it; Left / Right go along the bar even with the pointer resting on a
  menu's title (it took the menu back every frame: only a pointer that
  moves there opens another now); a menu opened by a key after the bar
  was drawn is no longer closed in the same frame (F10 did nothing).
- **Menus taller than the screen go on in columns**, as 3.1's long menus
  did (a tablet's Window menu): the rows wrap at the bottom of the screen
  into columns of about the same height, a line between them. A submenu
  or context menu that would only pass the bottom moves up instead, in
  one column (it wrapped into a strip of short columns along the bottom);
  a submenu opens beside the whole menu -- right of all its columns, else
  left of it -- and is drawn over it (it opened beside its own column,
  over the next one).
  The pointer on its way to an open submenu, over the rows of another
  column, leaves it open; resting on another row closes it after a moment
  (400 ms), as 3.1's menus waited (the submenu closed as soon as the
  pointer crossed a row: one beside a menu in columns could not be reached).
- **Type (and shapes) moved off the image come back**: their box is
  their whole text's, off the image too -- shown round it on the gray, a
  press there picks it and drags it back, Properties gives its X and Y
  (before, the box was cut to the image: all of it off, nothing to grab).
- `gfx.intersects(a, b)`.
- **The pin of a window's title bar works**: the title bar's drag took
  its press (it reached up to the minimize button), so a click on the pin
  moved the window instead.
- **Retro Files 3.3** also: Tabs or Windows from the tool bar, View >
  Folders In and the Window menu (always there on a desktop); each
  folder's window with a size grip (Folder Options: none to large); in a
  narrow window the search is a button, its box under the address bar;
  room inside the folder tree's frame; the folder tree's menu (a right
  click: open in a new tab or window, new folder, paste into it,
  favorites, copy as path, terminal, folder sizes, empty the trash,
  properties).

## 0.16.1

**The memory of the programs no longer only grows** (Retro Files showed
1.8 GB after a while of use).

- **The system's malloc for every program** (the examples' and tests'
  config.nims; `retroapk` adds `-d:useMalloc` to every APK): Nim's own
  allocator keeps every page it ever took -- on each thread, and the
  picture workers decode on three -- and never gives them back, so a
  program that shows many pictures only grew. The toolkit warns at compile
  time without it (`-d:retroNimAlloc` keeps Nim's allocator, quietly).
- **What is let go of goes back to the system** (`memwatch.trimHeap`:
  glibc's malloc_trim, Android's M_PURGE; big blocks -- pictures -- mapped
  on their own so freeing one returns it at once): after the caches let
  go, when the program goes to the background, and when it rests after
  its memory grew.
- **A budget for the program too** (`programBudget`: a tenth of the
  device's memory, 384 MB to 1.5 GB): past it the caches let go even with
  the device far from short.
- **The GPU's textures within a budget** (`gpuTextureBudget`, 160 MB): a
  viewer flicking through photos keeps a few, not one for every photo of
  the last two seconds.
- Pictures over 2 MP shown at less than half their size, and any over 24
  MB decoded, are read a band at a time (`bigPictureBytes`): a 12 MP photo
  in the viewer no longer takes its whole decode first.
- A long session in a folder of 25 big photos a time, six folders round:
  425 MB held with Nim's allocator, 269 MB with malloc alone, 162 MB now
  -- the pictures kept (124 MB) and little more (tests/test_memsoak keeps
  it so).

**Windows**

- A window opens with its inside the size the program asks for (the title
  bar and borders added around it, as on the other systems), grown by the
  display's scale and kept within the desktop: the content no longer
  scrolls in a window too small for it.
- `nimble photoexe` and `nimble filesexe` build Retro Photo and Retro Files
  for Windows from Linux or macOS, with their icons and version
  (`tools/winicon.nim`: a .ico and a VERSIONINFO linked in by windres).
- Smaller programs: `retrokit small` (and the examples' Windows builds)
  link with LTO, stripped -- a window with a photo and a button: 2.6 MB
  before, 1.48 MB now, 1.12 MB with `-d:retroNoW98 -d:retroNoKawkab` (Retro
  Sans and DejaVu Sans Mono standing in for MS W98 UI and Kawkab Mono).

Retro Files 3.2, Retro Photo 4.7.

## 0.16.0

**Retro Photo 4.6**

- **Pictures too big to edit whole** (a gigapixel scan, a 30000-pixel
  map: more than the device's memory allows) are no longer refused: Open
  offers **A Smaller Copy** (all of it, as big as the device allows) or
  **A Part of It...** (picked on a preview, at full size), read a band at
  a time; the copy is a new image, so saving never writes over the big
  file. (`photofiles`: `pictureTooBig`, `largestSize`, `bigPictureSize`,
  `openPictureScaled`, `openPictureRegion`, `PictureTooBigError`.)
- **JPEG XL written lossy too** (Export As > JPEG XL: Lossless off, a
  quality as cjxl's -q, 90 looking the same as the picture): XYB, the
  Squeeze transform and quantization through the MA tree, as `cjxl -m 1`
  -- about a tenth of the lossless size at quality 90, every file read by
  libjxl 0.12 to within one level of our own decoder.
- **Pexels and Unsplash** in the Assets window (photos and backgrounds;
  each with a free key in Assets > Settings): search, the curated or
  popular ones, credits and links as their rules ask (Unsplash told when
  one of its photos is used).

- **Dialogs on tablets and phones:** the controls at the right of Select
  and Mask (and of Layer Style, Export As, the color dialog and others)
  were cut off when the interface was scaled up -- their columns were
  scaled twice. Select and Mask is wider, and on a narrow screen puts its
  settings under the picture.

**Retro Files 3.1**

- Very big pictures no longer take their whole size in memory: their
  thumbnails and the picture viewer read them a band at a time (a
  12000 x 9000 PNG: a few MB instead of 1.1 GB).
- In the Arabic interface a line that mixes Arabic with numbers ("812 MB
  متاحة من 252 GB") reads right to left, in its order; the copy progress,
  the times left, the line counts and Rename's "Title Case" are Arabic too.

**Toolkit**

- `bigpicture`: very big pictures (gigapixel scans, panoramas, maps 30000
  pixels a side) read a band at a time straight from the file (mapped):
  `readScaled` (all of it fitted, averaged: the memory is what is made),
  `readRegion` (a part, 1:1 or at 1/n), `bigPictureInfo`, `fittedSize` --
  PNG (every kind, interlaced too), JPEG (baseline a few rows of blocks at
  a time, restart intervals skipped; progressive keeping only the
  coefficients of the rows wanted, or at 1/8 only the averages; EXIF
  turned), BMP, TGA, TIFF (strips inflated as they go, tiles a row at a
  time); a progress callback, Cancel. `loadPicture` reads big PNG, JPEG
  and BMP files so (`bigPictureBytes`): a 12000 x 9000 PNG shown at 1024
  pixels takes a few MB instead of 1.1 GB, a JPEG 14 MB in a tenth of a
  second. `codec`: `Inflater` (`initInflater`, `inflateRead`: deflate a
  little at a time). `jpeg`: `jpegLayout`, `jpegBands`, `exifTurned`;
  `decodeJpeg` reads from the file's bytes without a copy.
  `imageformats`: `tiffInfo`, `tiffCheck`, `tiffPiece`, `tiffSample`,
  `tiffPixel`, `tgaInfo`, `tgaPixel`, `maxFilePixels`; `decodeTiff` and
  `decodeTga` check the size a header claims against the data first (a
  damaged file cannot ask for gigabytes), and PackBits TIFFs whose last
  strip is short read.
- Fixed: 40 rows of the apps and the kit (`row([dp(80), -1])`) scaled their
  widths twice -- right on a desktop at 100 %, cut off on a tablet. `row`'s
  widths are design pixels (scaled once); `rowPx` takes widths measured on
  the screen.
- `typeset.setRtlInterface` (set by `setUiLanguage`): in a right-to-left
  interface a line that mixes Arabic with Latin and numbers reads right to
  left ("1.0 GB متاحة من 252 GB" in its order); one without Arabic keeps
  its own direction.
- `jxl`: `encodeJxl(b, quality, effort)`, `encodeJxlDistance`,
  `jxlDistance` -- lossy JPEG XL (lossy modular). `assetstore`: Pexels and
  Unsplash (`pexelsKey`, `unsplashKey`, `hasKey`, `AssetItem.pingUrl`);
  `assetfetch`: `withHeaders`, `splitHeaders` -- request headers (an API's
  key) sent with downloads on every system, Android too; `fetch.downloadFile`
  takes `headers`.
- Camera raw thumbnails checked on real files: a Canon CR2 and a Nikon NEF
  give their previews in 6 to 70 ms at thumbnail size; real Canon, Fuji,
  DNG and Panasonic files of exiftool's test set read cleanly.

## 0.15.0

**Retro Photo 4.5**

- **File > New as today's Photoshop, kept simple:** tabs by what the
  document is for -- Recent, Saved, Photo, Print, Social, Web, Mobile, Art &
  Illustration, Film & Video -- with blank presets as cards (A4 to roll-up
  banners, Instagram to YouTube, phones, 4K), the recent files and sizes,
  your own saved presets, and **15 ready-made templates** with their
  pictures: event flyer, employee of the month, certificate, staff notice,
  business card, announcement post, event story, Eid greeting, Facebook
  cover, YouTube thumbnail, photo collage, before and after, title card...
  Their type stays type, their photos go into frames (Layer > Place Into);
  in the Arabic interface their words are Arabic. Preset Details at the
  right: size in pixels, inches, centimeters, millimeters, points or picas,
  orientation, artboards, resolution, color mode, background. Preferences
  > General > Use Legacy "New Document" Interface brings back the 1994
  dialog.
- **Assets** (File > Browse Assets, Window > Assets): free photos,
  illustrations, SVG vectors, icons, textures and backgrounds from
  Openverse, Wikimedia Commons, Iconify (300,000 open-source icons), Poly
  Haven and ambientCG -- and Pixabay with your free key -- by kind and
  category, with a search; Insert puts one straight into the image (a
  photo as a Smart Object, an icon or SVG as vector shape layers in the
  foreground color, a texture as a layer), Open as Document, Download
  (to Pictures/Retro Photo Assets with CREDITS.txt); the credit kept in
  File Info. Through the sources' APIs only, as their terms ask.
- **The Retro Photo Library**, carried in the app (works offline) and
  online (a catalog on GitHub adds to it with no new version): 14 brushes
  (bokeh, sparkle, snowflake, crescent, khatam star, calligraphy nib...),
  14 patterns (Islamic khatam stars, arabesque, Moroccan trellis...), 12
  gradients (gold foil, rose gold, Oman flag...), 6 swatch sets, 10 layer
  styles and the designs; a pattern or gradient comes in as a fill layer,
  a style on the layer, a brush into the Brushes.
- **8 more templates** (23 in all): National Day greeting, Ramadan Kareem,
  We're Hiring, Quote Post, Wi-Fi Card (with its QR code), Thank You Card,
  Restaurant Menu, Welcome Card.
- **New QR Code** (Layer menu): links, text, Wi-Fi, phone, email, contact
  cards -- a vector shape layer, sharp at any size.
- **Retro Photo is a still-image editor again:** the Timeline (frame
  animation), animated GIF/WebP export and video import are taken out of
  the app; an animated GIF, WebP or JPEG XL opens as its first picture.
  The toolkit keeps all of it for other apps (`photoanim`, `gifanim`,
  `media`: frames, tweens, video reading and H.264 writing;
  `photofiles.openAnimations`).
- **Quick Actions** panel: Remove Background, Blur Background, Black &
  White Background (each a layer with its mask, editable), Select Subject,
  Enhance Image, Smooth Skin, Restore Old Photo, Frequency Separation, Crop
  and Straighten Photos, Share.
- **File > Share** (Android's share sheet: WhatsApp, mail...); **Export >
  Layers to Files**; **Automate > Image Processor** (a folder resized,
  converted to JPEG, PNG or WebP, watermarked), **Contact Sheet**, **Crop
  and Straighten Photos** (several photos scanned at once, each cut out and
  made straight).
- **Image > Adjustments > Match Color**, **Select > Focus Area**, **Filter
  > Other > Frequency Separation**, the **Color Themes** panel (analogous,
  triad, complementary... added to the Swatches), **View > Before &
  After** (a line to drag), **Type > Paste Lorem Ipsum**; R picks Rotate
  View, as in Photoshop.
- **Files:** **JPEG XL** (read: lossy, lossless, animated, 16-bit; written
  lossless), **SVG** opened and placed as editable shape layers, Canon
  **CR3** (lossless and C-RAW), HEIC and AVIF on desktops
  through the system's libraries (libheif, libavif, ImageIO, WIC; 10-bit
  kept at 16), AVIF and HEIC written where the system can.
- **The layers composited on the GPU** when that is quicker (the same
  pixels as the CPU's, exactly; it measures and keeps to the faster).
- **A pen's pressure, tilt and rotation on Windows, macOS and Linux (X11,
  GTK 4, SDL 3)**, its eraser end too.
- In the Arabic interface the color field, sliders, curves, gradients,
  the Navigator, Liquify, Lens Correction, Blur Gallery and Vanishing
  Point keep left and right.

- About boxes of every app made with the kit name the developer: Sultan
  Al Isaiee @foxoman, www.foxoman.net, sultan@foxoman.net.
- Help > Report a Problem is the toolkit's box now: add what you were
  doing, then Copy or **Send by Email**. The thumbnails of the Open dialog
  and the Assets window are kept on disk; when the device runs short of
  memory the zoomed-out copies are let go.

**Retro Files 3.0**

- **Thumbnails of almost every picture there is:** camera raw photos (CR3,
  CR2, NEF, ARW, DNG, RAF, ORF, RW2, PEF... -- the camera's own preview,
  turned the right way), Photoshop and Retro Photo documents, SVG, JPEG
  XL, WebP and GIF on every system, TIFF, TGA, EXR and HDR, HEIC and AVIF
  on desktops through the system's libraries.
- **Thumbnails kept on disk** (Folder Options > Work: on, at most 32 MB to
  1 GB, Clear): a folder of photos, videos or documents opens at once the
  second time -- 120 camera JPEGs: 2.7 s the first time, 0.06 s after.
- **Smart memory:** the pictures kept in memory are a share of the
  device's memory (16 to 192 MB, not a fixed 96 MB); when the device runs
  short they are let go, all but those on the screen, and all of them
  when the app goes to the background (a phone ends first the apps that
  keep the most). Tools > Free Memory; the About box says what is used.
- **Arabic interface**, mirrored right to left (Folder Options > Look >
  Language).
- **Tools > Folder Sizes:** what takes the room in a folder, measured in
  the background, largest first; double-click one to go there.
- Edit > **Copy To Folder / Move To Folder**, File > **Send To**
  (compressed folder, a folder, the other pane, Favorites), **Open with
  app**, **Share** on phones, New > **Markdown Document**; Help > What's
  New, **Report a Problem** (a fault no longer closes the app: it is kept
  for the report), Retro Files on the Web.
- Very large folders stay quick: 20,200 items are listed in about 0.1 s
  and every view draws a frame in under a millisecond while scrolling
  (tests/test_filespeed); thousands of random taps, drags and keys run
  without a fault (tests/test_filesapp).

**Toolkit**

- `memwatch`: `deviceMemory`, `freeMemory`, `programMemory`,
  `memoryNumbers`, `cacheBudget`, `memoryPressure`, `onMemoryPressure`,
  `releaseMemory`, `memoryReport` (Linux and Android from /proc, Windows
  from GlobalMemoryStatusEx and the working set, macOS and iOS from
  sysctl). The shared picture cache (`pictures()`) follows it:
  `newPictureCache()` sizes itself from the device's memory,
  `PictureCache.release`.
- `thumbcache`: `useThumbCache`, `thumbCacheFolder`, `cachedThumb`,
  `keepThumb`, `worthKeeping`, `thumbCacheBytes`, `clearThumbCache` --
  `background` keeps the thumbnails of slow files there by itself, on its
  worker threads, trimmed to the limit (least recently used first).
- `morepictures`: `addMorePictures` -- thumbnails and previews for camera
  raw files (their embedded previews), PSD/PSB, RPD, SVG, JPEG XL, TIFF,
  TGA, EXR, HDR everywhere; GIF, WebP, HEIC, AVIF on desktops.
- `desktop`: `reportProblem`, `problemBox` (the faults of the last run
  told at the next start; Copy, Send by Email); the About box's facts say
  how much memory is used and free.
- Fixed: the worker threads that decode thumbnails (`background`) shared
  the drawing thread's pool of cores, which could crash when several big
  pictures were decoded at once; each worker now decodes by itself.
  `decodeWithSystem` uses a file of its own per thread.
- **Another language goes further:** a label is looked up whole before it
  wraps (`label(name, literal = true)` shows a file's name as it is), and
  grid column titles, toasts, banners, empty and busy states, status bars,
  setting details, headings, search placeholders, combo lists, palette
  tabs, fact labels, the drive bar's and the tree's places, kinds of file
  ("صورة PNG"), counts, sizes, job summaries and the undo label are
  translated; the toolkit's Arabic table grew.

- `assetstore` / `assetfetch`: open asset sources (Openverse, Wikimedia
  Commons, Pixabay, Iconify, Poly Haven, ambientCG, a library catalog),
  their categories, queries and answers, a pool of download threads with
  a cache (Android through `RetroNet.java`). `svgimport`: SVG read
  (paths, shapes, transforms, gradients, clips, masks, CSS classes, use,
  markers), as shape layers (`placeSvg`) or drawn (`rasterizeSvg`). `jxl`:
  JPEG XL decoder and lossless encoder, pure Nim. `qrcode`: QR codes
  (versions 1-40, every level, as a bitmap or as outlines). `media`:
  `videoFrameAt`, `videoInfo`, `beginVideo` / `addFrame` / `finish` (H.264
  MP4: Android's MediaCodec, ffmpeg on desktops).
- `core`: `RetroDeveloper`, `RetroCredit`, `RetroWebsite`, `RetroEmail`.
- `phototemplates`: `docPresets`, `DocPreset.sizeLabel`, `docTemplates`,
  `templatesOf`, `buildTemplate`, `templateThumb`.
- `photoquick`: `blurBackground`, `bwBackground`, `frequencySeparation`,
  `focusArea`, `findPhotos`, `cutPhoto`, `colorTheme`, `featherMask`.
- `photogpu`: `enableGpuComposite`, `gpuComposite`, `gpuCompositeSupport`,
  `releaseGpuComposite`; `photo.gpuCompositeHook`.
- `cr3` (CRX codec), `rawformats` reads CR3; `systemimage`:
  `decodeWithSystem(path, hi)`, `encodeWithSystem`, `systemEncodeExts`.
- Pen events on the desktop drivers (`drivers/penaxes`).

## 0.14.0

**Retro Photo 4.4**

- **16 bits a channel, kept through the work:** blurs, sharpening, High
  Pass, Levels, Curves and every adjustment made of tables, gradients,
  Image Size, Canvas Size, Crop, Flip and Rotate work on the 16-bit
  numbers; the layers are composited at 16 bits (masks, opacity and fill,
  blend modes, clipping, adjustment layers). A tool that paints at 8 bits
  changes only the pixels it touched. 32-bit light is kept the same way.
- **CMYK by its ICC profile:** Color Settings > Load CMYK Profile (any
  printer's .icc), rendering intent and black point compensation; used for
  CMYK and Proof Colors and named as the PDF/X output intent.
- **OpenType:** text shaped by the font's own tables (GSUB and GPOS:
  ligatures, Arabic joining and its marks placed, kerning), the Amiri
  naskh font built in; **variable fonts** (weight, width, slant... and the
  named instances); an **OpenType panel** (the font's features on and off,
  its axes); **Character and Paragraph Styles** panels (define, apply,
  redefine, overrides shown with a +).
- **PSD:** type layers saved editable (Photoshop opens them as type);
  Smart Objects saved and read as smart objects (their file inside);
  **layered TIFF** read and written.
- **Formats:** WebP (lossy, lossless, animated; read and written), OpenEXR
  (half or float, read and written), camera raw files NEF, ARW, CR2, ORF,
  RW2, PEF and RAF, HEIC and AVIF opened (by Android itself; on a desktop
  by a converter installed there), Export > SVG (shapes and paths as
  vectors, the rest as a picture).
- **Timeline:** frame animation as Photoshop's -- frames, their delays,
  Play, loop, Make Frames From Layers, Tween, Flatten Frames Into Layers;
  animated GIF and WebP opened as frames and saved; Place Video Frames to
  Layers.
- **Rotate View** (in the Hand tool's group; Esc or Reset View) and the
  **Art History Brush** (10 styles).
- **Scripts:** File > Scripts -- a script editor, scripts run from files,
  in Retro Script (reads like JavaScript: `app`, `doc`, `layer`; safe: no
  files, no network).
- **A pen's pressure, tilt and rotation** (Android and iPad): Brush
  Settings > Pen Tilt and Rotation; the eraser end erases.
- **Liquify:** Smooth, Push Left, Freeze and Thaw Mask, pressure. **Filter
  > Vanishing Point:** a plane in perspective, Paste onto it, Stamp along
  it. **Select and Mask:** Color Aware edges.
- **The GPU for filters:** Gaussian Blur and the adjustments made of
  tables run on the GPU on big pictures (the CPU when there is none).
- **العربية:** the whole interface in Arabic, right to left
  (Preferences > Interface > Language); the picture is not mirrored.

**Toolkit**

- `photodeep` (16-bit composite, filters, gradients), `photo`: `hi`
  tracking (`syncHi`, `setHi`, `hiPixels`, `flattened16`), character and
  paragraph styles, `AnimFrame`; `photofx`: `HiWay`, `withHi`, `DeepImg`.
- `otshape` (OpenType shaping), `ttf`: variable axes and instances;
  `textengine`: `features`, `variation`, style names.
- `icclut`, `photoinks`: `setInkProfile`; `webp`, `exr`, `gifanim`,
  `rawformats`, `systemimage`, `photosvg`, `photoanim`, `photovp`,
  `rscript`; `psd`: TySh, smart objects; `media`: `videoFrames`.
- `core`: `ui.rtl`, `setUiLanguage`, `tr`, `beginKeepSides`; `gfx`:
  mirrored drawing; `lang_ar`; pen pressure, tilt, azimuth and twist in
  events (Android, iOS); `gfxgpu`: `gpuBlur`, `gpuColorTable`.

**Not yet:** layers composited on the GPU (the filters and the display
are), tiles for pictures bigger than memory, Canon CR3 and JPEG XL, video
layers (frames are placed as layers), pen pressure on Windows, macOS and
X11.

## 0.13.0

**Retro Photo 4.3**

- **32 Bits/Channel** (Image > Mode): the light kept as it is, brighter
  than white too -- from Image > Mode, or a Radiance (.hdr) or PFM picture
  opened; View > 32-bit Preview Options shows it at an exposure and gamma;
  HDR Toning (Exposure and Gamma, Highlight Compression, Equalize
  Histogram, Local Adaptation) brings it down to 16 or 8 bits. Kept in
  .rpd; saved as .hdr and .pfm.
- **24-bit output:** Export As names PNG-24 (24-bit color; 32 with its
  transparency; 48-bit from a 16-bit image) beside PNG-8; BMP at 24 bits
  or 32 (its transparency kept -- and read back).
- **PDF for a press:** PDF/X-4 or PDF/X-1a:2003 with its printing
  condition (FOGRA39, FOGRA51, GRACoL2006, SWOP2006, Japan Color 2001),
  crop marks, registration marks, color bars, page information, the bleed
  drawn from the picture's edges, trim and bleed boxes. **Type stays
  text:** its font (only the letters used) goes into the file, so a PDF
  editor finds, copies and edits it later -- Arabic too; outlines when
  asked. The web preset keeps the text and makes the pictures small.
- **Arabic justification by the scribes' rules:** a typed tatweel first,
  then after Seen and Sad (سـ صـ), before a final Heh, Teh Marbuta or Dal,
  after Jeem, Hah, Khah (جـ), after Tah, before a final Alef, Lam, Kaf...;
  never before the "teeth" letters in the middle of a word. The tashkeel
  stays over its letter while the join is drawn out.
- **Text in columns, and flowing on:** a paragraph box in up to 12
  columns with a gutter (Paragraph panel); Type > Flow Into a New Box makes
  a box that shows what does not fit the first (and on, box after box);
  "Overset" says when text is left out.
- **A new splash** with a 3.1 progress bar; **Help > Report a Problem:** a
  fault of the program (a panel that fails, a slip in a frame) no longer
  closes it -- the panel says so, the work stays, and what happened is
  kept for a report (shown at the next start if the program stopped).
- The Channels panel shows Photoshop's keys (Ctrl+2 for all, Ctrl+3, 4,
  5 for each); icons drawn in the theme's text color everywhere (dark
  and OLED themes).

**Toolkit**

- `retroui/photohdr`: 32-bit light (`Layer.hdr`), `toHdr`, `setExposure`,
  `toneMap`, `flattenedHdr`, `readHdr`/`writeHdr` (Radiance RGBE, run
  length), `readPfm`/`writePfm`; `encodeBmp32`, `decodeBmp` keeps alpha;
  `ExportFormat` `efHdr`, `efPfm`; `ExportOptions.bmpBits`.
- `pdf`: TrueType fonts embedded as Type 0 / CIDFontType2 with ToUnicode
  (`glyphText`, `textRender`, `canEmbed`), `subsetTtf`; `outputIntent`,
  `pdfx`. `photopdf`: `liveText`, `regMarks`, `colorBars`, `pageInfo`,
  `standard`, `condition`, `profile`.
- `textengine`: kashida ranking by the scribes' rules, marks kept with
  their letter; `TextData.columns`, `gutter`, `clipOverflow`,
  `TextLayout.overflow`, `remainder`. `photo`: `Layer.flowFrom`,
  `effectiveText`, `flowsOn`.
- `core`: `guarded`, `noteFault`, `takeFaults`, `layoutMark` /
  `layoutRestore`, `ui.lastFault`; faults written to the app's data folder
  (`errorMessageWriter`); the dock guards each panel. `gfx`: `drawMark` /
  `drawRestore`. `desktop`: `splashBox`.

## 0.12.0

**Retro Photo 4.2**

- **The Filter Gallery** (Filter > Filter Gallery): Artistic -- Colored
  Pencil, Cutout, Dry Brush, Film Grain, Paint Daubs, Plastic Wrap, Poster
  Edges, Sponge, Watercolor; Brush Strokes -- Accented Edges, Angled
  Strokes, Crosshatch, Ink Outlines, Spatter, Sumi-e; Sketch (in the
  foreground and background colors) -- Bas Relief, Charcoal, Chrome,
  Graphic Pen, Halftone Pattern, Photocopy, Reticulation, Stamp, Torn
  Edges; Texture -- Craquelure, Grain (ten kinds), Mosaic Tiles, Patchwork,
  Stained Glass, Texturizer (canvas, brick, burlap, sandstone). Each with
  its settings and the preview on the image.
- **More of the Filter menu:** Stylize > Oil Paint, Render > Fibers and
  Lighting Effects (spot, point, infinite; a texture's relief), Distort >
  Displace, Sharpen > Smart Sharpen.
- **109 custom shapes in 12 sets** (Shapes, Arrows, Banners & Awards,
  Frames, Nature, Animals, Objects, Symbols, Talk Bubbles, Music,
  Ornaments, Web); the Shapes panel shows a set at a time. **Live Shape**
  in Properties: the shape's W and H, a rectangle's corner radius, Flip
  Horizontal and Vertical, Rotate 90°.
- **New tools:** the Slice and Slice Select tools (with the Crop tool, C:
  boxes over the image, numbered; Slices From Guides; File > Export >
  Slices to Files saves each as a PNG), the Note tool (notes pinned on
  the image) and the Count tool (numbers on what is clicked, Alt+click to
  take one away), with the Eyedropper (I).
- **The toolbar docked down the left edge**, its header the docked panels'
  thin blue strip, its arrows (◂◂ ▸▸) one column or two. The workspace
  fills the window edge to edge: no margin of white round it, the
  pictures' tabs right under the options bar.
- **One look for every tab:** the documents' tabs, the docked panels',
  the palettes' and the dialogs' are drawn by the same code -- the same
  height, gray and labels. The Win 3.1 look stays: the white menu bar,
  the white windows.

**Toolkit**

- `retroui/photoartistic`: the 36 filters above, built on Kuwahara filters
  made of box sums, Voronoi cells and value noise, on all the cores.
- `photoshapes`: `CustomShape.category`, `ShapeCategories`, the shapes
  built from polygons, stars, circles and bands (`CustomShapes` is a seq).
- `dock.panelHeader`, `panelHeaderH`, `HeaderSide`: the docked column's
  header for any toolbar; `widgets.paletteTabFace`, `paletteTabH`: one
  palette tab look (dock, `tabStrip`, `beginTabs`, `paletteTabs`);
  `beginMdi(edgeToEdge = true)`; `core.barsBottom`.
- Pixel icons: Slice, Note, Count.

## 0.11.0

**Retro Photo 4.1**

- **Documents as tabs, filling the workspace:** pictures open as tabs in
  all the room between the toolbar and the panels, top to bottom, as
  Photoshop's. Windows of their own (MDI, as in 1994: Cascade, Tile) are an
  option: Window > Arrange > Floating Windows (MDI), or Preferences >
  Workspace; Tabbed Documents brings the tabs back.
- **A status bar under each picture**, as today's Photoshop: its zoom
  (typed in it), then what its menu shows (sizes, profile, dimensions,
  the tool, timing).
- **Type:** right-to-left and left-to-right buttons in the options bar and
  the Paragraph panel; **Arabic kashida** (Paragraph > Insert Kashida:
  None, Short, Medium, Long, Stylistic) lengthens justified Arabic lines at
  the places a scribe would, one a word.
- **New tools:** the Magnetic Lasso (sides that cling to edges as you go,
  its Width, Contrast and Frequency), the Triangle shape, the Frame tool
  (K: a box or an ellipse that a picture fills).
- **The selection tools as Photoshop's:** a drag inside the selection
  moves its outline, not the pixels (Ctrl+drag moves the pixels); a click
  inside deselects (the Magic Wand: selects again); the arrow keys move the
  outline; Shift held after the drag began makes a square or a circle, Alt
  draws from the middle; the Polygonal Lasso's sides at 45 degrees with
  Shift; the Magic Wand's Contiguous.
- **More of Photoshop's ways:** the Gradient at 45 degrees with Shift; the
  Paint Bucket's Contiguous and All Layers; the Zoom tool zooms to a box
  dragged; the number keys set the layer's opacity with the tools that do
  not paint, and two typed quickly set that value (4, 5: 45 %); a click
  (no drag) with a shape tool asks its size (Create Rectangle, Ellipse,
  Polygon...: width, height, From Center); the Move tool's Shift+click
  picks another layer to move with the first, Ctrl+click picks with
  Auto-Select off; Alt swaps Dodge and Burn.
- **A new About box:** a banner with the icon, the version, pages for
  What's New and Credits, Copy Info (the version, system and screen, for a
  report).
- **One gray everywhere:** the workspace, the toolbar, the options bar and
  the panels in the same face color, tabs as the docked panels' in every
  dialog; the dock's header in the title bar's blue.
- **Panels docked as today's Photoshop has them** (the toolkit's new
  `retroui/dock`): down the right, Color / Swatches / Gradients / Patterns,
  Properties / Adjustments / Libraries and Layers / Channels / Paths open,
  the rest as a strip of icons beside them (a click shows that panel
  beside the strip). Drag the bars between groups to share the height,
  double-click a group's tabs to fold it, the arrows at the top of a
  column collapse it to icons, its left edge sizes it. A panel dragged by
  its tab goes into another group, between groups (a group of its own),
  to the left of the dock (a column of its own) or out over the documents
  (a floating palette, dragged back by its title bar). Each panel's menu
  has Close and Close Tab Group; Window shows a closed panel where it was.
  The workspace (Window > Workspace) keeps it all.
- **The Layers panel as Photoshop's:** a filter (by kind -- pixels,
  adjustments, type, shapes, Smart Objects -- or by name, with its on/off
  switch), the blend mode and Opacity, the four locks (transparent pixels,
  image pixels, position, all) and Fill, and at the bottom Link, Style,
  Mask, Adjustment, Group, New, Delete. Linked layers (and layers picked
  together) move together; a layer whose position is locked does not
  move, one whose pixels are locked is not painted.
- **Adjustment Presets** in the Adjustments panel: 36 looks in six kinds
  (Portraits, Landscapes, Photography, Creative, Black & White,
  Cinematic), each shown on your image; a click puts its adjustment
  layers on in a group. Your own: pick adjustment layers, then the
  panel's menu > Save Adjustment Preset (My Presets); Import and Export
  (.radj); Batch: Apply a Preset to Files.
- **New adjustment layers: Clarity, Dehaze, Grain** (Layer > New
  Adjustment Layer, the Adjustments panel; set in Properties). Clarity and
  Grain look at the pixels around each, so the composite does them
  between the layers under and over them.
- **Layer > Layer Cleanup:** empty layers and groups (and, when asked,
  hidden ones) thrown away; layers still called "Layer 3" named after what
  they hold ("Blue Shape", the words of a type layer, "Gradient Fill").
- **Layer > Harmonize:** a placed object's colors and light made to fit
  the picture, and a shadow cast away from where the light comes from
  (with a darker touch where it stands), on a layer under it.
- **Colorize** (Filter > Neural Filters): click the picture to put colors
  on it; each runs out along what is alike and stops at edges, the
  picture's light kept.
- **Content-Aware Expand:** drag the Crop tool's handles past the image;
  with Fill: Content-Aware the new room is made up from what is near it.
- **The Artboard tool** (with the Move tool, V): drag a box for an
  artboard, drag one by its name to move it with all on it, sizes (A4,
  Phone, Square, HD) in the options bar; File > Export > Artboards to
  Files saves each as a PNG.
- **Dynamic Text** (Paragraph panel): text in a box drawn as big as fills
  the box -- size the box, the text follows.
- **The color picker on the canvas:** Alt+Shift + the right button on the
  image with a painting tool (a long press on a tablet): a square of
  shades and a strip of hues where you press; move to pick.
- **The healing tools as Photoshop's:** the Spot Healing Brush's Type
  (Content-Aware, Create Texture, Proximity Match); the Patch's Source /
  Destination, Transparent and Content-Aware (Structure, Color).
- **Quick Actions** in Properties for what is picked: Remove Background,
  Select Subject, Auto Tone and Color on a picture; Warp, Rasterize on
  type; Select and Mask, Content-Aware Fill, Layer via Copy on a
  selection.
- **A faster engine** (a 12-megapixel image, 8 layers, 2 cores; `tools/benchphoto.nim`):

  | | before | now |
  |---|---:|---:|
  | composite, the whole image | 619 ms | 257 ms |
  | composite, a 400 x 400 part | 9.1 ms | 5.0 ms |
  | brush stroke + composite | 333 ms | 186 ms |
  | Gaussian Blur 10 px | 240 ms | 192 ms |
  | Add Noise | 836 ms | 77 ms |
  | layer style made again | 827 ms | 389 ms |
  | save .rpd | 3470 ms | 1890 ms |
  | open .rpd | 2060 ms | 1070 ms |
  | flattened copy | 631 ms | 282 ms |

  The blend modes that mix each channel alone use a table, and over opaque
  pixels skip the divisions (to the same pixel); Curves, Levels and the
  other adjustments of each channel alone use a table by channel instead of
  the 3-D one; layer styles blur and measure distances along rows (kind to
  the cache) on all the cores; Add Noise is drawn from a table on all the
  cores; .rpd files are packed at the quick level (a little bigger) and
  their layers unpacked at once on all the cores; the resampler's loops are
  laid out for each number of taps.
- **Fixed:** fonts got from Google Fonts were listed but drawn in DejaVu
  Sans: they are now taken from Google's font repository (whole TTFs, the
  plain styles before the variable ones), each file checked before it is
  installed (WOFF/WOFF2, CFF-only and broken files refused; an Arabic family
  must have Arabic letters), and a font that cannot be read says why in the
  Character palette ("Drawn in DejaVu Sans: ...").

**Toolkit**

- `retroui/dock`: docked panels (groups of tabs, columns collapsed to icons,
  fly-outs, floating palettes, drag and drop of panels, kept as JSON).
- `retroui/photocc`: Layer Cleanup, Harmonize with a shadow, Colorize from
  color hints, Content-Aware Expand, artboards; `photosmart`: Spot Healing
  types, the Patch's options; `photodevelop`: Dehaze; the composite:
  Clarity and Grain layers; `textengine`: Dynamic Text (`fit`,
  `fitScale`); `photowidgets`: the on-canvas color picker
  (`hudPickerRects`, `drawHudPicker`, `hudPick`); `canvasSizeAt`.
- `retroui/photopresets`: Adjustment Presets -- 36 built in, put on an image
  as adjustment layers, their look on pixels, files, batches.
- `aboutBox`: a banner (the icon from a PNG or a glyph, name, version,
  tagline, a rainbow), pages of What's New and Credits, Copy Info
  (`aboutInfo`, `systemName`). MDI windows and dialogs default to the
  face gray; `beginTabs` in the palette look fills its page.
- `photo`: `moveSelection`, `shiftedMask` (the outline moved, the pixels
  stay); `photopaint.bucketFill`: `contiguous`, `allLayers`;
  `photowidgets`: `zoomToRect`, a status strip under the view
  (`statusW`, `statusRect`); `textengine`: kashida (`ParaStyle.kashida`),
  `magneticPath` (live-wire edges) in `photocc`.
- The photo engine: Lock Image Pixels, Lock Position and linked layers
  (`lockPixels`, `lockPosition`, `link`, `linkLayers`, `movedLayers`);
  the layer rows show links; MDI palettes can be `bare` (no title or
  frame).

## 0.10.0

**Retro Photo 4.0: the tools as Photoshop has them today**

- **New tools:** the Perspective Crop (four corners dragged onto the
  slanted thing, made straight), the Background Eraser (samples the color
  under its middle, erases it -- Once / Continuous, Contiguous / Discontiguous,
  Protect Foreground; the Background becomes a layer), the Color Replacement
  tool, the Freeform and Curvature pens, the Star and Spiral shapes. The
  Crop tool works as today's: handles pressed and dragged, Enter or the task
  bar commits.
- **The Move tool comes first, picking what you click** (Auto-Select on): the
  thing on the page under the click -- type, a shape, a placed picture, as
  far as its mask shows it, within a few pixels of a thin line (a finger's
  width on a touch screen) -- before a layer as big as the page, and the
  page before a texture laid over all (grain, light); not hidden layers or
  groups. The Layers palette scrolls to the layer picked; the click that
  picks a layer moves it (it does not grab its handles).
- **Smarter selections:** Select Subject and Remove Background know skin
  and go over the subject's edge a second time, finer.
- **Illustrator's path tools** (Layer > Path Operations): Merge Shape
  Components, Offset Path, Outline Stroke, Simplify, Reverse Path Direction,
  Join -- outlines fitted with curves, holes kept as holes.
- **Neural Filters** (Filter > Neural Filters): JPEG Artifacts Removal,
  Photo Restoration, Depth Blur, Color Transfer, Harmonization, Super Zoom,
  in a workspace of their own, output to a new layer or the current one.
- **Save Adobe PDF** with Photoshop's presets -- for the web, for print, for
  a press -- up to 3500 pixels an inch, CMYK, crop marks and bleed, type
  and shapes as outlines (they stay sharp at any size); **File > Automate >
  PDF Presentation** puts several documents in one PDF.
- **Opens PDF and Illustrator (.ai) files**: a page as pixels, or its
  drawing as shape layers (the Import PDF dialog: page, resolution); opens
  and saves **PostScript and EPS** (its picture or its preview).
- **Arabic on the canvas:** the alignment buttons go the way Arabic reads,
  justified Arabic is lengthened at its joins (kashida) before its spaces,
  Arabic-Indic and Persian digits, the arrow keys move the way the text
  runs.
- **Type > Get Google Fonts...** (and "+ Google Fonts" in the Character
  palette): search the catalog, a family downloaded into the app's folder,
  ready at once.
- **Layer Comps** keep positions too and are saved in the document; the
  **Libraries** panel keeps colors, styles and graphics between documents.
- Filters preview **on the canvas** as they are set (Preview).
- **The Open dialog shows the file** (pictures, Retro Photo and Photoshop
  documents, PDFs) and a picture of it while it opens.
- Documents in **windows** again by default (Preferences > Workspace:
  tabs); a new **icon**; Exit and the close box **ask before leaving
  unsaved work**; the open documents **come back** at the next start
  (Preferences: Reopen Documents).
- Retro Photo's documents are **.rpd** (no version in the name; .rp3 files
  still open), with a picture inside for the file lists.
- `examples/magazine.nim`: a three-page magazine made with the engine, tool
  by tool, saved as .rpd and exported as a PDF presentation.
- **Starts eight times faster:** the window is up in under a tenth of a
  second (it took 0.6 s: the printing inks' table, for the Info palette's
  CMYK, is made only when first needed, and then on all the cores).

**Retro Files 2.1**

- **The Columns view** (as Finder and DeskFiles have it): each folder of
  the way a column with its count, a sort button and "so many folders · so
  many files" under it; the picked file's preview in a column of its own.
  Left and Right go up and into folders, Up and Down along a column, typing
  goes to a name; a folder picked with the keys shows what is in it. Details
  / Icons / Columns buttons beside the address.
  More columns than fit scroll sideways, with a scroll bar under them (the
  newest kept in view; Shift + the wheel or a finger too) while the preview
  stays put at the right; a folder just opened has nothing picked yet, as
  in Finder.
- **Viewers for PDF** (the pages one under another, drawn on worker threads
  at the size shown; page box, zoom, as wide as the window), **video** (in
  the window on Linux and Android) and **sound** (a player with the folder's
  sounds as a play list, played on in order); a **slide show** in the
  picture viewer.
- **Pictures of PDFs and videos** in the lists and the preview (the first
  page; a frame of the video, a little way in when it starts black, with a
  play mark).
- **Rename several at once** by a pattern ("Holiday ###", find and replace,
  the letters' case) with the new names shown first; **Edit > Select
  Matching** (Ctrl+Shift+A: *.jpg *.png); **File > Duplicate** (Ctrl+D);
  **Tools > Open Terminal Here** (Ctrl+Alt+T); Rename and Refresh buttons.
- Faster: the column view makes only the rows in view (a folder of 5000
  files scrolls in under a millisecond a frame); the window is up in 25 ms
  (GStreamer is started by the first video picture, on a worker thread).

**Toolkit**

- `fileColumns` and `fvColumns`; `batchNames`, `renameAll` (names that swap
  places too), `selectMatching`, `globMatch`; `FileListEvent.preview`.
- **`retroui/pdfview`**: `openPdfView`, `pdfView` (pages drawn on workers at
  the size shown, zoom, page in view), `pdfPage`, `pdfPreview`,
  `addPdfPreviews`. `pageAsync` and `addPageReader` draw pages of documents
  on the worker threads.
- `audioView` (a sound file's player; `videoView(audio = true)`),
  `videoFrame` and `addVideoPreviews`; Android: `media.frame`.
- `openTerminal`, `canOpenTerminal`.
- `nimble photoapk` / `nimble apk`: 4.0 / 11 and 2.1 / 21; `nimble magazine`
  makes the sample magazine.
- `addPictureReader` teaches every picture list, preview and Open dialog a
  kind of file; `windowIcon` (the taskbar's picture), `busyPicture`,
  `filePicker(preview = true)`.
- New modules: `photopdf`, `pdfread` (a PDF reader: xref streams, object
  streams, damaged files, TrueType / CFF / Type 1 / Type 3 fonts, shadings,
  functions), `photoimport`, `photoneural`, `photovector`, `fetch`,
  `googlefonts`.
- Fonts named in a PDF but not in it (the standard 14) are drawn at
  Adobe's widths: the words fill their lines as they should.
- Tooltips sit above the pointer on tablets and phones (Android's mouse
  pointer, big, hid them under it); under its arrow on desktops, as before.
- **Fixes:** a data race when the screen was drawn on several threads with
  big pixel icons (it could crash a window full of file icons); PDF pages
  drawn on several threads at once shared objects (fresh ones each now);
  GStreamer no longer ends the program on a machine without sound (it
  plays silent).

## 0.9.0

**Retro Photo 3.9: today's Photoshop, for its tutorials** (drawn as 1994 drew)

- The menus as Photoshop CC has them -- File, Edit, Image, Layer, Type,
  Select, Filter, Plugins, View, Window, Help -- so a tutorial's paths work as
  written: Image > Adjustments > Curves, Image > Mode, Image > Image Rotation,
  Edit > Free Transform and Edit > Transform (Again, Rotate 180° / 90°, Flip),
  Layer > New, Layer > Layer Mask (Delete, Apply, Disable), Layer > Rasterize,
  Select > Modify, Select > All Layers, Filter > Camera Raw Filter, Filter >
  Convert for Smart Filters, View > Show, View > Screen Mode, Window's panels
  A to Z. The Retro Photo 1994 key set keeps Photoshop 3's menus.
- **Edit > Search** (Ctrl+F): any command, panel or tool by a few letters,
  with where it is in the menus and its keys; Enter does it.
- Today's keys: Ctrl+T Free Transform, Ctrl+Shift+T Transform Again,
  Ctrl+Alt+Z Toggle Last State, Ctrl+Alt+F Last Filter, Ctrl+, Hide Layers,
  Ctrl+Alt+A All Layers, Ctrl+Alt+P Close Others, F12 Revert, F6 Color.
- **Free Transform as since 2019:** a corner keeps the proportions (Shift
  frees them; shapes the other way round), Ctrl moves a corner alone,
  Ctrl+Alt+Shift in perspective, Ctrl+Shift on a side skews. Preferences >
  Tools > Use Legacy Free Transform brings back the old Shift.
- **New panels:** Adjustments (with Properties), Histogram (with the
  Navigator and History; kept up as the image changes, from a sample of a
  million pixels), Gradients and Patterns (with Color and Swatches; eight
  patterns made in the program, those defined and loaded), Styles (fifteen
  layer styles: shadows, bevels, glows, gold, chrome, neon, glass, a 1994
  button; Shift adds; New Style keeps the layer's), Shapes, Tool Presets,
  Layer Comps (visibility and appearance kept by name), Clone Source (five
  sources), Glyphs (with Character and Paragraph; recently used first).
- **The Contextual Task Bar** under the image: the next steps for what is
  there (Select Subject, Remove Background, Select and Mask, Feather,
  Invert, Mask, Fill, Deselect, Warp Text, Commit / Cancel a transform or a
  crop). Window > Contextual Task Bar or Preferences hides it.
- **New tools:** the Ruler (A, L, W, H in the options bar; Straighten Layer
  levels the photo), the Color Sampler (four points an image, their colors
  in the options bar), the Magic Eraser (a color made transparent; the
  Background becomes a layer, as Photoshop does).
- Palette tabs that do not fit share the width, their names shortened
  (the full name as a tooltip).

**Retro Files 2.0: Windows 98 Explorer**

- The Standard Buttons with text labels under the icons (View > Toolbars >
  Text Labels: under, beside, none, text only): Back, Forward, Up, Cut,
  Copy, Paste, Undo, Delete, Properties, Views, New Folder, Folders, Two
  Panes, Preview, Search, Options.
- **View as Web Page:** at the left of the files, the folder's name large
  over a rule in the title color, and the selection described (its kind,
  size, date, a picture's preview, a total for several).
- Explorer 98's menus: File > New (Folder, Text Document), View > Toolbars,
  Status Bar, Explorer Bar (Folders, Preview), As Web Page, Arrange Icons,
  Folder Options; Tools > Find > Files or Folders (F3), Go to Folder
  (Ctrl+G). The Address label (Alt+D), the zone (the place the folder is
  in) in the status bar, Properties of the folder when nothing is selected.
- The **Small icons** view; Ctrl+wheel still steps through the icon sizes.
- Keys: F3 finds (as Explorer; Alt+P the preview pane), Ctrl+G, Ctrl+A.
- **Termux from the side panel:** picking Termux (or another app's folder)
  in the folder tree or the drive bar did nothing; it opens now (and asks
  for access the first time).

**Toolkit**

- **Buttons with a picture and a label, four looks:** `ButtonLook`
  (`blIconOnly`, `blTextOnly`, `blTextBelow`, `blTextBeside`); `button(label,
  pic, look)`, `barButton` for tool bars (the bar's look: `setToolbarLook`,
  a taller bar for text below), `buttonAt` placed by hand; a picture is an
  `Icon` or a glyph of the icon font (`glyphPic`); `labeledSize`,
  `drawLabeled` for your own. Tool buttons fill a taller bar.
- **`retroui/morecontrols`:** `rangeSlider` (two thumbs; drag the band to move
  both), `menuButton`, `splitButton`, `tagInput` (chips with ×; Enter or a
  comma adds, Backspace takes the last off), `autocomplete` (a text box
  whose matches drop under it), `knob`, `led`, `accordionHeader`,
  `timeline`, `pill`. In the gallery's More page.
- `fvSmallIcons` for `fileList`; `iconView(oneLine = true)`.
- **Less memory:** where there is no graphics device (no /dev/dri: a
  server, a container, a VM without one), automatic drawing no longer
  starts OpenGL only to find a software renderer: an app takes some 15 MB
  instead of 88 MB. `$RETRO_GPU` now wins over the drawing kept in the
  settings. `nimble apps` strips the binaries (about 14 % smaller).
- `paletteTabs` fit any number of tabs.
- Shortcuts can use the comma and the period ("Ctrl+,").
- `retrokit doctor` knows the NDK is fetched by itself and the signing is
  built in.
- `retroapk`: the compiled pieces go to the user's cache folder
  (`~/.cache/retro/apk`), not beside the source; `--clean` removes them
  after, `--work:DIR` puts them elsewhere.
- `nimble photoapk` / `nimble apk` give the version and its code (3.9 / 10,
  2.0 / 20).

**The repository**

- Every module has a header and every exported routine a doc comment.
- `.github/workflows/ci.yml`: the tests and the fuzzers on Linux, every
  example built on Linux, Windows and macOS, the APKs built and kept.
- `CONTRIBUTING.md`; `.gitignore` keeps out builds, compiled examples and
  tests, and the generated `docs/api`.

## 0.8.1

- **A font from a file:** `setUiFontFile` / `loadUiFontFile` (a .ttf of the
  user's, its bold found beside it) make it every app's font (`ufFile`);
  `appearanceSettings` has "A Font File..." and `storeAppearance` keeps it.
  A pixel font (a bitmap font made outlines, as the Windows 3.1 and 98 ones
  people convert) is found to be one and drawn at whole multiples of its
  pixels, crisp at 100 %, 2x and in between (`pixelGrid`).
- **Kawkab Mono**, the new default font of every app: monospaced Arabic
  and Latin (Abdullah Arif's, with Source Code Pro's Latin; SIL OFL 1.1),
  regular and bold. A light hinter fits its stems to whole pixels and its
  size is set so each letter is a whole number of screen pixels wide, at
  100 %, 2x and in-between scales, so it is crisp everywhere and lines up
  in columns. `ufKawkab`; Retro Sans (`ufRetro`) and DejaVu Sans
  (`ufSmooth`) are still there, in `appearanceSettings` too.
- The panes of `split` (and `sidePane`) scroll when what they hold is
  taller than they are: their own scroll bar, the wheel, a finger, Tab.
- What split panes, scroll panels and MDI windows hold never makes the
  window scroll sideways (`beginClipped` / `endClipped` for your own).
- Grid cells, headers and totals too long for their column end in "...".
- Progress cells of a grid write their figure in two colors, as a 3.1
  gauge does, so it reads over the bar and beside it.
- `iconColumn` takes pixel icons by name ("Sheet", "pxSheet"), as its
  documentation said.
- `factList`: a label too long for its column puts the value under it
  instead of over it.
- `branch` with an icon of its own and an id did not compile when its
  arguments were expressions.
- `panel`: a framed white area with padding that scrolls when what it
  holds is taller (the content area of a business app).
- **Excel files:** `retroui/xlsx` reads .xlsx workbooks (shared strings,
  numbers, dates from their styles, both date systems) and writes plain
  ones (`readXlsx`, `writeXlsx`).
- **Sealed files:** `retroui/vault` seals data with a password or PIN
  (Monocypher, vendored: Argon2id and XChaCha20-Poly1305): `newVaultKey`,
  `seal`, `unseal`, `isSealed`, `vaultKeyFor`, `wipe`.
- `retroui/templates`: `#[tags]#` filled from a table (`fillTags`, with
  filters: `|words`, `|words-ar`, `|long`, `|long-ar`, `|n3`,
  `|ar-digits`, `|upper`...), blanks to ask (`#[?Purpose]#`), and amounts
  in words in English and Arabic (`amountWords`, `numberWords`,
  `arabicNumberWords`; Omani rials and baisa by default).
- Reports: `setBackground` puts a picture (a letterhead) behind every page.
- `editArea` wraps long lines at the words (`wrap = false` for the old
  sideways scrolling); Up, Down, Home and End go by the lines as shown.
  `editAt` takes `wrap` too.
- `focusFirstText()`: the next text box drawn takes the focus (a dialog
  that asks for a PIN can be typed into at once).
- A wrapped paragraph keeps its direction on every line: an English line
  that starts with an Arabic word is still laid out from the left (and
  the other way round). The marks U+200F and U+061C count as right to
  left.
- Charts write every category label when each has some room (shortened
  with "..." when long) instead of every other one.
- Touch: a tap that opens a row of a list (`tapActivates`) leaves nothing
  selected, so the next tap opens again instead of adding to a
  selection; `filePicker` forgets what was selected the last time it was
  open, and starts on the file it was given.
- **Image editing:** `retroui/photo` (documents of layers with 16 blend
  modes, a soft selection, alpha channels, Quick Mask, paths, tile-based
  undo of pixels, selections and paths, transforms by four corners
  (`warpedPixels`: scale, skew, perspective, distort, rotate), Apply Image
  and Calculations, .rp3 / PNG / JPEG / BMP files, size limits
  `sizeOk`), `retroui/photopaint` (brushes, the painting tools with Erase to
  Saved and the stamp From Snapshot / From Saved, bucket, gradients, lines
  with arrowheads, type, paths filled, stroked and edited point by
  point), `retroui/photofx` (over 45 filters with Shear and Extrude, Levels,
  Curves, Color Balance, Hue/Saturation by color range, Selective Color,
  Variations, Color Range, previews; a quick median for any radius) and
  `retroui/photowidgets` (the document view with zoom, rulers, marching ants
  and a Quick Mask of any color; the color picker, the curves, levels and
  shear editors, brush, swatch and layer rows). `examples/photo.nim` is
  Retro Photo 3, an image editor of 1994 made with them.
- **Warps:** `retroui/photowarp` -- Liquify on a mesh (`LiquifyMesh`:
  `push` for the Forward Warp, `reconstruct`, `twirl`, `pucker` / bloat,
  `reconstructAll`; `liquifyImg` of the whole, a part or a preview), Lens
  Correction (`LensCorrection`: distortion, red/cyan and blue/yellow
  fringes, vignette, vertical and horizontal perspective, angle, scale,
  the edges transparent, extended or of a color; `lensImg`) and
  Straighten (`straighten`: turned and cut to the biggest upright
  rectangle it fills, `innerRect`). Retro Photo has Filter > Liquify...,
  Filter > Lens Correction... and the crop tool's Straighten.
- **Styled type:** `retroui/textengine` sets text as an image editor does:
  any TrueType font of the system (`systemFontDirs`, `addFontDir`,
  `scanFonts`, `fontFamilies`, `fontStyles`, `fontFace` with faux bold
  and italic for the styles a family lacks) or the built-in ones; per
  character (`CharStyle`) the font, size, color, tracking, kerning on or
  off, leading, baseline shift, horizontal and vertical scale, faux bold
  and italic, all caps, small caps, superscript, subscript, underline,
  strikethrough; per paragraph (`ParaStyle`) the alignment (left, center,
  right, four justifications), indents, space before and after, the
  direction; point text or text in a box (wrapped at the words);
  right-to-left and joined Arabic; warps (`TextWarp`: Arc, Arc Lower and
  Upper, Arch, Bulge, Shell, Flag, Wave, Fish, Rise, Fisheye, Inflate,
  Squeeze, Twist, horizontal or vertical, with distortions) and text along
  a path. `layoutText` (the caret, `charAt`, `lineMove`, `wordLeft`...),
  `renderText` / `renderTextInto`, the caret and clicks on warped text
  (`caretLine`, `charAtDrawn`, `placePoint`), editing by spans
  (`insertText`, `deleteText`, `restyle`, `styleAt`), `scaled`, `moved`,
  JSON (`toJson`, `textFrom`). `ttf` reads a font's names, weight and
  slant (`family`, `style`, `weight`, `italic`, `faceInfo` without loading
  it), .ttc collections (`fontCount`, `parseFace(data, index)`), the
  underline's place and the outlines (`contours`).
- `retroui/textwidgets`: `fontCombo` (each family shown in its own letters),
  `fontStyleCombo`, `fontSample`. `combo` takes `preview` to draw its
  items (`ItemPreview`). Fills and polygons of a see-through color are
  drawn see-through (a selection's highlight over a picture).
- **Type layers and layer styles** (`retroui/photo`): `Layer.text` (a type
  layer: `isText`, `addTextLayer`, `setText`, `drawText`,
  `rasterizeText`, `rasterizeAllText`), kept editable through undo
  (`touchLayers`), Image Size (set again, sharp), Crop and Canvas Size,
  duplicated, merged and saved in .rp3. Layer styles (`Layer.fx`,
  `LayerFx`, `Effect`, Fill Opacity `fill`): Drop Shadow, Outer Glow,
  Gradient and Color Overlay, Satin, Inner Glow, Inner Shadow, Stroke
  (outside, inside, centered), Bevel and Emboss (inner, outer, emboss,
  pillow) -- made by `retroui/photostyles` (`defaultEffect`,
  `renderFx`, distance fields and blurs on all the cores), kept until the
  layer or the style changes, merged down, scaled by Image Size, saved.
  `layerRows`: a "T" for type layers (`thumbGlyph`) and an "fx" mark
  (`fx`, `fxOff`, `fxClicked`). Pixel icons for the alignments, the
  character switches, Warp Text, type on a path, layer styles, the
  Character and Paragraph palettes.
- Retro Photo: the Type tool of today -- type on the image (a click: a
  line; a box dragged: a paragraph; a click on the work path: along it),
  with the caret, selections, the keys and the clipboard; the Character
  and Paragraph palettes, Warp Text, Layer > Layer Style (every effect,
  copy, paste, hide), Layer > Type, Rasterize, and a new Layer menu. Text
  is still text after a move, an undo, an Image Size; painting or a filter
  on it asks to rasterize it first.
- `pictureBox` (photowidgets): a framed box with a picture fitted in it,
  where the mouse goes (`toPicture`) and whether it is dragged.
- **Layer masks and adjustment layers** (`retroui/photo`): a layer's
  `mask` (gray: white shows, black hides; `maskOff`), painted on when
  `editMask` is on (`layer` gives it; `current` the layer itself);
  `addLayerMask` (Reveal All, Hide All, Reveal / Hide Selection),
  `removeLayerMask` (thrown away or applied). Adjustment layers
  (`newAdjustmentLayer`, `setAdjustment`, `Adjustment`) change what is
  under them where their own pixels -- their mask -- let: Levels, Curves,
  Brightness/Contrast, Color Balance, Hue/Saturation, Selective Color,
  Vibrance, Exposure, Photo Filter, Black & White, Channel Mixer,
  Threshold, Posterize, Invert (`adjustmentFn` in `retroui/photodevelop`;
  composited through a 33^3 color table). Masks follow Image Size, Canvas
  Size, Crop, Flip, Rotate and Content-Aware Scale (`pixelLayers`), merge
  down with their layer and are kept in .rp3 files. Painting on any mask
  is gray (`Layer.gray`).
- 13 more blend modes: Color Burn, Linear Burn, Darker Color, Color Dodge,
  Linear Dodge (Add), Lighter Color, Vivid Light, Linear Light, Pin Light,
  Hard Mix, Exclusion, Subtract, Divide (`LayerModes` and `PaintModes`
  in their families).
- `touchLayers`: adding, removing, moving layers, masks and adjustment
  layers, and changing their settings, is undone without copying the image.
- `layerRows` shows a layer's mask beside its thumbnail (framed when it is
  painted on, crossed out when off) and an icon (`LayerRow.maskThumb`,
  `maskActive`, `maskOff`, `icon`; `LayerRowsEvent.maskClicked`,
  `thumbClicked`). Pixel icons for adjustment layers and layer masks.
- **Smart tools, on the device:** `retroui/photosmart` -- Content-Aware
  Fill (PatchMatch from a small copy up, lines that meet the hole carried
  into it, its colors made to meet the surroundings), healing (`heal`:
  another place's texture with the light and color of where it goes), the
  Spot Healing Brush, the Healing Brush and the Patch (`spotHeal`,
  `healStroke`, `patch`), red eye, Select Subject (what stands out from
  the picture's edges, in focus, near the middle, refined by GrabCut and
  a guided filter) and Select Sky, Content-Aware Scale (seams of least
  detail on a small copy, the subject and skin spared) and enlarging with
  Preserve Details (`enlarge`; Lanczos resampling, `rsLanczos`, in
  `retroui/photo`). Also a minimum cut of a graph (`CutGraph`, `maxflow`,
  Boykov-Kolmogorov). Retro Photo has them as tools (J), in Edit (Content-
  Aware Fill, Content-Aware Scale...), Select (Subject, Sky) and Image Size.
- `photopaint`: a stroke tells its document, layer, coverage and stamp
  offset (`strokeDoc`, `strokeLayer`, `coverage`, `stampOffset`).
- **Develop:** `retroui/photodevelop` makes a photo's everyday corrections in
  one go, as camera raw programs do: white balance (temperature, tint),
  exposure, contrast, highlights, shadows, whites, blacks, clarity,
  dehaze, vibrance, saturation, noise reduction (of the light, edges
  kept; of the color), sharpening, vignette and grain (`Develop`,
  `developImg`, `develop`), with Auto (`autoDevelop`), presets
  (`developPresets`, `$` / `parseDevelop` to keep your own) and quick
  previews of the whole or of a part 1:1 (`smallCopy`, `developBase`).
  Highlights, shadows and clarity follow the light around each pixel
  (a guided filter: edges kept, no halos). Also Auto Tone, Auto Contrast,
  Auto Color, Shadows/Highlights, Vibrance, Exposure, Photo Filter (20
  filters), Black & White (with a tint), Channel Mixer, and Reduce Noise
  (`detailImg`). Retro Photo has them in Image > Adjust and
  Filter > Develop... (Ctrl+Shift+A).
- **All the cores:** `retroui/parallel` shares work out among the
  processor's cores (`parallelFor`, `parallelRows`, `parallelChunks`;
  `threadCount`, `setThreadCount`, $RETRO_THREADS). The image engine uses
  it everywhere: compositing, the filters and adjustments, resampling,
  rotating, the histogram, JPEG decoding, the view. A 24 megapixel photo
  opens, blurs and sharpens in about half a second on two cores.
- The image engine is quicker on one core too: the gaussian blur in whole
  numbers in strips (a big radius through a smaller copy), adjustments of
  a big picture through a 3D colour table, resampling with its weights
  worked out once, filters written back without copies (`writeBack` with
  a `base` for previews made again and again). `mipLevel` keeps smaller
  copies of the image up to date where it changed: a zoomed-out view is
  drawn smoothly from them.
- A JPEG encoder: `encodeJpeg(bitmap, quality)`.
- MDI palettes: an `MdiWindow` with `palette` floats over the documents
  with a thin title bar and is never the active document; `sizable`,
  `flush` (no padding: a canvas); `paletteTabs`, `paletteSize`,
  `mdiIsActive`, `mdiAreaRect`.
- 35 more pixel icons: the tools of an image editor (marquee, lasso,
  magic wand, airbrush, rubber stamp, smudge, dodge, burn, sponge, the pen
  and its arrow, add, delete and convert point) and the mask and screen
  modes.
- `focusFirstText(inDialog = true)`: the first text box of the dialog
  being opened takes the focus, not a box of a palette drawn before it.
- `autoFocus` (true): false keeps the first box of a palette from taking
  the keys when nothing has the focus (a canvas program); dialogs still
  focus their first control.
- An empty `label("")` no longer takes the whole row.
- Palettes scroll when what they hold is taller than they are (a short
  or touch screen); `mdiWindowSize` gives the size a document window needs
  for its content.
- `picturesDir()` (the phone's Pictures with the access to all files, the
  user's Pictures on a desktop) and `askStorage` / `storageDialog`: asks
  for Android's "All files access" once, with the reason, or goes on in
  the app's own folder.
- `filePicker`: several pickers in one program (Open, Save As, Place) no
  longer reset each other; saving puts the focus in the file name.
- **Photoshop documents:** `retroui/psd` reads .psd and .psb (8, 16 and 32
  bits; RGB, grayscale, CMYK, Lab, indexed, duotone, bitmap,
  multichannel; RLE and ZIP data, with or without prediction): the
  layers, groups (`lsct` with the group's own blend mode), masks (with
  the "real" mask beside a vector mask), vector masks (`vmsk`, `vsms`:
  the path records and their combinations), shape strokes (`vstk`), fill
  and adjustment layers, effects and other action descriptors (a reader
  and now a writer: `descriptorData`, `psdObj`, `psdRgb`...), the merged
  picture, the resolution and the light's angles. `writePsd` writes them
  back (RGB, grayscale or CMYK; .psb when big) with any extra blocks
  (`PsdLayer.extra`, `vectorMaskData`).
- `retroui/photofiles`: any picture in, any picture out. `openPicture`
  (Retro Photo, Photoshop, PNG, JPEG, BMP, GIF, TIFF, Targa), `docOfPsd`
  (groups that pass through give their opacity and masks to their
  layers, others are merged into one; shape layers stay shapes; clipping
  masks, layer styles, Levels, Curves, Hue/Saturation with its ranges,
  Color Balance, Brightness/Contrast, Exposure, Vibrance, Selective
  Color, Channel Mixer, Black & White, Invert, Threshold, Posterize;
  gradient fills with all their stops and the five styles), `psdOf` /
  `savePsd` (shapes as fill layers with vector masks, styles as
  Photoshop's effects, adjustments, clipping, masks), `exportPicture`
  with `ExportOptions` (JPEG quality and 4:2:0, PNG compression, PNG-8
  and GIF with a palette and dither, TIFF compression -- CMYK
  separations for a CMYK image --, Targa RLE, BMP, transparency or a
  matte, scaled). All 316 files of psd-tools' test set open.
- **Shape layers** (`retroui/photoshapes`): `rectPath` (rounded),
  `ellipsePath`, `polygonPath` (stars, smooth corners), `linePath` (with
  arrowheads), `svgPath` (SVG path data), 19 `CustomShapes`
  (`customPath`), `combine` with the path operations (`PathOp`: combine,
  subtract, intersect, exclude; `SubPath.op`, `joined`). `ShapeData`: a
  fill and a stroke (`ShapePaint`: none, a color, a gradient through
  `GradientStop`s; inside, centered or outside; caps, miter, round or
  bevel joins; dashes), drawn sharp (`renderShape`, exact coverage in
  bands on every core) after every resize, turn, flip, crop or transform
  (`mapShape`, `quadMap`), kept in .rp3 and undo; `shapeMask` for vector
  masks; `gradientT` lays gradients out as Photoshop does. `Raster`:
  `edge` (outlines past the sides), `accumulate`, `clear`.
- **Clipping masks:** `Layer.clipped` -- a layer shows only where the
  layer under it does (its effects too), composited directly.
- **Printing inks, Lab, duotones:** `retroui/photoinks` models how cyan,
  magenta, yellow and black print on paper (Neugebauer's mixing of the
  inks and their overprints, dot gain, black generation, the total ink
  and black limits: `InkSetup`, `setInks`): `inkOf`, `printed`,
  `printedFast`, `proofOf`, `inGamut`, `gamutDistance`; Lab (`labOf`,
  `fromLab`, `labBytes`) and duotones (`DuotoneInk`, `duotoneTable`,
  `defaultDuotone`). `retroui/photo` has the CMYK Color, Lab Color and
  Duotone modes (`toCMYK`, `toLab`, `toDuotone`; `channelCount`,
  `channelNames`, `channelGray`, `showChannel`; one channel edited keeps
  the others in its own space), Proof Colors and the gamut warning
  (`Doc.proof`, `gamutWarning`, drawn by the view); `toCmyk` gives the
  printing inks.
- **Brushes:** `BrushDynamics` -- size, angle and roundness jitter, the
  smallest size, scattering (across or both ways), the dabs' count, flow,
  opacity and flow jitter, hue, brightness and foreground/background
  jitter -- and symmetry painting (`SymmetryKind`: vertical, horizontal,
  dual axis, radial and mandala with up to 16 axes; `symmetric`). A
  stroke's own buffers are made in 64-pixel tiles only where it paints
  (a stroke on a 96 megapixel image no longer takes 576 MB).
- **Filter Factory plug-ins:** `retroui/filterfactory` runs filters written
  as four formulas in the language of Adobe's Filter Factory (the
  channels, the place, eight sliders, `src`, `rad`, `cnv`, `sin`, `mix`,
  `scl`, `rnd`, `? :`...; `compileFormula`, `compileFilter`, `filterFn`
  on every core) and keeps them as plug-in files (`savePlugin`,
  `loadPlugins`, `builtInPlugins`: twelve to start with).
- Adjustments as Photoshop makes them: Curves through a natural spline,
  each channel's curve or levels before the master's, Hue/Saturation with
  the master's lightness first and the ranges' own limits (`HueRanges`,
  `rangeMask`).
- The busy box comes up sooner (a quarter of a second), names what is
  being done (nested work keeps the outer name, `busyLabels`) and shows
  how far it has got: opening and saving pictures (deflate and inflate
  quicker, PNG with a quick filter choice, JPEG decoded in bands on every
  core), filters, compositing. An image of one plain layer is drawn from
  that layer without a copy (`simpleLayer`, `compPtr`, `compCopy`); with
  `-d:useMalloc` big pictures give their memory back when closed.
- Retro Photo 3.4: File > Open reads Photoshop, TIFF and Targa too;
  Save As keeps layers in .psd; File > Export > Export As... (every
  format with its options, scaled) and Quick Export as PNG / JPEG;
  Layer > Layer from File... (a picture as a new layer above the current
  one; also in the Layers palette's menu); the Shape tools (Rectangle,
  Rounded Rectangle, Ellipse, Polygon, Line, Custom Shape) as shape
  layers, paths or pixels, with fill, stroke and path operations; the
  Move tool, the arrow keys and Free Transform move shapes and type as
  what they are; Layer > Create Clipping Mask (Ctrl+Alt+G); Mode > CMYK
  Color, Lab Color, Duotone..., Printing Inks Setup..., CMYK Preview
  (Ctrl+Alt+Y) and Gamut Warning (Ctrl+Shift+Y), CMYK and Lab channels;
  the color picker warns of colors that cannot print; Smoothing,
  Symmetry and Brush Dynamics... for the brushes; Filter > Plug-ins with
  Filter Factory... and its plug-ins.
- **Retro Photo 3.5**, toward a Photoshop of today in the clothes of 1994:
  - Layers: groups (pass through or mixing their own way, nested,
    collapsed, moved, duplicated and merged whole; clipping to a group);
    Blend If; mask Density and Feather; Lock Layer; Align and Distribute;
    Bring to Front... (Ctrl+] and Ctrl+[); fill layers (Solid Color,
    Gradient, Pattern); Gradient Map and Color Lookup (.cube files and
    built-in looks) as adjustments and adjustment layers.
  - The History palette (states and snapshots, the History Brush paints
    any of them), the Navigator, the Properties palette (the canvas,
    rulers and guides; a layer's place, its mask's density and feather;
    an adjustment's or fill's settings; type and shape; Smart Filters).
  - Actions: recorded, played, steps turned off, stops, kept, saved and
    loaded (.actions); File > Automate > Batch... (an action on a folder of
    pictures, saved where and as asked), Fit Image....
  - An options bar under the menu bar (Window > Options Bar): each tool's
    settings, with sliders that drop down, selection modes, align
    buttons, the gradient's kinds.
  - Guides, the grid and snapping (View); Select and Mask...; the Quick
    Selection and Object Selection tools; the Remove tool and
    Content-Aware Move; the Mixer Brush; textured and dual brushes; a
    gradient editor with midpoints; the Path Selection tool.
  - Smart Objects: Convert to Smart Object, Place... (one), scaled,
    turned and distorted without loss, flipped, Smart Filters (changed,
    hidden or taken off later), Edit Contents (in a window of its own,
    saved back), Replace and Export Contents, New Smart Object via Copy.
  - Warp (a grid, or a style), Puppet Warp (pins: rigid, normal or
    distort), Perspective Warp (a plane laid out, then moved, made upright
    or level); the Blur Gallery (Field, Iris, Tilt-Shift, with Light
    Bokeh); Surface Blur; Skin Smoothing.
  - Photomerge (panoramas: perspective, collage or reposition, blended,
    cropped, the edges filled), Merge to HDR Pro (exposures fused), Load
    Files into Stack, Auto-Align and Auto-Blend Layers (panorama, focus
    stacking), Sky Replacement (painted skies or a picture, its edge and
    light).
  - Color profiles: read from JPEG, PNG, TIFF and Photoshop files,
    converted to sRGB (or kept and shown converted), Assign / Convert to
    Profile, embedded on export. Raw photos: DNG (Camera Raw: white
    balance and exposure on the light itself). Brushes from .abr and .gbr
    files, and saved as .abr.
  - Big images are saved in the background; Edit > Purge > Everything.
- New in the toolkit for it: `retroui/photomerge` (corners matched,
  RANSAC, `photomerge`, `exposureFusion`, `focusStackMasks`, Surface Blur,
  Skin Smoothing, skies), `retroui/photowarp` (`drawMesh`, Warp,
  `puppetWarp`, `renderSmart`, `variableBlur` and the Blur Gallery's
  radii), `retroui/iccprofile`, `retroui/rawphoto` (DNG, lossless JPEG,
  demosaicing, `developRaw`), `retroui/abr`, `retroui/photosave` (saving on
  a thread of its own), `popupSlider`, `filePicker(fmFolder)` (a folder),
  pixel icons for the selection modes and gradient kinds.
- **MS W98 UI**, the new default font of every app: martyr—'s outline
  conversion (2022, after Lev Leontev's 2019 one) of the MS Sans Serif of
  Windows 98, regular and bold, drawn on its pixel grid so it is crisp at
  every scale. **It comes with no licence**: its authors say it is free to
  use, but MS Sans Serif is Microsoft's (see
  `src/retro/fonts/NOTICE-MSW98UI.txt`). Build with `-d:retroNoW98` to
  leave it out; `setUiFont(ufKawkab)`, `ufRetro` or `ufSmooth` for
  another. Arabic and the icon glyphs fall back to the other fonts.
- **Control sizes:** `setControlSizes(csAuto / csDesktop / csTouch)` and
  "Controls" in `appearanceSettings`: on a tablet the desktop sizes by
  default (Automatic: touch sizes on phones only), touch sizes when asked.
- `beginStatusBar` / `statusRow` / `statusSep` / `endStatusBar`: a status
  bar of cells, clipped to itself. `pane`: a plain panel of a height.
- `tabStrip`: tabs torn off (dragged out) and moved (`tornOff`, `moved`).
- MDI: a window docked behind the floating ones (`docked`), the chosen one
  of them, `mdiTitleDragged`.
- **Keymaps** (`retroui/desktop`): commands' keys with defaults and the
  user's own over them (`keyFor`, `setKey`, `keymapPressed`,
  `storeKeymap`, `restoreKeymap`, `keymapEditor`).
- `recentFiles` / `addRecentFile` (`retroui/platform`).
- `busy`: `lastBusy` and `busyNow`, what the last long command took.
- `retroui/adobefiles`: Photoshop's swatches (.aco v1/v2, .ase: read and
  written), curves (.acv) and levels (.alv) (read and written), gradients
  (.grd v5) and patterns (.pat) (read).
- `retroui/photobrushes`: brush presets in folders, tips (round, square,
  chalk, bristles, star, leaf, grass, splatter... and sampled), saved as
  JSON, `strokePreview`, `tipPreview`.
- Painting: brushes from 1 to 5000 pixels (tips over 1024 kept at 1024 and
  scaled), the dabs' rows on all cores, tiles made before a stroke, the
  color sampled only when a dynamic needs it. A 6000 x 4000 picture, a
  5000-pixel stroke on 2 cores: a 20-pixel soft brush 51 -> 24 ms, 500
  pixels 838 -> 252 ms, 1000 pixels 1846 -> 512 ms, 5000 pixels 8918 ->
  2814 ms; the memory at its peak 515 -> 336 MB.
- Photoshop files: masks' Density and Feather, a group's fill opacity, the
  merged picture matted on white as Photoshop keeps it, 16 bits a channel
  read and written. Of 316 test files (psd-tools' corpus) all open; drawn
  by our engine, 157 of 280 look the same as Photoshop's merged picture
  (116 before), 46 near, 77 different.
- 16-bit PNG read (`decodePng(data, addr hi)`) and written
  (`encodePng16`); a document's depth (`Doc.depth`, `setDepth`,
  `flattened16`).
- **Retro Photo 3.6**:
  - The window sized with the mouse (and on Android tablets and
    ChromeOS: freeform, 1280 x 800 to start); desktop-sized controls on
    tablets (Preferences > Interface for touch sizes).
  - Documents as tabs (dragged out to float, Window > Arrange >
    Consolidate All to Tabs / Float All in Windows, Ctrl+Tab), the
    status bar of today's Photoshop (the zoom typed in, and its menu:
    document sizes, profile, dimensions, measurement scale, scratch
    sizes, efficiency, timing, the tool, save progress, smart objects,
    layer count).
  - Preferences in pages, as Photoshop has them: General, Interface,
    Workspace, Tools, History & Saving, Performance, Scratch Disks,
    Cursors, Transparency & Gamut, Units & Rulers, Guides, Grid & Slices,
    Type, Color Profiles.
  - Keyboard Shortcuts... (Edit): Photoshop's keys by default, 1994's when
    asked, any changed.
  - Brushes as in Photoshop 2026: presets in folders, each shown as it
    paints; Brush Settings (F5) with the tip shape and the dynamics; 1 to
    5000 pixels; [ and ] (Shift: hardness), , and . the presets; Alt and
    the right button dragged for size and hardness; brush tips of one's
    own from the selection.
  - Presets: Photoshop's swatches, curves, levels, gradients, patterns and
    brushes read (Edit > Presets, and the Curves, Levels and Gradient
    dialogs); swatches, curves and levels saved.
  - Autosave and recovery; File > Open Recent; Window > Workspace (the
    palettes where they were, kept); Image > Mode > 8 / 16 Bits/Channel.
  - Idle: no CPU used, about 21 MB with three pictures open.
- **Drawing on the GPU:** OpenGL ES 2 (or OpenGL 2.1) loaded at run time --
  nothing to link -- through new optional relays (`GpuRelays`: EGL on X11
  and Android, WGL on Windows). Every command becomes rectangles: glyphs
  and shapes from a texture of masks the CPU makes as it always has (the
  text looks the same), icons from a texture of pictures, bitmaps from
  textures of their own (only the rows that changed sent again), the 3.1
  dither and the marching ants worked out by the shader. A self-test at
  the start, a fall back to the CPU when anything fails, and a guard file:
  a crash while starting the GPU means the CPU next time. `setGpuMode`
  (`gmAuto`: a real GPU, not a software one; `gmGpu`; `gmCpu`),
  `drawnWithGpu`, `gpuDescription`, "Drawing" in `appearanceSettings`,
  `RETRO_GPU=0/1`. On the GPU the CPU's framebuffer is let go (33 MB at
  4K). Under Mesa's llvmpipe the GPU's frames are the CPU's to the pixel
  (tests/test_gpu).
- `gpuImage` / `drawGpuImage` / `gpuHasImage`: an app's own picture on the
  GPU, sent while its pixels are there, drawn at any size (the photo
  editor's canvas: zoomed and scrolled by the GPU). `checkerAt`, a
  checkerboard command; `marchingAnts`, a selection's outline as a command
  (no copy of the picture under it).
- **The CPU draws less:** the screen in tiles (256 x 32) -- only those that
  changed drawn and sent; a bitmap changed in part (`changed(b, r)`) only
  there; the tiles drawn on all cores (the texts made ready first on the
  drawing thread); a bitmap drawn 1:1 copied by rows. At 3840 x 2160, the
  photo editor: a whole redraw 18.1 -> 10.2 ms, scrolling 18.4 -> 8.3 ms,
  zooming 26.0 -> 17.1 ms, a 64-pixel dab 18.9 -> 1.3 ms; the cursor over a
  menu sends 16 k pixels instead of 245 k. `parallelFor(keepAlive = false)`
  and `drawingRows` for work that is part of a frame (no events read).
- X11: only what pictures covered is copied to the window, and pictures are
  no longer hashed pixel by pixel.
- **HD and 4K:** MS W98 UI HD (tools/genw98hd.py): the W98 pixels traced
  into smooth outlines, the same advances; text whose pixels would be 1.5x
  or more is drawn from it -- 2x and 4K screens, large text, and a tablet's
  1.5x at exactly its size (not the next multiple of 11). Pixel icons
  magnified 2x, 3x, 4x by Scale2x / Scale3x (smooth diagonals, hard
  edges). Check marks, radio dots and arrows at the screen's resolution
  (`hdDetail`). `setHdText(false)` (or "Pixels" in the settings): the 1998
  look magnified. The OLED Black theme (`Oled`).
- `tabStrip(look = tlPalette)`: document tabs drawn as a palette's.
  Docked MDI windows can be `sizable` (their right and bottom edges, a grip
  at the corner; `userSized`). `scrubLabel` -- Photoshop's scrubby
  sliders: a label dragged sideways changes its number.
- `retroui/adobefiles`: color books (.acb: `readAcb`, `writeAcb`,
  `ColorBook`, `builtinBooks` -- the web's colors, CSS's, process tints,
  grays); `retroui/photosmart`: `refineHair`, `segment` / `regionAt` /
  `findObject` (an Object Finder), `removeBackground`.
- **Retro Photo 3.7**:
  - The canvas on the GPU when there is one (Preferences > Performance >
    Use Graphics Processor), only the part painted on sent.
  - Document tabs like the palettes'; the documents' panel sized by its
    edges and its grip (Window > Arrange > Fit Documents Panel).
  - Photoshop's held keys (Space the Hand, Ctrl+Space the Zoom, Ctrl the
    Move tool, Alt the Eyedropper), Alt+drag a copy, Alt+[ / Alt+], Stamp
    Visible, Alt/Ctrl+Backspace fills, Reselect, Ctrl+click a thumbnail to
    select its pixels, Alt+click between layers to clip, scrubby labels.
  - The Move tool's transform controls: the current layer's blue box,
    eight handles (Shift: proportions, Alt: from the middle), turning
    outside the corners, Auto-Select with the layer under the mouse
    outlined; type sized stays type, shapes stay sharp; Free Transform
    (Ctrl+T) on a layer's own box; W and H % in the options bar.
  - New in Bitmap, Grayscale, RGB, CMYK and Lab, at 8 or 16 bits; Edit >
    Color Settings; CMYK and Lab numbers in the color picker; Color
    Libraries (the books above, and the user's .acb files -- Pantone's
    included, which cannot come with it).
  - Layer > Layer Mask (Reveal / Hide All or the selection, Gradient
    Mask), Place Into (a picture inside type, a shape or a frame), New
    Frame; the Type Mask tool; paint on a mask in grays.
  - Select > Remove Background, the Object Finder, Refine Hair.
- **Big photos, live:** a change made with the mouse is shown before it
  is done (`LivePart`, `setLive`, `liveChanged`, `endLive`): the view's
  pixels made straight from the layers at their own size
  (`compositeSampled`: groups, masks, clipping, adjustment layers, effects
  -- at 1:1 exactly what putting it down makes), the full-size pixels
  changed once, when it is put down. `moveTo` / `endMove` work this way
  (nothing copied when a layer is lifted), and Free Transform, and an
  adjustment's slider on a big photo. On a 70-megapixel photo (2 cores):
  dragging a layer 440 -> 8 ms a frame, Free Transform's corner 3.3 s ->
  25 ms, Ctrl+T 313 -> 23 ms, the Move tool's press 282 -> 1 ms.
- `touchWhole`: a change of all of a layer hands its old pixels to the
  undo step (no copy; undo and redo swap them); filters on all of a layer,
  moves and transforms use it. `liftForWarp` / `warpOnto` / `vacatedCopy`:
  a transform's pixels taken up once and put down on all the cores (a
  stretch without perspective a row at a time, in fixed point; shrunk
  from a copy halved as often as it shrinks).
- `selBounds` kept while the selection stays (`selVer`) and found on all
  the cores; the marching ants' edges traced row by row on all the cores:
  Select All on 70 megapixels 820 -> 140 ms, its ants 100 -> 0.4 ms a frame.
- The composite: the first layer of a row copied; the zoomed-out copies of
  an opaque photo averaged four channels at a time. Old undo steps' files
  deleted by the scratch disk's writer (`waitScratch`), a step being
  written stopped in pieces. JPEG: a component's pixels no longer copied
  for each scan (a 70-megapixel file opens in 1.75 s instead of 2.45 s).
  The undo history keeps at most 512 MB in memory (the rest on the scratch
  disk).
- **Line icons:** every pixel icon has a twin among the Nerd Fonts symbols
  (`setPixelTwin`, `lineTwins`, tools/genlineicons.py: 176 symbols added to
  the icon font); `setIconStyle(isAuto / isPixel / isLine)` -- by default
  line icons in a dark theme, where the pixel art's black outlines do not
  show, in the text's color (folders, warnings, stars keep their own),
  crisp at any size. "Icons" in `appearanceSettings`; `storeAppearance`
  keeps it. Symbols asked for in black are drawn in the text's color in a
  dark theme. Six new pixel icons (`pxMarqueeRow`, `pxMarqueeColumn`,
  `pxPolyLasso`, `pxTypeMask`, `pxPatternStamp`, `pxMoreTools`).
- **OLED black and Dark:** the tabs behind (palettes', documents',
  notebooks') lifted from the black and labelled in what shows on it
  (`contrastInk`, `lumaOfColor`); `themeIsDark`. `RETRO_THEME` picks a
  theme by name for tests and screenshots.
- MS W98 UI HD (the smooth one: tablets, 4K, large text) as big as the
  other fonts -- its x-height theirs -- and on its own pixel grid only
  where that is within 9 % (it was rounded to the grid at any error: up to
  a fifth smaller on a 2.25x screen).
- **Retro Photo 3.8**:
  - Photoshop's toolbar: one column (two with the arrows; as many as fit
    when left to itself), the tools in Photoshop's groups -- a group shows
    the tool used last, a triangle when it holds more; hold it down,
    right-click or long-press: its tools beside it with their names and
    keys; Alt+click the next one; the letter picks the group, Shift and the
    letter the next tool in it; "..." and Edit > Toolbar for the groups
    taken off. The Pen, the Path Selection tools, the Pattern Stamp, the
    single row and column marquees, the Type Mask tool are on it.
  - The Polygonal Lasso (click the corners; on the first one, a
    double-click or Enter closes it; Backspace takes one back).
  - A big photo: moving, Free Transform and the adjustments' sliders live
    (above), the Object Finder and the palettes not made again meanwhile.
  - OLED Black and Dark: line icons, brush previews in the text's color,
    a dark workspace.

## 0.8.0

The 3.1 look, down to the pixel, that holds up on a 4K screen and a phone.

- **Retro Sans**, the new default font of every app: a recreation of the
  Windows 3.1 MS Sans Serif (after lou's, CC BY-SA 3.0), regular and bold,
  with the characters it lacked drawn in the same style (all of ASCII in
  bold, Latin-1, Latin Extended-A, punctuation) and the Arabic of GNU
  Unifont, joined and right to left. Drawn from its bitmaps at 100 % (one
  screen pixel per font pixel) and from smoothed outlines of the same
  letters when larger and on HD, 2K and 4K screens. Also shipped as
  TrueType files (`src/retro/fonts/RetroSans*.ttf`); the Arabic is a
  separate file, as its licence (OFL) cannot be merged with the Latin
  letters' (CC BY-SA).
- **Choose the font:** `setUiFont(ufRetro)` / `setUiFont(ufSmooth)`
  (DejaVu Sans), `uiFont()`; a "Font" choice in `appearanceSettings`, kept
  by `storeAppearance` ("look.font"). The layout's sizes follow a change
  at once. `setPixelFont` is deprecated (it maps to `setUiFont`).
- **The Windows 3.1 look**, studied from the Win31 project by Wiesław
  Šoltés: black outlines and two-step bevels (`Theme.face2`), the default
  button's ring, a dotted focus inside the face, embossed disabled labels,
  dithered scroll tracks, etched group boxes, separators and status bar
  parts, roomy menus with a hard black shadow, 3.1 window frames with the
  control-menu box and the caption buttons on dialogs and MDI windows,
  navy title bars in front and white ones behind
  (`Theme.inactiveTitle`, `inactiveTitleText`), tool buttons that stay
  down on a dither. New drawing helpers for your own controls:
  `raisedFace`, `buttonFace`, `fieldFrame`, `etchedBox`, `etchedLine`,
  `windowFrame`, `captionButton`, `controlMenuMark`, `titleColors`,
  `ditherFill`, `checker`.
- **Smooth scrolling everywhere:** lists, grids, trees, text areas, panels
  and pages glide a short way per wheel notch or key, follow a finger
  pixel for pixel and fly on after a flick (a finger landing stops them
  without picking an item); rows scroll by pixels, not whole rows.
  `setSmoothScrolling(false)` (a setting in `appearanceSettings`) turns it
  off. For your own views: `scrollWheel`, `scrollPan`, `scrollPan2`,
  `scrollTo`, `scrollBy`, `scrollShow`, `scrollTick`, `scrollStop`,
  `scrolling`, `scrollTarget`, `scrollCaught`.
- **109 pixel icons** (from 78), redrawn in the manner of the period:
  charts, reports, maps, mail, calendar, clock, database, terminal, media
  keys, zoom, filter, sort and more. They are stored compressed (12 KB),
  so apps are smaller: "hello" is 0.77 MB.
- **Notepad** (`examples/notepad.nim`) is a full 3.1 Notepad: New, Open,
  Save, Save As, Cut / Copy / Paste / Delete, Select All, Time/Date (F5),
  Find (Ctrl+F, F3), a status bar and "Save changes?".
- The gallery's Canvas, HTML, Reports and System pages; its pages use the
  room of big screens (the map, 3D, canvas and HTML views grow to the
  bottom) and fold on phones.
- `scrollPanel -1` fills down to the bottom; `buttonWidth(label)` tells
  how wide a button is.
- Fixes: a tool bar's "more" button or a status bar drawn before the
  content could give a phone-sized window needless scroll bars both ways;
  a banner's buttons could cover its close box; Markdown table cells could
  wrap a short word; struck-through and underlined text lost its line at
  100 %; the breadcrumb's last (bold) part could overflow its hover box;
  Android builds failed where `osproc` needs `posix_spawn` (before API
  28): commands now run through `popen` there; `setLineDash` read freed
  memory; the copy dialog's choices could lose their ids; PDFs are written
  to a temporary file and moved into place.

## 0.7.0

The business and desktop release: everything a business app is made of,
the system's own APIs, and a full reference of every control.

- **Data grids as business screens:** cells hold check boxes
  (`checkColumn`), status colours (`colorColumn`), progress bars
  (`progressColumn`), drop-down lists (`choiceColumn`), push buttons and
  links (`buttonColumn`, `linkColumn`), icons (`iconColumn`) or anything
  you draw (`customColumn`); `style(row, col)` gives any cell its own text
  and background colours and bold; `rowHeaders` adds the record indicator,
  `footer` a totals row. Clicks, Space and F4 work on the cells
  (`ev.toggled`, `ev.clicked`, `ev.edited`).
- **Records and forms** (`retroui/records`): `maskedEdit` (phone numbers,
  codes, dates; Arabic-Indic digits), `recordNav` (|< < 3 of 20 > >| New
  Delete Save, Ctrl+Home / End / PageUp / PageDown), `dateRange` with
  presets (this month, last quarter...), `dualList`, `propertyGrid`,
  `treeGrid`, `wizard`.
- **Desktop apps** (`retroui/desktop`): windows in the window (`mdiArea`,
  `mdiWindow`: move, size, minimize, maximize, the control menu, Ctrl+F6,
  Ctrl+F4, cascade, tile, the Window menu), `findBar` with `findIn` and
  `replaceAllIn`, hot keys the user picks (`hotkeyEdit`,
  `hotkeyPressed`), `aboutBox`.
- **Charts** (`retroui/charts`): 21 kinds -- bars (grouped, stacked, 100 %,
  sideways), lines, areas, combo with a second axis, pies, donuts,
  scatter, bubbles, waterfalls, funnels, gauges, candlesticks,
  histograms, heat maps, radars, tree maps, bullets -- with legends that
  hide series, tooltips by mouse, finger and keys, click events, money /
  percent / 1.2K formats, CSV tables (`readCsv`, `chart(..., table, ...)`)
  and PNG export. `examples/charts.nim` is a ready chart viewer.
- **Reports, PDF and printing** (`retroui/report`, `retroui/pdf`,
  `retroui/templates`): reports from Nim code or from HTML templates with
  data (Mustache style), laid out in pages with headers, footers, page
  numbers, repeated table headers and totals; on screen (`reportView`),
  as PDF (real text, the built-in fonts, Arabic), PNG pages, or printed
  through the system. `examples/invoice.nim`.
- **Planning views** (`retroui/planning`): `kanbanBoard`, `ganttView`,
  `agendaView`, `orgChart`, `kpiTile`, `statCard`, `kpiRow`.
- **Maps** (`retroui/mapview`): a world map with the countries of Natural
  Earth built in -- values by country, markers, routes, zoom and pan, no
  network.
- **3D** (`retroui/view3d`): scenes of boxes, spheres, cylinders, cones,
  OBJ and STL models, 3D bar charts; turn, move, zoom, pick; no GPU.
- **Canvas** (`retroui/canvas2d`): the HTML5 Canvas 2D API -- paths,
  curves, gradients, patterns, dashes, transforms, text, pictures,
  shadows, compositing, hit tests -- drawn anti-aliased by the kit.
- **HTML and the web** (`retroui/htmlview`): `htmlView` / `htmlBlock` show a
  safe subset of HTML (no scripts, no network), `htmlToMarkdown`;
  `webView` is the system's WebView on Android and local HTML elsewhere.
- **Sound and video** (`retroui/media`): WAV and tones made and mixed by the
  kit and played through the system's own audio (PulseAudio / ALSA,
  waveOut, AudioQueue, MediaPlayer), other formats through the system's
  player, `videoView`, animated GIFs (`loadGif`, `animation`), `uiSound`.
- **The system's own APIs** (`retroui/native`): any shared library
  (`nativeLib`, `nativeProc`), any Java API on Android by reflection
  (`javaStatic`, `javaCall`...), Objective-C on macOS and iOS (`objcSend`),
  Win32 and COM, Termux:API; `vibrate`, `deviceName`, `osVersion`,
  `batteryLevel`, `systemDarkMode`, `keepScreenOn`...
- **Standard scroll bars everywhere:** on touch screens too, content
  larger than its place scrolls in a 3.1 scroll bar (and by finger); the
  page scrolls sideways as well (Shift + the wheel), dialogs clip and
  scroll, Ctrl+Home / End jump. Labels wrap to their room (no more cut
  text in About boxes); `tabs(..., sameHeight = true)` keeps a dialog the
  same size on every tab; `popupMenu` drops a menu under a button.
- **Path bar as in Explorer:** a click on a folder goes there, the arrow
  after it drops a menu of the folders in it, "<<" lists the hidden ones.
  The drive bar scrolls when it does not fit; the preview pane scrolls.
- **retrokit:** `retrokit new` (hello, form, business, files and charts
  apps), `doctor` (checks the machine and says what is missing), `run`,
  `small` (the smallest build) and `apk`.
- **Smaller:** the fonts are stored compressed and unpacked on first use
  (an app is about 180 KB smaller); a stripped "hello" is about 920 KB.
- **Hardening:** every widget audited for mouse, keyboard and touch; NaN,
  negative and huge values clamped; new fuzzers for charts, HTML, 3D
  models, sounds, the canvas and report templates; the tests run under
  AddressSanitizer. Faster file lists (-54 %), icon views (-54 %) and
  label mnemonics.
- **Fixes found by the new tests and sanitizers:** a dash list of odd
  length read freed memory (`setLineDash`); the file job dialogs lost
  their keyboard when their state lived on the stack; a tree with nothing
  selected showed no focus (and Down now picks the first node); a masked
  field showed its caret late; map labels covered each other; Android
  builds no longer need `posix_spawn` (Android 9+) for system commands.
- **docs/controls.md:** every control with its signature, documentation,
  example and pictures in each state (normal, focus, mouse over, pressed,
  open, disabled, touch, dark), drawn by `tools/shots.nim`; the API
  reference in `docs/api/`.
- Retro Files 1.5: Settings in tabs, the Explorer path bar, About that
  fits, Termux access in the settings. The gallery has new pages:
  Records, Windows, Planning, Map & 3D, HTML, Canvas, Reports, System
  (native APIs, sound and video).


## 0.6.0

- **Windows 3.1 pixel icons everywhere** (`retroui/pixelicons`): 78 icons
  drawn pixel by pixel in the manner of 3.1 (folders, drives, the
  computer, file kinds, tool bar actions, message box signs, the
  hourglass...), each in 16x16 and 32x32, used as text like the icon font
  (`pxFolder`, `toolButton(pxCopy, "Copy")`). They grow by whole pixels
  only (sharp at any size), and show embossed when disabled.
  `retroOr(px, nf)` picks between them and the Nerd icons (`retroIcons`).
  Original art (not copied from Windows); `tools/genicons.py` makes them
  and the app icons.
- **The classic pixel font reads Arabic:** the Arabic glyphs of GNU
  Unifont (SIL OFL 1.1) are built in, joined and ordered right to left
  like the vector text. With the pixel font, 150% screens get 2x (it
  cannot grow by part of a pixel).
- **Fits the screen:** on X11 the scale comes from Xft.dpi, `GDK_SCALE`,
  `QT_SCALE_FACTOR` or, without them, the monitor's real size (XRandR),
  in steps of 25%: 4K monitors get 2x, small HD laptops stay 1x with
  larger text.
- **3.1 look:** a slide switch drawn as a 3.1 control (`toggle`,
  `settingToggle`; click, slide, keys), cards as group boxes with their
  title in the frame line, dialogs with the navy frame, bold menus
  (`boldMenus`), settings rows without hover fills, tiles that highlight
  only their text (Program Manager), the hourglass as the busy sign,
  color schemes Ocean, Desert, Plum, Hot Dog and Paper ("Color scheme" in
  `appearanceSettings`, `settingCombo`), `driveBar` (the drive buttons of
  File Manager).
- **Mouse, keyboard and touch everywhere:** the mouse's back and forward
  buttons (`mouseBack`, `mouseForward`; X11, Windows, macOS), the middle
  button (`middleClicked`: `tabStrip` closes, `fileList` reports
  `ev.middle`), the menu key and Shift+F10 open the menu of the focused
  row; `tabStrip` takes the arrows, Home and End, scrolls with the wheel
  and a finger, reports `ev.menu`; chips, steps, banners, the bottom bar
  and the floating button take the focus and keys; `tabStop`,
  `takePanX`, `heldFor`, `lifted`.
- **Other apps' files** (`retroui/docfs`): folders that another app shares
  through Android's documents providers -- Termux's home -- are listed,
  opened, copied, moved, zipped, renamed and deleted like folders on
  disk (`vIsDir`, `vOpen`, `vMove`... and the file jobs use them).
  `FolderModel` shows "Allow access" for such a folder (`needsAccess`,
  `askAccess`: the system's folder picker, asked once); `localCopy` for
  viewers. Inside Termux, its places ("Termux home", "Termux system",
  "Shared storage") are listed. `retroapk --query:PACKAGE`, and
  `--storage` lets the app see Termux.
- **Faster folders:** a folder not shown yet is listed in two steps --
  the names at once, then sizes and dates (`listFolder(quick = true)`,
  `FileItem.stub`) -- so a folder of thousands of photos on a phone's
  shared storage shows without waiting. `RETRO_STATS=1` prints frame
  times.
- **Selection fixes:** a click on the empty part, or a new rectangle,
  no longer leaves the first item selected (`clearMarks`); Ctrl plus a
  rectangle adds to the selection; Space selects, Ctrl+Space toggles.
- Classic tabs are measured in bold, so their labels sit centered in
  both weights.
- Retro Files 1.4: pixel icons, the drive bar, a tab menu (duplicate,
  close others, move to the other pane), the middle button opens a
  folder in a new tab, the mouse's side buttons go back and forward, a
  selection bar on phones, Termux's files, a cache of copies for other
  apps' documents.
- The gallery shows all the pixel icons and the new widgets.

## 0.5.0

- **Drag and drop** in the core: `startDrag`, `dragging`, `dropTarget`
  (`dsOver`, `dsDropped`), `dropHighlight`, `dragCopies` (Ctrl), `cancelDrag`
  (Esc), a label that follows the pointer; on touch screens a held, then
  moved, finger drags (`lifted`). Grids and icon views drag their rows
  (`dragRows`, `dragItems`) and take drops on rows (`dropOk`), draw a
  selection rectangle from the empty part, scroll while dragging near an
  edge, and report the row under the mouse (`hot`).
- **Explorer parts:** `tabStrip` (closable tabs, a + button, Ctrl+Tab,
  drop on a tab), `pathBar` (folder buttons, typing with suggestions),
  `placesView` ("This device"), tiles (`fvTiles`) and icon sizes with
  Ctrl + the wheel (`ev.zoom`), the preview following the mouse, drops on
  file lists, the tree and the path (`FileDrop`, `jobFor`, `jobTitle`),
  the trash (`moveToTrash`, `trashItems`, `restore`, `deleteForever`,
  `emptyTrash`, `trashList`, `jkTrash`), undo (`remember`, `canUndo`,
  `undoLabel`, `undo`), copy speed and time left in job boxes.
- **Balloons:** `toast` is a pale yellow Windows 95 / 98 balloon with a
  tail, an icon, a bold `title` and a close box; a click closes it
  (`dismissToast`, `toastShown`, `toastArea`).
- **Classic tabs that do not fit** scroll with two arrow buttons, as on
  Windows 95, and keep the chosen tab in view.
- `encodePng`, `savePng`; `RetroVersion`; `beginScroll` takes a key.
- Fixes: a frame asked for with `wakeIn` is no longer lost when another
  frame runs first (hover delays, background results); a key or click
  that changes something late in the frame shows on the next one;
  modifier keys are read from mouse and wheel events and cleared when let
  go (X11 reported them one event late, so Ctrl stuck); suggestions of
  `comboEdit` are not picked until Down, so Enter keeps what was typed;
  touch screens no longer focus the first text box by themselves (no
  keyboard popping up).
- The gallery has a **Files** tab (two lists on a sandbox folder, tabs,
  path bars, views, the details pane, "This device", the trash, undo) and
  is built as an APK too.
- **File widgets in the toolkit** (`retroui/filewidgets`): `FolderModel`
  (listing on a worker thread, filter, natural sort, search through
  subfolders, history, selection, make / rename, watching for changes),
  `fileList` (details or icons with thumbnails), `filePreview` (the
  details pane), `folderTree`, `PictureCache` / `cachedPicture` /
  `drawPicture` / `pictureBox`, `textFileView`, `hexFileView`,
  `runJobDialog`, `jobSummary`, `propertiesDialog`, `filePicker` (a modern
  Open / Save dialog), `fileGlyph`, `fileIcon`, `placeGlyph`, `placeList`,
  `diskSpaceCached`, `permissionsText`. Retro Files is now a thin app on
  top of them (1,000 lines instead of 1,800).
- **New widgets:** settings rows (`settingToggle`, `settingChoice`,
  `settingSlider`, `settingButtons`, `settingLink`), `appearanceSettings`
  with `storeAppearance` / `restoreAppearance`, `avatar`, `stepper`,
  `banner`, `pager`, `bottomNav`, `fab`, `sparkline`, `progressRing`,
  `emptyState`, `busyState`, `factList`, `drawFacts`, `drawSpinner`,
  `drawFit`; `sidePane` (beside the content, under it on phones),
  `paneBeside`, `splitBar`; `buttonRow` is public; `builtinThemes`,
  `themeIndex`.
- **Tool bars** put the buttons that do not fit into a "more" menu.
- **Background work:** requests take an `onDone` callback (run on the UI
  thread at the start of a frame) and a `group` to cancel together;
  cancelled requests tell their callback. `beginFrameHooks`.
- **Faster:** drawing loops use a local framebuffer pointer (a full
  redraw takes half the time), text and pictures blend with two
  multiplies, pictures scale with a column table; inflate decodes with
  lookup tables (PNG 3x faster); JPEG uses an integer IDCT and smooth
  chroma upsampling (1.8x faster, within 3 levels of libjpeg).
- **Safer:** fuzzed decoders and parsers (`tests/fuzz`); fixed crashes on
  damaged PNG headers and depths, BMP offsets, JPEG Huffman tables,
  coefficient ranges, scans and segment lengths, zip dates, Arabic
  tatweel, type-ahead with an out-of-range selection, deeply nested
  Markdown (stack), long Markdown words (time), shrinking text files;
  `maxPicturePixels`, inflate output limits (zip bombs), atomic bitmap
  stamps across threads, `saveSettings` no longer raises.
- The slider is finger-sized on touch screens; `wrapLines` and Markdown
  break long words by bisection; composite widgets set `ui.lastRect` to
  their whole area.

## 0.4.0

- **Faster drawing:** each drawing command carries a hash and the frame is
  redrawn in bands 32 pixels high, only where commands changed (a changed
  value costs 0.2 ms instead of 0.8); glyph masks in a direct-mapped
  cache; kerning of ASCII text from a table; cheaper alpha blending.
  Android keeps its frame in the window's pixel format, so showing it is
  a copy.
- **Work off the UI thread** (`retroui/background`): `folderAsync`,
  `pictureAsync`, `finished`, `cancelTasks`, `busy`, `toBitmap`. Android
  decodes pictures with the system decoder, scaled straight to the size
  asked for (and turned by EXIF), from any thread.
- **Files of any size** (`retroui/textfile`): `TextFile` (lines found in
  slices, read as shown) and `HexFile`; zip listings read only the
  archive's directory; listings ask the file system once per file;
  `cmpNatural` and natural sorting; `pictureSize` from the file header.
- **Hover:** a `hover` theme color; buttons, tool buttons, list and grid
  rows, tree nodes, icon tiles, scroll bars, combo boxes and menu titles
  light up under a mouse -- also a mouse on a phone (Android tells the
  tool type) -- and never under a finger. `hovered`, `canHover`, `finger`.
- **Back is not Exit:** `backPressed()` is true only for the phone's Back,
  so apps go back on Back and leave on Exit or the close box.
- `wrapLines` breaks long paths after a "/" (and finds the break by
  bisection); kinds "Markdown Document" and "Log File".
- APKs ask for a large heap (big photos).
- **Retro Files 1.2:** folders listed and pictures decoded in the
  background (big folders open at once, a spinner while they read),
  thumbnails without stalls, big texts and logs open at once (hex for
  anything), photos fitted to the screen and 1:1 on demand, a preview
  pane beside the listing (under it on phones) with the picture or text,
  sizes, folder contents and Open / Share / Properties, a Settings dialog,
  natural sorting, mouse hover, single tap to open (optional), Back goes
  back through folders and File > Exit leaves.

## 0.3.0 -- Retro Nim UI

- The project is now **Retro Nim UI**: package and module `retro`, tools
  `retroapk` and `retroios`, `RETRO_*` environment variables, Java
  package `org.retro`, default app ids `org.retro.<name>`.
- **Vector text:** DejaVu Sans, Sans Bold, Sans Mono and Mono Bold built
  in, with a TrueType reader and an anti-aliased rasterizer in plain Nim
  (exact area coverage, light hinting on 1x screens, glyph cache); kerning;
  `TextStyle` (bold, italic, mono, underline, strike, size, rtl);
  `lineHeight`; the 3.1 bitmap font stays as `setPixelFont(true)`.
- **Arabic and right-to-left text:** letters join (presentation forms,
  lam-alef ligatures, Persian and Urdu letters), marks sit over their
  letters, lines follow the Unicode bidi algorithm (numbers, brackets).
- **Icons:** 300 Nerd Fonts symbols (`nfFolder`, `nfCog`, ...) usable in
  any text, `glyphIcon` for an `Icon` at any size, `toolButton(nfSave,
  size = 1.3)`.
- **Sizes and layout:** sizes follow fractional densities, `setUiScale`,
  `setTextScale`, Ctrl + / - / 0 and the phone title-bar menu; `dp`;
  weighted row shares, `spring`, `adaptive` columns, `card`, size classes
  (`sizeClass`, `isCompact`, `responsive`, `columnsFor`), forms with an
  automatic label column that stack on phones, the window's content
  scrolls when it is taller than the window, tall dialogs scroll.
- **Shapes:** `disc`, `ring`, `roundRect`, `polygon`, `thickLine`,
  `pieSlice`, anti-aliased at full resolution.
- **New widgets:** `searchBox`, `toggle`, `segmented`, `expander`, `card`,
  `chips`, `badge`, `rating`, `spinner`, `toast`, `colorPicker`,
  `timePicker`, `lineView`, `icon`, `iconLabel`, `heading`, `styledText`.
- **Markdown:** `markdownView` and `markdown` (CommonMark plus GitHub
  tables, task lists, strikethrough and autolinks), `parseMarkdown`,
  `toggleTask`.
- **Files and pictures:** a JPEG decoder (baseline, progressive, EXIF
  orientation, fast 1/8 thumbnails); file jobs, zip and imaging from 0.2
  are part of the library.
- **Retro Files** (`examples/filemanager.nim`): a full file manager for
  desktops, tablets and phones.
- Gallery: "More" and "Markdown" tabs. Check boxes and radio buttons stay
  round and crisp when scaled; grids, trees and icon views scale too.

## 0.2.0

- uirelays is included (`retroui/uirelays`); retro needs only Nim.
- Android: a NativeActivity driver in C (touch, soft keyboard including
  Arabic text, Back, pause/resume, system-bar and keyboard insets,
  clipboard, links, system-font text) and `retroapk`, which builds,
  signs and installs an APK with no Gradle, Java or SDK -- also on the
  device itself in Termux. A 3 KB Java activity ships precompiled.
- iOS: a UIKit driver and `retroios`, which builds the .app (Simulator
  and device signing on a Mac).
- Business widgets: `grid` (virtual rows, sort, resize, in-place edit),
  `tree`, `split`/`vsplit`, `calendar`, `datePicker`, `checkList`,
  `numberEdit`, `intEdit`, `comboEdit` (auto-complete), `form`/`field`,
  `link`, `inputBox`, `fileDialog` (3.1 Open / Save As), `barChart`,
  `lineChart`, `pieChart`; `Date` helpers, `formatNumber`, `sortRows`.
- High DPI: zoom follows the display (2x, 3x), `setZoom`, touch metrics on
  touch screens, drag to scroll, long press for context menus.
- Platform services: `dataDir`, `loadSettings`/`saveSettings`/`put`,
  `openUrl`, `platformName`, `isMobile`.
- Windows: Alt shortcuts and F10 work (`WM_SYSKEYDOWN`), mouse capture.
- Popups (menus, drop-downs, date picker) keep their dialog's layer and are
  not clipped by the panel they open from.
- Examples: `ledger.nim` (a small business app), gallery tabs for the
  business widgets and charts.

## 0.1.0

- First release: the Windows 3.1 widgets, menus, dialogs, themes, the pixel
  font, X11 / GDI / Cocoa / SDL3 through uirelays.
