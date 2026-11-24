## Data loaded once and shared: `query(key, load)` asks for something slow -- a feed, a list
## from a server, a file read and parsed -- by a name. The first call starts `load` on a worker
## (`retroui/jobs`); every call that frame and the next, from any page or window of the app,
## gets the same entry: loading, its value, or why it failed. Its value stays while it is
## loaded again -- when it is older than `maxAge`, or the app says it is out of date
## (`invalidate`) -- so a page shows what it had and the new one when it comes; one nobody
## asked for in `keepFor` is let go of.
##
## .. code-block:: nim
##   import retroui, retroui/queries
##
##   proc loadFeed(url: string): seq[Episode] = parseFeed(httpRequest("GET", url).body)
##
##   app "Podcasts", 600, 400:
##     let q = query("feed:" & url, proc (): seq[Episode] = loadFeed(url), maxAge = 15 * 60_000)
##     if q.loading and not q.has: label "Loading..."
##     elif q.failed and not q.has: label "No feed: " & q.error
##     else:
##       for e in q.value: label e.title
##       if q.loading: label("Updating...", color = ui.theme.gray)
##     if button("&Refresh"): invalidate("feed:")          # (every feed: loaded again)
##
## A change made here (an episode marked played) can be put in at once with `setQuery`, and the
## entry loaded again after with `invalidate` -- the page never waits for the server to show it.
## The work gets its own copies of what it captures, as a `job`'s does. Without threads (a web
## page built without them) the work runs on the UI thread at the start of the next frame.
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[tables, strutils]
import core, jobs

type
  QueryState* = enum
    ## Where a query is.
    qsLoading      ## being loaded (the first time, or again: `value` is the last one, `has`)
    qsReady        ## loaded: `value`
    qsFailed       ## its last load failed: `error` (the value before it, if any, kept: `has`)

  Query*[T] = object
    ## What `query` gives each frame.
    state*: QueryState
    value*: T              ## the last value loaded (the type's empty one before the first)
    has*: bool             ## a value has been loaded (it may be being loaded again)
    error*: string         ## why the last load failed ("" when it did not)
    loadedAt*: int         ## when the value came (a `ui.now`; 0: not yet)

  EntryBase = ref object of RootObj
    seenAt: int            # the last frame a query asked for it
    keepFor: int
    stale: bool            # out of date: loaded again when next asked
  Entry[T] = ref object of EntryBase
    job: Job[T]
    q: Query[T]
    load: proc (): T {.closure, gcsafe.}
    tries: int             # the loads that failed in a row
    retryAt: int           # when to try again (0: not waiting to)

var entries: Table[string, EntryBase]
var sweptAt = 0

proc loading*[T](q: Query[T]): bool {.inline.} = q.state == qsLoading
  ## Being loaded: the first time (`has` false) or again.

proc ready*[T](q: Query[T]): bool {.inline.} = q.state == qsReady
  ## Loaded, and not being loaded again.

proc failed*[T](q: Query[T]): bool {.inline.} = q.state == qsFailed
  ## Its last load failed (`error`); the value before it is kept when there was one (`has`).

proc sweep() =
  ## (the entries nobody asked for in their `keepFor`: let go of, their loads stopped)
  if ui.now - sweptAt < 5_000: return
  sweptAt = ui.now
  var old: seq[string]
  for k, e in entries:
    if ui.now - e.seenAt > e.keepFor: old.add k
  for k in old: entries.del k

proc start[T](e: Entry[T]) =
  e.job = job(e.load)
  e.q.state = qsLoading
  e.stale = false
  e.retryAt = 0

proc query*[T](key: string; load: proc (): T {.closure, gcsafe.}; maxAge = 0; keepFor = 300_000;
               retries = 1): Query[T] =
  ## The entry `key` names: started the first time it is asked (`load` on a worker), the same
  ## for every call after, from anywhere in the app -- loading, its value, or why it failed.
  ## `maxAge` milliseconds after it came (0: never by itself) it is loaded again the next time
  ## it is asked, its value kept meanwhile; a failed load is tried `retries` more times (a
  ## second apart, then more) before it is told. Nobody asking for it for `keepFor`
  ## milliseconds: let go of. A key asked for with another type is a new entry under it.
  sweep()
  var e: Entry[T]
  let found = entries.getOrDefault(key)
  if found != nil and found of Entry[T]: e = Entry[T](found)
  if e == nil:
    e = Entry[T](load: load, keepFor: keepFor)
    entries[key] = e
    e.start()
  e.seenAt = ui.now
  e.keepFor = max(e.keepFor, keepFor)
  e.load = load                    # (the latest: what it captures may have changed)
  # its load ended: the value, or tried again later, or the error
  if e.job != nil and e.job.ended:
    let j = e.job
    e.job = nil
    if j.done:
      e.q.value = j.value
      e.q.has = true
      e.q.error = ""
      e.q.loadedAt = max(1, ui.now)
      e.q.state = qsReady
      e.tries = 0
    else:
      let why = if j.error.len > 0: j.error else: "cancelled"
      if e.tries < retries:
        # (tried again a second later, then two, four... -- still loading meanwhile)
        inc e.tries
        e.retryAt = ui.now + 1000 * (1 shl min(e.tries - 1, 5))
      else:
        e.q.error = why
        e.q.state = qsFailed
        e.tries = 0
  if e.job == nil:
    if e.retryAt > 0:
      if ui.now >= e.retryAt: e.start()
      else: wakeIn(e.retryAt - ui.now)
    elif e.stale or (maxAge > 0 and e.q.has and ui.now - e.q.loadedAt >= maxAge):
      # out of date, or too old: loaded again, the value kept meanwhile
      e.start()
    elif maxAge > 0 and e.q.has:
      wakeIn(max(1, maxAge - (ui.now - e.q.loadedAt)))
  result = e.q

proc invalidate*(prefix: string) =
  ## Every entry whose key starts with `prefix` is out of date: loaded again the next time it
  ## is asked, its value shown meanwhile ("": all of them).
  for k, e in entries:
    if k.startsWith(prefix): e.stale = true
  ui.redraw = true

proc setQuery*[T](key: string; value: T) =
  ## The entry `key` holds `value` now, as if it had just been loaded -- a change the app made
  ## shown at once (then `invalidate` to have it loaded from where it lives). An entry not
  ## asked for yet is made, with nothing to load it again until a `query` gives its `load`.
  var e: Entry[T]
  let found = entries.getOrDefault(key)
  if found != nil and found of Entry[T]: e = Entry[T](found)
  if e == nil:
    e = Entry[T](keepFor: 300_000, seenAt: ui.now,
                 load: proc (): T {.closure, gcsafe.} = raise newException(ValueError, "nothing to load it"))
    entries[key] = e
  if e.job != nil:
    e.job.cancel()
    e.job = nil
  e.q = Query[T](state: qsReady, value: value, has: true, loadedAt: max(1, ui.now))
  e.stale = false
  ui.redraw = true

proc forgetQueries*(prefix = "") =
  ## The entries whose key starts with `prefix` let go of, their loads stopped ("": all).
  var gone: seq[string]
  for k in entries.keys:
    if k.startsWith(prefix): gone.add k
  for k in gone: entries.del k

proc queriesHeld*(): int = entries.len
  ## How many entries there are (loaded, loading or failed).
