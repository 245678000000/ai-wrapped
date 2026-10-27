//! Agents with their own formats. Paths follow each tool's convention on every OS: CLI tools
//! keep `~/.tool`, desktop apps keep their data in %APPDATA% / Application Support.

use crate::model::*;
use crate::util::*;
use serde_json::Value;
use std::collections::{HashMap, HashSet};
use std::path::Path;

// MARK: - WorkBuddy / CodeBuddy (Tencent; OpenAI-Agents-style JSONL)

pub fn scan_buddy(agent: Agent, root: &Path) -> ScanResult {
    let mut c = Collector::new(agent);
    for file in jsonl_files(&root.join("projects")) {
        let fallback = stem(&file);
        for_each_json_line_in(&file, None, |d| {
            let session = s(d, "sessionId").unwrap_or(&fallback).to_string();
            let time = any_time(d.get("timestamp"));
            let cwd = s(d, "cwd");
            let provider = d.get("providerData");
            match s(d, "type") {
                Some("ai-title") => c.session(&session, cwd, s(d, "aiTitle"), None),
                Some("message") => {
                    c.session(&session, cwd, None, None);
                    if s(d, "role") == Some("user") {
                        c.prompt(&session, time, &plain_text(d.get("content")), s(d, "id"));
                    }
                }
                Some("function_call") => c.tool(s(d, "name"), time, ToolKind::Tool, s(d, "callId").or(s(d, "id"))),
                _ => {}
            }
            // Every item of one model response repeats its usage; count it once per response.
            if let Some(raw) = provider.and_then(|p| p.get("rawUsage")).or(d.get("usage")) {
                let model = provider.and_then(|p| s(p, "requestModelName").or(s(p, "model")));
                let id = provider.and_then(|p| s(p, "messageId")).or(s(d, "messageId")).or(s(d, "id"));
                c.usage(&session, time, model, normalize_usage(raw), id);
            }
        });
    }
    // WorkBuddy's index also lists cloud conversations whose transcripts aren't stored locally.
    if let Some(db) = open_ro(&root.join("workbuddy.db")) {
        each_row(&db, "SELECT id, cwd, coalesce(custom_title, title), created_at, deleted_at FROM sessions", |r| {
            let Some(id) = col_str(r, 0) else { return };
            if col_str(r, 4).is_some() && col_i64(r, 4) > 0 {
                return; // deleted
            }
            c.session(&id, col_str(r, 1).as_deref(), col_str(r, 2).as_deref(), epoch_ms(col_i64(r, 3)));
        });
    }
    c.finish()
}

// MARK: - Grok Build (~/.grok/sessions/<cwd>/<id>/updates.jsonl, ACP session updates)

pub fn scan_grok() -> ScanResult {
    let mut c = Collector::new(GROK);
    for file in files_where(&home_join(".grok/sessions"), |p| p.file_name().map_or(false, |n| n == "updates.jsonl")) {
        let cwd = file.parent().and_then(|p| p.parent()).and_then(|p| p.file_name())
            .map(|n| percent_encoding::percent_decode_str(&n.to_string_lossy()).decode_utf8_lossy().into_owned());
        let mut prompts: Vec<(String, String, Option<f64>, String)> = vec![]; // key, session, time, text
        let mut index_of: HashMap<String, usize> = HashMap::new();
        for_each_json_line_in(&file, None, |d| {
            let Some(params) = d.get("params") else { return };
            let (Some(session), Some(update)) = (s(params, "sessionId"), params.get("update")) else { return };
            let time = any_time(at(params, "_meta.agentTimestampMs")).or_else(|| any_time(d.get("timestamp")));
            c.session(session, cwd.as_deref(), None, None);
            match s(update, "sessionUpdate") {
                Some("user_message_chunk") => {
                    let idx = at(update, "_meta.promptIndex").map(|v| v.to_string())
                        .or_else(|| s(params, "_meta.promptId").map(String::from))
                        .unwrap_or_else(|| prompts.len().to_string());
                    let key = format!("{session}#{idx}");
                    let pos = *index_of.entry(key.clone()).or_insert_with(|| {
                        prompts.push((key.clone(), session.to_string(), time, String::new()));
                        prompts.len() - 1
                    });
                    prompts[pos].3.push_str(s(update, "content.text").unwrap_or(""));
                }
                Some("tool_call") => {
                    let name = update.get("_meta").and_then(|m| m.get("x.ai/tool")).and_then(|t| s(t, "name")).or(s(update, "title"));
                    c.tool(name, time, ToolKind::Tool, s(update, "toolCallId"));
                }
                // Each completed turn reports that turn's usage, broken down per model.
                Some("turn_completed") => {
                    let Some(usage) = update.get("usage") else { return };
                    let turn = s(params, "_meta.eventId").map(String::from).unwrap_or_else(|| format!("{session}@{time:?}"));
                    match usage.get("modelUsage").and_then(|m| m.as_object()) {
                        Some(per_model) => {
                            for (model, raw) in per_model {
                                // Grok Build records what each turn cost, in 1e-10 USD ticks.
                                let cost = raw.get("costUsdTicks").and_then(|v| v.as_f64()).filter(|t| *t > 0.0).map(|t| t / 1e10);
                                c.usage_priced(session, time, Some(model), normalize_usage(raw), Some(&format!("{turn}|{model}")), cost);
                            }
                        }
                        None => c.usage(session, time, Some("grok"), normalize_usage(usage), Some(&turn)),
                    }
                }
                _ => {}
            }
        });
        for (key, session, time, text) in prompts {
            c.prompt(&session, time, &text, Some(&key));
        }
    }
    c.finish()
}

// MARK: - Pi and MiniMax Code (both run the pi agent runtime)

fn pi_message(c: &mut Collector, m: &Value, session: &str, fallback: Option<f64>, model: Option<&str>, id: Option<&str>) {
    let time = any_time(m.get("timestamp")).or(fallback);
    match s(m, "role") {
        Some("user") => c.prompt(session, time, &plain_text(m.get("content")), id),
        Some("assistant") => {
            if let Some(u) = m.get("usage") {
                c.usage(session, time, s(m, "model").or(model), normalize_usage(u), id);
            }
            for b in m.get("content").and_then(|x| x.as_array()).into_iter().flatten() {
                if s(b, "type") == Some("toolCall") {
                    c.tool(s(b, "name"), time, ToolKind::Tool, s(b, "id"));
                }
            }
        }
        _ => {}
    }
}

pub fn scan_pi() -> ScanResult {
    let mut c = Collector::new(PI);
    for file in jsonl_files(&home_join(".pi/agent/sessions")) {
        let mut session = stem(&file);
        let mut model: Option<String> = None;
        for_each_json_line_in(&file, None, |d| match s(d, "type") {
            Some("session") => {
                if let Some(id) = s(d, "id") {
                    session = id.to_string();
                }
                c.session(&session, s(d, "cwd"), None, None);
            }
            Some("model_change") => model = s(d, "modelId").map(String::from).or(model.clone()),
            Some("message") => {
                if let Some(m) = d.get("message") {
                    pi_message(&mut c, m, &session, any_time(d.get("timestamp")), model.as_deref(), s(d, "id"));
                }
            }
            _ => {}
        });
    }
    c.finish()
}

/// MiniMax "root" sessions only carry injected agent context; the user's chats are "branch" sessions.
pub fn scan_minimax() -> ScanResult {
    let mut c = Collector::new(MINIMAX);
    for file in files_where(&home_join(".minimax/v2/sessions"), |p| p.file_name().map_or(false, |n| n == "ledger.jsonl")) {
        for_each_json_line_in(&file, None, |d| {
            let Some(session) = s(d, "sessionId") else { return };
            match s(d, "kind") {
                Some("session.created") | Some("session.metadata_updated") => {
                    let rec = d.get("record");
                    let title = rec.and_then(|r| s(r, "title")).filter(|t| *t != "Main");
                    c.session(session, rec.and_then(|r| s(r, "workspaceDir")), title, None);
                }
                Some("message.pi_history_appended") => {
                    let event = s(d, "eventId").unwrap_or("").to_string();
                    for (n, m) in d.get("messages").and_then(|x| x.as_array()).into_iter().flatten().enumerate() {
                        pi_message(&mut c, m, session, None, None, Some(&format!("{event}#{n}")));
                    }
                }
                _ => {}
            }
        });
    }
    c.finish()
}

// MARK: - Accio (~/.accio/accounts/**/*.messages.jsonl)

pub fn scan_accio() -> ScanResult {
    let mut c = Collector::new(ACCIO);
    let files = files_where(&home_join(".accio/accounts"), |p| p.to_string_lossy().ends_with(".messages.jsonl"));
    for file in files {
        let path = file.to_string_lossy().replace('\\', "/");
        let is_sub = path.contains("/subagent-sessions/");
        let name = file.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
        let session = name.trim_end_matches(".messages.jsonl").to_string();
        let mut first: Option<f64> = None;
        for_each_json_line_in(&file, None, |d| {
            let time = any_time(d.get("timestamp"));
            first = first.or(time);
            let meta = d.get("metadata");
            match s(d, "role") {
                Some("user") if !is_sub => c.prompt(&session, time, &plain_text(d.get("content")), s(d, "id")),
                Some("assistant") => {
                    if let Some(u) = meta.and_then(|m| m.get("usage")) {
                        let model = meta.and_then(|m| s(m, "model")).or(s(d, "model"));
                        c.usage(&session, time, model, normalize_usage(u), s(d, "id"));
                    }
                    for call in d.get("toolCalls").and_then(|x| x.as_array()).into_iter().flatten() {
                        c.tool(s(call, "name"), time, ToolKind::Tool, s(call, "id"));
                    }
                }
                _ => {}
            }
        });
        if is_sub {
            c.tool(Some("子任务 agent"), first, ToolKind::Subagent, None);
        }
    }
    c.finish()
}

// MARK: - Kiro (CLI sessions + Kiro Crew dashboard chats)

pub fn scan_kiro() -> ScanResult {
    let mut c = Collector::new(KIRO);
    for meta in files_where(&home_join(".kiro/sessions/cli"), |p| p.extension().map_or(false, |e| e == "json")) {
        let Some(d) = std::fs::read(&meta).ok().and_then(|b| serde_json::from_slice::<Value>(&b).ok()) else { continue };
        let Some(id) = s(&d, "session_id").map(String::from) else { continue };
        let created = any_time(d.get("created_at"));
        let is_sub = s(&d, "session_created_reason") == Some("subagent");
        c.session(&id, s(&d, "cwd"), s(&d, "title"), None);
        let mut turn_times: Vec<f64> = vec![];
        let turns = at(&d, "session_state.conversation_metadata.user_turn_metadatas").and_then(|t| t.as_array());
        for (n, t) in turns.into_iter().flatten().enumerate() {
            let time = any_time(t.get("end_timestamp")).or(created);
            turn_times.extend(time);
            let model = s(t, "model").or_else(|| s(t, "model.model_name"));
            c.usage(&id, time, model, normalize_usage(t), Some(&format!("{id}#{n}")));
        }
        if is_sub {
            c.tool(Some("子任务 agent"), created, ToolKind::Subagent, None);
        }
        let mut prompt_index = 0usize;
        for_each_json_line_in(&meta.with_extension("jsonl"), None, |line| {
            let body = line.get("data");
            match s(line, "kind") {
                Some("Prompt") => {
                    let time = turn_times.get(prompt_index).copied().or(turn_times.last().copied()).or(created);
                    prompt_index += 1;
                    if !is_sub {
                        c.prompt(&id, time, &plain_text(body.and_then(|b| b.get("content"))), body.and_then(|b| s(b, "message_id")));
                    }
                }
                Some("AssistantMessage") => {
                    let time = prompt_index.checked_sub(1).and_then(|k| turn_times.get(k).copied()).or(created);
                    for b in body.and_then(|b| b.get("content")).and_then(|x| x.as_array()).into_iter().flatten() {
                        if s(b, "kind") == Some("toolUse") {
                            let u = b.get("data");
                            c.tool(u.and_then(|u| s(u, "name")), time, ToolKind::Tool, u.and_then(|u| s(u, "toolUseId")));
                        }
                    }
                }
                _ => {}
            }
        });
    }
    // Kiro Crew's dashboard chats hold what the user typed to the crew.
    for file in jsonl_files(&home_join(".kiro/crew/sessions")) {
        let id = format!("crew-{}", stem(&file));
        let mut created: Option<f64> = None;
        for_each_json_line_in(&file, None, |d| {
            if s(d, "_type") == Some("metadata") {
                created = any_time(d.get("created_at"));
                c.session(&id, s(d, "project"), s(d, "title"), None);
            } else if s(d, "role") == Some("user") {
                c.prompt(&id, any_time(d.get("ts")).or(created), &plain_text(d.get("content")), None);
            }
        });
    }
    c.finish()
}

// MARK: - Antigravity (brain/<id>/.system_generated/logs/transcript.jsonl + summaries index)

pub fn scan_antigravity() -> ScanResult {
    let mut c = Collector::new(ANTIGRAVITY);
    let gemini = home_join(".gemini");
    let apps = ["antigravity", "antigravity-cli", "antigravity-ide"];
    let mut workspace: HashMap<String, String> = HashMap::new();
    let mut nested: HashSet<String> = HashSet::new();
    for app in apps {
        let Some(db) = open_ro(&gemini.join(app).join("conversation_summaries.db")) else { continue };
        each_row(&db, "SELECT conversation_id, workspace_uris, nesting_depth, coalesce(nullif(title,''), preview), last_user_input_time FROM conversation_summaries", |r| {
            let Some(id) = col_str(r, 0) else { return };
            if let Some(first) = col_str(r, 1).and_then(|w| serde_json::from_str::<Vec<String>>(&w).ok()).and_then(|v| v.into_iter().next()) {
                workspace.insert(id.clone(), file_uri_path(&first));
            }
            if col_i64(r, 2) > 0 {
                nested.insert(id);
                return;
            }
            let start = col_str(r, 4).and_then(|t| parse_iso8601(&t));
            c.session(&id, workspace.get(&id).map(|s| s.as_str()), col_str(r, 3).as_deref(), start);
        });
    }
    for app in apps {
        let brain = gemini.join(app).join("brain");
        let Ok(entries) = std::fs::read_dir(&brain) else { continue };
        for e in entries.flatten() {
            let id = e.file_name().to_string_lossy().into_owned();
            let t = e.path().join(".system_generated").join("logs").join("transcript.jsonl");
            if !t.exists() {
                continue;
            }
            let is_sub = nested.contains(&id);
            let mut first: Option<f64> = None;
            for_each_json_line_in(&t, None, |d| {
                let time = any_time(d.get("created_at"));
                first = first.or(time);
                match s(d, "type") {
                    Some("USER_INPUT") if !is_sub && s(d, "source") == Some("USER_EXPLICIT") => {
                        c.session(&id, workspace.get(&id).map(|s| s.as_str()), None, None);
                        let step = d.get("step_index").map(|v| v.to_string()).unwrap_or_default();
                        c.prompt(&id, time, s(d, "content").unwrap_or(""), Some(&format!("{id}#{step}")));
                    }
                    Some("PLANNER_RESPONSE") => {
                        for call in d.get("tool_calls").and_then(|x| x.as_array()).into_iter().flatten() {
                            c.tool(s(call, "name"), time, ToolKind::Tool, None);
                        }
                    }
                    _ => {}
                }
            });
            if is_sub {
                c.tool(Some("子任务 agent"), first, ToolKind::Subagent, None);
            }
        }
    }
    c.finish()
}

/// "file:///c%3A/Users/x/proj" or "file:///Users/x/proj" → a plain path.
fn file_uri_path(uri: &str) -> String {
    let rest = uri.strip_prefix("file://").unwrap_or(uri);
    let decoded = percent_encoding::percent_decode_str(rest).decode_utf8_lossy().into_owned();
    let b = decoded.as_bytes();
    if b.len() > 3 && b[0] == b'/' && b[2] == b':' {
        decoded[1..].to_string()
    } else {
        decoded
    }
}

// MARK: - Cursor (IDE chats in state.vscdb + cursor-agent CLI transcripts)

pub fn scan_cursor() -> ScanResult {
    let mut c = Collector::new(CURSOR);
    let mut composer_created: HashMap<String, f64> = HashMap::new();
    for user in app_data_dirs("Cursor").into_iter().map(|d| d.join("User")) {
        // Which workspace folder each composer belongs to.
        let mut folder: HashMap<String, String> = HashMap::new();
        for ws in std::fs::read_dir(user.join("workspaceStorage")).into_iter().flatten().flatten() {
            let Some(f) = std::fs::read(ws.path().join("workspace.json")).ok()
                .and_then(|b| serde_json::from_slice::<Value>(&b).ok())
                .and_then(|j| s(&j, "folder").map(file_uri_path)) else { continue };
            let Some(db) = open_ro(&ws.path().join("state.vscdb")) else { continue };
            each_row(&db, "SELECT value FROM ItemTable WHERE key = 'composer.composerData'", |r| {
                for comp in col_json(r, 0).and_then(|j| j.get("allComposers").cloned()).and_then(|a| a.as_array().cloned()).unwrap_or_default() {
                    if let Some(id) = s(&comp, "composerId") {
                        folder.insert(id.to_string(), f.clone());
                    }
                }
            });
        }
        let Some(db) = open_ro(&user.join("globalStorage").join("state.vscdb")) else { continue };
        let mut composer_model: HashMap<String, String> = HashMap::new();
        each_row(&db, "SELECT key, json_extract(value,'$.name'), json_extract(value,'$.createdAt'), json_extract(value,'$.modelConfig.modelName')
                       FROM cursorDiskKV WHERE key LIKE 'composerData:%' AND json_valid(value)", |r| {
            let Some(key) = col_str(r, 0) else { return };
            let id = key.trim_start_matches("composerData:").to_string();
            if let Some(m) = col_str(r, 3).filter(|m| m != "default") {
                composer_model.insert(id.clone(), m);
            }
            if let Some(t) = epoch_ms(col_i64(r, 2)) {
                composer_created.insert(id.clone(), t);
            }
            c.session(&id, folder.get(&id).map(|s| s.as_str()), col_str(r, 1).as_deref(), None);
        });
        each_row(&db, "SELECT key, json_extract(value,'$.type'), substr(json_extract(value,'$.text'),1,4000),
                              json_extract(value,'$.createdAt'), json_extract(value,'$.tokenCount.inputTokens'),
                              json_extract(value,'$.tokenCount.outputTokens'), json_extract(value,'$.toolFormerData.name'),
                              json_extract(value,'$.modelInfo.modelName')
                       FROM cursorDiskKV WHERE key LIKE 'bubbleId:%' AND json_valid(value)", |r| {
            let Some(key) = col_str(r, 0) else { return };
            let parts: Vec<&str> = key.split(':').collect();
            if parts.len() < 3 {
                return;
            }
            let (composer, bubble) = (parts[1], parts[2]);
            let time = col_str(r, 3).and_then(|t| any_time(Some(&Value::String(t)))).or(composer_created.get(composer).copied());
            if col_i64(r, 1) == 1 {
                c.prompt(composer, time, &col_str(r, 2).unwrap_or_default(), Some(bubble));
            } else {
                let model = col_str(r, 7).filter(|m| m != "default").or_else(|| composer_model.get(composer).cloned()).unwrap_or_else(|| "Cursor Auto".into());
                c.usage(composer, time, Some(&model), Some(Tokens { input: col_i64(r, 4), output: col_i64(r, 5), ..Default::default() }), Some(bubble));
                c.tool(col_str(r, 6).as_deref(), time, ToolKind::Tool, Some(bubble));
            }
        });
    }

    // Agent transcripts mirror IDE composers (which carry real timestamps), and the same one is
    // written under every project it touched; only read conversations the IDE doesn't have.
    let projects = home_join(".cursor/projects");
    let transcripts = files_where(&projects, |p| {
        p.extension().map_or(false, |e| e == "jsonl") && p.to_string_lossy().replace('\\', "/").contains("/agent-transcripts/")
    });
    for file in transcripts {
        let id = stem(&file);
        if composer_created.contains_key(&id) {
            continue;
        }
        let project_dir = file.strip_prefix(&projects).ok().and_then(|r| r.components().next())
            .map(|c| c.as_os_str().to_string_lossy().into_owned()).unwrap_or_default();
        let cwd = (project_dir != "empty-window").then(|| project_dir.replace('-', "/"));
        let mut time = mtime(&file);
        let mut index = 0;
        for_each_json_line_in(&file, None, |d| {
            let content = at(d, "message.content");
            if s(d, "role") == Some("user") {
                let text = plain_text(content);
                if let Some(t) = cursor_timestamp(&text) {
                    time = Some(t);
                }
                c.session(&id, cwd.as_deref(), None, None);
                c.prompt(&id, time, &text, Some(&format!("{id}#{index}")));
                index += 1;
            } else {
                for b in content.and_then(|x| x.as_array()).into_iter().flatten() {
                    if s(b, "type") == Some("tool_use") {
                        c.tool(s(b, "name"), time, ToolKind::Tool, None);
                    }
                }
            }
        });
    }
    c.finish()
}

/// "<timestamp>Monday, Aug 10, 2026, 3:26 PM (UTC+8)</timestamp>" → epoch seconds.
fn cursor_timestamp(text: &str) -> Option<f64> {
    let a = text.find("<timestamp>")? + "<timestamp>".len();
    let b = text[a..].find("</timestamp>")? + a;
    let raw = &text[a..b];
    let (stamp, offset_h) = match raw.find(" (UTC") {
        Some(p) => (&raw[..p], raw[p + 5..].trim_end_matches(')').replace('+', "").parse::<i32>().unwrap_or(0)),
        None => (raw, 0),
    };
    let naive = chrono::NaiveDateTime::parse_from_str(stamp, "%A, %b %d, %Y, %I:%M %p").ok()?;
    let tz = chrono::FixedOffset::east_opt(offset_h * 3600)?;
    Some(naive.and_local_timezone(tz).single()?.timestamp() as f64)
}

// MARK: - DeepSeek Harness (~/.dsh/sessions/**/session*.jsonl.zstd)

pub fn scan_dsh() -> ScanResult {
    let mut c = Collector::new(DSH);
    let all = files_where(&home_join(".dsh/sessions"), |p| {
        let n = p.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
        n.starts_with("session") && (n.ends_with(".jsonl") || n.ends_with(".jsonl.zstd"))
    });
    let paths: HashSet<String> = all.iter().map(|p| p.to_string_lossy().into_owned()).collect();
    for file in all {
        let p = file.to_string_lossy().into_owned();
        // A session upgraded in place keeps the old log next to the `.v4` one; read only one.
        if p.contains(".v4.") && paths.contains(&p.replace(".v4.", ".")) {
            continue;
        }
        let data = if p.ends_with(".zstd") {
            std::fs::read(&file).ok().and_then(|b| zstd::stream::decode_all(&b[..]).ok())
        } else {
            std::fs::read(&file).ok()
        };
        let Some(data) = data else { continue };
        let mut session = file.parent().and_then(|d| d.file_name()).map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
        let mut model: Option<String> = None;
        let mut depth = 0;
        let mut first: Option<f64> = None;
        for_each_json_line(&data, None, |d| {
            let time = any_time(d.get("time").or(d.get("time0")));
            first = first.or(time);
            let body = d.get("data");
            match s(d, "type") {
                Some("session") => {
                    if let Some(id) = s(d, "id") {
                        session = id.to_string();
                    }
                    depth = i(d, "delegationDepth");
                    c.session(&session, s(d, "cwd"), None, None);
                }
                Some("session/title") => c.session(&session, None, body.and_then(|b| s(b, "title")), None),
                Some("request/context") => model = body.and_then(|b| s(b, "model")).map(String::from).or(model.clone()),
                Some("request/header") => model = body.and_then(|b| s(b, "header.config.model")).map(String::from).or(model.clone()),
                Some("user/message") => {
                    if depth == 0 && body.and_then(|b| s(b, "source.kind")) == Some("user") {
                        c.prompt(&session, time, &plain_text(body.and_then(|b| b.get("content"))), body.and_then(|b| s(b, "id")));
                    }
                }
                Some("tool/call") => c.tool(body.and_then(|b| s(b, "name")), time, ToolKind::Tool, body.and_then(|b| s(b, "callId"))),
                _ => {}
            }
            if let Some(u) = body.and_then(|b| b.get("usage").or_else(|| at(b, "message.usage"))) {
                let seq = d.get("seq").or(d.get("seq0")).map(|v| v.to_string()).unwrap_or_default();
                c.usage(&session, time, model.as_deref(), normalize_usage(u), Some(&format!("{session}#{seq}")));
            }
        });
        if depth > 0 {
            c.tool(Some("子任务 agent"), first, ToolKind::Subagent, None);
        }
    }
    c.finish()
}

// MARK: - Agent Cowork (Claude Agent SDK desktop app)

pub fn scan_cowork() -> ScanResult {
    let mut c = Collector::new(COWORK);
    for dir in app_data_dirs("agent-cowork") {
        let Some(db) = open_ro(&dir.join("sessions.db")) else { continue };
        let mut model: HashMap<String, String> = HashMap::new();
        each_row(&db, "SELECT session_id, data, created_at FROM messages ORDER BY created_at", |r| {
            let (Some(sid), Some(d)) = (col_str(r, 0), col_json(r, 1)) else { return };
            let time = epoch_ms(col_i64(r, 2));
            match s(&d, "type") {
                Some("user_prompt") => c.prompt(&sid, time, s(&d, "prompt").unwrap_or(""), None),
                Some("system") if s(&d, "subtype") == Some("init") => {
                    c.session(&sid, s(&d, "cwd"), None, None);
                    if let Some(m) = s(&d, "model") {
                        model.insert(sid.clone(), m.to_string());
                    }
                }
                // The run summary carries the run's total usage; per-message usage is only in stream deltas.
                Some("result") => {
                    if let Some(u) = d.get("usage") {
                        c.usage(&sid, time, model.get(&sid).map(|s| s.as_str()), normalize_usage(u), s(&d, "uuid"));
                    }
                }
                _ => {}
            }
        });
    }
    c.finish()
}

// MARK: - Small local chat apps

pub fn scan_copilot() -> ScanResult {
    let mut c = Collector::new(COPILOT);
    if let Some(db) = open_ro(&home_join(".copilot/session-store.db")) {
        each_row(&db, "SELECT id, cwd, summary FROM sessions", |r| {
            if let Some(id) = col_str(r, 0) {
                let cwd = col_str(r, 1).filter(|c| c != "/");
                c.session(&id, cwd.as_deref(), col_str(r, 2).as_deref(), None);
            }
        });
        each_row(&db, "SELECT session_id, user_message, timestamp, id FROM turns", |r| {
            if let Some(sid) = col_str(r, 0) {
                let time = col_str(r, 2).and_then(|t| any_time(Some(&Value::String(t))));
                c.prompt(&sid, time, &col_str(r, 1).unwrap_or_default(), Some(&format!("turn-{}", col_i64(r, 3))));
            }
        });
    }
    c.finish()
}

pub fn scan_ollama() -> ScanResult {
    let mut c = Collector::new(OLLAMA);
    for dir in app_data_dirs("Ollama") {
        let Some(db) = open_ro(&dir.join("db.sqlite")) else { continue };
        if columns(&db, "chats").contains("title") {
            each_row(&db, "SELECT id, title FROM chats", |r| {
                if let Some(id) = col_str(r, 0) {
                    c.session(&id, None, col_str(r, 1).as_deref(), None);
                }
            });
        }
        each_row(&db, "SELECT chat_id, role, content, created_at, id FROM messages", |r| {
            let Some(chat) = col_str(r, 0) else { return };
            if col_str(r, 1).as_deref() != Some("user") {
                return;
            }
            let time = col_str(r, 3).and_then(|t| any_time(Some(&Value::String(t))));
            c.prompt(&chat, time, &col_str(r, 2).unwrap_or_default(), col_str(r, 4).as_deref());
        });
    }
    c.finish()
}

pub fn scan_chatwise() -> ScanResult {
    let mut c = Collector::new(CHATWISE);
    for dir in app_data_dirs("app.chatwise") {
        let Some(db) = open_ro(&dir.join("app.db")) else { continue };
        each_row(&db, "SELECT chatId, role, content, createdAt, id FROM message", |r| {
            let Some(chat) = col_str(r, 0) else { return };
            if col_str(r, 1).as_deref() == Some("user") {
                c.prompt(&chat, epoch_ms(col_i64(r, 3)), &col_str(r, 2).unwrap_or_default(), col_str(r, 4).as_deref());
            }
        });
    }
    c.finish()
}

/// Zed stores thread bodies zstd-compressed; the index rows are enough to count conversations.
pub fn scan_zed() -> ScanResult {
    let mut c = Collector::new(ZED);
    for dir in app_data_dirs("Zed") {
        let Some(db) = open_ro(&dir.join("threads").join("threads.db")) else { continue };
        let folders = if columns(&db, "threads").contains("folder_paths") { "folder_paths" } else { "NULL" };
        each_row(&db, &format!("SELECT id, summary, created_at, {folders}, parent_id FROM threads"), |r| {
            let Some(id) = col_str(r, 0) else { return };
            if col_str(r, 4).is_some() {
                return;
            }
            let folder = col_str(r, 3).and_then(|f| {
                f.split(|ch| ch == '\n' || ch == ',').next().map(|x| x.trim_matches(|ch| ch == '[' || ch == ']' || ch == '"' || ch == ' ').to_string())
            });
            let start = col_str(r, 2).and_then(|t| parse_iso8601(&t));
            c.session(&id, folder.as_deref(), col_str(r, 1).as_deref(), start);
        });
    }
    c.finish()
}
