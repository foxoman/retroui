// Drives tests/web/bigcheck in headless Chromium (Playwright): the page at process.argv[2] (built
// with `retroweb --threads`). First visit: the big file written; the next: read back left in the
// browser's storage (the page holds no copy of it); a file dropped on the page, big, left there too
// and read a piece at a time; the page again with no network (its service worker's copies);
// WebGPU's numbers for a thread (Chromium started with WebGPU on: the GPU's, or SwiftShader's).
// Exit code: the failures.
const { chromium } = require("playwright");

(async () => {
  const url = process.argv[2] || "http://127.0.0.1:8770/";
  const browser = await chromium.launch({
    args: ["--enable-unsafe-webgpu", "--enable-features=Vulkan", "--use-vulkan=swiftshader",
           "--use-webgpu-adapter=swiftshader", "--ignore-gpu-blocklist"] });
  const context = await browser.newContext();
  const page = await context.newPage();
  let failures = 0;
  const lines = [];
  page.on("console", (m) => {
    const t = m.text();
    lines.push(t);
    if (/^(PASS|FAIL)/.test(t)) { console.log(t); if (t.startsWith("FAIL")) failures++; }
    if (/^WEBGPU/.test(t)) console.log(t);
  });
  page.on("pageerror", (e) => { console.log("FAIL a page error: " + e.message); failures++; });
  // (what could not be fetched -- offline: what the service worker did not have)
  context.on("requestfailed", (r) => lines.push("REQUEST FAILED " + r.url() + " " +
                                                (r.failure() ? r.failure().errorText : "")));
  const until = async (what, ms) => {
    const t0 = Date.now();
    while (!lines.some((l) => l.startsWith(what)) && Date.now() - t0 < ms) await page.waitForTimeout(100);
    return lines.some((l) => l.startsWith(what));
  };
  try {
    await page.goto(url);
    if (!(await until("BIG DONE", 90000)) || !lines.some((l) => l.startsWith("BIG WRITTEN"))) {
      console.log("FAIL the first visit did not finish:\n  " + lines.slice(-12).join("\n  "));
      failures++;
    }
    await page.waitForTimeout(1500);              // (kept in IndexedDB a moment after it is written)
    lines.length = 0;
    await page.reload();
    if (!(await until("BIG DONE", 90000)) || !lines.some((l) => l.startsWith("BIG READ"))) {
      console.log("FAIL the next visit did not read it back:\n  " + lines.slice(-12).join("\n  "));
      failures++;
    }
    const kept = await page.evaluate(() => {
      const n = document.getElementById("retro").retro.fs.nodes.get("/data/big.bin");
      return n ? { blob: n.blob instanceof Blob, data: n.data === null, size: n.size } : null;
    });
    if (kept && kept.blob && kept.data) console.log("PASS the big file left in the browser's storage (" + kept.size + " bytes, no copy in the page)");
    else { console.log("FAIL the big file in the page's memory: " + JSON.stringify(kept)); failures++; }
    // a big file dropped on the page: left where the browser has it, read a piece at a time
    const dropped = await page.evaluate(async () => {
      const fs = document.getElementById("retro").retro.fs;
      const size = 10 * 1024 * 1024 + 777;
      const b = new Uint8Array(size);
      for (let i = 0; i < size; i++) b[i] = (i * 7 + (i >> 9)) & 255;
      await fs.addGiven("/tmp/dropped/big.bin", new File([b], "big.bin"));
      const n = fs.nodes.get("/tmp/dropped/big.bin");
      let ok = n.data === null && n.blob instanceof Blob;
      for (const [a, len] of [[0, 100], [4 * 1024 * 1024 - 50, 100], [size - 30, 30], [123457, 5 * 1024 * 1024]]) {
        const d = fs.piece(n, a, a + len);
        if (!d || d.length !== len) { ok = false; continue; }
        for (let i = 0; i < len; i++) if (d[i] !== b[a + i]) { ok = false; break; }
      }
      const small = new File([new Uint8Array(1000)], "small.bin");
      await fs.addGiven("/tmp/dropped/small.bin", small);
      const s = fs.nodes.get("/tmp/dropped/small.bin");
      return { ok, stillBlob: n.data === null, small: s.data !== null && s.size === 1000 };
    });
    if (dropped.ok && dropped.stillBlob) console.log("PASS a big file dropped: left in the browser's storage, read in pieces");
    else { console.log("FAIL a big file dropped: " + JSON.stringify(dropped)); failures++; }
    if (dropped.small) console.log("PASS a small one read in at once");
    else { console.log("FAIL a small file dropped"); failures++; }
    // offline: the page from its service worker's copies, the big file from the browser's storage
    lines.length = 0;
    await context.setOffline(true);
    await page.reload();
    if (await until("BIG DONE", 90000) && lines.some((l) => l.startsWith("BIG READ")))
      console.log("PASS offline after the first visit: the page and its big file");
    else { console.log("FAIL offline:\n  " + lines.slice(-8).join("\n  ")); failures++; }
    await context.setOffline(false);
    if (lines.some((l) => l.startsWith("WEBGPU NONE")))
      console.log("(no WebGPU in this browser: its numbers not tried)");
    else if (!lines.some((l) => l.startsWith("WEBGPU OK"))) { console.log("FAIL WebGPU's numbers"); failures++; }
  } catch (e) {
    console.log("FAIL " + e.message);
    failures++;
  }
  await browser.close();
  process.exit(failures);
})();
