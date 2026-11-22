// Drives tests/web/gpucheck in headless Chromium (Playwright): the page at process.argv[2] loaded
// twice -- asked to draw with the GPU (?gpu=1: forced, Chromium's GPU here being SwiftShader) and
// not asked --, the app's word on what drew it checked, and the two canvases compared: the GPU's
// frame the CPU's within a few levels (text is smoothed a hair differently). Exit code: the
// failures.
const { chromium } = require("playwright");

(async () => {
  const url = process.argv[2] || "http://localhost:8767/";
  const browser = await chromium.launch({ args: ["--enable-unsafe-swiftshader"] });
  let failures = 0;
  const shot = async (query) => {
    const page = await browser.newPage({ viewport: { width: 480, height: 320 }, deviceScaleFactor: 1 });
    const lines = [];
    page.on("console", (m) => lines.push(m.text()));
    page.on("pageerror", (e) => { console.log("FAIL a page error: " + e.message); failures++; });
    await page.goto(url + query);
    for (let i = 0; i < 300 && !lines.some((l) => l === "READY"); i++) await page.waitForTimeout(50);
    await page.waitForTimeout(400);
    const said = lines.find((l) => l.startsWith("GPU ")) || "(nothing said)";
    const px = await page.evaluate(() => {
      const shown = document.querySelector("#retro canvas");
      const c = document.createElement("canvas");
      c.width = shown.width;
      c.height = shown.height;
      const x = c.getContext("2d");
      x.drawImage(shown, 0, 0);
      return { w: c.width, h: c.height, data: Array.from(x.getImageData(0, 0, c.width, c.height).data) };
    });
    const gpuLines = lines.filter((l) => l.startsWith("[gpu]"));
    await page.close();
    return { said, px, gpuLines };
  };
  try {
    const gpu = await shot("?gpu=1");
    const cpu = await shot("");
    if (gpu.said.startsWith("GPU yes")) console.log("PASS asked, the GPU drew: " + gpu.said);
    else { console.log("FAIL asked, the GPU did not draw: " + gpu.said + " " + gpu.gpuLines.join(" | ")); failures++; }
    if (cpu.said.startsWith("GPU no")) console.log("PASS not asked, the CPU drew: " + cpu.said);
    else { console.log("FAIL not asked: " + cpu.said); failures++; }
    if (gpu.px.w !== cpu.px.w || gpu.px.h !== cpu.px.h) {
      console.log("FAIL the canvases' sizes: " + gpu.px.w + "x" + gpu.px.h + " and " + cpu.px.w + "x" + cpu.px.h);
      failures++;
    } else {
      // (the same frame: every pixel within 24 levels but for a few at the edges of letters)
      let far = 0, colors = new Set();
      const a = gpu.px.data, b = cpu.px.data;
      for (let i = 0; i < a.length; i += 4) {
        const d = Math.max(Math.abs(a[i] - b[i]), Math.abs(a[i + 1] - b[i + 1]), Math.abs(a[i + 2] - b[i + 2]));
        if (d > 24) far++;
        if (colors.size < 64) colors.add((a[i] << 16) | (a[i + 1] << 8) | a[i + 2]);
      }
      const n = a.length / 4, share = far / n;
      if (colors.size > 4 && share < 0.005)
        console.log("PASS the GPU's frame is the CPU's: " + far + " of " + n + " pixels apart, " + colors.size + "+ colors");
      else { console.log("FAIL the GPU's frame and the CPU's: " + far + " of " + n + " pixels apart, " + colors.size + " colors"); failures++; }
    }
  } catch (e) {
    console.log("FAIL " + e.message);
    failures++;
  }
  await browser.close();
  process.exit(failures);
})();
