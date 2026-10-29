// The report as a short MP4, like the macOS app: every page plays its entrance and crossfades into
// the next. Each frame draws the living background on a canvas, then the page's own markup seeked
// to that moment (as an SVG image), and WebCodecs encodes the canvas to H.264.
const VIDEO = { W: 1200, H: 790, SCALE: 1.6, FPS: 30, FADE: 0.5, COVER_LEAD: 1.4 };

/** Pages with start times; long enough for each entrance and count-up to finish and be read. */
function videoTimeline(r) {
  let t = 0;
  const pages = slideList(r).map((name) => {
    const duration = name === "cover" ? 2.6 : name === "summary" ? 5.0
      : ["week", "tokens", "agents", "rhythm", "persona"].includes(name) ? 4.2 : 3.8;
    const page = { name, start: t, duration };
    t += duration - VIDEO.FADE;
    return page;
  });
  return { pages, duration: t + VIDEO.FADE };
}

/** CSS cubic-bezier() timing, for seeking transitions the way the stylesheet runs them. */
function cubicBezier(x1, y1, x2, y2) {
  const at = (a, b, t) => 3 * a * t * (1 - t) ** 2 + 3 * b * t * t * (1 - t) + t ** 3;
  return (x) => {
    if (x <= 0) return 0;
    if (x >= 1) return 1;
    let lo = 0, hi = 1, t = x;
    for (let i = 0; i < 24; i++) {
      t = (lo + hi) / 2;
      if (at(x1, x2, t) < x) lo = t; else hi = t;
    }
    return at(y1, y2, t);
  };
}
const SETTLE = cubicBezier(0.2, 0.85, 0.25, 1);
const progress = (t, delay, length, ease = SETTLE) => ease(Math.min(1, Math.max(0, (t - delay) / length)));

// Frames are rendered without the stylesheet's animations; seekPage() sets each moment inline.
// The cover and the last page keep their content but not their buttons.
const VIDEO_CSS = `
.vroot { position: relative; width: ${VIDEO.W}px; height: ${VIDEO.H}px; overflow: hidden; color: var(--text); font-family: var(--ui); -webkit-font-smoothing: antialiased; }
.vroot, .vroot * { animation: none !important; transition: none !important; }
.vroot .year-btn, .vroot .cta { visibility: hidden; }
.vroot .summary .sub, .vroot .summary .actions { display: none; }
.v-seg { position: absolute; top: 20px; left: 28px; right: 28px; display: flex; gap: 5px; }
.v-seg i { flex: 1; height: 3px; border-radius: 3px; background: rgba(255,255,255,.22); }
.v-seg i.past { background: rgba(255,255,255,.75); }
.v-seg i.now { background: #fff; }
.v-foot { position: absolute; left: 28px; right: 28px; bottom: 26px; display: flex; align-items: center; }
.v-foot b { font-size: 12px; font-weight: 600; letter-spacing: 2px; opacity: .5; }
.v-foot span { margin-left: auto; font-size: 13px; font-weight: 600; opacity: .6; font-variant-numeric: tabular-nums; }`;

/** Puts a page's entrance at `t` seconds: reveals, count-ups, growing bars, the clock. */
function seekPage(el, t) {
  el.querySelectorAll(".rv").forEach((n) => {
    const p = progress(t, parseFloat(n.style.getPropertyValue("--d")) || 0, 0.8);
    n.style.opacity = p;
    n.style.transform = p < 1 ? `translateY(${(1 - p) * 26}px)` : "none";
    n.style.filter = p < 1 ? `blur(${(1 - p) * 10}px)` : "none";
  });
  el.querySelectorAll("[data-count]").forEach((n) => {
    const target = +n.dataset.count, ref = +n.dataset.ref || target;
    const format = n.dataset.fmt === "usd" ? Fmt.usd : Fmt.scaled;
    n.textContent = format(target * progress(t, 0.25, 1.7, (x) => 1 - (1 - x) ** 4), ref);
  });
  el.querySelectorAll(".bar i[data-w]").forEach((i) => {
    const p = progress(t, +(i.dataset.delay || 0.3), 1.1);
    i.style.width = `calc(max(var(--h, 14px), ${i.dataset.w * 100}%) * ${p})`;
  });
  el.querySelectorAll("i[data-hgt]").forEach((i, n) => {
    const p = progress(t, 0.5 + n * 0.02, 1.0);
    i.style.height = `${+i.dataset.h0 + (i.dataset.hgt - i.dataset.h0) * p}px`;
  });
  el.querySelectorAll(".clock .wedges").forEach((g) => {
    const p = progress(t, 0.4, 1.4);
    g.style.opacity = p;
    g.style.transform = `scale(${0.35 + 0.65 * p})`;
  });
}

/** Film grain: one noise tile, laid over the frame like the page's .grain layer. */
let grainTile;
function grainPattern(ctx) {
  if (!grainTile) {
    grainTile = document.createElement("canvas");
    grainTile.width = grainTile.height = 288;
    const g = grainTile.getContext("2d"), img = g.createImageData(288, 288);
    for (let i = 0; i < img.data.length; i += 4) {
      const v = Math.random() * 255;
      img.data[i] = img.data[i + 1] = img.data[i + 2] = v;
      img.data[i + 3] = 255;
    }
    g.putImageData(img, 0, 0);
  }
  return ctx.createPattern(grainTile, "repeat");
}

/** The page background at time `t`: the same nine drifting blobs as setBackground(). */
function drawBackground(ctx, palette, t) {
  const { width: w, height: h } = ctx.canvas;
  const vw = w / 100, vh = h / 100, vmax = Math.max(vw, vh);
  const [mesh] = PALETTES[palette];
  ctx.fillStyle = mesh[6];
  ctx.fillRect(0, 0, w, h);
  mesh.forEach((color, i) => {
    const dx = ((i * 37) % 9) - 4, dy = ((i * 53) % 7) - 3, dur = 16 + ((i * 7) % 11);
    const phase = (t / dur) % 2, k = phase < 1 ? phase : 2 - phase;
    const e = (1 - Math.cos(Math.PI * k)) / 2;
    const x = (i % 3) * 0.5 * w + dx * vw * e, y = Math.floor(i / 3) * 0.5 * h + dy * vh * e;
    const g = ctx.createRadialGradient(x, y, 0, x, y, 47.5 * vmax);
    g.addColorStop(0, color);
    g.addColorStop(1, color + "00");
    ctx.fillStyle = g;
    ctx.fillRect(0, 0, w, h);
  });
  ctx.save();
  ctx.globalCompositeOperation = "overlay";
  ctx.globalAlpha = 0.07;
  ctx.fillStyle = grainPattern(ctx);
  ctx.fillRect(0, 0, w, h);
  ctx.restore();
  const shade = ctx.createLinearGradient(0, 0, 0, h);
  shade.addColorStop(0, "rgba(0,0,0,.25)");
  shade.addColorStop(0.35, "rgba(0,0,0,0)");
  shade.addColorStop(0.65, "rgba(0,0,0,0)");
  shade.addColorStop(1, "rgba(0,0,0,.35)");
  ctx.fillStyle = shade;
  ctx.fillRect(0, 0, w, h);
}

const loadImage = (url) => new Promise((resolve, reject) => {
  const img = new Image();
  img.onload = () => resolve(img);
  img.onerror = () => reject(new Error("页面渲染失败"));
  img.src = url;
});

/** H.264 at 1920×1264 needs level 5.1; prefer High, fall back to Main and Baseline. */
async function encoderConfig(width, height) {
  for (const codec of ["avc1.640033", "avc1.4d0033", "avc1.420033"]) {
    const config = { codec, width, height, bitrate: 8_000_000, framerate: VIDEO.FPS, avc: { format: "avc" }, latencyMode: "quality" };
    try {
      if ((await VideoEncoder.isConfigSupported(config)).supported) return config;
    } catch { /* try the next profile */ }
  }
  throw new Error("这台电脑不支持 H.264 视频编码");
}

/** Renders the whole report and returns the MP4 bytes. */
async function exportVideo(r, cardURL, onProgress = () => {}) {
  if (typeof VideoEncoder === "undefined") throw new Error("这个版本的 WebView2 不支持视频编码");
  const { pages, duration } = videoTimeline(r);
  const width = VIDEO.W * VIDEO.SCALE, height = VIDEO.H * VIDEO.SCALE;
  const config = await encoderConfig(width, height);
  // The stylesheet as written: re-serialized rules lose shorthands that use var(), like .grad's gradient text.
  const css = (await (await fetch(document.querySelector('link[rel="stylesheet"]').href)).text()) + VIDEO_CSS;

  // Lay the pages out off screen, at the app's design size, so bar sizes resolve as on screen.
  const host = document.createElement("div");
  host.style.cssText = `position:fixed;left:0;top:0;width:${VIDEO.W}px;height:${VIDEO.H}px;visibility:hidden;pointer-events:none;z-index:-1;contain:strict`;
  document.body.appendChild(host);
  const built = pages.map((page, index) => {
    const def = SLIDES[page.name];
    const el = document.createElement("section");
    el.className = "slide";
    el.innerHTML = def.html(r, { cardURL, width: VIDEO.W });
    host.appendChild(el);
    el.querySelectorAll("i[data-hgt]").forEach((i) => { i.dataset.h0 = parseFloat(getComputedStyle(i).height) || 0; });
    const palette = typeof def.palette === "function" ? def.palette(r) : def.palette;
    const segments = pages.map((_, i) => `<i class="${i < index ? "past" : i === index ? "now" : ""}"></i>`).join("");
    const chrome = `<div class="v-seg">${segments}</div><div class="v-foot"><b>AI WRAPPED · ${esc(r.year ?? r.period.label)}</b><span>${index + 1} / ${pages.length}</span></div>`;
    return { ...page, el, palette, chrome, accent: PALETTES[palette][1], markup: "", image: null };
  });

  const serializer = new XMLSerializer();
  /** The page's content at local time `t`, re-rendered only when it changed. */
  async function contentAt(page, t) {
    seekPage(page.el, t);
    const markup = serializer.serializeToString(page.el);
    if (markup !== page.markup || !page.image) {
      const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="${width}" height="${height}" viewBox="0 0 ${VIDEO.W} ${VIDEO.H}">`
        + `<foreignObject x="0" y="0" width="${VIDEO.W}" height="${VIDEO.H}">`
        + `<div xmlns="http://www.w3.org/1999/xhtml" class="vroot" style="--accent:${page.accent}"><style><![CDATA[${css}]]></style>`
        + markup + page.chrome + `</div></foreignObject></svg>`;
      // A data: URL keeps the canvas exportable; a blob: URL with <foreignObject> taints it.
      page.image = await loadImage("data:image/svg+xml;charset=utf-8," + encodeURIComponent(svg));
      page.markup = markup;
    }
    return page.image;
  }

  const canvas = document.createElement("canvas");
  canvas.width = width;
  canvas.height = height;
  const ctx = canvas.getContext("2d");
  const layer = document.createElement("canvas");
  layer.width = width;
  layer.height = height;
  const lctx = layer.getContext("2d");

  const muxer = new Mp4Muxer.Muxer({
    target: new Mp4Muxer.ArrayBufferTarget(),
    video: { codec: "avc", width, height, frameRate: VIDEO.FPS },
    fastStart: "in-memory",
  });
  let failure = null;
  const encoder = new VideoEncoder({ output: (chunk, meta) => muxer.addVideoChunk(chunk, meta), error: (e) => { failure = e; } });
  encoder.configure(config);

  try {
    const frames = Math.ceil(duration * VIDEO.FPS);
    const last = built.length - 1;
    for (let f = 0; f < frames; f++) {
      if (failure) throw failure;
      const time = f / VIDEO.FPS;
      // The outgoing page stays underneath while the next one fades in over it.
      for (const [i, page] of built.entries()) {
        if (time < page.start || (time >= page.start + page.duration && i !== last)) continue;
        const local = time - page.start + (i === 0 ? VIDEO.COVER_LEAD : 0);
        drawBackground(lctx, page.palette, time);
        lctx.drawImage(await contentAt(page, local), 0, 0, width, height);
        ctx.globalAlpha = i === 0 ? 1 : Math.min(1, (time - page.start) / VIDEO.FADE);
        ctx.drawImage(layer, 0, 0);
      }
      ctx.globalAlpha = 1;
      const frame = new VideoFrame(canvas, { timestamp: Math.round((f * 1e6) / VIDEO.FPS), duration: Math.round(1e6 / VIDEO.FPS) });
      encoder.encode(frame, { keyFrame: f % (VIDEO.FPS * 2) === 0 });
      frame.close();
      while (encoder.encodeQueueSize > 4) await new Promise((res) => setTimeout(res, 2));
      onProgress((f + 1) / frames);
    }
    await encoder.flush();
    if (failure) throw failure;
    muxer.finalize();
    return new Uint8Array(muxer.target.buffer);
  } finally {
    if (encoder.state !== "closed") encoder.close();
    host.remove();
  }
}
