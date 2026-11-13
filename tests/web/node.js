// A headless test as WebAssembly under Node (no browser): the program
// built by retroweb (`--out:DIR`, its DIR/app.wasm), run with the page's C
// library side (retro.js's RetroFS and rl_* imports); the toolkit's
// browser driver answers nothing (the tests have their fake driver,
// tests/harness.nim). Folders of this machine can be put in its files.
//
//   node tests/web/node.js DIR/app.wasm [--mount:HOST_DIR=/path ...]
//
// Exit code: the program's.
const fs = require("fs");
const path = require("path");
const { Retro } = require("../../src/retroui/web/retro.js");

const args = process.argv.slice(2);
const wasm = args.find((a) => !a.startsWith("--"));
const rt = new Retro({ name: "test", onOutput: (fd, l) => (fd === 2 ? process.stderr : process.stdout).write(l + "\n") });
for (const a of args.filter((a) => a.startsWith("--mount:"))) {
  const [host, at] = a.slice(8).split("=");
  // (not build/: the builds of the other tests, made at the same time --
  // their files come and go as they are read)
  const walk = (dir, to) => {
    rt.fs.mkdirp(to);
    for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
      const h = path.join(dir, e.name), t = to + "/" + e.name;
      if (e.isDirectory()) { if (e.name !== "build") walk(h, t); }
      else if (e.isFile()) {
        let data;
        try { data = fs.readFileSync(h); } catch (err) { if (err.code === "ENOENT") continue; throw err; }
        rt.fs.addFile(t, new Uint8Array(data), false);
      }
    }
  };
  walk(host, at);
}
// (the kit's fonts, which a page has beside it: /kit/fonts)
for (const f of fs.readdirSync(path.join(__dirname, "../../src/retroui/fonts")))
  if (f.endsWith(".ttf.z"))
    rt.fs.addFile("/kit/fonts/" + f, new Uint8Array(fs.readFileSync(path.join(__dirname, "../../src/retroui/fonts", f))), true);
const mod = new WebAssembly.Module(fs.readFileSync(wasm));
// (what a page would answer -- the canvas, the clipboard, sound -- answers
// nothing here)
rt.opts.imports = {};
const have = rt.imports().env;
for (const i of WebAssembly.Module.imports(mod))
  if (i.kind === "function" && !(i.name in have)) rt.opts.imports[i.name] = () => 0;
rt.start(mod).then(() => {
  rt.flushConsole();
  process.exit(rt.exited || 0);
}, (e) => {
  rt.flushConsole();
  console.error(String(e && e.stack || e));
  process.exit(rt.exited || 1);
});
