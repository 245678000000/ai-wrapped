// Number and date formatting shared by the slides and the share card.
const Fmt = {
  scale(v) {
    if (v >= 1e8) return [1e8, "亿", 2];
    if (v >= 1e7) return [1e4, "万", 0];
    if (v >= 1e4) return [1e4, "万", 1];
    return [1, "", 0];
  },
  /** Number part only, in the unit chosen for `ref` so count-ups never jump units. */
  scaled(v, ref = v) {
    const [div, , digits] = Fmt.scale(ref);
    return div === 1 ? Fmt.grouped(Math.round(v)) : (v / div).toFixed(digits);
  },
  unit(ref) { return Fmt.scale(ref)[1]; },
  big(v) { return Fmt.scaled(v) + Fmt.unit(v); },
  grouped(n) { return Math.round(n).toLocaleString("en-US"); },
  percent(part, whole) {
    if (!whole) return "0%";
    const p = (part / whole) * 100;
    return p >= 10 || p === 0 ? `${Math.round(p)}%` : `${p.toFixed(1)}%`;
  },
  parts(date) { const [y, m, d] = date.split("-").map(Number); return { y, m, d }; },
  day(date, withYear = false) {
    const { y, m, d } = Fmt.parts(date);
    return (withYear ? `${y} 年 ` : "") + `${m} 月 ${d} 日`;
  },
  shortDay(date) { const { m, d } = Fmt.parts(date); return `${m}/${d}`; },
  duration(secs) {
    const minutes = Math.floor(secs / 60);
    if (minutes < 60) return `${Math.max(1, minutes)} 分钟`;
    const hours = Math.floor(minutes / 60);
    if (hours < 48) return `${hours} 小时 ${minutes % 60} 分`;
    return `${Math.floor(hours / 24)} 天 ${hours % 24} 小时`;
  },
  weekday: ["一", "二", "三", "四", "五", "六", "日"],
};

const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));

// Mesh palettes per slide: 3×3 grid of colors (row-major) plus an accent, as in the macOS app.
const PALETTES = {
  cover: [["#0E0624", "#2A0B52", "#12052E", "#5B1AA8", "#E04F8B", "#3D0E7A", "#1A0838", "#F08A4B", "#2B0A4F"], "#FFB36B"],
  first: [["#03141F", "#07344A", "#04202E", "#0B4F6C", "#1FA4A9", "#0A3550", "#021018", "#2C7DA0", "#06283A"], "#7FE7E0"],
  tokens: [["#2A0A05", "#6B1A0E", "#3A0C08", "#B23A1B", "#F2733A", "#7A1E12", "#3D0B07", "#E2A23B", "#5A140C"], "#FFD08A"],
  talk: [["#031A14", "#0A4033", "#05261D", "#0F6B4F", "#2EC4A0", "#0B5040", "#021511", "#6FBF7A", "#073326"], "#B8F5C9"],
  agents: [["#070B2E", "#16207A", "#0A0F3F", "#2B3BD1", "#6C7BFF", "#1A238F", "#05082A", "#9D5CFF", "#10176A"], "#B8C1FF"],
  models: [["#2A0716", "#6E1340", "#3A0A20", "#B0245E", "#FF6F91", "#7D1A48", "#2C0715", "#F59A85", "#5A0F35"], "#FFD1DC"],
  tools: [["#07170A", "#15401C", "#0A2210", "#246B2C", "#8CCB52", "#1C5224", "#051208", "#C9DB5A", "#123A18"], "#E6FF8A"],
  rhythm: [["#040516", "#121A4A", "#070A24", "#26307A", "#5B4BD6", "#1A2160", "#02030E", "#2F7FD8", "#0D1440"], "#9DB8FF"],
  calendar: [["#0A0F14", "#17252E", "#0D161C", "#1E3A3A", "#22875A", "#183032", "#060A0D", "#2DB37E", "#12221F"], "#7CFFC4"],
  projects: [["#1F0507", "#5C0F14", "#2E070A", "#9E1B22", "#F2552F", "#701219", "#1A0405", "#E8952A", "#4A0C10"], "#FFC78A"],
  persona: [["#0B0420", "#3A0E6E", "#081230", "#7B2FF7", "#E0237C", "#4361EE", "#10062A", "#3BB4E0", "#2A0E55"], "#FFFFFF"],
  summary: [["#07040F", "#1C0B36", "#0A0A1E", "#2E1460", "#5A1F6E", "#1E2A66", "#05030C", "#183A5C", "#150A2C"], "#FFFFFF"],
};
