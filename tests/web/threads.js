// Drives tests/web/threadcheck in headless Chromium (Playwright): the page
// at process.argv[2] (built with `retroweb --threads`), what it checked
// (PASS/FAIL on the console). process.argv[3]: "threads" (it must run with
// them: crossOriginIsolated, the threads' build), "one" (it must not) or
// "chat" (tests/web/chatcheck).
// Exit code: the failures.
const { chromium } = require("playwright");

(async () => {
  const url = process.argv[2] || "http://127.0.0.1:8768/";
  const want = process.argv[3] || "threads";
  const browser = await chromium.launch();
  const page = await (await browser.newContext()).newPage();
  let failures = 0, done = null;
  const lines = [];
  page.on("console", (m) => {
    const t = m.text();
    lines.push(t);
    if (/^(PASS|FAIL)/.test(t)) { console.log(t); if (t.startsWith("FAIL")) failures++; }
    if (/^(THREADS|CHAT) (DONE|NONE)/.test(t)) done = t;
  });
  page.on("pageerror", (e) => { console.log("FAIL a page error: " + e.message); failures++; });
  try {
    await page.goto(url);
    const t0 = Date.now();
    while (!done && Date.now() - t0 < 60000) await page.waitForTimeout(100);
    const isolated = await page.evaluate(() => self.crossOriginIsolated === true);
    const threaded = await page.evaluate(() => !!(document.getElementById("retro").retro || {}).threads);
    if (!done) { console.log("FAIL the page did not finish:\n  " + lines.slice(-12).join("\n  ")); failures++; }
    else if (want === "chat") {
      if (done !== "CHAT DONE") { console.log("FAIL chat: " + done); failures++; }
    } else if (want === "threads") {
      if (!done.startsWith("THREADS DONE") || !isolated || !threaded) {
        console.log("FAIL threads: " + done + " (isolated " + isolated + ", workers " + threaded + ")");
        failures++;
      } else console.log("PASS the page with threads (" + done.slice(13) + " on parallelFor)");
      if (!lines.some((l) => l.startsWith("a thread says hello"))) { console.log("FAIL a thread's echo"); failures++; }
    } else {
      if (done !== "THREADS NONE" || threaded) { console.log("FAIL one thread: " + done); failures++; }
      else console.log("PASS the page without threads (its fallback)");
    }
  } catch (e) {
    console.log("FAIL " + e.message);
    failures++;
  }
  await browser.close();
  process.exit(failures);
})();
