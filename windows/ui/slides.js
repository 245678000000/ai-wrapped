// Each slide is { palette, html(r, ctx) }. Elements opt into motion with:
//   .rv + --d (reveal delay) · data-count/data-ref (count-up) · .bar > i[data-w] (grow) · i[data-hgt] (rise)

const count = (v, ref = v) => `<span class="num" data-count="${v}" data-ref="${ref}">${Fmt.scaled(v, ref)}</span>`;
const bar = (fraction, color, h = 14, delay = 0.3) =>
  `<div class="bar" style="--c:${color};--h:${h}px"><i data-w="${Math.max(0, Math.min(1, fraction))}" data-delay="${delay}"></i></div>`;

const ICON_CAL = `<svg width="14" height="14" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5"><rect x="2" y="3" width="12" height="11" rx="2"/><path d="M2 6.5h12M5.5 1.5v3M10.5 1.5v3"/></svg>`;
const ICON_ARROW = `<svg width="18" height="18" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round"><path d="M3 8h10M9 4l4 4-4 4"/></svg>`;
// Small glyphs for the weekly highlights (sparkle, flame, folder, chip).
const ICONS = {
  agent: `<svg viewBox="0 0 16 16"><path d="M8 1.5l1.4 4.1 4.1 1.4-4.1 1.4L8 12.5 6.6 8.4 2.5 7l4.1-1.4z" fill="currentColor"/><path d="M12.5 11l.6 1.4 1.4.6-1.4.6-.6 1.4-.6-1.4-1.4-.6 1.4-.6z" fill="currentColor"/></svg>`,
  day: `<svg viewBox="0 0 16 16"><path d="M8.5 1.5c.4 2.3 3.5 3.6 3.5 7.1A4 4 0 0 1 4 8.6c0-1.6.9-2.8 1.8-3.6.1 1.2.7 2 1.5 2.4-.2-2.2.3-4.4 1.2-5.9z" fill="currentColor"/></svg>`,
  project: `<svg viewBox="0 0 16 16"><path d="M1.5 4.5A1.5 1.5 0 0 1 3 3h3.2l1.5 1.6H13a1.5 1.5 0 0 1 1.5 1.5v5.4A1.5 1.5 0 0 1 13 13H3a1.5 1.5 0 0 1-1.5-1.5z" fill="currentColor"/></svg>`,
  model: `<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.4"><rect x="4" y="4" width="8" height="8" rx="1.5"/><rect x="6.3" y="6.3" width="3.4" height="3.4" rx=".6" fill="currentColor"/><path d="M6 1.5V4M10 1.5V4M6 12v2.5M10 12v2.5M1.5 6H4M1.5 10H4M12 6h2.5M12 10h2.5"/></svg>`,
};

function slideList(r) {
  // A week or month is a lighter read: the summary up front, no year-scale pages.
  if (r.period.isShort) {
    const empty = r.tokens.total === 0 && r.promptCount === 0;
    if (empty) return ["cover", "week"];
    const s = ["cover", "week", "tokens"];
    if (r.promptCount > 0) s.push("talk");
    if (r.agents.length) s.push("agents");
    if (r.models.length) s.push("models");
    if (r.toolCallCount > 0) s.push("tools");
    if (r.promptCount > 0) s.push("rhythm");
    if (r.projects.length) s.push("projects");
    s.push("summary");
    return s;
  }
  const s = ["cover"];
  if (r.firstPrompt) s.push("first");
  s.push("tokens");
  if (r.promptCount > 0) s.push("talk");
  if (r.agents.length) s.push("agents");
  if (r.models.length) s.push("models");
  if (r.toolCallCount > 0) s.push("tools");
  if (r.promptCount > 0) s.push("rhythm");
  s.push("calendar");
  if (r.projects.length) s.push("projects");
  s.push("persona", "summary");
  return s;
}

const SLIDES = {
  cover: {
    palette: (r) => (r.period.isShort ? "weeklyCover" : "cover"),
    html(r) {
      const p = r.period;
      const names = r.agents.slice(0, 3).map((a) => a.name).join("、");
      const lead = r.agents.length > 3 ? `${names} 等 ${r.agents.length} 个 agent，` : names ? `${names}，` : "";
      let line = `${esc(lead)}${Fmt.grouped(r.sessionCount)} 次对话，都在这里了。数据只在本机读取。`;
      if (p.isShort) {
        const empty = r.tokens.total === 0 && r.promptCount === 0;
        const partial = p.elapsedDays < p.totalDays;
        const note = p.kind === "thisWeek" && partial ? `本周才过了 ${p.elapsedDays} 天，周日晚上再来看完整版。`
          : p.kind === "thisMonth" && partial ? `这个月才过了 ${p.elapsedDays} 天。` : "数据只在本机读取。";
        line = empty ? `${p.phrase}还没有和 AI 聊过。去开个头吧。` : `${esc(lead)}${Fmt.grouped(r.sessionCount)} 次对话。${note}`;
      }
      const hero = p.isShort ? p.rangeText : r.year ?? "ALL TIME";
      const heroSize = p.isWeek ? 136 : p.isShort ? 200 : r.year ? 210 : 150;
      return `
        <div class="cover-top">
          <div class="eyebrow rv" style="--d:0s">${p.isShort ? `AI WRAPPED · ${p.isWeek ? "WEEKLY" : "MONTHLY"}` : "AI WRAPPED"}</div>
          <div class="year-btn rv" style="--d:.1s">
            <button data-act="year-menu">${ICON_CAL}<span>${esc(p.label)}</span><span style="opacity:.6">▾</span></button>
          </div>
        </div>
        <div class="grow"></div>
        <p class="h rv" style="--d:.15s;font-size:40px;opacity:.85">你的</p>
        <div class="display cover-year ${p.isShort ? "night" : ""} rv" style="--d:.25s;font-size:${heroSize}px;white-space:nowrap${p.isWeek ? ";margin:4px 0 6px" : ""}">${esc(hero)}</div>
        <div class="rv" style="--d:.35s;font-size:60px;font-weight:800">${p.isShort ? `${esc(p.label)} · ${p.reportName}` : p.reportName}</div>
        <p class="sub rv" style="--d:.5s;margin-top:14px">${line}</p>
        <div class="grow"></div>
        <div class="cta rv" style="--d:.65s">
          <button data-act="next" class="${p.isShort ? "night" : ""}">${p.isShort ? `看看${esc(p.label)}` : "开始回顾"} ${ICON_ARROW}</button>
          <button class="ghost" data-act="${p.isShort ? "to-year" : "to-week"}">${p.isShort ? "✦&nbsp; 回到年度报告" : `${ICON_CAL}&nbsp; 本周小结`}</button>
          <span style="font-size:14px;color:var(--faint);margin-left:4px">← → 或空格翻页</span>
        </div>`;
    },
  },

  week: {
    palette: "weekly",
    html(r) {
      const p = r.period, prev = r.previous;
      const kpi = (label, value, before, suffix, d) => {
        const ch = delta(value, before);
        const unit = Fmt.unit(value) + suffix;
        const was = before == null ? "&nbsp;" : `${esc(p.comparisonLabel)} ${Fmt.big(before)}${suffix ? " " + suffix : ""}`;
        return `
          <div class="card kpi rv" style="--d:${d}s">
            <div class="k-label">${label}</div>
            <div class="k-value"><span class="display">${count(value)}</span><span class="k-unit">${unit}</span></div>
            <span class="delta ${ch.tone}">${ch.arrow}&nbsp;${ch.text}</span>
            <div class="k-prev">${was}</div>
          </div>`;
      };
      const total = Math.max(1, r.tokens.total);
      const top = r.agents[0], model = r.models[0], project = r.projects[0], busy = r.busiestDay;
      const busyText = busy && (busy.tokens || busy.prompts)
        ? p.isWeek ? `周${Fmt.weekday[(new Date(busy.date + "T00:00:00Z").getUTCDay() + 6) % 7]} · ${Fmt.shortDay(busy.date)}` : Fmt.day(busy.date)
        : null;
      const row = (icon, title, value, detail, dot) => `
        <div class="hl">
          <span class="hl-icon">${ICONS[icon]}</span>
          <div class="hl-text"><small>${title}</small><b>${dot ? `<i style="background:${dot}"></i>` : ""}${esc(value ?? "—")}</b></div>
          <span class="hl-detail">${detail ?? ""}</span>
        </div>`;
      return `
        <div class="eyebrow rv">${p.isWeek ? `WEEKLY · ${esc(p.badge)} · ${esc(p.rangeText)}` : `MONTHLY · ${esc(p.rangeText)}`}</div>
        <div class="grow"></div>
        <p class="h rv" style="--d:.1s">${p.phrase}，你和 AI</p>
        <p class="sub rv" style="--d:.15s;font-size:17px;margin-top:8px;color:rgba(255,255,255,.6)">${esc(p.basis)}</p>
        <div class="kpis">
          ${kpi("Tokens", r.tokens.total, prev?.tokens, "", 0.2)}
          ${kpi("对话", r.sessionCount, prev?.sessions, "次", 0.28)}
          ${kpi("消息", r.promptCount, prev?.prompts, "条", 0.36)}
          ${kpi("活跃", r.activeDays, prev?.activeDays, "天", 0.44)}
        </div>
        <div class="grow"></div>
        <div style="display:flex;gap:28px;align-items:flex-end">
          <div class="rv" style="--d:.5s;flex:1;min-width:0">${dailyChartHTML(r)}</div>
          <div class="card highlights rv" style="--d:.62s">
            <div class="label" style="margin-bottom:4px">${esc(p.label)}之最</div>
            ${row("agent", "最常用的 agent", top?.name, top ? (top.tokens > 0 ? `${Fmt.percent(top.tokens, total)} tokens` : `${top.prompts} 条消息`) : "", top?.color)}
            ${row("day", "最忙的一天", busyText, busyText ? (busy.tokens ? Fmt.big(busy.tokens) : `${busy.prompts} 条消息`) : "")}
            ${row("project", "主要项目", project?.name, project ? `${project.prompts} 条消息` : "")}
            ${row("model", "最爱模型", model?.name, model ? Fmt.percent(model.tokens, total) : "")}
          </div>
        </div>`;
    },
  },

  first: {
    palette: "first",
    html(r) {
      const p = r.firstPrompt;
      return `
        <div class="eyebrow rv">第一句话</div>
        <div class="grow"></div>
        <p class="h rv" style="--d:.1s">${r.year ? `${r.year} 年的故事，从这一天开始` : "故事从这一天开始"}</p>
        <div class="display grad rv" style="--d:.2s;font-size:120px;margin:4px 0">${Fmt.day(p.date, !r.year)}</div>
        <p class="sub rv" style="--d:.35s;font-size:22px">${p.clock}，你对 ${esc(p.agent)} 说：</p>
        <div class="card quote rv" style="--d:.5s;flex:none;padding:28px">
          <span class="mark">“</span><p>${esc(p.preview || "（一张图片）")}</p>
        </div>
        <div class="grow"></div>
        <p class="rv" style="--d:.7s;font-size:22px;font-weight:700;color:var(--accent);margin:0">
          ${p.daysAgo > 0 ? `到今天，已经过去 ${p.daysAgo} 天。` : "就在今天。"}</p>`;
    },
  },

  tokens: {
    palette: "tokens",
    html(r) {
      const t = r.tokens, total = t.total;
      const parts = [["缓存读取", t.cacheRead, "#FFD08A"], ["缓存写入", t.cacheWrite, "#FF9F5A"], ["输入", t.input, "#FF6B6B"], ["输出", t.output, "#FFF3E0"]];
      const stack = parts.filter((p) => total && p[1] / total > 0.002)
        .map((p) => `<i style="flex:${p[1]};background:${p[2]}"></i>`).join("");
      return `
        <div class="eyebrow rv">TOKENS</div>
        <div class="grow"></div>
        <p class="h rv" style="--d:.1s">${r.period.phrase}，你和 AI 一共消耗了</p>
        <div class="rv" style="--d:.2s;display:flex;align-items:baseline;gap:14px">
          <span class="display grad" style="font-size:150px">${count(total)}</span>
          <span class="unit">${Fmt.unit(total)} tokens</span>
        </div>
        <div class="stack rv" style="--d:.45s">${stack}</div>
        <div class="legend rv" style="--d:.55s">${parts.map((p) => `<span><em style="background:${p[2]}"></em><small>${p[0]}</small><b>${Fmt.big(p[1])}</b></span>`).join("")}</div>
        <div class="grow"></div>
        <div class="row rv" style="--d:.75s">
          <div class="card"><b>≈ ${Fmt.big(Math.max(1, total / 730000))} 部《红楼梦》</b><span>按一部约 73 万字、一字约一个 token 粗算</span></div>
          <div class="card"><b>AI 亲手写下 ${Fmt.big(t.output)}</b><span>≈ ${Fmt.big(Math.max(1, t.output / 30000))} 篇 3 万字的毕业论文</span></div>
          <div class="card"><b>${Fmt.percent(t.cacheRead, total)} 是缓存</b><span>AI 反复“重读”上下文的部分，便宜又省时</span></div>
        </div>`;
    },
  },

  talk: {
    palette: "talk",
    html(r) {
      const stat = (v, label, d) => `
        <div class="rv" style="--d:${d}s">
          <div style="display:flex;align-items:baseline;gap:4px"><span class="display" style="font-size:96px">${count(v)}</span><span style="font-size:34px;font-weight:800">${Fmt.unit(v)}</span></div>
          <div style="font-size:19px;font-weight:600;color:var(--muted)">${label}</div>
        </div>`;
      const streak = r.longestStreak > 1 ? `最长连续 ${r.longestStreak} 天：${Fmt.shortDay(r.streakStart)} – ${Fmt.shortDay(r.streakEnd)}` : "每一天都是新的开始";
      return `
        <div class="eyebrow rv">对话</div>
        <div class="grow"></div>
        <p class="h rv" style="--d:.1s">你们聊了很多</p>
        <div style="display:flex;gap:56px;margin-top:26px">
          ${stat(r.sessionCount, "次对话", 0.2)}${stat(r.promptCount, "条消息由你发出", 0.35)}${stat(r.charCount, "个字由你敲下", 0.5)}
        </div>
        <div class="grow"></div>
        <div class="row rv" style="--d:.7s">
          <div class="card"><b>活跃 ${r.activeDays} 天</b><span>${streak}</span></div>
          <div class="card"><b>平均每次 ${(r.promptCount / Math.max(1, r.sessionCount)).toFixed(1)} 轮</b><span>每条消息平均 ${Math.floor(r.charCount / Math.max(1, r.promptCount))} 字</span></div>
          <div class="card"><b>≈ ${Fmt.big(Math.max(1, Math.floor(r.charCount / 800)))} 篇高考作文</b><span>按每篇 800 字算，你写给 AI 的字</span></div>
        </div>`;
    },
  },

  agents: {
    palette: "agents",
    html(r) {
      const top = r.agents[0], total = Math.max(1, r.tokens.total);
      const byTokens = r.agents.filter((a) => a.tokens > 0).slice(0, 5);
      const byTalks = [...r.agents].sort((a, b) => b.sessions - a.sessions || b.prompts - a.prompts).slice(0, 5);
      const shown = new Set([...byTokens, ...byTalks].map((a) => a.id));
      const rest = r.agents.filter((a) => !shown.has(a.id)).sort((a, b) => b.sessions - a.sessions);
      const chattiest = r.agents.reduce((m, a) => (a.prompts > m.prompts ? a : m), r.agents[0]);
      const line = chattiest.id !== top.id && chattiest.prompts > top.prompts
        ? `承包了 ${Fmt.percent(top.tokens, total)} 的 tokens · 但和你聊得最多的是 ${esc(chattiest.name)}：${Fmt.grouped(chattiest.prompts)} 条消息`
        : `承包了 ${Fmt.percent(top.tokens, total)} 的 tokens 和 ${Fmt.percent(top.prompts, Math.max(1, r.promptCount))} 的消息`;
      const ranking = (title, rows, value, d) => {
        const max = Math.max(1, ...rows.map((a) => value(a)[0]));
        return `<div class="rank"><div class="label">${title}</div>${rows.map((a, i) => `
          <div class="r rv" style="--d:${d + i * 0.08}s">
            <span class="n">${esc(a.name)}</span>${bar(value(a)[0] / max, a.color, 14, d + i * 0.08)}<span class="v num">${value(a)[1]}</span>
          </div>`).join("")}</div>`;
      };
      return `
        <div class="eyebrow rv">AGENTS</div>
        <div class="grow"></div>
        <p class="h rv" style="--d:.1s">${r.agents.length > 1 ? `你一共用过 ${r.agents.length} 个 agent，头号搭档是` : "你的头号搭档是"}</p>
        <div class="display rv" style="--d:.2s;font-size:${top.name.length > 12 ? 76 : 96}px;margin:2px 0;background:linear-gradient(135deg,#fff,${top.color});-webkit-background-clip:text;background-clip:text;color:transparent">${esc(top.name)}</div>
        <p class="sub rv" style="--d:.3s;font-size:19px">${line}</p>
        <div class="grow"></div>
        <div style="display:flex;gap:40px">
          ${ranking("按 token 用量", byTokens, (a) => [a.tokens, Fmt.big(a.tokens)], 0.4)}
          ${ranking("按对话次数", byTalks, (a) => [a.sessions, `${Fmt.grouped(a.sessions)} 次`], 0.5)}
        </div>
        ${rest.length ? `<p class="rv" style="--d:.7s;font-size:14px;font-weight:500;margin:18px 0 0;line-height:1.5"><span style="color:var(--faint)">还用过（对话次数）&nbsp;&nbsp;</span>${rest.map((a) => `${esc(a.name)} ${a.sessions}`).join(" · ")}</p>` : ""}`;
    },
  },

  models: {
    palette: "models",
    html(r) {
      const top = r.models[0], total = Math.max(1, r.tokens.total);
      const rest = r.models.slice(1, 6);
      const max = Math.max(1, ...rest.map((m) => m.tokens));
      return `
        <div class="eyebrow rv">MODELS</div>
        <div class="grow"></div>
        <p class="h rv" style="--d:.1s">出场最多的模型</p>
        <div class="display grad rv" style="--d:.2s;font-size:${top.name.length > 16 ? 76 : 100}px;white-space:nowrap;margin:4px 0">${esc(top.name)}</div>
        <p class="sub rv" style="--d:.3s">${Fmt.percent(top.tokens, total)} 的 tokens 交给了它 · 在 ${esc(top.agent)} 里被调用 ${Fmt.grouped(top.calls)} 次</p>
        <div class="grow"></div>
        ${rest.length ? `<div class="label rv" style="--d:.4s">还有它们</div>
        <div class="rank" style="gap:14px">${rest.map((m, i) => `
          <div class="r rv" style="--d:${0.45 + i * 0.08}s">
            <span class="display" style="width:28px;font-size:22px;opacity:.5">${i + 2}</span>
            <span class="n" style="width:260px;font-size:19px">${esc(m.name)}</span>
            ${bar(m.tokens / max, m.color, 12, 0.5 + i * 0.08)}
            <span class="v num" style="width:90px;font-size:16px">${Fmt.big(m.tokens)}</span>
            <span class="x">${esc(m.agent)}</span>
          </div>`).join("")}</div>` : ""}`;
    },
  },

  tools: {
    palette: "tools",
    html(r) {
      const cats = r.toolCategories.slice(0, 7);
      const max = Math.max(1, ...cats.map((c) => c.count));
      const list = (items) => items.slice(0, 3).map((s) => `<div class="kv" style="font-size:15px;font-weight:500"><span style="color:#fff;font-size:15px">${esc(s.name)}</span><span>×${s.count}</span></div>`).join("");
      return `
        <div class="eyebrow rv">TOOLS</div>
        <div class="grow"></div>
        <div class="rv" style="--d:.1s;display:flex;align-items:baseline;gap:14px">
          <span class="display grad" style="font-size:110px">${count(r.toolCallCount)}</span>
          <span style="font-size:40px;font-weight:800">${Fmt.unit(r.toolCallCount)}次动手</span>
        </div>
        <p class="sub rv" style="--d:.2s">你说一句话，AI 平均要调用 ${(r.toolCallCount / Math.max(1, r.promptCount)).toFixed(1)} 次工具</p>
        <div class="grow"></div>
        <div style="display:flex;gap:36px;align-items:flex-start">
          <div class="rank" style="gap:13px">
            <div class="label">AI 最常替你干的活</div>
            ${cats.map((c, i) => `<div class="r rv" style="--d:${0.35 + i * 0.06}s"><span class="n">${esc(c.name)}</span>${bar(c.count / max, "var(--accent)", 12, 0.4 + i * 0.06)}<span class="v num" style="width:64px">${Fmt.big(c.count)}</span></div>`).join("")}
          </div>
          <div class="rv" style="--d:.6s;width:330px;display:flex;flex-direction:column;gap:16px">
            ${r.skills.length ? `<div class="card"><b style="font-size:22px">用了 ${r.skillCount} 次技能</b>${list(r.skills)}</div>` : ""}
            <div class="card"><b style="font-size:22px">派出 ${r.subagentCount} 个子 agent</b>${r.subagents.length ? list(r.subagents) : `<span>你习惯亲力亲为</span>`}</div>
          </div>
        </div>`;
    },
  },

  rhythm: {
    palette: "rhythm",
    html(r) {
      const peak = r.peakHour;
      const label = peak < 5 ? "夜深人静的时候" : peak < 9 ? "清晨，脑子最清醒" : peak < 12 ? "上午的黄金时间" : peak < 14 ? "午饭前后也不停"
        : peak < 18 ? "下午火力全开" : peak < 22 ? "下班后的第二战场" : "夜色正浓";
      const maxW = Math.max(1, ...r.weekday);
      const topW = r.weekday.indexOf(Math.max(...r.weekday));
      const ln = r.lateNight;
      return `
        <div style="display:flex;gap:40px;align-items:center;flex:1">
          <div style="flex:1;display:flex;flex-direction:column;height:100%">
            <div class="eyebrow rv">作息</div>
            <div class="grow"></div>
            <p class="h rv" style="--d:.1s">你最常在</p>
            <div class="rv grad" style="--d:.2s;display:flex;align-items:baseline;gap:8px;-webkit-background-clip:text;background-clip:text">
              <span class="display" style="font-size:130px">${peak}</span><span style="font-size:44px;font-weight:800">点</span>
            </div>
            <p class="rv" style="--d:.3s;font-size:22px;font-weight:700;margin:0;opacity:.85">找 AI 帮忙 · ${label}</p>
            <div class="week rv" style="--d:.45s">${r.weekday.map((v, i) => `<div><i class="${i === topW ? "top" : ""}" data-hgt="${Math.max(4, (66 * v) / maxW)}"></i><small style="${i === topW ? "opacity:1" : ""}">周${Fmt.weekday[i]}</small></div>`).join("")}</div>
            <div class="grow"></div>
            ${ln ? `<div class="card rv" style="--d:.6s;flex:none;max-width:560px">
                <b style="font-size:20px">最晚的一次：凌晨 ${ln.clock}</b>
                <p style="margin:0 0 8px;font-family:var(--serif);font-size:16px;font-weight:600;opacity:.85;overflow:hidden;text-overflow:ellipsis;white-space:nowrap">“${esc(ln.preview || "（一张图片）")}”</p>
                <span style="font-size:13px">${Fmt.day(ln.date)} · 凌晨 0–5 点你一共发了 ${r.lateNightCount} 条消息</span>
              </div>` : `<p class="rv" style="--d:.6s;font-size:18px;font-weight:600;opacity:.8">凌晨 0–5 点，你从不打扰 AI。作息满分。</p>`}
          </div>
          <div class="rv" style="--d:.3s">${clockSVG(r.hourly)}</div>
        </div>`;
    },
  },

  calendar: {
    palette: "calendar",
    html(r) {
      const b = r.busiestDay;
      return `
        <div class="eyebrow rv">日历</div>
        <div class="grow"></div>
        <div class="rv" style="--d:.1s;display:flex;align-items:baseline;gap:10px">
          <span class="display grad" style="font-size:120px">${count(r.activeDays)}</span><span style="font-size:40px;font-weight:800">个活跃日</span>
        </div>
        <p class="sub rv" style="--d:.2s">${r.longestStreak > 1 ? `最长一口气连续了 ${r.longestStreak} 天` : "每一天都算数"}</p>
        <div class="grow"></div>
        <div class="rv" style="--d:.35s">${heatmapHTML(r)}</div>
        <div class="grow"></div>
        <div class="rv" style="--d:.5s;display:flex;gap:18px;align-items:flex-end">
          ${b ? `<div class="card" style="flex:none;width:340px"><span style="font-size:14px;font-weight:600">最忙的一天</span><b style="font-size:30px;margin:6px 0">${Fmt.day(b.date, !r.year)}</b><span style="font-size:15px">${Fmt.big(b.tokens)} tokens · 你发了 ${b.prompts} 条消息</span></div>` : ""}
          ${monthsHTML(r.series, "var(--accent)", 112)}
        </div>`;
    },
  },

  projects: {
    palette: "projects",
    html(r) {
      const s = r.longestSession;
      return `
        <div class="eyebrow rv">项目</div>
        <div class="grow"></div>
        <p class="h rv" style="--d:.1s">你在这些地方花了最多心思</p>
        <div class="grow"></div>
        <div style="display:flex;gap:36px;align-items:flex-start">
          <div style="flex:1;display:flex;flex-direction:column;gap:18px;min-width:0">
            ${r.projects.slice(0, 5).map((p, i) => `
              <div class="proj ${i === 0 ? "first" : ""} rv" style="--d:${0.2 + i * 0.09}s">
                <span class="k">${i + 1}</span>
                <div style="min-width:0"><b>${esc(p.name)}</b><span>${Fmt.grouped(p.prompts)} 条消息 · ${p.sessions} 次对话 · ${Fmt.big(p.tokens)} tokens</span></div>
              </div>`).join("")}
          </div>
          ${s ? `<div class="card rv" style="--d:.6s;flex:none;width:340px;padding:26px">
              <span style="font-size:14px;font-weight:600">聊得最久的一次</span>
              <b style="font-size:26px;margin:10px 0 6px;display:-webkit-box;-webkit-line-clamp:3;-webkit-box-orient:vertical;overflow:hidden">${esc(s.title)}</b>
              <span>${esc(s.agent)} · ${esc(s.project)}</span>
              <hr style="border:0;border-top:1px solid rgba(255,255,255,.2);margin:14px 0 6px">
              <div class="kv"><span>来回</span><b style="font-size:16px;margin:0">${s.prompts} 轮</b></div>
              <div class="kv"><span>跨度</span><b style="font-size:16px;margin:0">${Fmt.duration(s.durationSecs)}</b></div>
              <div class="kv"><span>消耗</span><b style="font-size:16px;margin:0">${Fmt.big(s.tokens)} tokens</b></div>
            </div>` : ""}
        </div>`;
    },
  },

  persona: {
    palette: "persona",
    html(r) {
      const p = r.persona;
      return `
        <div class="center" style="display:flex;flex-direction:column;flex:1">
          <div class="eyebrow rv" style="justify-content:center">年度 AI 人格</div>
          <div class="grow"></div>
          <div class="persona-emoji rv" style="--d:.15s">${p.emoji}</div>
          <div class="display persona-title rv" style="--d:.3s">${esc(p.title)}</div>
          <p class="rv" style="--d:.45s;font-size:22px;font-weight:500;line-height:1.6;max-width:660px;margin:10px auto 0;opacity:.85">${esc(p.blurb)}</p>
          <div class="rv" style="--d:.6s;display:flex;gap:12px;justify-content:center;margin-top:28px;flex-wrap:wrap">${p.tags.map((t) => `<span class="chip">${esc(t)}</span>`).join("")}</div>
          <div class="grow"></div>
        </div>`;
    },
  },

  summary: {
    palette: "summary",
    html(r, ctx) {
      return `
        <div class="summary" style="display:flex;flex:1">
          <img class="rv" style="--d:.1s" src="${ctx.cardURL}" alt="分享卡片">
          <div class="rv" style="--d:.3s;display:flex;flex-direction:column;gap:18px">
            <div class="eyebrow">就是这样</div>
            <div style="font-size:40px;font-weight:800;line-height:1.3">这是你的<br>${summaryName(r)}</div>
            <p class="sub" style="font-size:17px">${r.period.isWeek ? "保存成图片，下周再来看看有没有进步。" : r.period.isShort ? "保存成图片，下个月再来对比。" : "保存成图片发给朋友，或者明年再来对比。"}</p>
            <div class="actions">
              <button class="primary" data-act="save">⤓&nbsp; 保存为图片…</button>
              <button data-act="copy">⧉&nbsp; 复制图片</button>
              <button data-act="restart">↺&nbsp; 从头再看一遍</button>
            </div>
            <p style="font-size:13px;color:var(--faint);margin:10px 0 0">🔒 所有数据均在本机读取与计算，没有上传任何内容</p>
          </div>
        </div>`;
    },
  },
};

/** 24-hour radial chart: one wedge per hour, the peak hour highlighted. */
function clockSVG(hourly) {
  const size = 380, c = size / 2, inner = size * 0.2, outer = size / 2 - 2;
  const max = Math.max(1, ...hourly);
  const peak = hourly.indexOf(Math.max(...hourly));
  const pt = (r, a) => `${(c + r * Math.cos(a)).toFixed(2)},${(c + r * Math.sin(a)).toFixed(2)}`;
  const wedges = hourly.map((v, h) => {
    const gap = 0.12 / 24;
    const a0 = (h / 24 + gap / 2) * 2 * Math.PI - Math.PI / 2, a1 = ((h + 1) / 24 - gap / 2) * 2 * Math.PI - Math.PI / 2;
    const r = inner + 4 + (outer - inner - 4) * Math.max(0.03, v / max);
    const outerArc = Array.from({ length: 9 }, (_, i) => pt(r, a0 + ((a1 - a0) * i) / 8)).join(" ");
    const innerArc = Array.from({ length: 9 }, (_, i) => pt(inner, a1 - ((a1 - a0) * i) / 8)).join(" ");
    return `<polygon points="${outerArc} ${innerArc}" fill="${h === peak ? "var(--accent)" : "rgba(255,255,255,.4)"}" ${h === peak ? 'filter="url(#glow)"' : ""}/>`;
  }).join("");
  const labels = [0, 6, 12, 18].map((h) => {
    const a = (h / 24) * 2 * Math.PI - Math.PI / 2;
    return `<text x="${c + (inner - 18) * Math.cos(a)}" y="${c + (inner - 18) * Math.sin(a) + 4}" text-anchor="middle" font-size="13" font-weight="700" fill="rgba(255,255,255,.6)">${h}</text>`;
  }).join("");
  return `<svg class="clock" viewBox="0 0 ${size} ${size}">
    <defs><filter id="glow"><feGaussianBlur stdDeviation="6" result="b"/><feMerge><feMergeNode in="b"/><feMergeNode in="SourceGraphic"/></feMerge></filter></defs>
    <circle cx="${c}" cy="${c}" r="${outer}" fill="none" stroke="rgba(255,255,255,.08)"/>
    <circle cx="${c}" cy="${c}" r="${size * 0.25}" fill="none" stroke="rgba(255,255,255,.06)"/>
    <g class="wedges" style="transform-origin:${c}px ${c}px">${wedges}</g>${labels}
    <text x="${c}" y="${c + 8}" text-anchor="middle" font-size="22">${peak >= 6 && peak < 18 ? "☀️" : "🌙"}</text>
  </svg>`;
}

/** GitHub-style year grid colored by token quartile. */
function heatmapHTML(r) {
  const toKey = (s) => Date.UTC(...s.split("-").map((n, i) => (i === 1 ? n - 1 : +n))) / 864e5;
  const lo = toKey(r.heatmapStart), hi = toKey(r.heatmapEnd);
  const weekday = (k) => (new Date(k * 864e5).getUTCDay() + 6) % 7;
  const start = lo - weekday(lo);
  const weeks = Math.floor((hi - start) / 7) + 1;
  const byDay = new Map(r.days.map((d) => [toKey(d.date), d.tokens || (d.prompts || d.sessions ? 1 : 0)]));
  const sorted = [...byDay.values()].filter((v) => v > 0).sort((a, b) => a - b);
  const level = (v) => {
    if (!v || !sorted.length) return 0;
    const idx = sorted.findIndex((x) => x >= v);
    const q = (idx < 0 ? sorted.length - 1 : idx) / Math.max(1, sorted.length - 1);
    return q < 0.25 ? 1 : q < 0.5 ? 2 : q < 0.8 ? 3 : 4;
  };
  const colors = ["rgba(255,255,255,.07)", "color-mix(in srgb, var(--accent) 30%, transparent)", "color-mix(in srgb, var(--accent) 50%, transparent)", "color-mix(in srgb, var(--accent) 75%, transparent)", "var(--accent)"];
  const cell = Math.min(17, Math.floor((innerWidth / uiScale - 144 - (weeks - 1) * 3) / weeks));
  let cells = "";
  for (let w = 0; w < weeks; w++) for (let d = 0; d < 7; d++) {
    const k = start + w * 7 + d;
    cells += `<i style="background:${k >= lo && k <= hi ? colors[level(byDay.get(k))] : "transparent"}"></i>`;
  }
  return `<div class="heat" style="--cell:${cell}px">${cells}</div>
    <div class="heat-legend">少 ${colors.map((c) => `<i style="background:${c}"></i>`).join("")} 多
      <span style="flex:1"></span>${Fmt.day(r.heatmapStart, true)} – ${Fmt.day(r.heatmapEnd, true)}</div>`;
}

function monthsHTML(months, accent, height) {
  const max = Math.max(1, ...months.map((m) => m.tokens));
  const peak = months.findIndex((m) => m.tokens === max);
  const every = Math.max(1, Math.floor(months.length / 12));
  return `<div class="months" style="height:${height}px">${months.map((m, i) => `
    <div><i class="${i === peak ? "top" : ""}" data-hgt="${Math.max(3, ((height - 20) * m.tokens) / max)}"></i><small style="${i === peak ? "opacity:1" : ""}">${i % every === 0 ? m.label : "&nbsp;"}</small></div>`).join("")}</div>`;
}

function summaryName(r) {
  const p = r.period;
  if (p.kind === "year") return `${r.year} 年 AI 年度报告`;
  if (p.kind === "all") return "全部 AI 年度报告";
  if (p.isWeek) return `${p.label} AI 周报`;
  return `${p.badge} AI 月报`;
}

/** One bar per day; the busiest lit in the accent color, days still to come dashed. */
function dailyChartHTML(r) {
  const days = r.daily;
  const isWeek = r.period.isWeek;
  const max = Math.max(1, ...days.map((d) => d.tokens));
  const peak = days.reduce((best, d, i) => (d.tokens > 0 && (best < 0 || d.tokens > days[best].tokens) ? i : best), -1);
  const maxBar = 236 - 28 - (isWeek ? 36 : 16) - 28;
  const cols = days.map((d, i) => {
    const h = Math.max(6, (maxBar * d.tokens) / max);
    const n = +d.date.slice(8);
    const label = isWeek
      ? `<b class="${d.isToday ? "today" : ""}">${d.isToday ? "今天" : d.label}</b><small>${Fmt.shortDay(d.date)}</small>`
      : `<b>${n === 1 || n % 5 === 0 || i === peak ? n : "&nbsp;"}</b>`;
    const barEl = d.isFuture
      ? `<i class="future"></i>`
      : `<i class="${i === peak ? "peak" : ""}" data-hgt="${h}">${i === peak ? `<em>${Fmt.big(d.tokens)}</em>` : ""}</i>`;
    return `<div class="dcol ${d.isFuture ? "is-future" : ""} ${i === peak ? "is-peak" : ""}">${barEl}<div class="dlabel">${label}</div></div>`;
  }).join("");
  return `<div class="label">每天的 tokens</div>
    <div class="daily ${isWeek ? "is-week" : "is-month"}" style="height:208px">${cols}</div>`;
}
