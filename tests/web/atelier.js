// Retro Atelier as a web page (`retroweb examples/photo.nim`) in headless Chromium (Playwright): the
// page at process.argv[2] opens, a big PSD (process.argv[3], beside the page) is dropped on it and
// opens -- how long it took, how much memory the page's program and the whole page then use --,
// the window is pictured (process.argv[4]). Exit code: the failures.
//
//   node tests/web/atelier.js http://127.0.0.1:8771/ big.psd atelier-psd.png
const { chromium } = require("playwright");

(async () => {
  const url = process.argv[2] || "http://127.0.0.1:8771/";
  const psd = process.argv[3] || "big.psd";
  const shot = process.argv[4] || "";
  const browser = await chromium.launch({
    args: ["--enable-unsafe-webgpu", "--enable-features=Vulkan", "--use-vulkan=swiftshader",
           "--use-webgpu-adapter=swiftshader", "--ignore-gpu-blocklist"] });
  const page = await (await browser.newContext({ viewport: { width: 1400, height: 900 } })).newPage();
  let failures = 0;
  const errors = [];
  page.on("pageerror", (e) => errors.push(e.message));
  page.on("console", (m) => { if (m.type() === "error") errors.push(m.text()); });
  const say = (ok, what) => { console.log((ok ? "PASS " : "FAIL ") + what); if (!ok) failures++; };
  try {
    const t0 = Date.now();
    await page.goto(url);
    await page.waitForFunction(() => {
      const r = document.getElementById("retro");
      return r && r.retro && r.retro.instance && r.retro.driver && !r.retro.driver.stopped;
    }, null, { timeout: 120000 });
    await page.waitForTimeout(4000);           // (the splash, the first frames)
    const info = await page.evaluate(() => ({
      isolated: self.crossOriginIsolated, threads: !!document.getElementById("retro").retro.threads,
      webgpu: !!navigator.gpu }));
    say(true, "the page up in " + ((Date.now() - t0) / 1000).toFixed(1) + " s (threads " + info.threads +
        ", WebGPU " + info.webgpu + ")");
    const before = await page.evaluate(() => document.getElementById("retro").retro.mem.buffer.byteLength);
    // the PSD dropped on the window (fetched from beside the page: as a file the user drags in)
    const t1 = Date.now();
    const size = await page.evaluate(async (name) => {
      const b = await (await fetch(name)).blob();
      const f = new File([b], name.slice(name.lastIndexOf("/") + 1));
      const dt = new DataTransfer();
      dt.items.add(f);
      const c = document.querySelector("#retro canvas");
      const r = c.getBoundingClientRect();
      c.dispatchEvent(new DragEvent("drop", { dataTransfer: dt, bubbles: true, cancelable: true,
                                              clientX: r.left + r.width / 2, clientY: r.top + r.height / 2 }));
      return f.size;
    }, psd);
    const base = psd.slice(psd.lastIndexOf("/") + 1);
    const stem = base.replace(/\.[^.]*$/, "");
    // (open: its document's tab, as the window's controls are mirrored for screen readers)
    const tabShown = (n) => {
      for (const e of document.querySelectorAll("[aria-label], [role]")) {
        const t = (e.getAttribute("aria-label") || e.textContent || "");
        if (t.startsWith(n + " (") || t.includes("Opened " + n + ".")) return true;
      }
      return false;
    };
    let opened = false;
    for (let i = 0; i < 600 && !opened; i++) {
      await page.waitForTimeout(500);
      opened = await page.evaluate(tabShown, stem).catch(() => false);
    }
    const secs = (Date.now() - t1) / 1000;
    say(opened, "a " + (size / 1048576).toFixed(0) + " MB PSD dropped on the page opened in " + secs.toFixed(1) + " s");
    await page.waitForTimeout(3000);
    const after = await page.evaluate(async () => {
      const rt = document.getElementById("retro").retro;
      let node = null;
      for (const [p, n] of rt.fs.nodes) if (p.startsWith("/tmp/dropped/") && !n.dir) node = n;
      let all = 0;
      try { if (performance.measureUserAgentSpecificMemory) all = (await performance.measureUserAgentSpecificMemory()).bytes; }
      catch (e) {}
      return { wasm: rt.mem.buffer.byteLength, all, kept: node ? node.data === null : null };
    });
    say(true, "memory: the program's " + (before / 1048576).toFixed(0) + " MB before, " +
        (after.wasm / 1048576).toFixed(0) + " MB with the PSD open" +
        (after.all ? "; the whole page " + (after.all / 1048576).toFixed(0) + " MB" : ""));
    if (after.kept !== null) say(after.kept, "the PSD itself left in the browser's storage (no copy in the page)");
    if (shot) await page.screenshot({ path: shot });
    say(errors.length === 0, "no errors in the page" + (errors.length ? ": " + errors.slice(0, 3).join(" | ") : ""));
  } catch (e) {
    say(false, e.message);
  }
  await browser.close();
  process.exit(failures);
})();
