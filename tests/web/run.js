// Drives tests/web/webcheck in headless Chromium (Playwright): the page at
// process.argv[2]; the app says where its widgets are and what it checked
// (the console), this side clicks, types, pastes, and compares the canvas
// with the frame the app drew. process.argv[4] "threads": the page must
// have run with them (`retroweb --threads`). Exit code: the failures.
const { chromium } = require("playwright");

(async () => {
  const url = process.argv[2] || "http://localhost:8766/";
  const scale = +(process.argv[3] || 1);
  // (a camera and a microphone of Chromium's own: a moving picture, a tone)
  const browser = await chromium.launch({ args: ["--use-fake-device-for-media-stream",
                                                 "--use-fake-ui-for-media-stream"] });
  const context = await browser.newContext({ viewport: { width: 800, height: 600 }, deviceScaleFactor: scale,
    acceptDownloads: true, permissions: ["geolocation", "notifications", "camera", "microphone"],
    geolocation: { latitude: 23.588, longitude: 58.3829, accuracy: 20 } });
  const page = await context.newPage();
  let failures = 0;
  // a file the app wrote in /downloads comes as a download; the browser's
  // file chooser gets a file
  page.on("download", async (d) => {
    if (d.suggestedFilename() !== "saved.txt") return;
    const t = require("fs").readFileSync(await d.path(), "utf8");
    if (t === "saved by the app") console.log("PASS a file handed to the user: saved.txt");
    else { console.log("FAIL the file handed over says: " + t); failures++; }
  });
  page.on("filechooser", (fc) => fc.setFiles({ name: "picked.txt", mimeType: "text/plain",
                                                buffer: Buffer.from("picked by the browser") }));
  const lines = [];
  const waiters = [];
  let quiet = false;           // (after the reload: the page's checks wait for input that does not come)
  page.on("console", (m) => {
    const t = m.text();
    lines.push(t);
    if (/^(PASS|FAIL)/.test(t) && !quiet) console.log(t);
    for (const w of waiters.slice()) if (t.startsWith(w.prefix)) { waiters.splice(waiters.indexOf(w), 1); w.ok(t); }
  });
  page.on("pageerror", (e) => { console.log("FAIL a page error: " + e.message); process.exitCode = 1; });
  const waitFor = (prefix, ms = 20000) => {
    const seen = lines.find((l) => l.startsWith(prefix));
    if (seen) return Promise.resolve(seen);
    return new Promise((ok, bad) => {
      waiters.push({ prefix, ok });
      setTimeout(() => bad(new Error("no " + prefix)), ms);
    });
  };
  try {
    await page.goto(url);
    await waitFor("READY");
    const at = {};
    for (const l of lines) {
      const m = /^AT (\w+) (\d+) (\d+)/.exec(l);
      if (m) at[m[1]] = [+m[2] / scale, +m[3] / scale];
    }
    await page.mouse.click(...at.button);
    await page.waitForTimeout(150);
    await page.mouse.click(...at.button);
    await waitFor("NEXT typing");
    await page.mouse.click(...at.edit);
    await page.keyboard.press("Control+A");
    await page.keyboard.type("Hello, browser!");
    await waitFor("NEXT paste");
    await page.mouse.click(...at.edit);
    await page.keyboard.press("Control+A");
    await page.evaluate(() => {
      const t = document.querySelector("#retro textarea");
      t.dispatchEvent(new KeyboardEvent("keydown", { code: "KeyV", key: "v", ctrlKey: true, bubbles: true }));
      const dt = new DataTransfer();
      dt.setData("text/plain", "Grüße ✓ 你好");
      t.dispatchEvent(new ClipboardEvent("paste", { clipboardData: dt, bubbles: true }));
      t.dispatchEvent(new KeyboardEvent("keyup", { code: "KeyV", key: "v", ctrlKey: true, bubbles: true }));
    });
    await waitFor("NEXT list");
    await page.mouse.click(...at.list);
    await page.keyboard.press("ArrowDown");
    await page.keyboard.press("ArrowDown");
    await waitFor("NEXT open", 40000);
    {
      const m = lines.map((l) => /^AT open (\d+) (\d+)/.exec(l)).filter(Boolean).pop();
      if (m) await page.mouse.click(+m[1] / scale, +m[2] / scale);
    }
    await waitFor("NEXT access", 40000);
    {
      // the window's controls as ARIA; the button pressed as a screen reader does
      const aria = await page.evaluate(() => {
        const b = document.querySelector('#retro-access [role="button"][aria-label="Press"]');
        const n = document.querySelectorAll("#retro-access [data-rid]").length;
        if (b) b.click();
        return [!!b, n];
      });
      if (aria[0]) console.log("PASS the controls as ARIA: " + aria[1] + " elements, the button among them");
      else { console.log("FAIL no ARIA button (" + aria[1] + " elements)"); failures++; }
      const media = await page.evaluate(() => navigator.mediaSession && navigator.mediaSession.metadata ?
        navigator.mediaSession.metadata.title + " / " + navigator.mediaSession.playbackState : "none");
      if (media === "webcheck song / playing") console.log("PASS the browser's media controls: " + media);
      else { console.log("FAIL the media controls: " + media); failures++; }
      const sealed = await page.evaluate(() => localStorage.getItem("retro-secrets-webcheck") || "");
      if (sealed.length > 20 && !sealed.includes("s3cr")) console.log("PASS the secrets sealed in the page's storage");
      else { console.log("FAIL the secrets as stored: " + sealed); failures++; }
    }
    const done = await waitFor("DONE", 40000);
    failures += +done.split(" ")[1];
    // the canvas: the frame the app drew, pixel for pixel
    const diff = await page.evaluate(async () => {
      const rt = document.getElementById("retro").retro;
      const n = rt.fs.nodes.get("/tmp/drawn.png");
      if (!n) return "no frame";
      const bmp = await createImageBitmap(new Blob([n.data.slice(0, n.size)], { type: "image/png" }));
      const c = document.createElement("canvas");
      c.width = bmp.width;
      c.height = bmp.height;
      const x = c.getContext("2d");
      x.drawImage(bmp, 0, 0);
      const drawn = x.getImageData(0, 0, c.width, c.height).data;
      const shownCanvas = document.querySelector("#retro canvas");
      if (shownCanvas.width !== c.width || shownCanvas.height !== c.height)
        return "sizes: " + shownCanvas.width + "x" + shownCanvas.height + " and " + c.width + "x" + c.height;
      // (the page's canvas is WebGL's or a 2D one: read through a copy)
      const copy = document.createElement("canvas");
      copy.width = c.width;
      copy.height = c.height;
      const cx = copy.getContext("2d");
      cx.drawImage(shownCanvas, 0, 0);
      const shown = cx.getImageData(0, 0, c.width, c.height).data;
      let d = 0, x0 = 1e9, y0 = 1e9, x1 = -1, y1 = -1;
      for (let i = 0; i < drawn.length; i += 4)
        if (drawn[i] !== shown[i] || drawn[i + 1] !== shown[i + 1] || drawn[i + 2] !== shown[i + 2]) {
          d++;
          const px = (i / 4) % c.width, py = Math.floor(i / 4 / c.width);
          x0 = Math.min(x0, px); y0 = Math.min(y0, py); x1 = Math.max(x1, px); y1 = Math.max(y1, py);
        }
      return d === 0 ? 0 : d + " pixels, in " + x0 + "," + y0 + " .. " + x1 + "," + y1;
    });
    if (diff === 0) console.log("PASS the canvas shows the frame the app drew");
    else { console.log("FAIL the canvas and the frame differ: " + diff); failures++; }
    // a file written stays after a reload (IndexedDB)
    await page.waitForTimeout(800);
    lines.length = 0;
    quiet = true;
    await page.reload();
    await waitFor("READY");
    // (the app comes to its files after the steps before them have waited
    // for input that does not come this time: some seconds)
    let kept;
    for (let t = 0; t < 600 && !kept; t++) {
      kept = lines.find((l) => l.includes("a file written in the home folder"));
      if (!kept) await page.waitForTimeout(100);
    }
    if (kept && kept.includes("was: written")) console.log("PASS a file kept across a reload");
    else { console.log("FAIL the file was not kept: " + kept); failures++; }
    if (process.argv[4] === "threads") {
      // (a build with threads: the page took it, its workers running)
      const n = await page.evaluate(() => {
        const t = document.getElementById("retro").retro.threads;
        return self.crossOriginIsolated && t ? t.slots.length : 0;
      });
      if (n > 0) console.log("PASS the page ran with threads: " + n + " workers");
      else { console.log("FAIL the page ran without threads"); failures++; }
    }
  } catch (e) {
    console.log("FAIL " + e.message);
    failures++;
  }
  if (failures > 0) {
    console.log("-- the page's last lines:");
    for (const l of lines.slice(-25)) console.log("   " + l);
  }
  await browser.close();
  console.log(failures === 0 ? "web: ok" : "web: " + failures + " failed");
  process.exit(failures);
})();
