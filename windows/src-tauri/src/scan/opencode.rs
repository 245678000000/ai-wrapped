//! OpenCode and its relatives (ZCode, MiMo Code) keep sessions in near-identical SQLite
//! schemas: `session`, `message` (JSON `data` with role, tokens, model) and `part`.

use crate::model::*;
use crate::util::*;
use std::collections::{HashMap, HashSet};
use std::path::PathBuf;

pub struct OpenCodeFamily {
    pub agent: Agent,
    pub candidates: Vec<PathBuf>,
}

pub fn all() -> Vec<OpenCodeFamily> {
    let mut mimo = vec![home_join(".local/share/mimocode/mimocode.db")];
    mimo.extend(app_data_dirs("mimocode").into_iter().map(|d| d.join("mimocode.db")));
    vec![
        OpenCodeFamily { agent: OPENCODE, candidates: vec![home_join(".local/share/opencode/opencode.db")] },
        OpenCodeFamily { agent: ZCODE, candidates: vec![home_join(".zcode/cli/db/db.sqlite")] },
        OpenCodeFamily { agent: MIMO, candidates: mimo },
    ]
}

impl OpenCodeFamily {
    pub fn db_path(&self) -> Option<PathBuf> {
        self.candidates.iter().find(|p| p.exists()).cloned()
    }

    pub fn scan(&self) -> ScanResult {
        let mut c = Collector::new(self.agent);
        let Some(db) = self.db_path().and_then(|p| open_ro(&p)) else { return c.finish() };
        let task_type = if columns(&db, "session").contains("task_type") { "task_type" } else { "NULL" };

        let mut sub_sessions = HashSet::new();
        each_row(&db, &format!("SELECT id, directory, title, parent_id, time_created, {task_type} FROM session"), |r| {
            let Some(id) = col_str(r, 0) else { return };
            let title = col_str(r, 2).filter(|t| !t.is_empty() && !t.starts_with("New session"));
            c.session(&id, col_str(r, 1).as_deref(), title.as_deref(), None);
            if col_str(r, 3).is_some() {
                let name = if col_str(r, 5).as_deref() == Some("workflow_child") { "工作流子任务" } else { "子任务 agent" };
                c.tool(Some(name), epoch_ms(col_i64(r, 4)), ToolKind::Subagent, None);
                sub_sessions.insert(id);
            }
        });

        let mut user_messages: HashMap<String, (String, f64)> = HashMap::new();
        each_row(
            &db,
            "SELECT id, session_id, time_created, json_extract(data,'$.role'),
                    coalesce(json_extract(data,'$.modelID'), json_extract(data,'$.modelId')),
                    json_extract(data,'$.tokens.input'), json_extract(data,'$.tokens.output'),
                    json_extract(data,'$.tokens.reasoning'), json_extract(data,'$.tokens.cache.read'),
                    json_extract(data,'$.tokens.cache.write'), json_extract(data,'$.tokens.total'),
                    json_extract(data,'$.semantics.origin')
             FROM message",
            |r| {
                let (Some(id), Some(session)) = (col_str(r, 0), col_str(r, 1)) else { return };
                let Some(time) = epoch_ms(col_i64(r, 2)) else { return };
                if col_str(r, 3).as_deref() == Some("user") {
                    // ZCode injects reminders and notifications as hidden "user" turns.
                    let origin = col_str(r, 11);
                    if !sub_sessions.contains(&session) && (origin.is_none() || origin.as_deref() == Some("real_user")) {
                        user_messages.insert(id, (session, time));
                    }
                    return;
                }
                let (input, output, reasoning) = (col_i64(r, 5), col_i64(r, 6), col_i64(r, 7));
                let (cache_read, cache_write, total) = (col_i64(r, 8), col_i64(r, 9), col_i64(r, 10));
                // ZCode folds cache reads into `input` (total = input + output); the others keep
                // them separate. `tokens.total` tells us which.
                let separate = input + output + reasoning + cache_read + cache_write;
                let folded = total > 0 && cache_read + cache_write > 0 && (total - (input + output)).abs() < (total - separate).abs();
                let t = Tokens {
                    input: if folded { (input - cache_read - cache_write).max(0) } else { input },
                    output: if folded { output.max(total - input) } else { output + reasoning },
                    cache_read,
                    cache_write,
                };
                c.usage(&session, Some(time), col_str(r, 4).as_deref(), Some(t), None);
            },
        );

        let mut prompt_text: HashMap<String, String> = HashMap::new();
        each_row(
            &db,
            "SELECT message_id, json_extract(data,'$.type'), json_extract(data,'$.tool'),
                    substr(json_extract(data,'$.text'), 1, 4000), time_created, json_extract(data,'$.synthetic'),
                    coalesce(json_extract(data,'$.state.input.skill'), json_extract(data,'$.state.input.name'))
             FROM part",
            |r| {
                let Some(mid) = col_str(r, 0) else { return };
                match col_str(r, 1).as_deref() {
                    Some("tool") => {
                        let time = epoch_ms(col_i64(r, 4));
                        let tool = col_str(r, 2);
                        c.tool(tool.as_deref(), time, ToolKind::Tool, None);
                        if tool.as_deref().map(|t| t.eq_ignore_ascii_case("skill")).unwrap_or(false) {
                            c.tool(col_str(r, 6).as_deref(), time, ToolKind::Skill, None);
                        }
                    }
                    Some("text") => {
                        if user_messages.contains_key(&mid) && col_i64(r, 5) == 0 {
                            if let Some(t) = col_str(r, 3) {
                                prompt_text.entry(mid).or_default().push_str(&t);
                            }
                        }
                    }
                    _ => {}
                }
            },
        );

        for (mid, (session, time)) in user_messages {
            let text = prompt_text.get(&mid).map(|s| s.as_str()).unwrap_or("");
            c.prompt(&session, Some(time), text, None);
        }
        c.finish()
    }
}
