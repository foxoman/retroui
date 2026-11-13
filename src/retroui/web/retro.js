// Retro Nim UI in a browser: the page's side of a program built with
// `retrokit web` (WebAssembly from Nim's C by clang alone -- no
// Emscripten). It gives the program's C library its files, clock, console
// and randomness (`RetroFS`, the `rl_*` imports), the toolkit's browser
// driver a canvas, the keyboard and mouse, text, the clipboard, sound,
// pages, videos and fetches (the `rw_*` imports), and runs the program's
// frames (`retro_frame`) when something happened or it asked for one.
//
// Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

"use strict";

(function (root) {

const textDecoder = new TextDecoder("utf-8");
const textEncoder = new TextEncoder();
// (a memory shared with threads cannot be decoded in place: copied first)
const decodeAt = (m, a, b) =>
  textDecoder.decode(typeof SharedArrayBuffer !== "undefined" && m.buffer instanceof SharedArrayBuffer
                     ? m.slice(a, b) : m.subarray(a, b));
// (iconv in the C library: a character set to UTF-8, the browser's
// TextDecoder knows them all; -1 when it did not fit, nothing written)
const charsets = new Map();
const charsetOk = (name) => {
  if (!charsets.has(name)) { try { charsets.set(name, new TextDecoder(name)); } catch (e) { charsets.set(name, null); } }
  return charsets.get(name);
};
const charsetDecode = (m, from, p, n, out, cap) => {
  const d = charsetOk(from);
  if (!d) return -1;
  const b = textEncoder.encode(d.decode(m.slice(p, p + n)));
  if (b.length > cap) return -1;
  m.set(b, out);
  return b.length;
};
const isWorker = typeof WorkerGlobalScope !== "undefined" && self instanceof WorkerGlobalScope;
// (this script's own address: a thread's worker runs it too)
const scriptUrl = isWorker ? self.location.href
  : typeof document !== "undefined" && document.currentScript ? document.currentScript.src : "retro.js";

// ---- errors (Linux's numbers, as the C library has them) ----
const E = { PERM: 1, NOENT: 2, IO: 5, BADF: 9, AGAIN: 11, NOMEM: 12, ACCES: 13, EXIST: 17,
            NOTDIR: 20, ISDIR: 21, INVAL: 22, MFILE: 24, NOSPC: 28, SPIPE: 29, ROFS: 30,
            NOSYS: 38, NOTEMPTY: 39 };
const S_IFDIR = 0o040000, S_IFREG = 0o100000;

// ---- a file system in the page ----------------------------------------------------------------
// Folders and files in memory; what is under the folders kept (`persist`,
// the app's data and home) is stored in IndexedDB a moment after it
// changes, and brought back before the program starts. /app holds the
// files the app came with (read only). A file the app writes in
// /downloads is handed to the user when it is done (the browser's "Save
// as", or a download): that is where a web app's "Save as" goes.

class RetroFS {
  constructor(name, persist) {
    this.name = name;
    this.persist = persist || ["/home", "/data", "/tmp/keep"];
    this.nodes = new Map();
    this.fds = new Map();
    this.nextFd = 3;
    this.nextIno = 1;
    this.dirty = new Set();
    this.saveTimer = 0;
    this.fresh = new Set();          // (files written in /downloads, to hand to the user)
    for (const d of ["/", "/home", "/home/web", "/data", "/tmp", "/app", "/downloads"]) this.mkdirp(d);
  }
  norm(p) {
    const parts = [];
    for (const s of p.split("/")) {
      if (!s || s === ".") continue;
      if (s === "..") parts.pop(); else parts.push(s);
    }
    return "/" + parts.join("/");
  }
  parent(p) { const i = p.lastIndexOf("/"); return i <= 0 ? "/" : p.slice(0, i); }
  mkdirp(p) {
    p = this.norm(p);
    if (this.nodes.has(p)) return;
    if (p !== "/") this.mkdirp(this.parent(p));
    this.nodes.set(p, { dir: true, mtime: Date.now(), ino: this.nextIno++ });
  }
  kept(p) { return this.persist.some(r => p === r || p.startsWith(r + "/")); }
  touch(p) {
    if (p.startsWith("/downloads/")) this.fresh.add(p);
    if (!this.kept(p) || !this.db) return;
    if (!this.askedPersist) {
      // (kept for good: the browser may otherwise clear a site's storage when space runs short)
      this.askedPersist = true;
      if (typeof navigator !== "undefined" && navigator.storage && navigator.storage.persist)
        navigator.storage.persisted().then((on) => { if (!on) navigator.storage.persist(); }).catch(() => {});
    }
    this.dirty.add(p);
    if (!this.saveTimer) this.saveTimer = setTimeout(() => this.save(), 400);
  }
  addFile(p, bytes, readOnly, url) {
    p = this.norm(p);
    this.mkdirp(this.parent(p));
    this.nodes.set(p, { dir: false, data: bytes, size: bytes.length, mtime: Date.now(),
                        ino: this.nextIno++, ro: !!readOnly, url: url || null });
  }
  // a file the app came with that is only fetched when it is first read
  // (a big one: videos, maps, models); `url` is where the page has it
  addLater(p, url, size) {
    p = this.norm(p);
    this.mkdirp(this.parent(p));
    this.nodes.set(p, { dir: false, data: null, size: size, mtime: Date.now(),
                        ino: this.nextIno++, ro: true, url: url, later: true });
  }
  load(n) {
    if (!n.later) return true;
    // (it waits, as reading a file does everywhere)
    try {
      const x = new XMLHttpRequest();
      x.open("GET", n.url, false);
      x.overrideMimeType("text/plain; charset=x-user-defined");
      x.send();
      if (x.status !== 200 && x.status !== 0) return false;
      const t = x.responseText || "";
      const d = new Uint8Array(t.length);
      for (let i = 0; i < t.length; i++) d[i] = t.charCodeAt(i) & 255;
      n.data = d;
      n.size = d.length;
      n.later = false;
      return true;
    } catch (e) {
      return false;
    }
  }
  // IndexedDB
  async open() {
    if (typeof indexedDB === "undefined") return;
    this.db = await new Promise((ok) => {
      const r = indexedDB.open("retro-fs-" + this.name, 1);
      r.onupgradeneeded = () => r.result.createObjectStore("nodes");
      r.onsuccess = () => ok(r.result);
      r.onerror = () => ok(null);
    });
    if (!this.db) return;
    const all = await new Promise((ok) => {
      const out = [];
      const tx = this.db.transaction("nodes", "readonly");
      const req = tx.objectStore("nodes").openCursor();
      req.onsuccess = () => {
        const c = req.result;
        if (c) { out.push([c.key, c.value]); c.continue(); } else ok(out);
      };
      req.onerror = () => ok(out);
    });
    all.sort((a, b) => a[0].length - b[0].length);
    for (const [p, v] of all) {
      if (v.dir) this.mkdirp(p);
      else {
        this.mkdirp(this.parent(p));
        this.nodes.set(p, { dir: false, data: new Uint8Array(v.data), size: v.data.byteLength,
                            mtime: v.mtime, ino: this.nextIno++ });
      }
    }
    if (typeof addEventListener !== "undefined")
      addEventListener("pagehide", () => this.save());
  }
  save() {
    this.saveTimer = 0;
    if (!this.db || !this.dirty.size) return;
    const tx = this.db.transaction("nodes", "readwrite");
    const st = tx.objectStore("nodes");
    for (const p of this.dirty) {
      const n = this.nodes.get(p);
      if (!n) st.delete(p);
      else if (n.dir) st.put({ dir: true, mtime: n.mtime }, p);
      else st.put({ dir: false, mtime: n.mtime, data: n.data.slice(0, n.size).buffer }, p);
    }
    this.dirty.clear();
  }
  // what the C library asks
  open_(p, flags) {
    p = this.norm(p);
    const acc = flags & 3, creat = flags & 0o100, excl = flags & 0o200, trunc = flags & 0o1000;
    let n = this.nodes.get(p);
    if (n && creat && excl) return -E.EXIST;
    if (!n) {
      if (!creat) return -E.NOENT;
      const dir = this.nodes.get(this.parent(p));
      if (!dir || !dir.dir) return -E.NOENT;
      if (p.startsWith("/app/")) return -E.ROFS;
      n = { dir: false, data: new Uint8Array(0), size: 0, mtime: Date.now(), ino: this.nextIno++ };
      this.nodes.set(p, n);
      this.touch(p);
    }
    if (n.dir && acc !== 0) return -E.ISDIR;
    if (n.ro && acc !== 0) return -E.ROFS;
    if (!n.dir && !this.load(n)) return -E.IO;
    if (trunc && acc !== 0 && !n.dir) { n.size = 0; n.mtime = Date.now(); this.touch(p); }
    if (this.fds.size > 1000) return -E.MFILE;
    const fd = this.nextFd++;
    this.fds.set(fd, { p, n, pos: 0, flags });
    return fd;
  }
  // a whole file the page itself writes (a recording of the microphone)
  writeWhole(p, bytes) {
    p = this.norm(p);
    this.mkdirp(this.parent(p));
    const old = this.nodes.get(p);
    this.nodes.set(p, { dir: false, data: bytes, size: bytes.length, mtime: Date.now(),
                        ino: old ? old.ino : this.nextIno++ });
    this.touch(p);
  }
  ensure(n, size) {
    if (n.data.length >= size) return;
    const d = new Uint8Array(Math.max(size, n.data.length * 2, 256));
    d.set(n.data.subarray(0, n.size));
    n.data = d;
  }
}

// ---- the runtime ------------------------------------------------------------------------------

class Retro {
  constructor(opts) {
    this.opts = opts || {};
    this.fs = new RetroFS(this.opts.name || "app", this.opts.persist);
    this.env = Object.assign({
      HOME: "/home/web", USER: "web", LANG: (typeof navigator !== "undefined" &&
        navigator.language ? navigator.language.replace("-", "_") : "en_US") + ".UTF-8",
      XDG_DATA_HOME: "/data", XDG_CONFIG_HOME: "/data/config", XDG_CACHE_HOME: "/tmp/cache",
      TMPDIR: "/tmp", PATH: "/app"
    }, this.opts.env || {});
    this.lineBuf = ["", "", ""];
    this.exited = null;
    this.driver = null;            // (the toolkit's browser driver, retro-web.js)
  }
  get mem() { return this.memory || this.instance.exports.memory; }
  u8() { return new Uint8Array(this.mem.buffer); }
  str(p) {
    const m = this.u8();
    let e = p;
    while (m[e]) e++;
    return decodeAt(m, p, e);
  }
  putStr(s, p, cap) {
    const b = textEncoder.encode(s);
    const n = Math.min(b.length, cap - 1);
    this.u8().set(b.subarray(0, n), p);
    this.u8()[p + n] = 0;
    return n;
  }
  console(fd, bytes) {
    const text = this.lineBuf[fd] + textDecoder.decode(bytes, { stream: false });
    const lines = text.split("\n");
    this.lineBuf[fd] = lines.pop();
    for (const l of lines) {
      if (fd === 2) {
        // (the last lines of stderr: shown when the program stops on an error)
        this.errLines = (this.errLines || []).concat([l]).slice(-30);
        this.lastError = this.errLines.join("\n");
      }
      if (this.opts.onOutput) this.opts.onOutput(fd, l);
      else if (fd === 2) console.warn(l); else console.log(l);
    }
  }
  flushConsole() {
    for (const fd of [1, 2]) if (this.lineBuf[fd]) { this.console(fd, new Uint8Array([10])); }
  }
  imports() {
    const rt = this, fs = this.fs;
    const statOut = (n, buf) => {
      const dv = new DataView(rt.mem.buffer);
      dv.setUint32(buf, n.dir ? S_IFDIR | 0o755 : S_IFREG | (n.ro ? 0o444 : 0o644), true);
      dv.setUint32(buf + 4, 1, true);
      dv.setFloat64(buf + 8, n.dir ? 4096 : n.size, true);
      dv.setFloat64(buf + 16, n.mtime, true);
      dv.setFloat64(buf + 24, n.ino, true);
      return 0;
    };
    const env = {
      rl_open: (p, flags, mode) => fs.open_(rt.str(p), flags),
      rl_close: (fd) => {
        const f = fs.fds.get(fd);
        if (!f) return -E.BADF;
        fs.fds.delete(fd);
        return 0;
      },
      rl_read: (fd, p, n) => {
        if (fd === 0) return 0;
        const f = fs.fds.get(fd);
        if (!f) return -E.BADF;
        if (f.n.dir) return -E.ISDIR;
        const k = Math.max(0, Math.min(n, f.n.size - f.pos));
        rt.u8().set(f.n.data.subarray(f.pos, f.pos + k), p);
        f.pos += k;
        return k;
      },
      rl_write: (fd, p, n) => {
        const bytes = rt.u8().slice(p, p + n);
        if (fd === 1 || fd === 2) { rt.console(fd, bytes); return n; }
        const f = fs.fds.get(fd);
        if (!f) return -E.BADF;
        if ((f.flags & 3) === 0) return -E.BADF;
        if (f.flags & 0o2000) f.pos = f.n.size;
        fs.ensure(f.n, f.pos + n);
        f.n.data.set(bytes, f.pos);
        f.pos += n;
        if (f.pos > f.n.size) f.n.size = f.pos;
        f.n.mtime = Date.now();
        fs.touch(f.p);
        return n;
      },
      rl_seek: (fd, off, whence) => {
        const f = fs.fds.get(fd);
        if (!f) return -E.BADF;
        const at = whence === 0 ? off : whence === 1 ? f.pos + off : f.n.size + off;
        if (at < 0) return -E.INVAL;
        f.pos = at;
        return at;
      },
      rl_stat: (p, buf) => {
        const n = fs.nodes.get(fs.norm(rt.str(p)));
        return n ? statOut(n, buf) : -E.NOENT;
      },
      rl_fstat: (fd, buf) => {
        const f = fs.fds.get(fd);
        return f ? statOut(f.n, buf) : -E.BADF;
      },
      rl_mkdir: (p) => {
        const path = fs.norm(rt.str(p));
        if (fs.nodes.has(path)) return -E.EXIST;
        const par = fs.nodes.get(fs.parent(path));
        if (!par) return -E.NOENT;
        if (!par.dir) return -E.NOTDIR;
        fs.nodes.set(path, { dir: true, mtime: Date.now(), ino: fs.nextIno++ });
        fs.touch(path);
        return 0;
      },
      rl_rmdir: (p) => {
        const path = fs.norm(rt.str(p));
        const n = fs.nodes.get(path);
        if (!n) return -E.NOENT;
        if (!n.dir) return -E.NOTDIR;
        for (const k of fs.nodes.keys()) if (k.startsWith(path + "/")) return -E.NOTEMPTY;
        fs.nodes.delete(path);
        fs.touch(path);
        return 0;
      },
      rl_unlink: (p) => {
        const path = fs.norm(rt.str(p));
        const n = fs.nodes.get(path);
        if (!n) return -E.NOENT;
        if (n.dir) return -E.ISDIR;
        if (n.ro) return -E.ROFS;
        fs.nodes.delete(path);
        fs.touch(path);
        return 0;
      },
      rl_rename: (a, b) => {
        const pa = fs.norm(rt.str(a)), pb = fs.norm(rt.str(b));
        const n = fs.nodes.get(pa);
        if (!n) return -E.NOENT;
        if (!fs.nodes.get(fs.parent(pb))) return -E.NOENT;
        const moves = [[pa, n]];
        if (n.dir) for (const [k, v] of fs.nodes) if (k.startsWith(pa + "/")) moves.push([k, v]);
        for (const [k] of moves) { fs.nodes.delete(k); fs.touch(k); }
        for (const [k, v] of moves) {
          const nk = pb + k.slice(pa.length);
          fs.nodes.set(nk, v);
          fs.touch(nk);
        }
        for (const f of fs.fds.values()) if (f.p === pa) f.p = pb;
        return 0;
      },
      rl_truncate: (fd, size) => {
        const f = fs.fds.get(fd);
        if (!f) return -E.BADF;
        fs.ensure(f.n, size);
        if (size > f.n.size) f.n.data.fill(0, f.n.size, size);
        f.n.size = size;
        fs.touch(f.p);
        return 0;
      },
      rl_utime: (p, ms) => {
        const path = fs.norm(rt.str(p));
        const n = fs.nodes.get(path);
        if (!n) return -E.NOENT;
        n.mtime = ms;
        fs.touch(path);
        return 0;
      },
      rl_listdir: (p, buf, cap) => {
        const path = fs.norm(rt.str(p));
        const n = fs.nodes.get(path);
        if (!n) return -E.NOENT;
        if (!n.dir) return -E.NOTDIR;
        const pre = path === "/" ? "/" : path + "/";
        const parts = [];
        for (const [k, v] of fs.nodes) {
          if (k === path || !k.startsWith(pre)) continue;
          const rest = k.slice(pre.length);
          if (rest.includes("/")) continue;
          const name = textEncoder.encode(rest);
          const e = new Uint8Array(name.length + 2);
          e[0] = v.dir ? 4 : 8;
          e.set(name, 1);
          parts.push(e);
        }
        const total = parts.reduce((a, e) => a + e.length, 0);
        if (total > cap) return total;
        const m = rt.u8();
        let at = buf;
        for (const e of parts) { m.set(e, at); at += e.length; }
        return total;
      },
      rl_now: (clock) => clock === 0 ? Date.now() : performance.now(),
      rl_charset: (name) => charsetOk(rt.str(name)) ? 1 : 0,
      rl_decode: (from, p, n, out, cap) => charsetDecode(rt.u8(), rt.str(from), p, n, out, cap),
      rl_tzoffset: (ms) => new Date(ms).getTimezoneOffset(),
      rl_random: (p, n) => {
        const b = new Uint8Array(n);
        for (let i = 0; i < n; i += 65536) crypto.getRandomValues(b.subarray(i, Math.min(n, i + 65536)));
        rt.u8().set(b, p);
      },
      rl_exit: (code) => {
        rt.flushConsole();
        rt.exited = code;
        throw new RetroExit(code);
      },
      rl_abort: (why) => {
        rt.flushConsole();
        const msg = rt.str(why);
        rt.exited = 134;
        throw new Error("The program stopped: " + msg);
      },
      rl_env: (buf, cap) => {
        const parts = Object.entries(rt.env).map(([k, v]) => textEncoder.encode(k + "=" + v + "\0"));
        const total = parts.reduce((a, e) => a + e.length, 0);
        if (buf && total <= cap) {
          const m = rt.u8();
          let at = buf;
          for (const e of parts) { m.set(e, at); at += e.length; }
        }
        return total;
      },
    };
    for (const f of ["sin", "cos", "tan", "asin", "acos", "atan", "sinh", "cosh", "tanh", "asinh",
                     "acosh", "atanh", "exp", "expm1", "log", "log2", "log10", "log1p", "cbrt",
                     "atan2", "pow", "hypot"])
      env["m_" + f] = Math[f];
    env.m_fmod = (x, y) => x % y;
    // threads (a build with them): workers started, their calls served
    env.rl_cpus = () => (typeof navigator !== "undefined" && navigator.hardwareConcurrency) || 1;
    env.rl_thread_spawn = (t, top, tls) => rt.threads ? rt.threads.spawn(t, top, tls) : -1;
    env.rl_thread_exit = () => { throw new Error("the page's own thread cannot end as a thread"); };
    env.rl_thread_serve = () => { if (rt.threads) rt.threads.serve(); };
    if (this.driver) Object.assign(env, this.driver.imports(this));
    if (this.opts.imports) Object.assign(env, this.opts.imports);
    if (this.memory) env.memory = this.memory;
    return { env };
  }
  async start(wasm, threads) {
    await this.fs.open();
    if (threads) {
      // one memory for the page and its workers, made here at its largest
      const [initial, maximum] = threads.memory || [512, 16384];
      this.memory = new WebAssembly.Memory({ initial, maximum, shared: true });
    }
    const imports = this.imports();
    let module;
    if (wasm instanceof WebAssembly.Module) module = wasm;
    else if (typeof Response !== "undefined" && wasm instanceof Response)
      module = await WebAssembly.compileStreaming(wasm);
    else module = await WebAssembly.compile(wasm);
    this.module = module;
    this.instance = await WebAssembly.instantiate(module, imports);
    const ex = this.instance.exports;
    if (threads) {
      // (the workers after the page's instance: it set up the memory)
      this.threads = new RetroThreads(this, threads.workers > 0 ? threads.workers
        : Math.max(2, Math.min(8, env_cpus())));
      await this.threads.start(module, imports.env);
    }
    try {
      if (ex._initialize) ex._initialize();
      if (ex.NimMain) ex.NimMain();
      else if (ex.main) ex.main(0, 0);
    } catch (e) {
      if (!(e instanceof RetroExit)) throw e;
    }
    this.flushConsole();
    // (a program without windows has no frames: it ran in NimMain)
    if (this.driver && this.exited === null && ex.retro_frame) this.driver.run(this);
    return this;
  }
}

// ---- the toolkit's browser driver: a canvas, input, text, sound, pages ----------------------------

const CURSORS = ["default", "default", "text", "wait", "crosshair", "pointer", "ns-resize",
                 "ew-resize", "nwse-resize", "nesw-resize", "move"];
const EV = { move: 1, down: 2, up: 3, wheel: 4, keyDown: 5, keyUp: 6, text: 7, resize: 8,
             focus: 9, blur: 10, hide: 11, show: 12, compose: 13, leave: 14, close: 15, drop: 16 };

class RetroWeb {
  constructor(root) {
    this.root = root;                 // the element the app fills
    this.events = [];
    this.lastText = "";
    this.pending = false;
    this.timer = 0;
    this.fonts = [null];
    this.images = new Map();
    this.pages = new Map();
    this.clip = "";
    this.wheelAcc = [0, 0];
    this.wantText = false;
    this.stopped = false;
  }
  dpr() { return (typeof devicePixelRatio === "number" && devicePixelRatio > 0) ? devicePixelRatio : 1; }
  push(e) {
    this.events.push(e);
    this.schedule();
  }
  mods(e) {
    let m = 0;
    if (e.shiftKey) m |= 1;
    // (Cmd on a Mac is the app's Ctrl, as on the native macOS driver)
    const mac = typeof navigator !== "undefined" && /Mac|iPhone|iPad/.test(navigator.platform || "");
    if (mac ? e.metaKey : e.ctrlKey) m |= 2;
    if (e.altKey) m |= 4;
    if (mac ? e.ctrlKey : e.metaKey) m |= 8;
    return m;
  }
  at(e) {
    const r = this.canvas.getBoundingClientRect();
    const k = this.dpr();
    return [Math.floor((e.clientX - r.left) * k), Math.floor((e.clientY - r.top) * k)];
  }
  open() {
    const root = this.root;
    if (getComputedStyle(root).position === "static") root.style.position = "relative";
    const c = this.canvas = document.createElement("canvas");
    c.style.cssText = "position:absolute;left:0;top:0;width:100%;height:100%;touch-action:none;outline:none";
    c.tabIndex = -1;
    root.appendChild(c);
    // the frame through WebGL 2 (the changed rows uploaded straight from
    // the program's memory, no copy in script); a 2D canvas where there is
    // none (or `Retro.boot({ gl: false })`)
    if (this.rt.opts.gl !== false) this.gl = this.startGl(c);
    if (!this.gl) this.ctx2d = c.getContext("2d", { alpha: false });
    c.addEventListener("webglcontextlost", (e) => { e.preventDefault(); this.glLost = true; });
    c.addEventListener("webglcontextrestored", () => {
      this.glLost = false;
      this.gl = this.startGl(c);
      this.push({ kind: EV.resize, full: true });   // (everything drawn again)
    });
    // a text box out of sight: where the keyboard types (dead keys, input methods, phones' keyboards)
    const t = this.input = document.createElement("textarea");
    t.setAttribute("autocapitalize", "off");
    t.setAttribute("autocomplete", "off");
    t.setAttribute("autocorrect", "off");
    t.setAttribute("spellcheck", "false");
    t.setAttribute("aria-hidden", "true");
    t.style.cssText = "position:absolute;left:0;top:0;width:2px;height:20px;opacity:0;padding:0;border:0;" +
                      "resize:none;overflow:hidden;font-size:16px;z-index:-1";
    root.appendChild(t);
    this.size();
    this.listen();
    setTimeout(() => t.focus({ preventScroll: true }), 0);
  }
  startGl(c) {
    let gl;
    try { gl = c.getContext("webgl2", { alpha: false, antialias: false, depth: false, stencil: false,
                                         preserveDrawingBuffer: true, premultipliedAlpha: false }); }
    catch (e) { gl = null; }
    if (!gl) return null;
    const sh = (kind, src) => {
      const o = gl.createShader(kind);
      gl.shaderSource(o, src);
      gl.compileShader(o);
      return gl.getShaderParameter(o, gl.COMPILE_STATUS) ? o : null;
    };
    const vs = sh(gl.VERTEX_SHADER, `#version 300 es
in vec2 p; out vec2 uv;
void main() { uv = vec2(p.x * 0.5 + 0.5, 0.5 - p.y * 0.5); gl_Position = vec4(p, 0.0, 1.0); }`);
    // (the program's pixels are 0x..RRGGBB: bytes B, G, R, x -- swapped here)
    const fs = sh(gl.FRAGMENT_SHADER, `#version 300 es
precision mediump float; uniform sampler2D t; in vec2 uv; out vec4 o;
void main() { vec4 c = texture(t, uv); o = vec4(c.b, c.g, c.r, 1.0); }`);
    if (!vs || !fs) return null;
    const prog = gl.createProgram();
    gl.attachShader(prog, vs);
    gl.attachShader(prog, fs);
    gl.linkProgram(prog);
    if (!gl.getProgramParameter(prog, gl.LINK_STATUS)) return null;
    gl.useProgram(prog);
    const buf = gl.createBuffer();
    gl.bindBuffer(gl.ARRAY_BUFFER, buf);
    gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 1, -1, -1, 1, 1, 1]), gl.STATIC_DRAW);
    const at = gl.getAttribLocation(prog, "p");
    gl.enableVertexAttribArray(at);
    gl.vertexAttribPointer(at, 2, gl.FLOAT, false, 0, 0);
    this.tex = gl.createTexture();
    gl.bindTexture(gl.TEXTURE_2D, this.tex);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
    this.texW = this.texH = 0;
    return gl;
  }
  presentGl(px, stride, x, y, w, h, fullW, fullH) {
    const gl = this.gl;
    if (this.glLost || gl.isContextLost()) return;
    if (this.texW !== fullW || this.texH !== fullH) {
      gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA8, fullW, fullH, 0, gl.RGBA, gl.UNSIGNED_BYTE, null);
      this.texW = fullW;
      this.texH = fullH;
      x = 0; y = 0; w = fullW; h = fullH;               // (all of it, the first time)
    }
    gl.pixelStorei(gl.UNPACK_ROW_LENGTH, stride);
    gl.pixelStorei(gl.UNPACK_SKIP_PIXELS, x);
    gl.pixelStorei(gl.UNPACK_SKIP_ROWS, y);
    gl.texSubImage2D(gl.TEXTURE_2D, 0, x, y, w, h, gl.RGBA, gl.UNSIGNED_BYTE,
                     new Uint8Array(this.rt.mem.buffer, px, stride * (y + h) * 4));
    gl.viewport(0, 0, fullW, fullH);
    gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4);
  }
  size() {
    const r = this.root.getBoundingClientRect();
    const k = this.dpr();
    const w = Math.max(1, Math.round(r.width * k)), h = Math.max(1, Math.round(r.height * k));
    if (this.canvas.width !== w || this.canvas.height !== h) {
      this.canvas.width = w;
      this.canvas.height = h;
      this.img = null;
    }
    this.w = w;
    this.h = h;
    this.scale = Math.round(k * 100);
  }
  listen() {
    const c = this.canvas, t = this.input;
    const pointer = (kind) => (e) => {
      const [x, y] = this.at(e);
      const flags = (e.pointerType === "touch" ? 0 : 1) | (e.pointerType === "pen" ? 2 : 0);
      const button = kind === EV.move ? 0 : [0, 1, 2, 3, 4][e.button] || 0;
      if (kind === EV.down) {
        c.setPointerCapture(e.pointerId);
        t.focus({ preventScroll: true });
        this.resumeAudio();
      }
      this.push({ kind, x, y, button, mods: this.mods(e), flags, pressure: e.pressure || 0 });
      if (kind !== EV.move) e.preventDefault();
    };
    c.addEventListener("pointerdown", pointer(EV.down));
    c.addEventListener("pointerup", pointer(EV.up));
    c.addEventListener("pointercancel", pointer(EV.up));
    c.addEventListener("pointermove", (e) => {
      // (every sample the browser kept, not just the last)
      const list = e.getCoalescedEvents ? e.getCoalescedEvents() : [e];
      pointer(EV.move)(list.length ? list[list.length - 1] : e);
    });
    c.addEventListener("pointerleave", (e) => {
      if (!e.buttons) this.push({ kind: EV.leave, mods: this.mods(e) });
    });
    c.addEventListener("contextmenu", (e) => e.preventDefault());
    c.addEventListener("wheel", (e) => {
      e.preventDefault();
      // notches: a wheel's line is a notch's third; a touch pad's pixels, a hundredth
      const unit = e.deltaMode === 1 ? 1 / 3 : e.deltaMode === 2 ? 3 : 1 / 100;
      this.wheelAcc[0] += e.deltaX * unit;
      this.wheelAcc[1] += -e.deltaY * unit;
      const dx = Math.trunc(this.wheelAcc[0]), dy = Math.trunc(this.wheelAcc[1]);
      if (dx || dy) {
        this.wheelAcc[0] -= dx;
        this.wheelAcc[1] -= dy;
        this.push({ kind: EV.wheel, dx, dy, mods: this.mods(e) });
      }
    }, { passive: false });
    // keys
    let pasteKey = null;
    t.addEventListener("keydown", (e) => {
      if (e.isComposing || e.keyCode === 229) return;
      const ev = { kind: EV.keyDown, key: e.code || e.key, mods: this.mods(e) };
      const m = ev.mods;
      const printable = e.key.length === 1 && !(m & 2) && !(m & 8);
      if ((m & 2) && (e.code === "KeyV")) {
        // (the paste that follows brings the clipboard's text first)
        pasteKey = ev;
        setTimeout(() => { if (pasteKey) { this.push(pasteKey); pasteKey = null; } }, 60);
        return;
      }
      if ((m & 2) && (e.code === "KeyC" || e.code === "KeyX")) {
        this.push(ev);           // (the app puts the text on the clipboard: rw_clip_put)
        return;
      }
      this.push(ev);
      if (!printable) e.preventDefault();
    });
    t.addEventListener("keyup", (e) => {
      this.push({ kind: EV.keyUp, key: e.code || e.key, mods: this.mods(e) });
    });
    t.addEventListener("input", (e) => {
      if (e.isComposing) return;
      const v = t.value;
      t.value = "";
      if (v) this.push({ kind: EV.text, text: v });
    });
    t.addEventListener("compositionupdate", (e) => {
      this.push({ kind: EV.compose, text: e.data || "", x: textEncoder.encode(e.data || "").length });
    });
    t.addEventListener("compositionend", (e) => {
      this.push({ kind: EV.compose, text: "", x: 0 });
      t.value = "";
      if (e.data) this.push({ kind: EV.text, text: e.data });
    });
    t.addEventListener("paste", (e) => {
      const s = e.clipboardData ? e.clipboardData.getData("text/plain") : "";
      if (s) this.clip = s;
      e.preventDefault();
      if (pasteKey) { this.push(pasteKey); pasteKey = null; }
    });
    t.addEventListener("copy", (e) => {
      if (e.clipboardData && this.clip) { e.clipboardData.setData("text/plain", this.clip); e.preventDefault(); }
    });
    t.addEventListener("cut", (e) => {
      if (e.clipboardData && this.clip) { e.clipboardData.setData("text/plain", this.clip); e.preventDefault(); }
    });
    // the window
    const resized = () => {
      const was = [this.w, this.h, this.scale];
      this.size();
      if (was[0] !== this.w || was[1] !== this.h || was[2] !== this.scale) this.push({ kind: EV.resize });
    };
    if (typeof ResizeObserver !== "undefined") new ResizeObserver(resized).observe(this.root);
    addEventListener("resize", resized);
    addEventListener("focus", () => this.push({ kind: EV.focus }));
    addEventListener("blur", () => this.push({ kind: EV.blur }));
    document.addEventListener("visibilitychange", () =>
      this.push({ kind: document.hidden ? EV.hide : EV.show }));
    // files dropped on the page: into /tmp/dropped, their paths to the app
    c.addEventListener("dragover", (e) => e.preventDefault());
    c.addEventListener("drop", async (e) => {
      e.preventDefault();
      const [x, y] = this.at(e);
      const paths = [];
      for (const f of e.dataTransfer ? e.dataTransfer.files : []) {
        const p = "/tmp/dropped/" + f.name.replace(/[\/\\]/g, "_");
        this.rt.fs.addFile(p, new Uint8Array(await f.arrayBuffer()));
        paths.push(p);
      }
      if (paths.length) this.push({ kind: EV.drop, x, y, text: paths.join("\n") });
    });
  }
  // the frames
  schedule() {
    if (this.pending || this.stopped || !this.rt) return;
    this.pending = true;
    requestAnimationFrame(() => this.frame());
  }
  frame() {
    this.pending = false;
    if (this.stopped) return;
    if (this.timer) { clearTimeout(this.timer); this.timer = 0; }
    let wait;
    try {
      wait = this.rt.instance.exports.retro_frame();
    } catch (e) {
      this.stopped = true;
      this.rt.flushConsole();
      if (e instanceof RetroExit) return;
      this.fail(e);
      return;
    }
    this.rt.flushConsole();
    this.handOff();
    if (wait === -2) {
      this.stopped = true;
      if (this.rt.threads) this.rt.threads.stop();
      this.rt.fs.save();
      if (this.rt.opts.onExit) this.rt.opts.onExit();
      else this.ended();
      return;
    }
    if (wait === -3) {
      // an error the program did not catch (its message went to the console)
      this.stopped = true;
      this.fail(this.rt.lastError || "an error the program did not catch");
      return;
    }
    if (wait === 0 || this.events.length) this.schedule();
    else if (wait > 0) this.timer = setTimeout(() => { this.timer = 0; this.schedule(); }, wait);
  }
  // the program ended (File, Exit): the window closes when the browser
  // lets it (a page opened by a script, an installed app); else the page
  // says so and offers to start it again
  ended() {
    for (const v of (this.videos || new Map()).values()) v.v.pause();
    if (this.audio) this.audio.suspend().catch(() => {});
    try { window.close(); } catch (e) {}
    setTimeout(() => {
      const d = document.createElement("div");
      d.setAttribute("role", "dialog");
      d.style.cssText = "position:absolute;inset:0;display:flex;align-items:center;justify-content:center;" +
                        "background:#008080;font:14px system-ui,sans-serif;z-index:10";
      const box = document.createElement("div");
      box.style.cssText = "background:#c0c0c0;border:2px solid;border-color:#fff #000 #000 #fff;" +
                          "box-shadow:2px 2px 0 #000;min-width:260px;text-align:center";
      const title = document.createElement("div");
      title.style.cssText = "background:#000080;color:#fff;font-weight:bold;padding:3px 6px;text-align:left";
      title.textContent = document.title || "The app";
      const text = document.createElement("p");
      text.style.cssText = "margin:18px 16px";
      text.textContent = (document.title || "The app") + " has ended.";
      const again = document.createElement("button");
      again.textContent = "Start again";
      again.style.cssText = "margin:0 0 14px;padding:4px 18px;font:inherit;background:#c0c0c0;" +
                            "border:2px solid;border-color:#fff #000 #000 #fff;cursor:pointer";
      again.onclick = () => location.reload();
      box.append(title, text, again);
      d.appendChild(box);
      this.root.appendChild(d);
      again.focus();
    }, 150);
  }
  // files written in /downloads, done (not open, not a temporary name):
  // to the user -- the browser's "Save as" while the click that asked is
  // fresh (Chrome, Edge), a download else
  handOff() {
    const fs = this.rt.fs;
    if (!fs.fresh.size) return;
    for (const p of Array.from(fs.fresh)) {
      const name = p.slice(p.lastIndexOf("/") + 1);
      if (!name || name.startsWith(".") || /(\.tmp|\.part|~)$/.test(name)) { fs.fresh.delete(p); continue; }
      let open = false;
      for (const f of fs.fds.values()) if (f.p === p) open = true;
      if (open) continue;
      fs.fresh.delete(p);
      const n = fs.nodes.get(p);
      if (!n || n.dir) continue;
      this.give(name, n.data.slice(0, n.size));
    }
  }
  give(name, data) {
    const download = () => {
      const a = document.createElement("a");
      a.href = URL.createObjectURL(new Blob([data]));
      a.download = name;
      document.body.appendChild(a);
      a.click();
      a.remove();
      setTimeout(() => URL.revokeObjectURL(a.href), 30000);
    };
    const fresh = typeof navigator !== "undefined" && navigator.userActivation ? navigator.userActivation.isActive : false;
    if (typeof showSaveFilePicker === "function" && fresh && !navigator.webdriver && !this.rt.opts.downloads) {
      showSaveFilePicker({ suggestedName: name })
        .then((h) => h.createWritable())
        .then(async (w) => { await w.write(data); await w.close(); })
        .catch((e) => { if (!e || e.name !== "AbortError") download(); });
    } else download();
  }
  fail(e) {
    console.error(e);
    const d = document.createElement("pre");
    d.style.cssText = "position:absolute;left:8px;right:8px;bottom:8px;margin:0;padding:8px;" +
                      "background:#fff;color:#a00;border:2px solid #a00;font:12px monospace;white-space:pre-wrap";
    d.textContent = "The program stopped: " + (e && e.stack || e);
    this.root.appendChild(d);
  }
  run(rt) {
    this.rt = rt;
    this.schedule();
  }
  // sound: the program mixes (retro_audio), an AudioWorklet plays; the
  // worklet asks for more when its buffer runs low (asked by message, so
  // a page in the background keeps playing), a ScriptProcessor where
  // there are no worklets (an old browser, a page not served over https)
  startAudio(rate, channels) {
    if (this.audio || typeof AudioContext === "undefined") return;
    let ctx;
    try { ctx = new AudioContext({ sampleRate: rate, latencyHint: "interactive" }); } catch (e) { ctx = new AudioContext(); }
    this.audio = ctx;
    const ex = this.rt.instance.exports;
    const chunk = 1024;
    const buf = ex.malloc(chunk * 2 * 2);
    const pull = () => {
      ex.retro_audio(buf, chunk * 2);
      const s = new Int16Array(this.rt.mem.buffer, buf, chunk * 2);
      const out = new Float32Array(chunk * 2);
      for (let i = 0; i < chunk * 2; i++) out[i] = s[i] / 32768;
      return out;
    };
    const scriptProcessor = () => {
      const node = ctx.createScriptProcessor(chunk, 0, 2);
      node.onaudioprocess = (e) => {
        if (this.stopped) return;
        const f = pull();
        const l = e.outputBuffer.getChannelData(0), r = e.outputBuffer.getChannelData(1);
        for (let i = 0; i < chunk; i++) { l[i] = f[2 * i]; r[i] = f[2 * i + 1]; }
      };
      node.connect(ctx.destination);
    };
    if (ctx.audioWorklet && typeof AudioWorkletNode !== "undefined") {
      const code = `class RetroSound extends AudioWorkletProcessor {
  constructor() {
    super();
    this.q = []; this.at = 0; this.queued = 0; this.asked = false;
    this.port.onmessage = (e) => { this.q.push(e.data); this.queued += e.data.length / 2; this.asked = false; };
  }
  process(inputs, outputs) {
    const l = outputs[0][0], r = outputs[0][1] || outputs[0][0];
    for (let i = 0; i < l.length; i++) {
      if (!this.q.length) { l[i] = 0; r[i] = 0; continue; }
      const b = this.q[0];
      l[i] = b[this.at]; r[i] = b[this.at + 1];
      this.at += 2; this.queued--;
      if (this.at >= b.length) { this.q.shift(); this.at = 0; }
    }
    if (this.queued < 3072 && !this.asked) { this.asked = true; this.port.postMessage(0); }
    return true;
  }
}
registerProcessor("retro-sound", RetroSound);`;
      const url = URL.createObjectURL(new Blob([code], { type: "text/javascript" }));
      ctx.audioWorklet.addModule(url).then(() => {
        const node = new AudioWorkletNode(ctx, "retro-sound", { numberOfInputs: 0, outputChannelCount: [2] });
        node.port.onmessage = () => {
          if (this.stopped) return;
          // (a few chunks: about 70 ms ahead)
          for (let k = 0; k < 3; k++) { const f = pull(); node.port.postMessage(f, [f.buffer]); }
        };
        node.connect(ctx.destination);
        node.port.onmessage();
      }).catch(() => scriptProcessor());
    } else scriptProcessor();
    this.resumeAudio();
  }
  resumeAudio() {
    if (this.audio && this.audio.state === "suspended") this.audio.resume().catch(() => {});
  }
  // the system's features (`systemCall(name, arg)` in the program,
  // `retroui/system`): each answers a string; what the browser answers
  // later (a place, a battery, a file picked) is asked again each frame
  call(name, arg) {
    const nav = typeof navigator !== "undefined" ? navigator : {};
    const json = () => { try { return JSON.parse(arg || "{}"); } catch (e) { return {}; } };
    const st = this.sys = this.sys || {};
    switch (name) {
    case "notify": {
      if (typeof Notification === "undefined") return "0";
      const o = json();
      const show = () => {
        try {
          const n = new Notification(o.title || document.title, { body: o.body || "", tag: o.tag || undefined,
                                                                 icon: o.icon || "icon-192.png" });
          n.onclick = () => { try { window.focus(); } catch (e) {} n.close(); };
          (st.notes = st.notes || new Map()).set(o.tag || "", n);
        } catch (e) {
          // (Chrome on Android: only through the service worker)
          if (nav.serviceWorker) nav.serviceWorker.ready.then((r) => r.showNotification(o.title || "", { body: o.body || "", tag: o.tag || undefined, icon: "icon-192.png" })).catch(() => {});
        }
      };
      if (Notification.permission === "granted") { show(); return "1"; }
      if (Notification.permission === "denied") return "0";
      Notification.requestPermission().then((p) => { if (p === "granted") show(); this.schedule(); });
      return "1";
    }
    case "notify.close": {
      const n = st.notes && st.notes.get(arg || "");
      if (n) n.close();
      return "1";
    }
    case "notify.allowed":
      return typeof Notification === "undefined" ? "no" : Notification.permission;
    case "badge":
      if (!nav.setAppBadge) return "0";
      (+arg > 0 ? nav.setAppBadge(+arg) : nav.clearAppBadge()).catch(() => {});
      return "1";
    case "vibrate":
      return nav.vibrate && nav.vibrate(arg.split(",").map(Number)) ? "1" : "0";
    case "wakelock":
      if (!nav.wakeLock) return "0";
      st.wantAwake = arg === "1";
      if (!st.awakeHooked) {
        st.awakeHooked = true;
        document.addEventListener("visibilitychange", () => {
          if (st.wantAwake && document.visibilityState === "visible")
            nav.wakeLock.request("screen").then((l) => { st.wake = l; }).catch(() => {});
        });
      }
      if (st.wantAwake) nav.wakeLock.request("screen").then((l) => { st.wake = l; }).catch(() => {});
      else if (st.wake) { st.wake.release().catch(() => {}); st.wake = null; }
      return "1";
    case "battery":
      if (!nav.getBattery) return "-1";
      if (!st.battery) {
        st.battery = { level: -1, charging: false };
        nav.getBattery().then((b) => {
          const upd = () => { st.battery = { level: Math.round(b.level * 100), charging: b.charging }; this.schedule(); };
          b.addEventListener("levelchange", upd);
          b.addEventListener("chargingchange", upd);
          upd();
        }).catch(() => {});
      }
      return st.battery.level + (st.battery.charging ? " charging" : "");
    case "dark":
      return typeof matchMedia !== "undefined" && matchMedia("(prefers-color-scheme: dark)").matches ? "1" : "0";
    case "online":
      return nav.onLine === false ? "0" : "1";
    case "metered": {
      const c = nav.connection;
      return c && (c.saveData || c.type === "cellular") ? "1" : "0";
    }
    case "prefs": {
      const m = (q) => typeof matchMedia !== "undefined" && matchMedia(q).matches ? "1" : "0";
      return m("(prefers-reduced-motion: reduce)") + " " + m("(prefers-contrast: more)");
    }
    case "language":
      return nav.language || "en";
    case "device": {
      const ua = nav.userAgentData;
      const brand = ua && ua.brands ? (ua.brands.find((b) => !/Not.A|Chromium/i.test(b.brand)) || ua.brands[0]) : null;
      const m = /(Firefox|Edg|OPR|Chrome|Safari)\/(\d+)/.exec(nav.userAgent || "");
      const name = brand ? brand.brand + " " + brand.version : m ? m[1].replace("Edg", "Edge").replace("OPR", "Opera") + " " + m[2] : "A browser";
      const os = ua && ua.platform ? ua.platform : /Android/.test(nav.userAgent) ? "Android" :
                 /iPhone|iPad/.test(nav.userAgent) ? "iOS" : /Mac/.test(nav.platform || "") ? "macOS" :
                 /Win/.test(nav.platform || "") ? "Windows" : /Linux/.test(nav.platform || "") ? "Linux" : "";
      return name + (os ? " on " + os : "");
    }
    case "cpus":
      return String(nav.hardwareConcurrency || 1);
    case "share": {
      const o = json();
      if (!nav.share) return "0";
      const data = {};
      if (o.title) data.title = o.title;
      if (o.text) data.text = o.text;
      if (o.url) data.url = o.url;
      if (o.files && o.files.length && typeof File !== "undefined") {
        const files = [];
        for (const p of o.files) {
          const n = this.rt.fs.nodes.get(this.rt.fs.norm(p));
          if (n && !n.dir && this.rt.fs.load(n)) files.push(new File([n.data.slice(0, n.size)], p.slice(p.lastIndexOf("/") + 1)));
        }
        if (files.length && (!nav.canShare || nav.canShare({ files }))) data.files = files;
      }
      nav.share(data).catch(() => {});
      return "1";
    }
    case "location": {
      if (!nav.geolocation) return "none";
      if (!st.place) {
        st.place = "waiting";
        st.placeWatch = nav.geolocation.watchPosition((p) => {
          st.place = "ok " + p.coords.latitude + " " + p.coords.longitude + " " + Math.round(p.coords.accuracy);
          this.schedule();
        }, (e) => { st.place = e.code === 1 ? "denied" : "none"; this.schedule(); },
        { enableHighAccuracy: arg === "fine", maximumAge: 30000, timeout: 30000 });
      }
      return st.place;
    }
    case "location.stop":
      if (st.placeWatch !== undefined && nav.geolocation) nav.geolocation.clearWatch(st.placeWatch);
      st.place = null;
      return "1";
    case "speak": {
      if (typeof speechSynthesis === "undefined") return "0";
      const o = json();
      const u = new SpeechSynthesisUtterance(o.text || "");
      if (o.lang) u.lang = o.lang;
      if (o.rate) u.rate = o.rate;
      u.onend = () => this.schedule();
      speechSynthesis.speak(u);
      return "1";
    }
    case "speak.stop":
      if (typeof speechSynthesis !== "undefined") speechSynthesis.cancel();
      return "1";
    case "speaking":
      return typeof speechSynthesis !== "undefined" && speechSynthesis.speaking ? "1" : "0";
    case "attention": {
      if (document.hasFocus()) return "1";
      const was = document.title;
      let on = false;
      clearInterval(st.blink);
      st.blink = setInterval(() => {
        if (document.hasFocus()) { clearInterval(st.blink); document.title = was; return; }
        on = !on;
        document.title = on ? "\u2022 " + (arg || was) : was;
      }, 900);
      return "1";
    }
    case "pick": {
      // the browser's own file chooser (the click that asked is still fresh)
      const o = json();
      const inp = document.createElement("input");
      inp.type = "file";
      if (o.accept) inp.accept = o.accept;
      if (o.multiple) inp.multiple = true;
      if (o.folder) inp.webkitdirectory = true;
      inp.style.display = "none";
      st.pick = "";
      inp.addEventListener("change", async () => {
        const paths = [];
        for (const f of inp.files) {
          const p = "/tmp/opened/" + (f.webkitRelativePath || f.name).replace(/[\\]/g, "_");
          this.rt.fs.addFile(p, new Uint8Array(await f.arrayBuffer()));
          paths.push(p);
        }
        st.pick = paths.length ? paths.join("\n") : "\u0001";
        inp.remove();
        this.schedule();
      });
      inp.addEventListener("cancel", () => { st.pick = "\u0001"; inp.remove(); this.schedule(); });
      document.body.appendChild(inp);
      inp.click();
      return "1";
    }
    case "pick.result": {
      const r = st.pick || "";
      if (r) st.pick = "";
      return r;
    }
    case "fullscreen":
      if (arg === "1") { if (this.root.requestFullscreen) this.root.requestFullscreen().catch(() => {}); }
      else if (document.fullscreenElement) document.exitFullscreen().catch(() => {});
      return "1";
    case "beep": {
      if (typeof AudioContext === "undefined") return "0";
      const c = st.beepCtx = st.beepCtx || new AudioContext();
      const o = c.createOscillator(), g = c.createGain();
      o.frequency.value = 880;
      g.gain.setValueAtTime(0.25, c.currentTime);
      g.gain.exponentialRampToValueAtTime(0.001, c.currentTime + 0.12);
      o.connect(g).connect(c.destination);
      o.start();
      o.stop(c.currentTime + 0.13);
      return "1";
    }
    case "canplay": {
      const v = document.createElement("video");
      return v.canPlayType && v.canPlayType(arg) ? "1" : "0";
    }
    case "print": {
      // a PDF in a frame of its own, printed by the browser (its print dialog)
      const n = this.rt.fs.nodes.get(this.rt.fs.norm(arg));
      if (!n || n.dir || !this.rt.fs.load(n)) return "0";
      const url = URL.createObjectURL(new Blob([n.data.slice(0, n.size)], { type: "application/pdf" }));
      const f = document.createElement("iframe");
      f.style.cssText = "position:fixed;right:0;bottom:0;width:1px;height:1px;border:0;opacity:0";
      f.onload = () => {
        setTimeout(() => {
          try { f.contentWindow.focus(); f.contentWindow.print(); }
          catch (e) { window.open(url, "_blank"); }         // (a browser that will not print a frame: the PDF in a tab)
          setTimeout(() => { f.remove(); URL.revokeObjectURL(url); }, 60000);
        }, 300);
      };
      f.src = url;
      document.body.appendChild(f);
      return "1";
    }
    // ---- updates (retroui/update): the newest build through the service
    // worker, the page loaded again with it ----
    case "update.web": {
      if (!nav.serviceWorker || !nav.serviceWorker.getRegistration) return "0";
      nav.serviceWorker.getRegistration().then((reg) => {
        if (!reg) { location.reload(); return; }
        nav.serviceWorker.addEventListener("controllerchange", () => location.reload(), { once: true });
        reg.update().then(() => { if (!reg.installing && !reg.waiting) location.reload(); })
          .catch(() => location.reload());
      });
      return "1";
    }
    case "update.reload":
      setTimeout(() => location.reload(), 50);
      return "1";
    // ---- signing in (retroui/oauth): the sign-in page in a window of its
    // own; oauth.html (beside the page) posts back where it came to ----
    case "page.url":
      try { return new URL(arg, document.baseURI).href; } catch (e) { return ""; }
    case "oauth.open": {
      const id = (st.nextSignIn = (st.nextSignIn || 0) + 1);
      const w = typeof window !== "undefined" ? window.open(arg, "retro-signin-" + id, "popup,width=520,height=680") : null;
      if (!w) return "0";
      (st.signIns = st.signIns || new Map()).set(id, { w, got: "" });
      if (!st.signInHooked) {
        // (the answer: posted by oauth.html to its opener, and on a
        // BroadcastChannel -- a page kept apart for threads has no opener
        // once the window went to the sign-in's site)
        st.signInHooked = true;
        const take = (q) => {
          const all = [...st.signIns.values()].filter((v) => !v.got);
          if (all.length) all[all.length - 1].got = q || "?";
          this.schedule();
        };
        window.addEventListener("message", (e) => {
          if (e.origin === location.origin && e.data && e.data.retroSignIn != null) take(e.data.retroSignIn);
        });
        try { new BroadcastChannel("retro-signin").onmessage = (e) => take(e.data); } catch (e) {}
      }
      return String(id);
    }
    case "oauth.result": {
      const s = st.signIns && st.signIns.get(+arg);
      if (!s) return "\x01";
      if (s.got) { st.signIns.delete(+arg); return s.got; }
      // (closed by the user; a window cut off from an isolated page says
      // closed while it is open: there the time it has decides)
      if (s.w.closed && !self.crossOriginIsolated) { st.signIns.delete(+arg); return "\x01"; }
      return "";
    }
    case "oauth.close": {
      const s = st.signIns && st.signIns.get(+arg);
      if (s) { try { s.w.close(); } catch (e) {} st.signIns.delete(+arg); }
      return "1";
    }
    // ---- WebSockets (chat: XMPP over a WebSocket, retroui/xmpp): what
    // comes kept until the program takes it ----
    case "ws.open": {
      if (typeof WebSocket === "undefined") return "0";
      const id = (st.nextWs = (st.nextWs || 0) + 1);
      const w = { got: [], state: "connecting" };
      (st.ws = st.ws || new Map()).set(id, w);
      try {
        w.s = new WebSocket(arg, /xmpp/i.test(arg) ? "xmpp" : undefined);
        w.s.onopen = () => { w.state = "open"; };
        w.s.onmessage = (e) => { w.got.push(typeof e.data === "string" ? e.data : ""); this.schedule(); };
        w.s.onclose = () => { w.state = "closed"; this.schedule(); };
        w.s.onerror = () => { w.state = "closed"; };
      } catch (e) { w.state = "closed"; }
      return String(id);
    }
    case "ws.state": {
      const w = st.ws && st.ws.get(+arg);
      return w ? w.state : "closed";
    }
    case "ws.send": {
      const i = arg.indexOf("\n"), w = st.ws && st.ws.get(+arg.slice(0, i));
      if (!w || w.state !== "open") return "0";
      w.s.send(arg.slice(i + 1));
      return "1";
    }
    case "ws.recv": {
      const w = st.ws && st.ws.get(+arg);
      if (!w) return "\x01";
      if (w.got.length) return w.got.splice(0).join("");
      return w.state === "closed" ? "\x01" : "";
    }
    case "ws.close": {
      const w = st.ws && st.ws.get(+arg);
      if (w) { try { w.s.close(); } catch (e) {} st.ws.delete(+arg); }
      return "1";
    }
    // ---- screen readers: the window's controls mirrored as ARIA ----
    case "access.on":
      return this.rt.opts.accessible === false ? "0" : "1";
    case "access.take":
      return (st.accessAsked || []).splice(0).join("\n");
    case "access.say": {
      this.accessSay(arg, true);
      return "1";
    }
    case "installed":
      return typeof matchMedia !== "undefined" && matchMedia("(display-mode: standalone)").matches ? "1" : "0";
    // ---- the camera (retroui/capture): a stream into a hidden <video>,
    // its pictures read by rw_camera_frame ----
    case "camera.list": {
      // ("id\tname\tfacing" lines; the names once the user allowed a camera)
      if (!nav.mediaDevices || !nav.mediaDevices.enumerateDevices) return "";
      if (!st.camList) {
        st.camList = "";
        nav.mediaDevices.enumerateDevices().then((ds) => {
          st.camList = ds.filter((d) => d.kind === "videoinput").map((d, i) => {
            const l = d.label || "Camera " + (i + 1);
            const f = /back|rear|environment/i.test(l) ? "back" : /front|user|face/i.test(l) ? "front" : "any";
            return (d.deviceId || String(i)) + "\t" + l + "\t" + f;
          }).join("\n");
          this.schedule();
        }).catch(() => {});
      }
      return st.camList;
    }
    case "camera.open": {
      if (!nav.mediaDevices || !nav.mediaDevices.getUserMedia) return "0";
      const o = json();
      const id = (st.nextCam = (st.nextCam || 0) + 1);
      const cam = { state: "waiting", v: document.createElement("video"), frames: 0, seen: 0 };
      cam.v.muted = true;
      cam.v.playsInline = true;
      (st.cams = st.cams || new Map()).set(id, cam);
      const video = { width: { ideal: o.width || 1280 }, height: { ideal: o.height || 720 } };
      if (o.id) video.deviceId = { exact: o.id };
      else if (o.facing === "front") video.facingMode = "user";
      else if (o.facing === "back") video.facingMode = "environment";
      nav.mediaDevices.getUserMedia({ video, audio: false }).then((stream) => {
        if (cam.closed) { stream.getTracks().forEach((t) => t.stop()); return; }
        cam.stream = stream;
        cam.v.srcObject = stream;
        const tick = () => {
          if (cam.closed) return;
          cam.frames++;
          this.schedule();
          if (cam.v.requestVideoFrameCallback) cam.v.requestVideoFrameCallback(tick);
          else setTimeout(tick, 33);
        };
        cam.v.play().then(() => { cam.state = "ok"; tick(); }).catch((e) => { cam.state = "error " + e.message; });
        st.camList = null;                    // (the names, now that it is allowed)
      }).catch((e) => {
        cam.state = e && e.name === "NotAllowedError" ? "denied" : "error " + (e && e.message || e);
        this.schedule();
      });
      return String(id);
    }
    case "camera.state": {
      const cam = st.cams && st.cams.get(+arg);
      return cam ? cam.state : "none";
    }
    case "camera.close": {
      const cam = st.cams && st.cams.get(+arg);
      if (cam) {
        cam.closed = true;
        if (cam.stream) cam.stream.getTracks().forEach((t) => t.stop());
        cam.v.srcObject = null;
        st.cams.delete(+arg);
      }
      return "1";
    }
    // ---- the microphone: its sound kept as 16-bit WAV, written to the
    // app's file when it stops ----
    case "mic.start": {
      if (!nav.mediaDevices || !nav.mediaDevices.getUserMedia || st.mic) return "0";
      const mic = st.mic = { path: arg, state: "waiting", chunks: [], level: 0, rate: 44100, t0: 0 };
      nav.mediaDevices.getUserMedia({ audio: { channelCount: 1, echoCancellation: false }, video: false }).then((stream) => {
        if (mic.stopped) { stream.getTracks().forEach((t) => t.stop()); return; }
        const ctx = new AudioContext();
        const src = ctx.createMediaStreamSource(stream);
        const node = ctx.createScriptProcessor(4096, 1, 1);
        node.onaudioprocess = (e) => {
          const d = e.inputBuffer.getChannelData(0);
          mic.chunks.push(new Float32Array(d));
          let sum = 0;
          for (let i = 0; i < d.length; i++) sum += d[i] * d[i];
          mic.level = Math.min(1, Math.sqrt(sum / d.length) * 3);
        };
        src.connect(node);
        node.connect(ctx.destination);
        Object.assign(mic, { stream, ctx, node, src, rate: ctx.sampleRate, state: "ok", t0: performance.now() });
      }).catch((e) => { mic.state = e && e.name === "NotAllowedError" ? "denied" : "none"; st.mic = null; });
      return "1";
    }
    case "mic.state":
      return st.mic ? st.mic.state : "none";
    case "mic.level":
      return st.mic ? String(st.mic.level) : "0";
    case "mic.stop": {
      const mic = st.mic;
      if (!mic) return "0";
      st.mic = null;
      mic.stopped = true;
      if (!mic.stream) return "0";
      mic.stream.getTracks().forEach((t) => t.stop());
      try { mic.node.disconnect(); mic.src.disconnect(); mic.ctx.close(); } catch (e) {}
      let n = 0;
      for (const c of mic.chunks) n += c.length;
      const wav = new Uint8Array(44 + n * 2), dv = new DataView(wav.buffer);
      const tag = (at, t) => { for (let i = 0; i < 4; i++) wav[at + i] = t.charCodeAt(i); };
      tag(0, "RIFF"); dv.setUint32(4, 36 + n * 2, true); tag(8, "WAVE"); tag(12, "fmt ");
      dv.setUint32(16, 16, true); dv.setUint16(20, 1, true); dv.setUint16(22, 1, true);
      dv.setUint32(24, mic.rate, true); dv.setUint32(28, mic.rate * 2, true);
      dv.setUint16(32, 2, true); dv.setUint16(34, 16, true); tag(36, "data"); dv.setUint32(40, n * 2, true);
      let at = 44;
      for (const c of mic.chunks)
        for (let i = 0; i < c.length; i++, at += 2) dv.setInt16(at, Math.max(-1, Math.min(1, c[i])) * 32767, true);
      this.rt.fs.writeWhole(mic.path, wav);
      return String(Math.round(n * 1000 / mic.rate));
    }
    // ---- the system's media controls (a lock screen, a headset's keys):
    // what plays, its buttons; a button pressed is asked for each frame ----
    case "media.set": {
      if (!nav.mediaSession) return "0";
      const o = json();
      try {
        // (its picture: a file of the app's, handed to the browser as a blob)
        let art = [];
        if (o.art) {
          const n = this.rt.fs.nodes.get(this.rt.fs.norm(o.art));
          if (n && !n.dir && this.rt.fs.load(n)) {
            if (st.artPath !== o.art) {
              if (st.artUrl) URL.revokeObjectURL(st.artUrl);
              st.artPath = o.art;
              st.artUrl = URL.createObjectURL(new Blob([n.data.slice(0, n.size)],
                { type: /\.png$/i.test(o.art) ? "image/png" : "image/jpeg" }));
            }
            art = [{ src: st.artUrl, sizes: "512x512" }];
          }
        }
        nav.mediaSession.metadata = new MediaMetadata({ title: o.title || "", artist: o.artist || "",
          album: o.album || "", artwork: art });
        nav.mediaSession.playbackState = o.playing ? "playing" : "paused";
        st.mediaPressed = st.mediaPressed || [];
        const can = { previoustrack: o.previous, nexttrack: o.next, seekto: o.seek, seekbackward: o.seek,
                      seekforward: o.seek, play: true, pause: true, stop: true };
        for (const a of Object.keys(can)) {
          try {
            nav.mediaSession.setActionHandler(a, can[a] ? (d) => {
              st.mediaPressed.push(a === "seekto" ? "seekto\t" + Math.round((d.seekTime || 0) * 1000) : a);
              this.schedule();
            } : null);
          } catch (e) {}
        }
        if (o.duration > 0 && nav.mediaSession.setPositionState)
          nav.mediaSession.setPositionState({ duration: o.duration, position: Math.min(o.position || 0, o.duration),
                                              playbackRate: 1 });
      } catch (e) { return "0"; }
      return "1";
    }
    case "media.pressed":
      return st.mediaPressed && st.mediaPressed.length ? st.mediaPressed.shift() : "";
    case "media.clear":
      if (nav.mediaSession) { nav.mediaSession.metadata = null; nav.mediaSession.playbackState = "none"; }
      return "1";
    // ---- secrets (retroui/secrets): kept in the page's storage, sealed with
    // a key the browser keeps and will not hand out (WebCrypto, AES-GCM, a
    // key that cannot be exported, in IndexedDB) ----
    case "secret.get": case "secret.set": case "secret.delete": {
      // (opened before the program started: `openSecrets`)
      const sec = st.secrets;
      if (!sec || sec.state !== "ok") return "\x01";
      const o = json();
      if (name === "secret.get") return o.key in sec.values ? "=" + sec.values[o.key] : "";
      if (name === "secret.set") sec.values[o.key] = o.value;
      else if (o.key in sec.values) delete sec.values[o.key];
      else return "1";
      this.saveSecrets(sec);
      return "1";
    }
    }
    return undefined;
  }
  // the 3D view's GPU (`retroui/webgl3d`): a WebGL 2 context of its own,
  // its objects kept here by number; what it draws is read back
  gl3(op, a, b, c, d, e, f, g, h, i) {
    let x = this.g3;
    if (!x) {
      x = this.g3 = { gl: null, objs: [null], epoch: 1 };
      try {
        const cv = typeof OffscreenCanvas !== "undefined" ? new OffscreenCanvas(1, 1) : document.createElement("canvas");
        x.gl = cv.getContext("webgl2", { alpha: false, antialias: false, depth: false, stencil: false,
                                          premultipliedAlpha: false, preserveDrawingBuffer: false });
        if (x.gl) cv.addEventListener("webglcontextlost", (ev) => { ev.preventDefault(); x.epoch++; x.objs = [null]; });
      } catch (err) { x.gl = null; }
    }
    const gl = x.gl;
    if (!gl) return 0;
    if (op === 0) return gl.isContextLost() ? 0 : 1;
    if (op === 1) return x.epoch;
    const o = (k) => x.objs[k] || null;
    const put = (v) => { x.objs.push(v); return x.objs.length - 1; };
    const rt = this.rt;
    const mem = () => rt.mem.buffer;
    const shared = typeof SharedArrayBuffer !== "undefined" && mem() instanceof SharedArrayBuffer;
    const gen = (k, at, make) => { const dv = new DataView(mem()); for (let n = 0; n < k; n++) dv.setUint32(at + 4 * n, put(make()), true); };
    const del = (k, at, kill) => {
      const dv = new DataView(mem());
      for (let n = 0; n < k; n++) {
        const id = dv.getUint32(at + 4 * n, true);
        if (x.objs[id]) { kill(x.objs[id]); x.objs[id] = null; }
      }
    };
    const bytes = (at, len) => shared ? new Uint8Array(mem(), at, len).slice() : new Uint8Array(mem(), at, len);
    switch (op) {
    case 2: gl.viewport(a, b, c, d); break;
    case 3: gl.clearColor(a, b, c, d); break;
    case 4: gl.clear(a); break;
    case 5: gl.enable(a); break;
    case 6: gl.disable(a); break;
    case 7: gl.blendFunc(a, b); break;
    case 8: gl.colorMask(!!a, !!b, !!c, !!d); break;
    case 9: gen(a, b, () => gl.createTexture()); break;
    case 10: del(a, b, (t) => gl.deleteTexture(t)); break;
    case 11: gl.bindTexture(a, o(b)); break;
    case 12: gl.activeTexture(a); break;
    case 13: gl.texImage2D(a, b, c, d, e, f, g, h, i ? bytes(i, d * e * 4) : null); break;
    case 14: gl.texParameteri(a, b, c); break;
    case 15: gl.pixelStorei(a, b); break;
    case 16: {
      const out = new Uint8Array(c * d * 4);
      gl.readPixels(a, b, c, d, e, f, out);
      new Uint8Array(mem(), g, out.length).set(out);
      break;
    }
    case 17: gl.useProgram(o(a)); break;
    case 18: if (o(a)) { gl.deleteProgram(o(a)); x.objs[a] = null; } break;
    case 19: {
      const loc = gl.getUniformLocation(o(a), rt.str(b));
      return loc ? put(loc) : -1;
    }
    case 20: if (a > 0) gl.uniform1i(o(a), b); break;
    case 21: if (a > 0) gl.uniform1f(o(a), b); break;
    case 22: if (a > 0) gl.uniform2f(o(a), b, c); break;
    case 23: if (a > 0) gl.uniform3f(o(a), b, c, d); break;
    case 24: if (a > 0) gl.uniform4f(o(a), b, c, d, e); break;
    case 25: gen(a, b, () => gl.createBuffer()); break;
    case 26: del(a, b, (t) => gl.deleteBuffer(t)); break;
    case 27: gl.bindBuffer(a, o(b)); break;
    case 28: gl.bufferData(a, c ? bytes(c, b) : b, d); break;
    case 29: gl.vertexAttribPointer(a, b, c, !!d, e, f); break;
    case 30: gl.enableVertexAttribArray(a); break;
    case 31: gl.disableVertexAttribArray(a); break;
    case 32: gl.drawArrays(a, b, c); break;
    case 33: gl.drawElements(a, b, c, d); break;
    case 34: gen(a, b, () => gl.createFramebuffer()); break;
    case 35: del(a, b, (t) => gl.deleteFramebuffer(t)); break;
    case 36: gl.bindFramebuffer(a, o(b)); break;
    case 37: gl.framebufferTexture2D(a, b, c, o(d), e); break;
    case 38: return gl.checkFramebufferStatus(a);
    case 39: gen(a, b, () => gl.createRenderbuffer()); break;
    case 40: del(a, b, (t) => gl.deleteRenderbuffer(t)); break;
    case 41: gl.bindRenderbuffer(a, o(b)); break;
    case 42: gl.renderbufferStorage(a, b, c, d); break;
    case 43: gl.framebufferRenderbuffer(a, b, c, o(d)); break;
    case 44: gl.depthFunc(a); break;
    case 45: gl.depthMask(!!a); break;
    case 46: {
      // a program: GLSL ES 1.0 shaders (the precision put first), the
      // attributes at 0, 1... in the order named
      const sh = (kind, src) => {
        const s = gl.createShader(kind);
        gl.shaderSource(s, src);
        gl.compileShader(s);
        if (!gl.getShaderParameter(s, gl.COMPILE_STATUS)) {
          console.warn("retro: a 3D shader did not compile: " + gl.getShaderInfoLog(s));
          gl.deleteShader(s);
          return null;
        }
        return s;
      };
      const vs = sh(gl.VERTEX_SHADER, "precision highp float;\n" + rt.str(a));
      const fs = sh(gl.FRAGMENT_SHADER, "precision highp float;\n" + rt.str(b));
      if (!vs || !fs) return 0;
      const pr = gl.createProgram();
      gl.attachShader(pr, vs);
      gl.attachShader(pr, fs);
      rt.str(c).split("\n").filter((n) => n).forEach((n, k) => gl.bindAttribLocation(pr, k, n));
      gl.linkProgram(pr);
      gl.deleteShader(vs);
      gl.deleteShader(fs);
      if (!gl.getProgramParameter(pr, gl.LINK_STATUS)) {
        console.warn("retro: a 3D program did not link: " + gl.getProgramInfoLog(pr));
        gl.deleteProgram(pr);
        return 0;
      }
      return put(pr);
    }
    case 47: gl.finish(); break;
    }
    return 0;
  }
  // screen readers: the program's tree of controls (`retroui/uirelays/access`)
  // as ARIA elements over the canvas, where each control is -- read in a
  // screen reader's browse mode, pressed by it (a click on one is the
  // control's press); the focus said in a live region as it moves
  accessTree(t, focus) {
    if (!this.aria) {
      const a = this.aria = document.createElement("div");
      a.id = "retro-access";
      a.style.cssText = "position:absolute;left:0;top:0;width:100%;height:100%;overflow:hidden;" +
                        "pointer-events:none;color:transparent;opacity:0.01";
      this.root.appendChild(a);
      const live = this.ariaLive = document.createElement("div");
      live.setAttribute("aria-live", "polite");
      live.style.cssText = "position:absolute;width:1px;height:1px;overflow:hidden;clip:rect(0 0 0 0)";
      this.root.appendChild(live);
      this.ariaEls = new Map();
      a.addEventListener("click", (e) => {
        const el = e.target.closest("[data-rid]");
        if (!el) return;
        e.preventDefault();
        const st = this.sys = this.sys || {};
        (st.accessAsked = st.accessAsked || []).push("press\t" + el.dataset.rid);
        this.schedule();
      });
    }
    const ROLES = ["region", "group", "group", "", "button", "button", "checkbox", "radio", "textbox",
      "textbox", "textbox", "combobox", "listbox", "option", "slider", "spinbutton", "progressbar",
      "scrollbar", "menubar", "menu", "menuitem", "toolbar", "status", "tablist", "tab", "tree",
      "treeitem", "grid", "row", "gridcell", "columnheader", "dialog", "link", "img", "heading",
      "separator", "tooltip", "alert"];
    const k = this.dpr();
    const nodes = t.split("\n").filter((l) => l).map((l) => l.split("\t"));
    const seen = new Set(), els = [];
    for (const f of nodes) {
      const [id, parent, role, states, x, y, w, h, name, value, help, lo, hi, now, pos, count, level, key] = f;
      let el = this.ariaEls.get(id);
      if (!el) {
        el = document.createElement(+role === 32 ? "a" : "div");
        el.dataset.rid = id;
        el.style.position = "absolute";
        this.ariaEls.set(id, el);
      }
      seen.add(id);
      els.push([el, +parent, f]);
      const st = +states, r = ROLES[+role] || "";
      const set = (a, v) => { if (v == null || v === "") el.removeAttribute(a); else if (el.getAttribute(a) !== String(v)) el.setAttribute(a, v); };
      set("role", r);
      set("aria-label", +role === 3 ? "" : name);
      if (+role === 3 || +role === 34) { if (el.textContent !== name) el.textContent = name; }
      set("aria-description", help);
      set("aria-disabled", st & 4 ? "true" : "");
      set("aria-checked", +role === 6 || +role === 7 ? (st & 16 ? "mixed" : st & 8 ? "true" : "false") : "");
      set("aria-pressed", +role === 5 ? (st & 1024 ? "true" : "false") : "");
      set("aria-selected", +role === 13 || +role === 24 || +role === 26 ? (st & 32 ? "true" : "false") : "");
      set("aria-expanded", st & 64 ? (st & 128 ? "true" : "false") : "");
      set("aria-readonly", st & 256 && (+role >= 8 && +role <= 10) ? "true" : "");
      set("aria-multiline", +role === 9 ? "true" : "");
      set("aria-modal", st & 8192 ? "true" : "");
      set("aria-keyshortcuts", key);
      set("aria-level", +level > 0 ? level : "");
      set("aria-posinset", +pos > 0 ? pos : "");
      set("aria-setsize", +count > 0 ? count : "");
      const ranged = +role === 14 || +role === 15 || +role === 16 || +role === 17;
      set("aria-valuemin", ranged ? lo : "");
      set("aria-valuemax", ranged ? hi : "");
      set("aria-valuenow", ranged ? now : "");
      set("aria-valuetext", ranged && value ? value : "");
      if (+role >= 8 && +role <= 11 && !(st & 4096)) set("aria-valuetext", value);
      el.dataset.x = x; el.dataset.y = y;
      el.style.left = "0px"; el.style.top = "0px";
      el.style.width = (w / k) + "px"; el.style.height = (h / k) + "px";
    }
    // (in their parents, each placed where its control is)
    for (const [el, parent, f] of els) {
      let p = parent >= 0 && parent < els.length ? els[parent][0] : this.aria;
      if (p === el || el.contains(p)) p = this.aria;      // (the root: its own parent)
      if (el.parentNode !== p) p.appendChild(el);
      const px = p === this.aria ? 0 : +p.dataset.x, py = p === this.aria ? 0 : +p.dataset.y;
      el.style.left = ((+f[4] - px) / k) + "px";
      el.style.top = ((+f[5] - py) / k) + "px";
    }
    for (const [id, el] of this.ariaEls) if (!seen.has(id)) { el.remove(); this.ariaEls.delete(id); }
    // the focus, said as it moves
    const fo = focus >= 0 && focus < nodes.length ? nodes[focus] : null;
    const fid = fo ? fo[0] : "";
    if (fid !== this.ariaFocus) {
      this.ariaFocus = fid;
      if (fo) {
        const r = ROLES[+fo[2]] || "";
        const val = +fo[3] & 4096 ? "" : fo[9];
        this.accessSay([fo[8], r === "textbox" ? "edit" : r, val].filter((x) => x).join(", "), false);
      }
    }
    for (const f of nodes) if (+f[2] === 37 && !this.ariaSaid?.has(f[0])) {
      (this.ariaSaid = this.ariaSaid || new Set()).add(f[0]);
      this.accessSay(f[8] + (f[9] ? ": " + f[9] : ""), true);
    }
  }
  accessSay(text, now) {
    if (!this.ariaLive) this.accessTree("", -1);
    const live = this.ariaLive;
    live.setAttribute("aria-live", now ? "assertive" : "polite");
    live.textContent = "";
    setTimeout(() => { live.textContent = text; }, 30);
  }
  // (secrets: the values sealed in localStorage with a key made once and
  // kept in IndexedDB as a CryptoKey that cannot be exported; opened
  // before the program starts, so a secret is there when it first asks)
  async secretKey(make) {
    const db = await new Promise((ok, bad) => {
      const r = indexedDB.open("retro-secrets", 1);
      r.onupgradeneeded = () => r.result.createObjectStore("keys");
      r.onsuccess = () => ok(r.result);
      r.onerror = () => bad(r.error);
    });
    const app = this.appName || "app";
    let key = await new Promise((ok, bad) => {
      const r = db.transaction("keys").objectStore("keys").get(app);
      r.onsuccess = () => ok(r.result);
      r.onerror = () => bad(r.error);
    });
    if (!key && make) {
      key = await crypto.subtle.generateKey({ name: "AES-GCM", length: 256 }, false, ["encrypt", "decrypt"]);
      await new Promise((ok, bad) => {
        const t = db.transaction("keys", "readwrite");
        t.objectStore("keys").put(key, app);
        t.oncomplete = () => ok();
        t.onerror = () => bad(t.error);
      });
    }
    db.close();
    return key;
  }
  async openSecrets() {
    const st = this.sys = this.sys || {};
    const sec = st.secrets = { state: "none", values: {}, store: "retro-secrets-" + (this.appName || "app") };
    if (typeof indexedDB === "undefined" || typeof crypto === "undefined" || !crypto.subtle) return;
    let sealed = null;
    try { sealed = localStorage.getItem(sec.store); } catch (e) { return; }
    try {
      if (sealed) {
        sec.key = await this.secretKey(false);
        const b = Uint8Array.from(atob(sealed), (c) => c.charCodeAt(0));
        if (sec.key) {
          const plain = await crypto.subtle.decrypt({ name: "AES-GCM", iv: b.subarray(0, 12) }, sec.key, b.subarray(12));
          sec.values = JSON.parse(textDecoder.decode(plain));
        }
      }
      sec.state = "ok";
    } catch (e) {
      // (sealed with a key that is gone: the site's data cleared) -- none
      sec.values = {};
      sec.state = "ok";
    }
  }
  saveSecrets(sec) {
    const plain = textEncoder.encode(JSON.stringify(sec.values));
    sec.saving = (sec.saving || Promise.resolve()).then(async () => {
      if (!sec.key) sec.key = await this.secretKey(true);
      const iv = crypto.getRandomValues(new Uint8Array(12));
      const c = new Uint8Array(await crypto.subtle.encrypt({ name: "AES-GCM", iv }, sec.key, plain));
      const all = new Uint8Array(12 + c.length);
      all.set(iv);
      all.set(c, 12);
      let bin = "";
      for (let i = 0; i < all.length; i += 32768) bin += String.fromCharCode.apply(null, all.subarray(i, i + 32768));
      try { localStorage.setItem(sec.store, btoa(bin)); } catch (e) {}
    }).catch((e) => console.warn("retro: a secret was not kept", e));
  }
  // text in the page's fonts
  measureCtx() {
    if (!this.mctx) {
      const c = typeof OffscreenCanvas !== "undefined" ? new OffscreenCanvas(16, 16) : document.createElement("canvas");
      this.mctx = c.getContext("2d");
    }
    return this.mctx;
  }
  // pages: iframes over the canvas
  page(key) {
    let p = this.pages.get(key);
    if (!p) {
      const f = document.createElement("iframe");
      f.style.cssText = "position:absolute;border:0;background:#fff;display:none";
      f.setAttribute("referrerpolicy", "strict-origin-when-cross-origin");
      p = { frame: f, url: "", title: "", progress: 0, notes: [], blocked: [], hosts: [], allow: -1 };
      f.addEventListener("load", () => {
        p.progress = 100;
        try {
          const w = f.contentWindow;
          p.title = w.document.title || "";
          p.url = w.location.href;
          // (the app's own pages: retro.post)
          if (!w.retro) w.retro = { post: (m) => { p.notes.push(String(m)); this.schedule(); } };
          w.addEventListener("retro", () => {});
        } catch (e) { /* another site's: not ours to read */ }
        this.schedule();
      });
      this.root.appendChild(f);
      this.pages.set(key, p);
    }
    return p;
  }
  imports(rt) {
    const self = this;
    this.rt = rt;
    if (!this.messages && typeof addEventListener !== "undefined") {
      this.messages = true;
      addEventListener("message", (e) => {
        for (const p of self.pages.values())
          if (p.frame.contentWindow === e.source && e.data && e.data.retro !== undefined) {
            p.notes.push(String(e.data.retro));
            self.schedule();
          }
      });
    }
    const str = (p) => rt.str(p);
    const text = (p, n) => decodeAt(rt.u8(), p, p + n);
    return {
      rw_window_open: (title, w, h, flags) => self.open(),
      rw_window_size: (out) => {
        const dv = new DataView(rt.mem.buffer);
        dv.setInt32(out, self.w, true);
        dv.setInt32(out + 4, self.h, true);
        dv.setInt32(out + 8, self.scale, true);
      },
      rw_present: (px, stride, x, y, w, h, fullW, fullH) => {
        if (fullW !== self.canvas.width || fullH !== self.canvas.height) return;
        if (self.gl) { self.presentGl(px, stride, x, y, w, h, fullW, fullH); return; }
        if (!self.img || self.img.width !== w || self.img.height !== h) self.img = self.ctx2d.createImageData(w, h);
        const src = new Uint32Array(rt.mem.buffer, px, stride * (y + h));
        const dst = new Uint32Array(self.img.data.buffer);
        let k = 0;
        for (let row = y; row < y + h; row++) {
          let i = row * stride + x;
          for (let col = 0; col < w; col++, i++) {
            const p = src[i];
            // 0x..RRGGBB (little-endian B,G,R,x) -> bytes R,G,B,A
            dst[k++] = 0xff000000 | ((p & 0xff) << 16) | (p & 0xff00) | ((p >>> 16) & 0xff);
          }
        }
        self.ctx2d.putImageData(self.img, x, y);
      },
      rw_title: (p) => { if (typeof document !== "undefined") document.title = str(p); },
      rw_cursor: (k) => { self.canvas.style.cursor = CURSORS[k] || "default"; },
      rw_event: (out) => {
        const e = self.events.shift();
        if (!e) return 0;
        const dv = new DataView(rt.mem.buffer);
        const vals = [e.kind | 0, e.x | 0, e.y | 0, e.button | 0, e.clicks | 0, e.mods | 0, e.flags | 0];
        for (let i = 0; i < 7; i++) dv.setInt32(out + i * 4, vals[i], true);
        const m = rt.u8();
        m.fill(0, out + 28, out + 52);
        const s = e.key !== undefined ? e.key : (e.text || "");
        self.lastText = s;
        const b = textEncoder.encode(s);
        m.set(b.subarray(0, Math.min(b.length, 23)), out + 28);
        dv.setFloat32(out + 52, e.dx || 0, true);
        dv.setFloat32(out + 56, e.dy || 0, true);
        dv.setFloat32(out + 60, e.pressure || 0, true);
        return 1;
      },
      rw_event_text: (p, cap) => {
        const b = textEncoder.encode(self.lastText);
        if (!p) return b.length;
        rt.u8().set(b.subarray(0, Math.min(b.length, cap)), p);
        return b.length;
      },
      rw_want_text: (on) => { self.wantText = !!on; },
      rw_clip_put: (p, n) => {
        self.clip = text(p, n);
        if (navigator.clipboard && navigator.clipboard.writeText)
          navigator.clipboard.writeText(self.clip).catch(() => {});
      },
      rw_clip_put_png: (p, n) => {
        // (a picture: the browser asks no question for a write the user started)
        if (!navigator.clipboard || !navigator.clipboard.write || typeof ClipboardItem === "undefined")
          return 0;
        const blob = new Blob([rt.u8().slice(p, p + n)], { type: "image/png" });
        navigator.clipboard.write([new ClipboardItem({ "image/png": blob })]).catch(() => {});
        return 1;
      },
      rw_clip_get: (p, cap) => {
        const b = textEncoder.encode(self.clip);
        if (!p) return b.length;
        rt.u8().set(b.subarray(0, Math.min(b.length, cap)), p);
        return b.length;
      },
      rw_font_open: (size, bold, italic, mono) => {
        const css = (italic ? "italic " : "") + (bold ? "bold " : "") + size + "px " +
          (mono ? "ui-monospace, Menlo, Consolas, 'DejaVu Sans Mono', monospace"
                : "system-ui, -apple-system, 'Segoe UI', Roboto, 'Noto Sans', sans-serif");
        const c = self.measureCtx();
        c.font = css;
        const mm = c.measureText("Mgy中");
        const asc = Math.ceil(mm.fontBoundingBoxAscent || size * 0.8);
        const desc = Math.ceil(mm.fontBoundingBoxDescent || size * 0.2);
        self.fonts.push({ css, asc, desc, lh: asc + desc });
        return self.fonts.length - 1;
      },
      rw_font_metrics: (f, out) => {
        const ft = self.fonts[f], dv = new DataView(rt.mem.buffer);
        dv.setInt32(out, ft.asc, true);
        dv.setInt32(out + 4, ft.desc, true);
        dv.setInt32(out + 8, ft.lh, true);
      },
      rw_text_width: (f, p, n) => {
        const c = self.measureCtx();
        c.font = self.fonts[f].css;
        return Math.ceil(c.measureText(text(p, n)).width);
      },
      rw_text_render: (f, p, n, out, cap) => {
        const ft = self.fonts[f], s = text(p, n);
        const c = self.measureCtx();
        c.font = ft.css;
        const w = Math.max(1, Math.ceil(c.measureText(s).width)), h = ft.lh;
        if (w * h > cap) return 0;
        const cv = c.canvas;
        if (cv.width < w || cv.height < h) { cv.width = Math.max(cv.width, w); cv.height = Math.max(cv.height, h); }
        c.font = ft.css;
        c.clearRect(0, 0, w, h);
        c.fillStyle = "#fff";
        c.textBaseline = "alphabetic";
        c.fillText(s, 0, ft.asc);
        const d = c.getImageData(0, 0, w, h).data;
        const m = rt.u8();
        for (let i = 0; i < w * h; i++) m[out + i] = d[i * 4 + 3];
        return w;
      },
      rw_open_url: (p) => { const w = window.open(str(p), "_blank", "noopener"); return w || true ? 1 : 0; },
      rw_open_file: (p) => {
        // a file of the app's given to the user: downloaded
        const path = rt.fs.norm(str(p)), n = rt.fs.nodes.get(path);
        if (!n || n.dir || !rt.fs.load(n)) return 0;
        const a = document.createElement("a");
        a.href = URL.createObjectURL(new Blob([n.data.slice(0, n.size)]));
        a.download = path.slice(path.lastIndexOf("/") + 1);
        document.body.appendChild(a);
        a.click();
        a.remove();
        setTimeout(() => URL.revokeObjectURL(a.href), 30000);
        return 1;
      },
      rw_text_caret: (x, y, w, h) => {
        const k = self.dpr();
        self.input.style.left = (x / k) + "px";
        self.input.style.top = (y / k) + "px";
        self.input.style.height = Math.max(12, h / k) + "px";
      },
      rw_audio_start: (rate, channels) => self.startAudio(rate, channels),
      rw_call: (name, arg, out, cap) => {
        // (the answer kept until it is read whole: a longer one is asked again with room for it)
        const key = str(name) + "\u0000" + str(arg);
        let b = self.lastCall && self.lastCall.key === key ? self.lastCall.bytes : null;
        if (!b) {
          let r;
          try { r = self.call(str(name), str(arg)); } catch (e) { r = undefined; }
          if (r === undefined) return -1;
          b = textEncoder.encode(String(r));
          self.lastCall = { key, bytes: b };
        }
        if (b.length >= cap) return b.length;
        rt.u8().set(b, out);
        rt.u8()[out + b.length] = 0;
        self.lastCall = null;
        return b.length;
      },
      rw_http: (meth, url, headers, body, bodyLen, timeoutMs, follow) => {
        // (it waits: the program asked as everywhere; the site must allow
        // pages of other sites, CORS)
        const x = new XMLHttpRequest();
        const id = (self.nextHttp = (self.nextHttp || 0) + 1);
        const res = { status: 0, headers: "", body: new Uint8Array(0), error: "" };
        try {
          x.open(str(meth), str(url), false);
          x.overrideMimeType("text/plain; charset=x-user-defined");
          for (const line of str(headers).split("\r\n")) {
            const i = line.indexOf(":");
            if (i <= 0) continue;
            try { x.setRequestHeader(line.slice(0, i).trim(), line.slice(i + 1).trim()); } catch (e) {}
          }
          x.send(bodyLen ? rt.u8().slice(body, body + bodyLen) : null);
          res.status = x.status;
          res.headers = x.getAllResponseHeaders();
          const t = x.responseText || "";
          const b = new Uint8Array(t.length);
          for (let i = 0; i < t.length; i++) b[i] = t.charCodeAt(i) & 255;
          res.body = b;
        } catch (e) {
          res.status = 0;
          res.error = String(e && e.message || e);
        }
        (self.http = self.http || new Map()).set(id, res);
        return id;
      },
      rw_http_part: (h, part, buf, cap) => {
        const r = self.http && self.http.get(h);
        if (!r) return 0;
        if (part === 0) return r.status;
        const b = part === 1 ? textEncoder.encode(r.headers) : part === 2 ? r.body : textEncoder.encode(r.error);
        if (!buf) return b.length;
        rt.u8().set(b.subarray(0, Math.min(b.length, cap)), buf);
        return b.length;
      },
      rw_http_free: (h) => { if (self.http) self.http.delete(h); },
      // a request that does not wait (map tiles): its state asked each frame
      rw_fetch_start: (url, headers) => {
        const id = (self.nextFetch = (self.nextFetch || 0) + 1);
        const res = { status: 0, headers: "", body: new Uint8Array(0), error: "" };
        (self.fetches = self.fetches || new Map()).set(id, res);
        const h = {};
        for (const line of str(headers).split("\r\n")) {
          const i = line.indexOf(":");
          if (i > 0 && !/^user-agent$/i.test(line.slice(0, i).trim())) h[line.slice(0, i).trim()] = line.slice(i + 1).trim();
        }
        fetch(str(url), { headers: h }).then(async (r) => {
          res.body = new Uint8Array(await r.arrayBuffer());
          res.status = r.status || 200;
          self.schedule();
        }).catch((e) => { res.status = -1; res.error = String(e && e.message || e); self.schedule(); });
        return id;
      },
      rw_fetch_state: (id) => { const r = self.fetches && self.fetches.get(id); return r ? r.status : -1; },
      rw_fetch_part: (id, part, buf, cap) => {
        const r = self.fetches && self.fetches.get(id);
        if (!r) return 0;
        const b = part === 2 ? r.body : textEncoder.encode(part === 1 ? r.headers : r.error);
        if (!buf) return b.length;
        rt.u8().set(b.subarray(0, Math.min(b.length, cap)), buf);
        return b.length;
      },
      rw_fetch_free: (id) => { if (self.fetches) self.fetches.delete(id); },
      rw_page_url: (s, p, cap) => {
        // an address of the page's own site ("data/x.json") made whole
        let href = "";
        try { href = new URL(str(s), document.baseURI).href; } catch (e) { return 0; }
        const b = textEncoder.encode(href);
        if (p && b.length < cap) { rt.u8().set(b, p); rt.u8()[p + b.length] = 0; }
        return b.length;
      },
      rw_video_open: (src, video) => {
        const path = str(src);
        const v = document.createElement("video");
        v.playsInline = true;
        v.preload = "auto";
        v.crossOrigin = "anonymous";
        v.style.cssText = "position:absolute;left:0;top:0;width:1px;height:1px;opacity:0;pointer-events:none";
        let url = path;
        if (!/^(https?|blob|data):/i.test(path)) {
          const n = rt.fs.nodes.get(rt.fs.norm(path));
          if (!n || n.dir) return 0;
          // (a file the app came with: from the page's own site, streamed)
          if (n.url && n.ro) url = n.url;
          else {
            if (!rt.fs.load(n)) return 0;
            const ext = path.slice(path.lastIndexOf(".") + 1).toLowerCase();
            const type = { mp4: "video/mp4", m4v: "video/mp4", webm: "video/webm", ogv: "video/ogg",
                           mp3: "audio/mpeg", m4a: "audio/mp4", ogg: "audio/ogg", wav: "audio/wav",
                           opus: "audio/ogg" }[ext] || "";
            url = URL.createObjectURL(new Blob([n.data.slice(0, n.size)], { type }));
          }
        }
        const id = (self.nextVideo = (self.nextVideo || 0) + 1);
        const pl = { v, url, frames: 0, seen: 0, failed: false, canvas: null };
        v.addEventListener("error", () => { pl.failed = true; self.schedule(); });
        v.addEventListener("ended", () => self.schedule());
        const tick = () => { pl.frames++; self.schedule(); if (v.requestVideoFrameCallback) v.requestVideoFrameCallback(tick); };
        if (v.requestVideoFrameCallback) v.requestVideoFrameCallback(tick);
        else v.addEventListener("timeupdate", () => { pl.frames++; self.schedule(); });
        v.addEventListener("loadeddata", () => { pl.frames++; self.schedule(); });
        v.src = url;
        self.root.appendChild(v);
        (self.videos = self.videos || new Map()).set(id, pl);
        return id;
      },
      rw_video_close: (id) => {
        const pl = self.videos && self.videos.get(id);
        if (!pl) return;
        pl.v.pause();
        pl.v.removeAttribute("src");
        pl.v.load();
        pl.v.remove();
        if (pl.url.startsWith("blob:")) URL.revokeObjectURL(pl.url);
        self.videos.delete(id);
      },
      rw_video_play: (id, on) => {
        const pl = self.videos && self.videos.get(id);
        if (!pl) return;
        if (on) pl.v.play().catch(() => { pl.v.muted = true; pl.v.play().catch(() => {}); });
        else pl.v.pause();
      },
      rw_video_state: (id, out) => {
        const pl = self.videos && self.videos.get(id), dv = new DataView(rt.mem.buffer);
        const v = pl ? pl.v : null;
        const vals = v ? [(!v.paused && !v.ended) ? 1 : 0, v.ended ? 1 : 0, pl.failed ? 1 : 0,
                          Math.round(v.currentTime * 1000),
                          isFinite(v.duration) ? Math.round(v.duration * 1000) : 0,
                          pl.frames !== pl.seen && v.videoWidth > 0 ? 1 : 0] : [0, 0, 1, 0, 0, 0];
        for (let i = 0; i < 6; i++) dv.setInt32(out + i * 4, vals[i], true);
      },
      rw_video_seek: (id, ms) => {
        const pl = self.videos && self.videos.get(id);
        if (pl) pl.v.currentTime = ms / 1000;
      },
      rw_video_volume: (id, vol) => {
        const pl = self.videos && self.videos.get(id);
        if (pl) pl.v.volume = Math.max(0, Math.min(1, vol));
      },
      rw_access: (p, n, focus) => { self.accessTree(text(p, n), focus); },
      rw_gl: (op, a, b, c, d, e, f, g, h, i) => self.gl3(op, a, b, c, d, e, f, g, h, i),
      rw_camera_frame: (id, px, w, h) => {
        // the camera's newest picture (0: none new), its size asked first
        // (px 0: w -1 the height, else the width)
        const cam = self.sys && self.sys.cams && self.sys.cams.get(id);
        if (!cam || cam.state !== "ok" || !cam.v.videoWidth) return 0;
        const v = cam.v;
        const tw = Math.min(v.videoWidth, 1280);
        const th = Math.max(1, Math.round(v.videoHeight * tw / v.videoWidth));
        if (!px) return w === -1 ? th : tw;
        if (cam.seen === cam.frames) return 0;
        if (!cam.canvas || cam.canvas.width !== w || cam.canvas.height !== h) {
          cam.canvas = typeof OffscreenCanvas !== "undefined" ? new OffscreenCanvas(w, h) : document.createElement("canvas");
          cam.canvas.width = w;
          cam.canvas.height = h;
          cam.ctx = cam.canvas.getContext("2d", { willReadFrequently: true });
        }
        cam.ctx.drawImage(v, 0, 0, w, h);
        const d = cam.ctx.getImageData(0, 0, w, h).data;
        const src = new Uint32Array(d.buffer), dst = new Uint32Array(rt.mem.buffer, px, w * h);
        for (let i = 0; i < w * h; i++) {
          const p = src[i];
          dst[i] = 0xff000000 | ((p & 0xff) << 16) | (p & 0xff00) | ((p >>> 16) & 0xff);
        }
        cam.seen = cam.frames;
        return w;
      },
      rw_video_frame: (id, px, w, h) => {
        const pl = self.videos && self.videos.get(id);
        if (!pl || !pl.v.videoWidth) return 0;
        const v = pl.v;
        const tw = Math.min(v.videoWidth, 1280);
        const th = Math.max(1, Math.round(v.videoHeight * tw / v.videoWidth));
        if (!px) return w === -1 ? th : tw;
        if (!pl.canvas || pl.canvas.width !== w || pl.canvas.height !== h) {
          pl.canvas = typeof OffscreenCanvas !== "undefined" ? new OffscreenCanvas(w, h) : document.createElement("canvas");
          pl.canvas.width = w;
          pl.canvas.height = h;
          pl.ctx = pl.canvas.getContext("2d", { willReadFrequently: true });
        }
        pl.ctx.drawImage(v, 0, 0, w, h);
        let d;
        try { d = pl.ctx.getImageData(0, 0, w, h).data; } catch (e) { pl.failed = true; return 0; }
        const src = new Uint32Array(d.buffer), dst = new Uint32Array(rt.mem.buffer, px, w * h);
        for (let i = 0; i < w * h; i++) {
          const p = src[i];                     // bytes R,G,B,A -> 0xAARRGGBB
          dst[i] = 0xff000000 | ((p & 0xff) << 16) | (p & 0xff00) | ((p >>> 16) & 0xff);
        }
        pl.seen = pl.frames;
        return w;
      },
      rw_web_show: (key, url, x, y, w, h, zoom, allow) => {
        const p = self.page(str(key)), f = p.frame, k = self.dpr(), u = str(url);
        if (allow !== p.allow) {
          p.allow = allow;
          const list = [];
          if (allow & 1) list.push("camera");
          if (allow & 2) list.push("microphone");
          if (allow & 4) list.push("geolocation");
          list.push("clipboard-write", "fullscreen");
          f.setAttribute("allow", list.join("; "));
        }
        if (u && u !== p.asked) { p.asked = u; p.url = u; p.progress = 10; f.src = u; }
        f.style.left = (x / k) + "px";
        f.style.top = (y / k) + "px";
        f.style.width = (w / k) + "px";
        f.style.height = (h / k) + "px";
        f.style.zoom = zoom > 0 ? String(zoom) : "";
        f.style.display = "block";
      },
      rw_web_hide: (key) => { const p = self.pages.get(str(key)); if (p) p.frame.style.display = "none"; },
      rw_web_close: (key) => {
        const k = str(key), p = self.pages.get(k);
        if (p) { p.frame.remove(); self.pages.delete(k); }
      },
      rw_web_nav: (key, what) => {
        const p = self.pages.get(str(key));
        if (!p) return;
        try {
          const w = p.frame.contentWindow;
          if (what === 0) w.history.back();
          else if (what === 1) w.history.forward();
          else if (what === 2) { p.progress = 10; w.location.reload(); }
          else if (what === 3) w.stop();
          else if (what === 4) w.print();
        } catch (e) {
          if (what === 2) { p.progress = 10; p.frame.src = p.asked; }
        }
      },
      rw_web_run: (key, js) => {
        const p = self.pages.get(str(key));
        if (!p) return;
        const code = str(js);
        try { p.frame.contentWindow.eval(code); }
        catch (e) { p.frame.contentWindow.postMessage({ retroRun: code }, "*"); }
      },
      rw_web_allow: (key, hosts) => {
        const p = self.page(str(key));
        p.hosts = str(hosts).split("\n").filter(Boolean);
      },
      rw_web_state: (key, buf, cap) => {
        const p = self.pages.get(str(key));
        if (!p) return 0;
        let back = 0;
        try { p.title = p.frame.contentWindow.document.title || p.title; p.url = p.frame.contentWindow.location.href; } catch (e) {}
        const parts = [p.url, p.title, String(p.progress), String(back), "0"];
        for (const b of p.blocked) parts.push("\u0002" + b);
        for (const n of p.notes) parts.push(n.replace(/\u0001/g, " "));
        const b = textEncoder.encode(parts.join("\u0001"));
        if (b.length > cap) return b.length;
        rt.u8().set(b, buf);
        p.notes = [];
        p.blocked = [];
        return b.length;
      },
    };
  }
}

// (the page loaded once more for threads: once a visit, so a browser that
// will not isolate it does not reload forever)
function onceIsolated() {
  try {
    if (sessionStorage.getItem("retro-isolated")) return true;
    sessionStorage.setItem("retro-isolated", "1");
    return false;
  } catch (e) { return true; }
}

// ---- starting an app built with `retrokit web` ----------------------------------------------------
// Retro.boot({ wasm: "app.wasm", name: "app", files: ["app/index.html", ...], element })

async function boot(opts) {
  const root = typeof opts.element === "string" ? document.querySelector(opts.element)
             : opts.element || document.getElementById("retro") || document.body;
  const rt = new Retro(opts);
  rt.driver = new RetroWeb(root);
  root.retro = rt;               // (for the page's own scripts and tests)
  // the files the app came with: /app (read only)
  // (each [address, size]: up to `preload` bytes (1 MB) loaded before the
  // program starts, a bigger one when it is first read; a video or a sound
  // is played from its address)
  const preload = opts.preload != null ? opts.preload : 1 << 20;
  const media = /\.(mp4|m4v|webm|ogv|mov|mp3|m4a|ogg|oga|opus|wav|flac|aac)$/i;
  await Promise.all((opts.files || []).map(async (f) => {
    const [url, size] = Array.isArray(f) ? f : [f, 0];
    const path = "/app/" + url.replace(/^(\.\/)?(app\/)?/, "");
    if (size > preload || media.test(url)) { rt.fs.addLater(path, url, size); return; }
    try {
      const r = await fetch(url);
      if (r.ok) rt.fs.addFile(path, new Uint8Array(await r.arrayBuffer()), true, url);
      else console.warn("retro: " + url + " was not loaded (" + r.status + ")");
    } catch (e) { console.warn("retro: " + url + " was not loaded", e); }
  }));
  // the kit's own files (its fonts): fetched when first read
  for (const [url, size] of opts.kit || []) rt.fs.addLater("/" + url, url, size);
  // threads (a build with them) where the page may share memory with its
  // workers: kept apart from other sites (crossOriginIsolated). A server
  // that does not say so is helped by the service worker, which does: the
  // page is loaded once more through it. Else (or ?threads=0): one thread.
  let threads = null;
  const want = opts.threads && opts.threads.wasm && !/[?&]threads=0\b/.test(location.search);
  const sw = opts.serviceWorker && "serviceWorker" in navigator && location.protocol !== "file:";
  if (want && typeof SharedArrayBuffer !== "undefined" && self.crossOriginIsolated) threads = opts.threads;
  else if (want && sw && !onceIsolated()) {
    try {
      await navigator.serviceWorker.register(opts.serviceWorker);
      await navigator.serviceWorker.ready;
      if (!navigator.serviceWorker.controller)
        await new Promise((ok) => navigator.serviceWorker.addEventListener("controllerchange", ok, { once: true }));
      location.reload();
      return new Promise(() => {});
    } catch (e) { console.warn("retro: no threads (the service worker)", e); }
  }
  if (sw && !threads) navigator.serviceWorker.register(opts.serviceWorker).catch(() => {});
  if (!threads && opts.threads && opts.threads.only) {
    // (built with threads alone: a page that may not have them says so)
    rt.driver.fail("This app needs threads: a browser that keeps the page apart from other sites " +
                   "(crossOriginIsolated -- a recent Chrome, Edge, Firefox or Safari, the page served " +
                   "over https or from localhost).");
    return rt;
  }
  rt.driver.appName = opts.name || "app";
  await rt.driver.openSecrets().catch(() => {});
  const wasm = await fetch(threads ? threads.wasm : opts.wasm || "app.wasm");
  try {
    await rt.start(wasm.headers.get("content-type") === "application/wasm" ? wasm
                   : await wasm.arrayBuffer(), threads);
  } catch (e) {
    rt.driver.fail(e);
    throw e;
  }
  return rt;
}

class RetroExit extends Error {
  constructor(code) { super("exit " + code); this.code = code; }
}

function env_cpus() {
  return (typeof navigator !== "undefined" && navigator.hardwareConcurrency) || 2;
}

// ---- threads: Web Workers on the program's memory ------------------------------------------------
// A build with threads (`retrokit web --threads`) runs its threads in Web
// Workers started with the page (the same program, the same shared
// memory, each its own stack and thread-local storage). What a thread
// asks of the page -- its files, its console, the canvas -- is done by the
// page: the thread writes the call in its mailbox and waits; the page does
// it when it is free, or while it spins for a lock (`rl_thread_serve`).
//
// A mailbox (Int32 slots): 0 the call's state (0 none, 1 asked, 2
// answered), 1 which import, 2 how many arguments, 3 the answer's kind (0 a
// number, 1 a BigInt, 2 it failed), 4..19 each argument's kind; 24 the
// worker's state (0 free, 3 being given a thread, 1 go, 2 running), 25..27
// the thread, its stack's top, its TLS. Float64 from byte 128: 0 the
// answer, 1..16 the arguments.

const BOX_BYTES = 512, BOX_VALS = 128;

class RetroThreads {
  constructor(rt, count) {
    this.rt = rt;
    this.count = count;
    this.slots = [];
    this.waiting = [];          // threads asked for while every worker was busy
  }
  start(module, env) {
    this.module = module;
    // (the imports in the module's order: a call names one by its place)
    this.names = WebAssembly.Module.imports(module).filter((i) => i.kind === "function").map((i) => i.name);
    this.fns = this.names.map((n) => env[n]);
    const all = [];
    for (let i = 0; i < this.count; i++) all.push(this.add());
    return Promise.all(all);
  }
  add() {
    return new Promise((ok, bad) => {
      const box = new SharedArrayBuffer(BOX_BYTES);
      const slot = { box, ctl: new Int32Array(box), vals: new Float64Array(box, BOX_VALS) };
      const w = new Worker(scriptUrl, { name: "retro-thread-" + this.slots.length });
      slot.w = w;
      w.onmessage = (e) => {
        const d = e.data;
        if (d === 0) { this.serve(); return; }
        if (d.ready) { this.slots.push(slot); this.next(); ok(); return; }
        if (d.reap) {
          try { this.rt.instance.exports.retro_thread_reap(d.reap); } catch (err) { console.error(err); }
          this.next();
          return;
        }
        if (d.free) { this.next(); return; }
        if (d.exit != null) { this.rt.exited = d.exit; this.end(d.exit); return; }
        if (d.error) {
          this.rt.flushConsole();
          if (this.rt.driver) { this.rt.driver.stopped = true; this.rt.driver.fail("a thread stopped: " + d.error); }
          else console.error("retro: a thread stopped: " + d.error);
        }
      };
      w.onerror = (e) => { console.error("retro: a thread's worker did not start", e.message || e); bad(e); };
      w.postMessage({ retroThread: true, module: this.module, memory: this.rt.memory, box,
                      origin: performance.timeOrigin });
    });
  }
  spawn(t, top, tls) {
    for (const s of this.slots) {
      if (Atomics.compareExchange(s.ctl, 24, 0, 3) !== 0) continue;
      s.ctl[25] = t; s.ctl[26] = top; s.ctl[27] = tls;
      Atomics.store(s.ctl, 24, 1);
      Atomics.notify(s.ctl, 24);
      return 0;
    }
    // (every worker busy: one more, the thread starts when it is ready --
    // the page's thread must not wait for it before then)
    this.waiting.push([t, top, tls]);
    this.add().catch(() => {});
    return 0;
  }
  next() {
    while (this.waiting.length) {
      const free = this.slots.find((s) => Atomics.load(s.ctl, 24) === 0);
      if (!free) return;
      const [t, top, tls] = this.waiting.shift();
      this.spawn(t, top, tls);
    }
  }
  // the calls the threads are waiting for: done
  serve() {
    for (const s of this.slots) {
      const ctl = s.ctl, vals = s.vals;
      if (Atomics.load(ctl, 0) !== 1) continue;
      const n = ctl[2], args = new Array(n);
      for (let k = 0; k < n; k++) args[k] = ctl[4 + k] === 1 ? BigInt(vals[1 + k]) : vals[1 + k];
      let kind = 0, r = 0;
      try {
        r = this.fns[ctl[1]](...args);
        if (typeof r === "bigint") { kind = 1; r = Number(r); }
        else r = r === undefined ? 0 : +r;
      } catch (e) {
        kind = 2;
        if (!(e instanceof RetroExit)) console.error("retro: " + this.names[ctl[1]] + " for a thread:", e);
      }
      ctl[3] = kind;
      vals[0] = r;
      Atomics.store(ctl, 0, 2);
      Atomics.notify(ctl, 0);
    }
  }
  end(code) {
    this.rt.flushConsole();
    if (this.rt.driver) this.rt.driver.stopped = true;
    this.stop();
    if (this.rt.driver) {
      this.rt.fs.save();
      if (this.rt.opts.onExit) this.rt.opts.onExit(); else this.rt.driver.ended();
    }
  }
  stop() {
    for (const s of this.slots) s.w.terminate();
    this.slots = [];
  }
}

// (in a thread's worker: this script, run there)
class ThreadExit extends Error {}

function threadWorker(d) {
  const memory = d.memory, ctl = new Int32Array(d.box), vals = new Float64Array(d.box, BOX_VALS);
  const u8 = () => new Uint8Array(memory.buffer);
  const str = (p) => { const m = u8(); let e = p; while (m[e]) e++; return decodeAt(m, p, e); };
  const call = (i, args) => {
    for (let k = 0; k < args.length; k++) {
      const a = args[k];
      if (typeof a === "bigint") { ctl[4 + k] = 1; vals[1 + k] = Number(a); }
      else { ctl[4 + k] = 0; vals[1 + k] = a; }
    }
    ctl[1] = i;
    ctl[2] = args.length;
    Atomics.store(ctl, 0, 1);
    postMessage(0);
    while (Atomics.load(ctl, 0) === 1) Atomics.wait(ctl, 0, 1);
    const kind = ctl[3], r = vals[0];
    Atomics.store(ctl, 0, 0);
    if (kind === 2) throw new Error("the page could not do it for this thread");
    return kind === 1 ? BigInt(r) : r;
  };
  // (what a worker does itself; anything else the page does)
  const http = new Map();
  let nextHttp = 0;
  const local = {
    rl_now: (clock) => clock === 0 ? Date.now() : performance.timeOrigin + performance.now() - d.origin,
    rl_random: (p, n) => {
      const b = new Uint8Array(n);
      for (let i = 0; i < n; i += 65536) crypto.getRandomValues(b.subarray(i, Math.min(n, i + 65536)));
      u8().set(b, p);
    },
    rl_cpus: () => navigator.hardwareConcurrency || 1,
    rl_charset: (name) => charsetOk(str(name)) ? 1 : 0,
    rl_decode: (from, p, n, out, cap) => charsetDecode(u8(), str(from), p, n, out, cap),
    rl_thread_exit: () => { throw new ThreadExit(); },
    rl_thread_serve: () => {},
    rl_exit: (code) => { postMessage({ exit: code }); throw new ThreadExit(); },
    rl_abort: (why) => { throw new Error(str(why)); },
    // (a request waits here, in the worker, not in the page: XMLHttpRequest
    // as the page has it)
    rw_http: (meth, url, headers, body, bodyLen, timeoutMs, follow) => {
      const id = ++nextHttp;
      const res = { status: 0, headers: "", body: new Uint8Array(0), error: "" };
      try {
        const x = new XMLHttpRequest();
        x.open(str(meth), str(url), false);
        x.responseType = "arraybuffer";
        for (const line of str(headers).split("\r\n")) {
          const i = line.indexOf(":");
          if (i <= 0 || /^user-agent$/i.test(line.slice(0, i).trim())) continue;
          try { x.setRequestHeader(line.slice(0, i).trim(), line.slice(i + 1).trim()); } catch (e) {}
        }
        x.send(bodyLen ? u8().slice(body, body + bodyLen) : null);
        res.status = x.status;
        res.headers = x.getAllResponseHeaders();
        res.body = new Uint8Array(x.response || new ArrayBuffer(0));
      } catch (e) {
        res.status = 0;
        res.error = String(e && e.message || e);
      }
      http.set(id, res);
      return id;
    },
    rw_http_part: (h, part, buf, cap) => {
      const r = http.get(h);
      if (!r) return 0;
      if (part === 0) return r.status;
      const b = part === 1 ? textEncoder.encode(r.headers) : part === 2 ? r.body : textEncoder.encode(r.error);
      if (!buf) return b.length;
      u8().set(b.subarray(0, Math.min(b.length, cap)), buf);
      return b.length;
    },
    rw_http_free: (h) => { http.delete(h); },
    m_fmod: (x, y) => x % y,
  };
  for (const f of ["sin", "cos", "tan", "asin", "acos", "atan", "sinh", "cosh", "tanh", "asinh",
                   "acosh", "atanh", "exp", "expm1", "log", "log2", "log10", "log1p", "cbrt",
                   "atan2", "pow", "hypot"])
    local["m_" + f] = Math[f];
  const env = { memory };
  const names = WebAssembly.Module.imports(d.module).filter((i) => i.kind === "function").map((i) => i.name);
  names.forEach((n, i) => { env[n] = local[n] || ((...args) => call(i, args)); });
  const ex = new WebAssembly.Instance(d.module, { env }).exports;
  postMessage({ ready: true });
  for (;;) {
    let v;
    while ((v = Atomics.load(ctl, 24)) !== 1) Atomics.wait(ctl, 24, v);
    Atomics.store(ctl, 24, 2);
    const t = ctl[25] >>> 0, top = ctl[26] >>> 0, tls = ctl[27] >>> 0;
    ex.__stack_pointer.value = top;
    ex.__wasm_init_tls(tls);
    try {
      ex.retro_thread_entry(t);
    } catch (e) {
      if (!(e instanceof ThreadExit)) postMessage({ error: String(e && e.stack || e) });
    }
    const h = new Int32Array(memory.buffer);
    Atomics.store(h, (t + 12) >> 2, 2);
    Atomics.notify(h, (t + 12) >> 2);
    const detached = Atomics.exchange(h, (t + 16) >> 2, 2) === 1;
    Atomics.store(ctl, 24, 0);
    postMessage(detached ? { reap: t } : { free: true });
  }
}

if (isWorker && typeof document === "undefined") {
  self.onmessage = (e) => {
    if (e.data && e.data.retroThread) {
      self.onmessage = null;
      try { threadWorker(e.data); }
      catch (err) { postMessage({ error: String(err && err.stack || err) }); }
    }
  };
}

Retro.boot = boot;
root.Retro = Retro;
root.RetroFS = RetroFS;
root.RetroWeb = RetroWeb;
root.RetroExit = RetroExit;
root.RetroThreads = RetroThreads;
if (typeof module !== "undefined") module.exports = { Retro, RetroFS, RetroWeb, RetroExit };

})(typeof globalThis !== "undefined" ? globalThis : this);
