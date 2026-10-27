//! Claude-Code-format transcripts: Claude Code itself and agents built on the same format
//! (Qoder, Qoder CN, 千问办公). Each streamed content block is written as its own line with the
//! same message id and usage, and forked/resumed sessions copy earlier lines into new files,
//! so usage, prompts and tool calls are de-duplicated by id across every file.

use crate::model::*;
use crate::util::*;
use memchr::memmem::Finder;
use rayon::prelude::*;
use serde_json::Value;
use std::collections::HashMap;
use std::path::{Path, PathBuf};

pub struct ClaudeFormat {
    pub agent: Agent,
    pub roots: Vec<PathBuf>,
}

pub fn all() -> Vec<ClaudeFormat> {
    let claude_root = std::env::var_os("CLAUDE_CONFIG_DIR")
        .map(|d| PathBuf::from(d).join("projects"))
        .unwrap_or_else(|| home_join(".claude/projects"));
    vec![
        ClaudeFormat { agent: CLAUDE_CODE, roots: vec![claude_root] },
        ClaudeFormat { agent: QODER_CN, roots: vec![home_join(".qoder-cn/projects")] },
        ClaudeFormat { agent: QODER, roots: vec![home_join(".qoder/projects")] },
        // 千问办公 migrated from QoderWork CN and kept the old folder; ids overlap and de-duplicate.
        ClaudeFormat { agent: QWEN_WORK, roots: vec![home_join(".qwenworkcn/projects"), home_join(".qoderworkcn/projects")] },
    ]
}

#[derive(Default)]
struct FileOut {
    usage: HashMap<String, Usage>,
    anon_usage: Vec<Usage>,
    prompts: HashMap<String, Prompt>,
    tools: HashMap<String, Tool>,
    sessions: HashMap<String, Session>,
}

impl ClaudeFormat {
    pub fn files(&self) -> Vec<PathBuf> {
        self.roots.iter().flat_map(|r| jsonl_files(r)).collect()
    }

    pub fn scan(&self) -> ScanResult {
        let files = self.files();
        let outs: Vec<FileOut> = files.par_iter().map(|f| self.scan_file(f)).collect();
        merge(outs)
    }

    fn scan_file(&self, path: &Path) -> FileOut {
        let mut out = FileOut::default();
        let Ok(bytes) = std::fs::read(path) else { return out };
        let agent = self.agent;
        let fallback = stem(path);
        let (f_assistant, f_user) = (Finder::new(b"\"type\":\"assistant\""), Finder::new(b"\"type\":\"user\""));
        let (f_result, f_title) = (Finder::new(b"\"toolUseResult\""), Finder::new(b"\"type\":\"custom-title\""));

        for line in bytes.split(|b| *b == b'\n') {
            let is_assistant = f_assistant.find(line).is_some();
            let is_user = !is_assistant && f_user.find(line).is_some() && f_result.find(line).is_none();
            let is_title = !is_assistant && !is_user && f_title.find(line).is_some();
            if !(is_assistant || is_user || is_title) {
                continue;
            }
            let Ok(v) = serde_json::from_slice::<Value>(line) else { continue };
            let session = s(&v, "sessionId").unwrap_or(&fallback).to_string();
            let key = format!("{}:{}", agent.id, session);
            let ty = s(&v, "type");
            let ensure = |out: &mut FileOut, cwd: Option<&str>| {
                let e = out.sessions.entry(key.clone()).or_insert_with(|| Session { agent, project: project_name(cwd), title: None, start: None });
                if e.project == UNKNOWN_PROJECT && cwd.is_some() {
                    e.project = project_name(cwd);
                }
            };

            if ty == Some("custom-title") {
                if let Some(t) = s(&v, "customTitle").filter(|t| !t.is_empty()) {
                    ensure(&mut out, None);
                    out.sessions.get_mut(&key).unwrap().title = Some(t.to_string());
                }
                continue;
            }

            let time = s(&v, "timestamp").and_then(parse_iso8601).unwrap_or(0.0);
            let Some(msg) = v.get("message").filter(|m| m.is_object()) else { continue };
            if time <= 0.0 {
                continue;
            }
            ensure(&mut out, s(&v, "cwd"));

            if ty == Some("assistant") {
                let model = s(msg, "model").unwrap_or("unknown");
                if let Some(u) = msg.get("usage").filter(|_| model != "<synthetic>") {
                    let t = Tokens {
                        input: i(u, "input_tokens"),
                        output: i(u, "output_tokens"),
                        cache_read: i(u, "cache_read_input_tokens"),
                        cache_write: i(u, "cache_creation_input_tokens"),
                    };
                    let rec = Usage { agent, model: model.to_string(), time, tokens: t, session: key.clone() };
                    match s(msg, "id") {
                        Some(id) => {
                            if out.usage.get(id).map_or(true, |o| o.tokens.total() < t.total()) {
                                out.usage.insert(id.to_string(), rec);
                            }
                        }
                        None => out.anon_usage.push(rec),
                    }
                }
                for b in msg.get("content").and_then(|c| c.as_array()).into_iter().flatten() {
                    if s(b, "type") != Some("tool_use") {
                        continue;
                    }
                    let Some(name) = s(b, "name") else { continue };
                    let id = s(b, "id").map(String::from).unwrap_or_else(|| format!("{key}#{}", out.tools.len()));
                    out.tools.insert(id.clone(), Tool { name: name.to_string(), kind: ToolKind::Tool, time });
                    if name == "Skill" {
                        if let Some(skill) = s(b, "input.skill") {
                            out.tools.insert(format!("{id}#skill"), Tool { name: skill.to_string(), kind: ToolKind::Skill, time });
                        }
                    }
                    if name == "Agent" || name == "Task" {
                        let sub = s(b, "input.subagent_type").unwrap_or("general-purpose");
                        out.tools.insert(format!("{id}#agent"), Tool { name: sub.to_string(), kind: ToolKind::Subagent, time });
                    }
                }
                continue;
            }

            // A prompt the user actually typed: main chain only, not tool results or harness notes.
            let flag = |k: &str| v.get(k).and_then(|x| x.as_bool()) == Some(true);
            if ty != Some("user") || flag("isSidechain") || flag("isMeta") || flag("isCompactSummary") {
                continue;
            }
            let (mut texts, mut has_image, mut has_tool_result) = (vec![], false, false);
            match msg.get("content") {
                Some(Value::String(st)) => texts.push(st.clone()),
                Some(Value::Array(blocks)) => {
                    for b in blocks {
                        match s(b, "type") {
                            Some("text") => texts.extend(s(b, "text").map(String::from)),
                            Some("image") => has_image = true,
                            Some("tool_result") => has_tool_result = true,
                            _ => {}
                        }
                    }
                }
                _ => {}
            }
            let parts: Vec<&str> = texts.iter().map(|t| t.trim()).filter(|t| !t.is_empty() && !is_automated(t)).collect();
            if parts.is_empty() && !(has_image && !has_tool_result) {
                continue;
            }
            let mut text = parts.join("\n");
            if text.starts_with("<command-name>") {
                if let Some(end) = text.find("</command-name>") {
                    text = text[14..end].to_string();
                }
            }
            let clean = clean_prompt_text(&text);
            let uuid = s(&v, "uuid").map(String::from).unwrap_or_else(|| format!("{key}#{}", out.prompts.len()));
            out.prompts.insert(uuid, Prompt { agent, session: key, time, chars: clean.chars().count(), preview: preview(&clean) });
        }
        out
    }
}

fn merge(outs: Vec<FileOut>) -> ScanResult {
    let mut usage: HashMap<String, Usage> = HashMap::new();
    let mut prompts: HashMap<String, Prompt> = HashMap::new();
    let mut tools: HashMap<String, Tool> = HashMap::new();
    let mut result = ScanResult::default();
    for o in outs {
        for (k, v) in o.usage {
            if usage.get(&k).map_or(true, |old| old.tokens.total() < v.tokens.total()) {
                usage.insert(k, v);
            }
        }
        result.usage.extend(o.anon_usage);
        for (k, v) in o.prompts {
            prompts.entry(k).or_insert(v);
        }
        for (k, v) in o.tools {
            tools.entry(k).or_insert(v);
        }
        let mut part = ScanResult::default();
        part.sessions = o.sessions;
        result.merge(part);
    }
    result.usage.extend(usage.into_values());
    result.prompts = prompts.into_values().collect();
    result.tools = tools.into_values().collect();
    result
}
