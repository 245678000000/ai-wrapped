//! Codex rollouts (~/.codex/sessions) and Factory Droid (~/.factory/sessions).

use crate::model::*;
use crate::util::*;
use rayon::prelude::*;
use regex::Regex;
use serde_json::Value;
use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::sync::OnceLock;

fn codex_root() -> PathBuf {
    std::env::var_os("CODEX_HOME").map(PathBuf::from).unwrap_or_else(|| home_join(".codex"))
}

pub fn codex_files() -> Vec<PathBuf> {
    let r = codex_root();
    let mut f = jsonl_files(&r.join("sessions"));
    f.extend(jsonl_files(&r.join("archived_sessions")));
    f
}

pub fn scan_codex() -> ScanResult {
    let outs: Vec<(String, ScanResult)> = codex_files().par_iter().map(|f| scan_codex_file(f)).collect();
    let mut seen = HashSet::new();
    let mut result = ScanResult::default();
    for (id, r) in outs {
        if seen.insert(id) {
            result.merge(r);
        }
    }
    result
}

#[derive(Default, Clone, Copy)]
struct Totals {
    input: i64,
    cached: i64,
    cache_write: i64,
    output: i64,
    total: i64,
}

fn nested_tool() -> &'static Regex {
    static R: OnceLock<Regex> = OnceLock::new();
    R.get_or_init(|| Regex::new(r"tools\.([A-Za-z_][A-Za-z0-9_]*)\s*\(").unwrap())
}

const CODEX_FILTERS: &[&[u8]] = &[
    b"\"type\":\"session_meta\"", b"\"type\":\"turn_context\"", b"\"thread_settings_applied\"",
    b"\"type\":\"token_count\"", b"\"type\":\"user_message\"", b"\"type\":\"UserMessage\"",
    b"\"type\":\"function_call\"", b"\"type\":\"custom_tool_call\"", b"\"type\":\"local_shell_call\"",
    b"\"type\":\"web_search_call\"",
];

/// Returns the session id alongside the result so archived duplicates can be dropped.
fn scan_codex_file(path: &Path) -> (String, ScanResult) {
    let mut session_id = stem(path);
    let mut seen_meta = false;
    let mut cwd: Option<String> = None;
    let mut user_facing = true;
    let mut subagent_name: Option<String> = None;
    let mut start_time = 0.0;
    let mut model = "unknown".to_string();
    let mut prev = Totals::default();
    let mut event_prompts: Vec<(f64, String)> = vec![];
    let mut item_prompts: Vec<(f64, String)> = vec![];
    let mut usage: Vec<(f64, String, Tokens)> = vec![];
    let mut tools: Vec<(f64, String)> = vec![];

    for_each_json_line_in(path, Some(CODEX_FILTERS), |v| {
        let Some(payload) = v.get("payload").filter(|p| p.is_object()) else { return };
        let time = any_time(v.get("timestamp")).unwrap_or(0.0);
        match s(v, "type") {
            // Sub-agent rollouts embed their parent's session_meta after their own; only the
            // first one describes this file.
            Some("session_meta") if !seen_meta => {
                seen_meta = true;
                if let Some(id) = s(payload, "id") {
                    session_id = id.to_string();
                }
                cwd = s(payload, "cwd").map(String::from);
                start_time = s(payload, "timestamp").and_then(parse_iso8601).unwrap_or(time);
                let thread_source = s(payload, "thread_source");
                if let Some(sub) = payload.get("source").and_then(|x| x.get("subagent")) {
                    user_facing = false;
                    subagent_name = Some(match sub.get("thread_spawn") {
                        Some(spawn) => s(spawn, "agent_role").unwrap_or("子任务 agent").to_string(),
                        None if thread_source == Some("guardian_review") => "自动审查".into(),
                        None => "子任务 agent".into(),
                    });
                } else if let Some(ts) = thread_source.filter(|t| *t != "user") {
                    user_facing = false;
                    subagent_name = Some(if ts == "guardian_review" { "自动审查".into() } else { ts.to_string() });
                }
            }
            Some("turn_context") => {
                if let Some(m) = s(payload, "model") {
                    model = m.to_string();
                }
            }
            Some("event_msg") => match s(payload, "type") {
                Some("thread_settings_applied") => {
                    if let Some(m) = s(payload, "thread_settings.model") {
                        model = m.to_string();
                    }
                }
                Some("token_count") => {
                    let Some(tu) = at(payload, "info.total_token_usage") else { return };
                    let cur = Totals {
                        input: i(tu, "input_tokens"),
                        cached: i(tu, "cached_input_tokens"),
                        cache_write: i(tu, "cache_write_input_tokens"),
                        output: i(tu, "output_tokens"),
                        total: i(tu, "total_tokens"),
                    };
                    if cur.total == prev.total {
                        return;
                    }
                    // Totals are cumulative per thread; a drop means the counter restarted.
                    let base = if cur.total > prev.total { prev } else { Totals::default() };
                    prev = cur;
                    let (d_in, d_cached) = (cur.input - base.input, cur.cached - base.cached);
                    let (d_write, d_out) = (cur.cache_write - base.cache_write, cur.output - base.output);
                    let t = Tokens {
                        input: (d_in - d_cached - d_write).max(0),
                        output: d_out.max(0),
                        cache_read: d_cached.max(0),
                        cache_write: d_write.max(0),
                    };
                    if t.total() > 0 {
                        usage.push((time, model.clone(), t));
                    }
                }
                Some("user_message") => {
                    if let Some(m) = s(payload, "message") {
                        event_prompts.push((time, m.to_string()));
                    }
                }
                Some("item_completed") => {
                    let Some(item) = payload.get("item").filter(|it| s(it, "type") == Some("UserMessage")) else { return };
                    let text = item.get("content").and_then(|c| c.as_array()).into_iter().flatten()
                        .filter(|b| s(b, "type") == Some("text"))
                        .filter_map(|b| s(b, "text"))
                        .collect::<Vec<_>>()
                        .join("\n");
                    item_prompts.push((time, text));
                }
                _ => {}
            },
            Some("response_item") => match s(payload, "type") {
                Some("function_call") | Some("custom_tool_call") => {
                    let Some(name) = s(payload, "name") else { return };
                    match (name, s(payload, "input")) {
                        ("exec", Some(input)) => {
                            let nested: Vec<String> = nested_tool().captures_iter(input).map(|c| c[1].to_string()).collect();
                            if nested.is_empty() {
                                tools.push((time, name.to_string()));
                            }
                            tools.extend(nested.into_iter().map(|n| (time, n)));
                        }
                        _ => tools.push((time, name.to_string())),
                    }
                }
                Some("local_shell_call") => tools.push((time, "shell".into())),
                Some("web_search_call") => tools.push((time, "web_search".into())),
                _ => {}
            },
            _ => {}
        }
    });

    let mut c = Collector::new(CODEX);
    c.session(&session_id, cwd.as_deref(), None, None);
    for (time, m, t) in usage {
        c.usage(&session_id, Some(time), Some(&m), Some(t), None);
    }
    for (time, name) in tools {
        c.tool(Some(&name), Some(time), ToolKind::Tool, None);
    }
    if user_facing {
        let prompts = if event_prompts.is_empty() { item_prompts } else { event_prompts };
        for (time, raw) in prompts {
            let text = raw.split_once("## My request:").map(|(_, r)| r).unwrap_or(&raw);
            c.prompt(&session_id, Some(time), text, None);
        }
    } else if let Some(name) = subagent_name.filter(|_| start_time > 0.0) {
        c.tool(Some(&name), Some(start_time), ToolKind::Subagent, None);
    }
    (session_id, c.finish())
}

pub fn scan_droid() -> ScanResult {
    let mut c = Collector::new(DROID);
    for file in jsonl_files(&home_join(".factory/sessions")) {
        let mut session_id = stem(&file);
        let (mut cwd, mut title): (Option<String>, Option<String>) = (None, None);
        let mut last_time = 0.0;
        let mut prompts: Vec<(f64, String)> = vec![];
        let mut tools: Vec<(f64, String)> = vec![];
        for_each_json_line_in(&file, None, |v| match s(v, "type") {
            Some("session_start") => {
                if let Some(id) = s(v, "id") {
                    session_id = id.to_string();
                }
                cwd = s(v, "cwd").map(String::from);
                title = s(v, "title").filter(|t| *t != "New Session").map(String::from);
            }
            Some("message") => {
                let (Some(time), Some(msg)) = (s(v, "timestamp").and_then(parse_iso8601), v.get("message")) else { return };
                last_time = f64::max(last_time, time);
                if s(msg, "role") == Some("user") {
                    prompts.push((time, plain_text(msg.get("content"))));
                } else {
                    for b in msg.get("content").and_then(|c| c.as_array()).into_iter().flatten() {
                        if s(b, "type") == Some("tool_use") {
                            tools.extend(s(b, "name").map(|n| (time, n.to_string())));
                        }
                    }
                }
            }
            _ => {}
        });
        c.session(&session_id, cwd.as_deref(), title.as_deref(), None);
        for (time, text) in prompts {
            c.prompt(&session_id, Some(time), &text, None);
        }
        for (time, name) in tools {
            c.tool(Some(&name), Some(time), ToolKind::Tool, None);
        }
        let settings = file.with_extension("settings.json");
        if let Some(cfg) = std::fs::read(&settings).ok().and_then(|b| serde_json::from_slice::<Value>(&b).ok()) {
            if let Some(tu) = cfg.get("tokenUsage") {
                let t = Tokens {
                    input: i(tu, "inputTokens"),
                    output: i(tu, "outputTokens") + i(tu, "thinkingTokens"),
                    cache_read: i(tu, "cacheReadTokens"),
                    cache_write: i(tu, "cacheCreationTokens"),
                };
                let time = if last_time > 0.0 { Some(last_time) } else { mtime(&settings) };
                c.usage(&session_id, time, s(&cfg, "model"), Some(t), None);
            }
        }
    }
    c.finish()
}
