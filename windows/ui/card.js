// The exportable share card, drawn on a canvas so the PNG matches what is shown on screen.
const CARD_W = 600, CARD_H = 780;
const CARD_FONT = '"Segoe UI", "Microsoft YaHei UI", "PingFang SC", system-ui, sans-serif';
const CARD_DISPLAY = '"Segoe UI Black", "Arial Black", "Microsoft YaHei UI", "PingFang SC", system-ui, sans-serif';

function roundRect(ctx, x, y, w, h, r) {
  ctx.beginPath();
  ctx.moveTo(x + r, y);
  ctx.arcTo(x + w, y, x + w, y + h, r);
  ctx.arcTo(x + w, y + h, x, y + h, r);
  ctx.arcTo(x, y + h, x, y, r);
  ctx.arcTo(x, y, x + w, y, r);
  ctx.closePath();
}

/** Shrinks the font until `text` fits in `maxW`. */
function fitText(ctx, text, maxW, size, weight, family) {
  let s = size;
  do {
    ctx.font = `${weight} ${s}px ${family}`;
    if (ctx.measureText(text).width <= maxW) break;
    s -= 1;
  } while (s > 12);
}

function drawCard(r, scale = 2) {
  const canvas = document.createElement("canvas");
  canvas.width = CARD_W * scale;
  canvas.height = CARD_H * scale;
  const ctx = canvas.getContext("2d");
  ctx.scale(scale, scale);

  roundRect(ctx, 0, 0, CARD_W, CARD_H, 36);
  ctx.clip();

  const short = r.period.isShort;
  // Mesh-like background: nine colors as soft radial blobs (night sky for weeks and months).
  const [mesh] = short ? PALETTES.weeklyCover : PALETTES.persona;
  ctx.fillStyle = mesh[6];
  ctx.fillRect(0, 0, CARD_W, CARD_H);
  mesh.forEach((color, i) => {
    const x = (i % 3) * (CARD_W / 2), y = Math.floor(i / 3) * (CARD_H / 2);
    const g = ctx.createRadialGradient(x, y, 0, x, y, CARD_W * 0.75);
    g.addColorStop(0, color);
    g.addColorStop(1, color + "00");
    ctx.fillStyle = g;
    ctx.fillRect(0, 0, CARD_W, CARD_H);
  });
  const shade = ctx.createLinearGradient(0, 0, 0, CARD_H);
  shade.addColorStop(0, "rgba(0,0,0,.25)");
  shade.addColorStop(0.4, "rgba(0,0,0,0)");
  shade.addColorStop(0.7, "rgba(0,0,0,0)");
  shade.addColorStop(1, "rgba(0,0,0,.35)");
  ctx.fillStyle = shade;
  ctx.fillRect(0, 0, CARD_W, CARD_H);

  const P = 40;
  ctx.fillStyle = "rgba(255,255,255,.85)";
  ctx.textBaseline = "alphabetic";
  ctx.font = `700 13px ${CARD_FONT}`;
  if ("letterSpacing" in ctx) ctx.letterSpacing = "4px";
  ctx.fillText("AI WRAPPED", P, 62);
  if ("letterSpacing" in ctx) ctx.letterSpacing = "0px";
  ctx.font = `900 18px ${CARD_DISPLAY}`;
  ctx.textAlign = "right";
  ctx.fillText(short ? r.period.rangeText : r.year ? String(r.year) : "ALL TIME", CARD_W - P, 62);
  ctx.textAlign = "left";

  ctx.fillStyle = "rgba(255,255,255,.7)";
  ctx.font = `600 14px ${CARD_FONT}`;
  ctx.fillText(short ? `${r.period.label} AI 人格 · ${r.period.badge}` : "年度 AI 人格", P, 116);
  ctx.fillStyle = "#fff";
  ctx.font = `40px ${CARD_FONT}`;
  ctx.fillText(r.persona.emoji, P, 176);
  fitText(ctx, r.persona.title, CARD_W - P * 2 - 60, 54, 900, CARD_DISPLAY);
  ctx.fillText(r.persona.title, P + 58, 176);

  let x = P;
  ctx.font = `600 12px ${CARD_FONT}`;
  for (const tag of r.persona.tags.slice(0, 3)) {
    const w = ctx.measureText(tag).width + 20;
    ctx.fillStyle = "rgba(255,255,255,.15)";
    roundRect(ctx, x, 194, w, 24, 12);
    ctx.fill();
    ctx.fillStyle = "#fff";
    ctx.fillText(tag, x + 10, 210);
    x += w + 8;
  }

  const prev = short ? r.previous : null;
  const cells = [
    ["Tokens", Fmt.big(r.tokens.total), prev && delta(r.tokens.total, prev.tokens)],
    ["对话", `${Fmt.grouped(r.sessionCount)} 次`, prev && delta(r.sessionCount, prev.sessions)],
    ["消息", `${Fmt.grouped(r.promptCount)} 条`, prev && delta(r.promptCount, prev.prompts)],
    ["活跃", `${r.activeDays} 天`, prev && delta(r.activeDays, prev.activeDays)],
    ["头号搭档", r.agents[0]?.name ?? "—"], ["最爱模型", r.models[0]?.name ?? "—"],
    ["用过的 agent", `${r.agents.length} 个`], ["工具调用", `${Fmt.big(r.toolCallCount)} 次`],
  ];
  const cw = (CARD_W - P * 2 - 18) / 2, ch = 74;
  cells.forEach(([k, v, change], i) => {
    const cx = P + (i % 2) * (cw + 18), cy = 240 + Math.floor(i / 2) * (ch + 14);
    roundRect(ctx, cx, cy, cw, ch, 18);
    ctx.fillStyle = "rgba(255,255,255,.1)";
    ctx.fill();
    ctx.strokeStyle = "rgba(255,255,255,.15)";
    ctx.lineWidth = 1;
    ctx.stroke();
    ctx.fillStyle = "rgba(255,255,255,.65)";
    ctx.font = `600 13px ${CARD_FONT}`;
    ctx.fillText(k, cx + 16, cy + 26);
    if (change) {
      // Change chip in the cell's top-right corner, colored like the weekly page.
      const label = `${change.arrow} ${change.text}`;
      ctx.font = `700 11px ${CARD_FONT}`;
      const w = ctx.measureText(label).width + 16;
      const color = DELTA_COLORS[change.tone];
      ctx.save();
      roundRect(ctx, cx + cw - 12 - w, cy + 12, w, 20, 10);
      ctx.globalAlpha = 0.16;
      ctx.fillStyle = color;
      ctx.fill();
      ctx.restore();
      ctx.fillStyle = color;
      ctx.fillText(label, cx + cw - 12 - w + 8, cy + 26);
    }
    ctx.fillStyle = "#fff";
    fitText(ctx, v, cw - 32, 26, 800, CARD_FONT);
    ctx.fillText(v, cx + 16, cy + 58);
  });

  // Monthly bars
  const months = r.series;
  const max = Math.max(1, ...months.map((m) => m.tokens));
  const peak = months.findIndex((m) => m.tokens === max);
  const area = { x: P, y: 604, w: CARD_W - P * 2, h: 70 };
  const gap = 4, bw = (area.w - gap * (months.length - 1)) / Math.max(1, months.length);
  const every = Math.max(1, Math.floor(months.length / 12));
  ctx.textAlign = "center";
  months.forEach((m, i) => {
    const h = Math.max(3, (area.h * m.tokens) / max);
    const bx = area.x + i * (bw + gap);
    ctx.fillStyle = i === peak ? (short ? "#9EF0FF" : "#9EE6FF") : "rgba(255,255,255,.3)";
    roundRect(ctx, bx, area.y + area.h - h, bw, h, Math.min(4, bw / 2));
    ctx.fill();
    if (i % every === 0) {
      ctx.fillStyle = i === peak ? "#fff" : "rgba(255,255,255,.55)";
      ctx.font = `${i === peak ? 700 : 500} 10px ${CARD_FONT}`;
      ctx.fillText(m.label, bx + bw / 2, area.y + area.h + 16);
    }
  });
  ctx.textAlign = "left";

  ctx.fillStyle = "rgba(255,255,255,.6)";
  ctx.font = `500 12px ${CARD_FONT}`;
  ctx.fillText(short
    ? `箭头对比${r.period.comparisonLabel} · 最常在 ${r.peakHour} 点出没 · 敲下 ${Fmt.big(r.charCount)} 字`
    : `最常在 ${r.peakHour} 点出没 · 最长连续 ${r.longestStreak} 天 · 敲下 ${Fmt.big(r.charCount)} 字`, P, 742);
  ctx.textAlign = "right";
  ctx.fillText("本机生成", CARD_W - P, 742);
  ctx.textAlign = "left";
  return canvas;
}
