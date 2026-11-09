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

// ---- errors (Linux's numbers, as the C library has them) ----
const E = { PERM: 1, NOENT: 2, IO: 5, BADF: 9, AGAIN: 11, NOMEM: 12, ACCES: 13, EXIST: 17,
            NOTDIR: 20, ISDIR: 21, INVAL: 22, MFILE: 24, NOSPC: 28, SPIPE: 29, ROFS: 30,
            NOSYS: 38, NOTEMPTY: 39 };
const S_IFDIR = 0o040000, S_IFREG = 0o100000;

// ---- a file system in the page ----------------------------------------------------------------
// Folders and files in memory; what is under the folders kept (`persist`,
// the app's data and home) is stored in IndexedDB a moment after it
// changes, and brought back before the program starts. /app holds the
// files the app came with (read only).

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
    for (const d of ["/", "/home", "/home/web", "/data", "/tmp", "/app"]) this.mkdirp(d);
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
    if (!this.kept(p) || !this.db) return;
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
  get mem() { return this.instance.exports.memory; }
  u8() { return new Uint8Array(this.mem.buffer); }
  str(p) {
    const m = this.u8();
    let e = p;
    while (m[e]) e++;
    return textDecoder.decode(m.subarray(p, e));
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
    if (this.driver) Object.assign(env, this.driver.imports(this));
    if (this.opts.imports) Object.assign(env, this.opts.imports);
    return { env };
  }
  async start(wasm) {
    await this.fs.open();
    const imports = this.imports();
    let result;
    if (wasm instanceof WebAssembly.Module) result = { instance: await WebAssembly.instantiate(wasm, imports) };
    else if (typeof Response !== "undefined" && wasm instanceof Response)
      result = await WebAssembly.instantiateStreaming(wasm, imports);
    else result = await WebAssembly.instantiate(wasm, imports);
    this.instance = result.instance;
    const ex = this.instance.exports;
    try {
      if (ex._initialize) ex._initialize();
      if (ex.NimMain) ex.NimMain();
      else if (ex.main) ex.main(0, 0);
    } catch (e) {
      if (!(e instanceof RetroExit)) throw e;
    }
    this.flushConsole();
    if (this.driver && this.exited === null) this.driver.run(this);
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
    this.ctx2d = c.getContext("2d", { alpha: false });
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
    if (wait === -2) { this.stopped = true; if (this.rt.opts.onExit) this.rt.opts.onExit(); return; }
    if (wait === -3) {
      // an error the program did not catch (its message went to the console)
      this.stopped = true;
      this.fail(this.rt.lastError || "an error the program did not catch");
      return;
    }
    if (wait === 0 || this.events.length) this.schedule();
    else if (wait > 0) this.timer = setTimeout(() => { this.timer = 0; this.schedule(); }, wait);
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
  // sound
  startAudio(rate, channels) {
    if (this.audio || typeof AudioContext === "undefined") return;
    const ex = this.rt.instance.exports;
    const frames = 2048;
    let ctx;
    try { ctx = new AudioContext({ sampleRate: rate }); } catch (e) { ctx = new AudioContext(); }
    const node = ctx.createScriptProcessor(frames, 0, 2);
    const buf = ex.malloc(frames * 2 * 2);
    node.onaudioprocess = (e) => {
      if (this.stopped) return;
      ex.retro_audio(buf, frames * 2);
      const s = new Int16Array(this.rt.mem.buffer, buf, frames * 2);
      const l = e.outputBuffer.getChannelData(0), r = e.outputBuffer.getChannelData(1);
      for (let i = 0; i < frames; i++) { l[i] = s[2 * i] / 32768; r[i] = s[2 * i + 1] / 32768; }
    };
    node.connect(ctx.destination);
    this.audio = ctx;
    this.resumeAudio();
  }
  resumeAudio() {
    if (this.audio && this.audio.state === "suspended") this.audio.resume().catch(() => {});
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
    const text = (p, n) => textDecoder.decode(rt.u8().subarray(p, p + n));
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
  if (opts.serviceWorker && "serviceWorker" in navigator && location.protocol !== "file:")
    navigator.serviceWorker.register(opts.serviceWorker).catch(() => {});
  const wasm = await fetch(opts.wasm || "app.wasm");
  try {
    await rt.start(wasm.headers.get("content-type") === "application/wasm" ? wasm
                   : await wasm.arrayBuffer());
  } catch (e) {
    rt.driver.fail(e);
    throw e;
  }
  return rt;
}

class RetroExit extends Error {
  constructor(code) { super("exit " + code); this.code = code; }
}

Retro.boot = boot;
root.Retro = Retro;
root.RetroFS = RetroFS;
root.RetroWeb = RetroWeb;
root.RetroExit = RetroExit;
if (typeof module !== "undefined") module.exports = { Retro, RetroFS, RetroWeb, RetroExit };

})(typeof globalThis !== "undefined" ? globalThis : this);
