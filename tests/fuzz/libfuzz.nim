## The decoders under libFuzzer (coverage-guided, clang's
## -fsanitize=fuzzer) with AddressSanitizer and UBSan: what the mutation
## fuzzers (fuzz.nim) find by chance, this finds by following the code's
## branches. One target a build:
##
##   nim c --cc:clang --noMain -d:useMalloc -d:release --debugger:native \
##     --passC:"-fsanitize=fuzzer,address,undefined -fno-sanitize=function" \
##     --passL:"-fsanitize=fuzzer,address,undefined" \
##     -d:fuzzTarget=png -o:tests/fuzz/lf_png tests/fuzz/libfuzz.nim
##   tests/fuzz/lf_png -max_total_time=300 corpus/ tests/fuzz/seeds
##
## Targets: png, bmp, jpg, webp, inflate, md, html, pdf, gltf, mvt. A
## Defect (an index, a range, an overflow) or a sanitizer's report is a
## bug: libFuzzer stops and saves the input (crash-...).

import retroui/[imaging, jpeg, codec, markdown, webp, htmldom, pdfread, gltf, mvt]

const fuzzTarget {.strdefine.} = "png"

proc NimMain() {.importc, cdecl.}

# (what Nim's own main would define: libFuzzer has the main)
var cmdLine {.exportc: "cmdLine".}: cstringArray
var cmdCount {.exportc: "cmdCount".}: cint

proc LLVMFuzzerInitialize(argc: ptr cint; argv: ptr cstringArray): cint {.exportc, cdecl.} =
  cmdCount = argc[]
  cmdLine = argv[]
  NimMain()
  0

proc LLVMFuzzerTestOneInput(data: ptr UncheckedArray[byte]; len: csize_t): cint {.exportc, cdecl.} =
  var s = newString(int(len))
  if len > 0: copyMem(addr s[0], data, int(len))
  try:
    when fuzzTarget == "png": discard decodePng(s)
    elif fuzzTarget == "bmp": discard decodeBmp(s)
    elif fuzzTarget == "jpg": discard decodeJpeg(s)
    elif fuzzTarget == "webp": discard decodeWebp(s)
    elif fuzzTarget == "inflate": discard zlibDecompress(s.toOpenArrayByte(0, s.high))
    elif fuzzTarget == "md": discard parseMarkdown(s)
    elif fuzzTarget == "html": discard parseHtml(s)
    elif fuzzTarget == "pdf":
      let p = openPdf(s)
      discard p
    elif fuzzTarget == "gltf": discard readGltf(s)
    elif fuzzTarget == "mvt": discard decodeMvt(s)
    else: {.error: "fuzzTarget: png, bmp, jpg, webp, inflate, md, html, pdf, gltf or mvt".}
  except CatchableError:
    discard                          # (bad input refused: as it should be)
  0
