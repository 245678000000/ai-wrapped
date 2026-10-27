use crate::model::*;
use memchr::memmem;
use rusqlite::{Connection, OpenFlags};
use serde_json::Value;
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};

// MARK: - Paths

pub fn home() -> PathBuf {
    dirs::home_dir().unwrap_or_default()
}

/// `~/.x`-style folders live directly under the user directory on every platform.
pub fn home_join(rel: &str) -> PathBuf {
    rel.split('/').fold(home(), |p, part| p.join(part))
}

/// Where desktop (Electron/Tauri) apps keep data: %APPDATA% and %LOCALAPPDATA% on Windows,
/// Application Support on macOS, ~/.config elsewhere. Returns the ones that exist.
pub fn app_data_dirs(app: &str) -> Vec<PathBuf> {
    let h = home();
    [
        h.join("AppData").join("Roaming").join(app),
        h.join("AppData").join("Local").join(app),
        h.join("Library").join("Application Support").join(app),
        h.join(".config").join(app),
    ]
    .into_iter()
    .filter(|p| p.exists())
    .collect()
}

pub fn files_where(root: &Path, pred: impl Fn(&Path) -> bool) -> Vec<PathBuf> {
    if !root.exists() {
        return vec![];
    }
    walkdir::WalkDir::new(root)
        .follow_links(false)
        .into_iter()
        .filter_map(|e| e.ok())
        .filter(|e| e.file_type().is_file() && pred(e.path()))
        .map(|e| e.into_path())
        .collect()
}

pub fn jsonl_files(root: &Path) -> Vec<PathBuf> {
    files_where(root, |p| p.extension().map_or(false, |e| e == "jsonl"))
}

pub fn file_size(p: &Path) -> u64 {
    std::fs::metadata(p).map(|m| m.len()).unwrap_or(0)
}

pub fn mtime(p: &Path) -> Option<f64> {
    let m = std::fs::metadata(p).ok()?.modified().ok()?;
    Some(m.duration_since(std::time::UNIX_EPOCH).ok()?.as_secs_f64())
}

pub fn stem(p: &Path) -> String {
    p.file_stem().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default()
}

// MARK: - JSON lines

/// Calls `f` with each JSON object line of `bytes`. With `filters`, only lines containing at
/// least one of the byte patterns are parsed — most transcript bytes are tool output we skip.
pub fn for_each_json_line(bytes: &[u8], filters: Option<&[&[u8]]>, mut f: impl FnMut(&Value)) {
    let finders: Vec<memmem::Finder> = filters.unwrap_or(&[]).iter().map(|p| memmem::Finder::new(p)).collect();
    for line in bytes.split(|b| *b == b'\n') {
        if line.len() < 2 {
            continue;
        }
        if !finders.is_empty() && !finders.iter().any(|fi| fi.find(line).is_some()) {
            continue;
        }
        if let Ok(v) = serde_json::from_slice::<Value>(line) {
            if v.is_object() {
                f(&v);
            }
        }
    }
}

pub fn for_each_json_line_in(path: &Path, filters: Option<&[&[u8]]>, f: impl FnMut(&Value)) {
    if let Ok(bytes) = std::fs::read(path) {
        for_each_json_line(&bytes, filters, f);
    }
}

/// Value at a dotted path such as "params.update.usage".
pub fn at<'a>(v: &'a Value, path: &str) -> Option<&'a Value> {
    path.split('.').try_fold(v, |cur, part| cur.get(part))
}

pub fn s<'a>(v: &'a Value, path: &str) -> Option<&'a str> {
    at(v, path)?.as_str()
}

pub fn i(v: &Value, path: &str) -> i64 {
    at(v, path).and_then(|x| x.as_i64().or_else(|| x.as_f64().map(|f| f as i64))).unwrap_or(0)
}

// MARK: - Time

/// Parses "2026-10-21T03:06:10.587Z" / "+08:00" offsets / "2026-10-27 03:00:13.8+00:00".
pub fn parse_iso8601(s: &str) -> Option<f64> {
    let u = s.as_bytes();
    if u.len() < 19 || !u[0].is_ascii_digit() {
        return None;
    }
    let num = |a: usize, b: usize| -> i64 { u[a..b].iter().fold(0, |v, c| v * 10 + (c.wrapping_sub(b'0')) as i64) };
    let (y, mo, d) = (num(0, 4), num(5, 7), num(8, 10));
    let (h, mi, se) = (num(11, 13), num(14, 16), num(17, 19));
    let mut idx = 19;
    let mut frac = 0.0;
    if idx < u.len() && u[idx] == b'.' {
        let mut scale = 0.1;
        idx += 1;
        while idx < u.len() && u[idx].is_ascii_digit() {
            frac += (u[idx] - b'0') as f64 * scale;
            scale *= 0.1;
            idx += 1;
        }
    }
    let mut offset = 0;
    if idx + 6 <= u.len() && (u[idx] == b'+' || u[idx] == b'-') {
        let sign = if u[idx] == b'+' { 1 } else { -1 };
        offset = sign * (num(idx + 1, idx + 3) * 3600 + num(idx + 4, idx + 6) * 60);
    }
    let yy = if mo <= 2 { y - 1 } else { y };
    let era = (if yy >= 0 { yy } else { yy - 399 }) / 400;
    let yoe = yy - era * 400;
    let mp = (mo + 9) % 12;
    let doy = (153 * mp + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    let days = era * 146097 + doe - 719468;
    Some((days * 86400 + h * 3600 + mi * 60 + se - offset) as f64 + frac)
}

/// ISO-8601 strings, or epoch seconds / milliseconds / microseconds as numbers or strings.
pub fn any_time(v: Option<&Value>) -> Option<f64> {
    fn epoch(d: f64) -> Option<f64> {
        if d > 1e14 {
            Some(d / 1e6)
        } else if d > 1e11 {
            Some(d / 1000.0)
        } else if d > 1e9 {
            Some(d)
        } else {
            None
        }
    }
    match v? {
        Value::Number(n) => epoch(n.as_f64()?),
        Value::String(s) => s.parse::<f64>().ok().and_then(epoch).or_else(|| parse_iso8601(s)),
        _ => None,
    }
}

pub fn epoch_ms(ms: i64) -> Option<f64> {
    any_time(Some(&Value::from(ms)))
}

// MARK: - Usage

/// Normalizes any usage shape agents write (Anthropic, OpenAI, Grok, Pi, Kiro…). Some fold
/// cache reads into `input`; with a total present we pick whichever reading adds up to it.
pub fn normalize_usage(u: &Value) -> Option<Tokens> {
    let m = u.as_object()?;
    let pick = |keys: &[&str]| -> Option<i64> {
        keys.iter().find_map(|k| m.get(*k).and_then(|v| v.as_i64().or_else(|| v.as_f64().map(|f| f as i64))))
    };
    let input = pick(&["input_tokens", "inputTokens", "prompt_tokens", "promptTokens", "input", "tokensIn",
        "input_token_count", "inputTokenCount", "promptTokenCount"]).unwrap_or(0);
    let mut output = pick(&["output_tokens", "outputTokens", "completion_tokens", "completionTokens", "output",
        "tokensOut", "output_token_count", "outputTokenCount", "candidatesTokenCount"]).unwrap_or(0);
    let mut cache_read = pick(&["cache_read_input_tokens", "cachedReadTokens", "cacheReadTokens", "cacheRead",
        "cache_read", "cached_input_tokens", "cachedTokens", "cached_tokens", "cacheReads",
        "cache_read_input_token_count", "cachedContentTokenCount"]).unwrap_or(0);
    let mut nested_cache = false;
    if cache_read == 0 {
        for key in ["prompt_tokens_details", "input_tokens_details"] {
            if let Some(c) = m.get(key).and_then(|d| d.get("cached_tokens")).and_then(|c| c.as_i64()) {
                cache_read = c;
                nested_cache = true;
            }
        }
    }
    let cache_write = pick(&["cache_creation_input_tokens", "cacheCreationTokens", "cacheWriteTokens", "cacheWrite",
        "cache_write", "cache_creation_tokens", "cacheWrites", "cache_write_input_token_count"]).unwrap_or(0);
    let mut reasoning = pick(&["reasoning_tokens", "reasoningTokens", "reasoning", "thoughtsTokenCount"]).unwrap_or(0);
    if reasoning == 0 {
        reasoning = m.get("completion_tokens_details").and_then(|d| d.get("reasoning_tokens")).and_then(|r| r.as_i64()).unwrap_or(0);
    }
    if input + output + cache_read + cache_write <= 0 {
        return None;
    }
    let (folded, add_reasoning) = match pick(&["total_tokens", "totalTokens", "total", "totalTokenCount"]).filter(|t| *t > 0) {
        Some(total) => {
            let separate = input + output + cache_read + cache_write;
            let candidates = [
                (separate, false, false),
                (input + output, true, false),
                (separate + reasoning, false, true),
                (input + output + reasoning, true, true),
            ];
            let best = candidates.iter().min_by_key(|c| (total - c.0).abs()).unwrap();
            (best.1 && cache_read + cache_write > 0, best.2 && reasoning > 0)
        }
        None => (nested_cache || m.contains_key("prompt_tokens") || m.contains_key("cached_input_tokens"), false),
    };
    if add_reasoning {
        output += reasoning;
    }
    let uncached = if folded { (input - cache_read - cache_write).max(0) } else { input };
    Some(Tokens { input: uncached, output, cache_read, cache_write })
}

// MARK: - Text

pub const AUTOMATED_PREFIXES: &[&str] = &[
    "<system-reminder", "<local-command", "Caveat:", "[Request interrupted", "<task-notification",
    "<side-sessions-event", "<ci-monitor-event", "This session is being continued", "<environment_context",
    "<user_instructions", "# AGENTS.md", "<turn_aborted", "[AGENT SYSTEM PROMPT]", "<system_reminder",
    "<environment_details", "The TodoWrite tool hasn't been used",
];

pub fn is_automated(t: &str) -> bool {
    AUTOMATED_PREFIXES.iter().any(|p| t.starts_with(p))
}

fn remove_tag_blocks(t: &mut String, open_prefix: &str, close: &str) {
    while let Some(start) = t.find(open_prefix) {
        match t[start..].find(close) {
            Some(rel) => t.replace_range(start..start + rel + close.len(), " "),
            None => break,
        }
    }
}

pub fn strip_reminders(text: &str) -> String {
    let mut t = text.to_string();
    remove_tag_blocks(&mut t, "<system-reminder", "</system-reminder>");
    t.trim().to_string()
}

pub fn clean_prompt_text(text: &str) -> String {
    let mut t = text.to_string();
    for tag in ["user_query", "USER_REQUEST", "user_request"] {
        let (open, close) = (format!("<{tag}>"), format!("</{tag}>"));
        if let Some(a) = t.find(&open) {
            if let Some(rel) = t[a + open.len()..].find(&close) {
                t = t[a + open.len()..a + open.len() + rel].to_string();
            }
        }
    }
    remove_tag_blocks(&mut t, "<timestamp>", "</timestamp>");
    remove_tag_blocks(&mut t, "<pasted_content", "</pasted_content>");
    remove_tag_blocks(&mut t, "<system-reminder", "</system-reminder>");
    t.replace('\n', " ").trim().to_string()
}

/// Text of a message's content: a string, or the text blocks of a block array.
pub fn plain_text(content: Option<&Value>) -> String {
    match content {
        Some(Value::String(s)) => strip_reminders(s),
        Some(Value::Object(o)) => o.get("text").and_then(|t| t.as_str()).unwrap_or("").to_string(),
        Some(Value::Array(blocks)) => blocks
            .iter()
            .filter_map(|b| {
                if let Some(s) = b.as_str() {
                    return Some(s.to_string());
                }
                let ty = b.get("type").or_else(|| b.get("kind")).and_then(|t| t.as_str());
                if !matches!(ty, None | Some("text") | Some("input_text") | Some("output_text")) {
                    return None;
                }
                let raw = b.get("text").or_else(|| b.get("data")).and_then(|t| t.as_str()).unwrap_or("");
                let text = strip_reminders(raw);
                (!text.is_empty() && !is_automated(&text)).then_some(text)
            })
            .collect::<Vec<_>>()
            .join("\n"),
        _ => String::new(),
    }
}

pub fn preview(clean: &str) -> String {
    clean.chars().take(160).collect()
}

// MARK: - Naming

pub fn project_name(cwd: Option<&str>) -> String {
    let Some(cwd) = cwd.filter(|c| !c.is_empty()) else { return UNKNOWN_PROJECT.into() };
    let norm = cwd.replace('\\', "/");
    if norm.contains("/scratch-workspaces/") {
        return "临时会话".into();
    }
    let h = home().to_string_lossy().replace('\\', "/");
    let trimmed = norm.trim_end_matches('/');
    if trimmed.eq_ignore_ascii_case(h.trim_end_matches('/')) {
        return "主目录 ~".into();
    }
    let last = trimmed.rsplit('/').next().unwrap_or(trimmed);
    if last == "new-chat" || last.starts_with("new-chat-") {
        return "临时会话".into();
    }
    if last.is_empty() { UNKNOWN_PROJECT.into() } else { last.to_string() }
}

/// "claude-opus-5-5" → "Claude Opus 5.5", "auto/gpt-6-astra" → "GPT-6 Astra".
pub fn pretty_model_name(raw: &str) -> String {
    let mut s = raw.rsplit('/').next().unwrap_or(raw);
    if let Some(at) = s.find('@') {
        s = &s[..at];
    }
    if s.is_empty() || s == "unknown" {
        return "未知模型".into();
    }
    let mut out: Vec<String> = vec![];
    let mut run: Vec<String> = vec![];
    let flush = |out: &mut Vec<String>, run: &mut Vec<String>| {
        if !run.is_empty() {
            out.push(run.join("."));
            run.clear();
        }
    };
    for p in s.split(|c| c == '-' || c == '_').filter(|p| !p.is_empty()) {
        let all_digits = p.chars().all(|c| c.is_ascii_digit());
        if all_digits && p.len() >= 6 {
            continue; // date stamp
        }
        if p.chars().next().map_or(false, |c| c.is_ascii_digit()) && p.chars().all(|c| c.is_ascii_digit() || c == '.') {
            run.push(p.to_string());
            continue;
        }
        flush(&mut out, &mut run);
        let word = match p.to_lowercase().as_str() {
            "gpt" => "GPT".to_string(),
            "glm" => "GLM".to_string(),
            "kimi" => "Kimi".to_string(),
            "deepseek" => "DeepSeek".to_string(),
            "qwen" => "Qwen".to_string(),
            _ => {
                let mut c = p.chars();
                c.next().map(|f| f.to_uppercase().collect::<String>() + c.as_str()).unwrap_or_default()
            }
        };
        out.push(word);
    }
    flush(&mut out, &mut run);
    if (out.first().map(|s| s.as_str()) == Some("GPT") || out.first().map(|s| s.as_str()) == Some("GLM")) && out.len() > 1 {
        let joined = format!("{}-{}", out[0], out[1]);
        out.splice(0..2, [joined]);
    }
    out.join(" ")
}

// MARK: - Collector

/// Accumulates one agent's records, namespacing session keys and de-duplicating by id.
pub struct Collector {
    pub agent: Agent,
    pub result: ScanResult,
    seen_prompts: HashSet<String>,
    usage_by_id: HashMap<String, usize>,
    seen_tools: HashSet<String>,
}

impl Collector {
    pub fn new(agent: Agent) -> Self {
        Collector { agent, result: ScanResult::default(), seen_prompts: HashSet::new(), usage_by_id: HashMap::new(), seen_tools: HashSet::new() }
    }

    pub fn key(&self, session: &str) -> String {
        format!("{}:{}", self.agent.id, session)
    }

    pub fn session(&mut self, id: &str, cwd: Option<&str>, title: Option<&str>, start: Option<f64>) {
        let k = self.key(id);
        let agent = self.agent;
        let s = self.result.sessions.entry(k).or_insert_with(|| Session { agent, project: project_name(cwd), title: None, start: None });
        if s.project == UNKNOWN_PROJECT && cwd.is_some() {
            s.project = project_name(cwd);
        }
        if let Some(t) = title.filter(|t| !t.is_empty()) {
            if s.title.is_none() {
                s.title = Some(t.to_string());
            }
        }
        if let Some(st) = start {
            if s.start.map_or(true, |cur| st < cur) {
                s.start = Some(st);
            }
        }
    }

    pub fn prompt(&mut self, session: &str, time: Option<f64>, raw: &str, id: Option<&str>) {
        let Some(time) = time.filter(|t| *t > 0.0) else { return };
        if let Some(id) = id {
            if !self.seen_prompts.insert(id.to_string()) {
                return;
            }
        }
        let trimmed = raw.trim();
        if trimmed.is_empty() || is_automated(trimmed) {
            return;
        }
        let clean = clean_prompt_text(trimmed);
        if clean.is_empty() {
            return;
        }
        if !self.result.sessions.contains_key(&self.key(session)) {
            self.session(session, None, None, None);
        }
        self.result.prompts.push(Prompt { agent: self.agent, session: self.key(session), time, chars: clean.chars().count(), preview: preview(&clean) });
    }

    /// With an `id`, later records for the same id replace earlier ones when they are larger.
    pub fn usage(&mut self, session: &str, time: Option<f64>, model: Option<&str>, t: Option<Tokens>, id: Option<&str>) {
        let (Some(time), Some(t)) = (time.filter(|t| *t > 0.0), t.filter(|t| t.total() > 0)) else { return };
        let rec = Usage { agent: self.agent, model: model.unwrap_or("unknown").to_string(), time, tokens: t, session: self.key(session) };
        if let Some(id) = id {
            if let Some(&i) = self.usage_by_id.get(id) {
                if self.result.usage[i].tokens.total() < t.total() {
                    self.result.usage[i] = rec;
                }
                return;
            }
            self.usage_by_id.insert(id.to_string(), self.result.usage.len());
        }
        self.result.usage.push(rec);
    }

    pub fn tool(&mut self, name: Option<&str>, time: Option<f64>, kind: ToolKind, id: Option<&str>) {
        let (Some(name), Some(time)) = (name.filter(|n| !n.is_empty()), time.filter(|t| *t > 0.0)) else { return };
        if let Some(id) = id {
            if !self.seen_tools.insert(id.to_string()) {
                return;
            }
        }
        self.result.tools.push(Tool { name: name.to_string(), kind, time });
    }

    pub fn finish(self) -> ScanResult {
        self.result
    }
}

// MARK: - SQLite

/// Opens a database read-only, falling back to `immutable` when the owning app holds a WAL lock.
pub fn open_ro(path: &Path) -> Option<Connection> {
    if !path.exists() {
        return None;
    }
    let mut p = path.to_string_lossy().replace('\\', "/");
    if p.as_bytes().get(1) == Some(&b':') {
        p = format!("/{p}"); // C:/… → /C:/…
    }
    let encoded = percent_encoding::utf8_percent_encode(&p, &URI_PATH).to_string();
    for mode in ["mode=ro", "immutable=1"] {
        let uri = format!("file://{encoded}?{mode}");
        if let Ok(c) = Connection::open_with_flags(&uri, OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_URI) {
            let _ = c.busy_timeout(std::time::Duration::from_millis(1500));
            if c.query_row("SELECT count(*) FROM sqlite_master", [], |r| r.get::<_, i64>(0)).is_ok() {
                return Some(c);
            }
        }
    }
    None
}

const URI_PATH: &percent_encoding::AsciiSet = &percent_encoding::CONTROLS.add(b' ').add(b'#').add(b'?').add(b'%').add(b'"');

pub fn columns(c: &Connection, table: &str) -> HashSet<String> {
    let mut out = HashSet::new();
    if let Ok(mut st) = c.prepare(&format!("PRAGMA table_info({table})")) {
        if let Ok(rows) = st.query_map([], |r| r.get::<_, String>(1)) {
            out.extend(rows.flatten());
        }
    }
    out
}

/// Runs a query and hands every row to `f`; failures (missing tables, old schemas) yield nothing.
pub fn each_row(c: &Connection, sql: &str, mut f: impl FnMut(&rusqlite::Row)) {
    if let Ok(mut st) = c.prepare(sql) {
        if let Ok(mut rows) = st.query([]) {
            while let Ok(Some(r)) = rows.next() {
                f(r);
            }
        }
    }
}

pub fn col_str(r: &rusqlite::Row, i: usize) -> Option<String> {
    use rusqlite::types::ValueRef;
    match r.get_ref(i).ok()? {
        ValueRef::Text(t) | ValueRef::Blob(t) => Some(String::from_utf8_lossy(t).into_owned()),
        ValueRef::Integer(n) => Some(n.to_string()),
        ValueRef::Real(f) => Some(f.to_string()),
        ValueRef::Null => None,
    }
}

pub fn col_i64(r: &rusqlite::Row, i: usize) -> i64 {
    use rusqlite::types::ValueRef;
    match r.get_ref(i) {
        Ok(ValueRef::Integer(n)) => n,
        Ok(ValueRef::Real(f)) => f as i64,
        Ok(ValueRef::Text(t)) => std::str::from_utf8(t).ok().and_then(|s| s.parse().ok()).unwrap_or(0),
        _ => 0,
    }
}

pub fn col_json(r: &rusqlite::Row, i: usize) -> Option<Value> {
    use rusqlite::types::ValueRef;
    match r.get_ref(i).ok()? {
        ValueRef::Text(t) | ValueRef::Blob(t) => serde_json::from_slice(t).ok(),
        _ => None,
    }
}

