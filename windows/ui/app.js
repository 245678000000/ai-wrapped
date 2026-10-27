// App controller: scanning, navigation, background, window chrome.
const TAURI = window.__TAURI__;
const $ = (sel) => document.querySelector(sel);

const state = { report: null, years: [], slides: [], index: 0, cardURL: "", cardCanvas: null, scanning: false };

// ---------- backend ----------
async function scan(onProgress) {
  if (!TAURI) {
    // Opened in a plain browser (UI development): use a report exported with --dump-json.
    onProgress(0.6, "示例数据");
    const r = await (await fetch("sample-report.json")).json();
    return { years: r.years, sample: r };
  }
  const unlisten = await TAURI.event.listen("scan-progress", (e) => onProgress(e.payload.fraction, e.payload.label));
  try {
    return { years: await TAURI.core.invoke("start_scan") };
  } finally {
    unlisten();
  }
}

async function loadReport(year, sample) {
  if (!TAURI) return sample ?? state.report;
  return TAURI.core.invoke("get_report", { year });
}

// ---------- background ----------
function setBackground(name) {
  const [mesh, accent] = PALETTES[name];
  document.documentElement.style.setProperty("--accent", accent);
  const bg = $("#bg");
  if (bg.dataset.palette === name) return;
  bg.dataset.palette = name;
  bg.style.background = mesh[6];
  const layer = document.createElement("div");
  layer.className = "mesh";
  layer.innerHTML = mesh.map((color, i) => {
    const x = (i % 3) * 50, y = Math.floor(i / 3) * 50;
    const dx = ((i * 37) % 9) - 4, dy = ((i * 53) % 7) - 3;
    return `<i style="left:${x}%;top:${y}%;background:radial-gradient(closest-side, ${color}, ${color}00);--dur:${16 + ((i * 7) % 11)}s;--dx:${dx}vw;--dy:${dy}vh"></i>`;
  }).join("");
  bg.appendChild(layer);
  requestAnimationFrame(() => layer.classList.add("on"));
  const old = [...bg.children].slice(0, -1);
  setTimeout(() => old.forEach((el) => el.remove()), 1000);
}

// ---------- motion helpers ----------
function animateIn(root) {
  root.querySelectorAll("[data-count]").forEach((el) => {
    const target = +el.dataset.count, ref = +el.dataset.ref || target;
    const t0 = performance.now(), dur = 1700, delay = 250;
    const tick = (now) => {
      const p = Math.min(1, Math.max(0, (now - t0 - delay) / dur));
      const eased = 1 - Math.pow(1 - p, 4);
      el.textContent = Fmt.scaled(target * eased, ref);
      if (p < 1) requestAnimationFrame(tick);
    };
    el.textContent = Fmt.scaled(0, ref);
    requestAnimationFrame(tick);
  });
  requestAnimationFrame(() => requestAnimationFrame(() => {
    root.querySelectorAll(".bar i[data-w]").forEach((i) => {
      i.style.transitionDelay = `${i.dataset.delay || 0.3}s`;
      i.style.width = `max(${getComputedStyle(i.parentElement).height}, ${i.dataset.w * 100}%)`;
    });
    root.querySelectorAll("i[data-hgt]").forEach((i, n) => {
      i.style.transitionDelay = `${0.5 + n * 0.02}s`;
      i.style.height = `${i.dataset.hgt}px`;
    });
  }));
}

// ---------- rendering ----------
function render(direction = 1) {
  const r = state.report;
  const name = state.slides[state.index];
  const def = SLIDES[name];
  setBackground(def.palette);

  const stage = $("#stage");
  stage.querySelectorAll(".slide").forEach((old) => {
    old.classList.add("leaving");
    setTimeout(() => old.remove(), 450);
  });
  const el = document.createElement("section");
  el.className = "slide";
  el.dataset.name = name;
  el.innerHTML = def.html(r, { cardURL: state.cardURL });
  if (direction < 0) el.style.animationName = "slideInBack";
  stage.appendChild(el);
  animateIn(el);

  $("#segments").innerHTML = state.slides.map((_, i) => `<i class="${i < state.index ? "past" : i === state.index ? "now" : ""}"></i>`).join("");
  $("#bottombar").hidden = false;
  $("#brand").textContent = `AI WRAPPED · ${r.year ?? "全部"}`;
  $("#counter").textContent = `${state.index + 1} / ${state.slides.length}`;
  $("#prev").disabled = state.index === 0;
  $("#next").disabled = state.index === state.slides.length - 1;
}

function go(delta) { goTo(state.index + delta, delta); }
function goTo(i, direction = 1) {
  if (!state.report) return;
  const next = Math.max(0, Math.min(state.slides.length - 1, i));
  if (next === state.index) return;
  closeMenu();
  state.index = next;
  render(direction);
}

async function showReport(year, sample) {
  const r = await loadReport(year, sample);
  state.report = r;
  state.slides = slideList(r);
  state.index = 0;
  state.cardCanvas = drawCard(r);
  state.cardURL = state.cardCanvas.toDataURL("image/png");
  if (r.tokens.total === 0 && r.promptCount === 0 && r.sessionCount === 0) return showEmpty();
  render();
}

function showLoading() {
  setBackground("cover");
  $("#bottombar").hidden = true;
  $("#segments").innerHTML = "";
  $("#stage").innerHTML = `
    <section class="slide loading center">
      <div class="spark">✦</div>
      <div style="font-size:30px;font-weight:700">正在翻阅你和 AI 的聊天记录…</div>
      <div style="display:flex;flex-direction:column;align-items:center;gap:10px">
        <div class="progress"><i id="bar"></i></div>
        <div id="plabel" style="font-size:14px;opacity:.7" class="num">准备中</div>
      </div>
      <div style="font-size:13px;opacity:.55;margin-top:20px">🔒 只在本机读取 ~/.claude、~/.codex 等 20 多个 agent 的目录，不会上传任何内容</div>
    </section>`;
}

function showEmpty() {
  setBackground("summary");
  $("#bottombar").hidden = true;
  $("#stage").innerHTML = `
    <section class="slide loading center">
      <div style="font-size:54px">📭</div>
      <div style="font-size:30px;font-weight:700">没有找到本地的 agent 记录</div>
      <div style="opacity:.7;line-height:1.7">支持 Claude Code、Codex、Cursor、Qoder、Kiro、Antigravity、WorkBuddy 等 24 个 agent。<br>用它们聊过之后再回来看看吧。</div>
      <div class="cta"><button data-act="rescan">重新扫描</button></div>
    </section>`;
}

async function start() {
  if (state.scanning) return;
  state.scanning = true;
  state.report = null;
  showLoading();
  const began = performance.now();
  try {
    const result = await scan((fraction, label) => {
      const bar = $("#bar"), pl = $("#plabel");
      if (bar) bar.style.width = `${Math.max(2, fraction * 100)}%`;
      if (pl) pl.textContent = `${label} · ${Math.round(fraction * 100)}%`;
    });
    state.years = result.years;
    const wait = 1400 - (performance.now() - began);
    if (wait > 0) await new Promise((res) => setTimeout(res, wait));
    const current = new Date().getFullYear();
    const year = result.sample ? result.sample.year : result.years.includes(current) ? current : result.years.at(-1) ?? null;
    await showReport(year, result.sample);
  } catch (err) {
    console.error(err);
    showEmpty();
  } finally {
    state.scanning = false;
  }
}

// ---------- year menu ----------
function closeMenu() { document.querySelector(".menu")?.remove(); }
function toggleMenu(anchor) {
  if (document.querySelector(".menu")) return closeMenu();
  const menu = document.createElement("div");
  menu.className = "menu";
  menu.innerHTML = [...state.years].reverse().map((y) => `<button data-year="${y}">${y} 年</button>`).join("")
    + `<hr><button data-year="all">全部时间</button><hr><button data-act="rescan">重新扫描本地记录</button>`;
  anchor.parentElement.appendChild(menu);
}

// ---------- share card ----------
function toast(text) {
  const t = $("#toast");
  t.textContent = text;
  t.hidden = false;
  clearTimeout(toast.timer);
  toast.timer = setTimeout(() => (t.hidden = true), 2200);
}

async function saveCard() {
  const name = `AI年度报告-${state.report.year ?? "全部"}.png`;
  if (TAURI) {
    const ok = await TAURI.core.invoke("save_png", { dataUrl: state.cardURL, fileName: name });
    if (ok) toast("已保存");
  } else {
    const a = document.createElement("a");
    a.href = state.cardURL;
    a.download = name;
    a.click();
  }
}

async function copyCard() {
  try {
    const blob = await new Promise((res) => state.cardCanvas.toBlob(res, "image/png"));
    await navigator.clipboard.write([new ClipboardItem({ "image/png": blob })]);
    toast("已复制到剪贴板");
  } catch (err) {
    console.error(err);
    toast("复制失败，请用“保存为图片”");
  }
}

// ---------- events ----------
document.addEventListener("click", async (e) => {
  const yearBtn = e.target.closest("[data-year]");
  if (yearBtn) {
    closeMenu();
    const y = yearBtn.dataset.year;
    return showReport(y === "all" ? null : +y);
  }
  const act = e.target.closest("[data-act]")?.dataset.act;
  if (act === "next") return go(1);
  if (act === "year-menu") return toggleMenu(e.target.closest("button"));
  if (act === "rescan") { closeMenu(); return start(); }
  if (act === "save") return saveCard();
  if (act === "copy") return copyCard();
  if (act === "restart") return goTo(0, -1);
  if (e.target.closest("button, .menu, #titlebar, #bottombar")) return;
  closeMenu();
  // Click to page through, like stories: left edge goes back.
  const name = state.slides[state.index];
  if (!state.report || name === "cover" || name === "summary") return;
  go(e.clientX < 260 ? -1 : 1);
});

document.addEventListener("keydown", (e) => {
  if (e.ctrlKey || e.metaKey || e.altKey) {
    if ((e.key === "r" || e.key === "R") && (e.ctrlKey || e.metaKey)) { e.preventDefault(); start(); }
    return;
  }
  if (["ArrowRight", "ArrowDown", " ", "Enter", "PageDown"].includes(e.key)) { e.preventDefault(); go(1); }
  if (["ArrowLeft", "ArrowUp", "PageUp"].includes(e.key)) { e.preventDefault(); go(-1); }
  if (e.key === "Home") goTo(0, -1);
  if (e.key === "Escape") closeMenu();
});

$("#prev").onclick = () => go(-1);
$("#next").onclick = () => go(1);

if (TAURI) {
  const win = TAURI.window.getCurrentWindow();
  $("#win-min").onclick = () => win.minimize();
  $("#win-max").onclick = () => win.toggleMaximize();
  $("#win-close").onclick = () => win.close();
} else {
  document.querySelector(".caption").style.visibility = "hidden";
}

// Slides are laid out for 1200×790; scale everything with the window (small laptops, maximized).
let uiScale = 1;
function fitToWindow() {
  uiScale = Math.max(0.6, Math.min(1.6, innerWidth / 1200, innerHeight / 790));
  document.body.style.zoom = uiScale;
}
fitToWindow();
let resizeTimer;
window.addEventListener("resize", () => {
  fitToWindow();
  clearTimeout(resizeTimer);
  resizeTimer = setTimeout(() => { if (state.slides[state.index] === "calendar") render(); }, 200);
});

start();
