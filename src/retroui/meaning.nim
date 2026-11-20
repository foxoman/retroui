## Search by meaning: texts made vectors by an embedding model on this device
## (`retroui/devicemodel`'s `deviceEmbed`; `retroui/modelstore`'s Qwen3 Embedding), kept in an
## index file, and found by what a question means rather than by its words -- "the invoice from
## Ahmed" finds the mail that says "bill" and "Ahmad". Nothing leaves the device.
##
## .. code-block:: nim
##   let ix = openMeaningIndex(dataDir("MyApp") / "meaning.idx", modelPath(storeModel("qwen3-embed-0.6b")))
##   indexing = ix.update(items)          # (key, stamp, text) each: those new or changed made vectors
##   # ... a later frame, its job done:
##   finding = ix.find("Find the documents that answer the question", "budget for next year")
##   for (key, score) in finding.value: echo key, " ", score
##
## A model reads a text in about a second (shorter is quicker: the first 1500 letters of each are
## read); what is read once is kept, and read again only when its stamp (a file's date and size)
## changes. Another model makes vectors of its own: its index starts again.
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[os, strutils, algorithm, tables, streams]
import jobs, devicemodel

type
  MeaningItem* = tuple[key, stamp, text: string]
    ## A text to find: its key (a file's path, a message's number), its stamp (what changes when
    ## it does: a date and a size), the text.

  MeaningIndex* = ref object
    ## Texts' vectors, kept in a file.
    path*: string                ## (the index's file)
    model*: string               ## (the embedding model's file)
    keys*: seq[string]
    stamps*: seq[string]
    vecs*: seq[seq[float32]]
    at: Table[string, int]

  MeaningHit* = tuple[key: string; score: float32]

const
  magic = "RMIX1"
  readMost* = 1500               ## (the letters of each text read)

proc openMeaningIndex*(path, model: string): MeaningIndex =
  ## The index kept at `path` for the embedding model at `model` (another model's, or none
  ## there: an empty one).
  result = MeaningIndex(path: path, model: model)
  if not fileExists(path): return
  var s = newFileStream(path, fmRead)
  if s == nil: return
  defer: s.close()
  try:
    if s.readLine() != magic or s.readLine() != model.extractFilename: return
    let n = parseInt(s.readLine())
    let dim = parseInt(s.readLine())
    if n < 0 or n > 10_000_000 or dim <= 0 or dim > 65536: return
    for i in 0 ..< n:
      let k = s.readLine()
      let st = s.readLine()
      var v = newSeq[float32](dim)
      if s.readData(addr v[0], dim * 4) != dim * 4: break
      result.at[k] = result.keys.len
      result.keys.add k
      result.stamps.add st
      result.vecs.add v
  except CatchableError:
    result.keys.setLen(0)
    result.stamps.setLen(0)
    result.vecs.setLen(0)
    result.at.clear()

proc len*(ix: MeaningIndex): int = ix.keys.len
  ## How many texts it has.

proc save*(ix: MeaningIndex): bool {.discardable.} =
  ## Writes the index to its file (false: it could not be).
  try:
    createDir(ix.path.parentDir)
    var s = newFileStream(ix.path & ".new", fmWrite)
    if s == nil: return false
    let dim = if ix.vecs.len > 0: ix.vecs[0].len else: 1
    s.writeLine(magic)
    s.writeLine(ix.model.extractFilename)
    s.writeLine($ix.keys.len)
    s.writeLine($dim)
    for i in 0 ..< ix.keys.len:
      s.writeLine(ix.keys[i].replace("\n", " "))
      s.writeLine(ix.stamps[i].replace("\n", " "))
      s.writeData(unsafeAddr ix.vecs[i][0], dim * 4)
    s.close()
    moveFile(ix.path & ".new", ix.path)
    true
  except CatchableError: false

proc needs*(ix: MeaningIndex; key, stamp: string): bool =
  ## The text is not in the index as it is now.
  let i = ix.at.getOrDefault(key, -1)
  i < 0 or ix.stamps[i] != stamp

proc put*(ix: MeaningIndex; key, stamp: string; vec: seq[float32]) =
  ## A text's vector, in the index.
  let i = ix.at.getOrDefault(key, -1)
  if i >= 0:
    ix.stamps[i] = stamp
    ix.vecs[i] = vec
  else:
    ix.at[key] = ix.keys.len
    ix.keys.add key
    ix.stamps.add stamp
    ix.vecs.add vec

proc keep*(ix: MeaningIndex; keys: openArray[string]) =
  ## Only these texts kept (the others are gone: files deleted, mail let go).
  var want: Table[string, bool]
  for k in keys: want[k] = true
  var n = MeaningIndex(path: ix.path, model: ix.model)
  for i in 0 ..< ix.keys.len:
    if ix.keys[i] in want: n.put(ix.keys[i], ix.stamps[i], ix.vecs[i])
  ix.keys = n.keys
  ix.stamps = n.stamps
  ix.vecs = n.vecs
  ix.at = n.at

proc rank*(ix: MeaningIndex; query: openArray[float32]; count = 50; within: openArray[string] = []):
    seq[MeaningHit] =
  ## The texts nearest `query` (a vector of the same model's), nearest first (`within`: only
  ## those keys).
  var only: Table[string, bool]
  for k in within: only[k] = true
  for i in 0 ..< ix.keys.len:
    if within.len > 0 and ix.keys[i] notin only: continue
    result.add (ix.keys[i], similarity(query, ix.vecs[i]))
  result.sort(proc (a, b: MeaningHit): int = cmp(b.score, a.score))
  if result.len > count: result.setLen(count)

type MeaningMade = seq[tuple[key, stamp: string; vec: seq[float32]]]

proc update*(ix: MeaningIndex; items: openArray[MeaningItem]; onDone: proc () {.closure.} = nil): Job[int] =
  ## Makes vectors of the `items` new or changed, on a worker (`progress`: how far; `cancel`:
  ## what is made so far is kept); they go into the index, and it is saved, when the job ends.
  ## The job's value: how many were made.
  var todo: seq[MeaningItem]
  for it in items:
    if ix.needs(it.key, it.stamp): todo.add (it.key, it.stamp, it.text[0 ..< min(it.text.len, readMost * 2)])
  let model = ix.model
  var made = new MeaningMade
  let ixr = ix
  result = job(proc (c: JobCtl): int {.gcsafe.} =
    {.cast(gcsafe).}:
      for i, it in todo:
        if c.cancelled: break
        let v = deviceEmbed(model, [it.text])
        if v.len == 1:
          made[].add (it.key, it.stamp, v[0])
          inc result
        c.progress(float(i + 1) / float(max(1, todo.len))),
    proc () =
      for m in made[]: ixr.put(m.key, m.stamp, m.vec)
      if made[].len > 0: ixr.save()
      if onDone != nil: onDone())

proc find*(ix: MeaningIndex; task, question: string; count = 50; within: openArray[string] = [];
           onDone: proc () {.closure.} = nil): Job[seq[MeaningHit]] =
  ## The texts that answer `question`, nearest first: the question made a vector on a worker
  ## (`task` says what is looked for -- "Find the mail that answers the question" -- as Qwen3
  ## Embedding asks), then ranked. The index must not change while it runs.
  let model = ix.model
  let q = queryText(task, question)
  let ixr = ix
  let only = @within
  job(proc (c: JobCtl): seq[MeaningHit] {.gcsafe.} =
    {.cast(gcsafe).}:
      let v = deviceEmbed(model, [q])
      if v.len == 1: result = ixr.rank(v[0], count, only),
    onDone)
