//! Turns raw records into one year's (or all-time) report, the same rules as the macOS app.

use crate::model::*;
use crate::period::{totals, weekday_index, Period, PeriodInfo, PeriodTotals, WEEKDAYS};
use crate::pricing::{Cost, ModelPrice};
use crate::util::pretty_model_name;
use chrono::{DateTime, Datelike, Local, NaiveDate, TimeZone};
use serde::Serialize;
use std::collections::{HashMap, HashSet};

pub type DayKey = i64;

fn local_seconds(t: f64) -> f64 {
    let offset = Local.timestamp_opt(t as i64, 0).single().map(|d| d.offset().local_minus_utc()).unwrap_or(0);
    t + offset as f64
}
pub fn day_of(t: f64) -> DayKey {
    (local_seconds(t) / 86400.0).floor() as i64
}
fn hour_of(t: f64) -> usize {
    (local_seconds(t).rem_euclid(86400.0) / 3600.0) as usize
}
fn minute_of(t: f64) -> i64 {
    (local_seconds(t).rem_euclid(86400.0) / 60.0) as i64
}
pub fn date_of(d: DayKey) -> NaiveDate {
    DateTime::from_timestamp(d * 86400, 0).unwrap_or_default().date_naive()
}
pub fn key_of(date: NaiveDate) -> DayKey {
    date.and_hms_opt(0, 0, 0).unwrap().and_utc().timestamp().div_euclid(86400)
}
fn date_str(d: DayKey) -> String {
    date_of(d).format("%Y-%m-%d").to_string()
}
pub fn today() -> DayKey {
    day_of(chrono::Utc::now().timestamp() as f64)
}

#[derive(Serialize, Default, Clone)]
#[serde(rename_all = "camelCase")]
pub struct TokensOut {
    pub input: i64,
    pub output: i64,
    pub cache_read: i64,
    pub cache_write: i64,
    pub total: i64,
}

#[derive(Serialize, Clone)]
#[serde(rename_all = "camelCase")]
pub struct AgentStat {
    pub id: String,
    pub name: String,
    pub color: String,
    pub tokens: i64,
    pub sessions: usize,
    pub prompts: usize,
}

#[derive(Serialize, Clone)]
pub struct ModelStat {
    pub name: String,
    pub agent: String,
    pub color: String,
    pub tokens: i64,
    pub calls: usize,
    pub cost: f64,
}

#[derive(Serialize, Clone)]
pub struct NamedCount {
    pub name: String,
    pub count: usize,
}

#[derive(Serialize, Clone, Default)]
pub struct DayOut {
    pub date: String,
    pub tokens: i64,
    pub prompts: usize,
    pub sessions: usize,
}

/// One day of a week or month, including days still to come.
#[derive(Serialize, Clone)]
#[serde(rename_all = "camelCase")]
pub struct DailyOut {
    pub date: String,
    pub label: String,
    pub tokens: i64,
    pub prompts: usize,
    pub sessions: usize,
    pub is_today: bool,
    pub is_future: bool,
}

#[derive(Serialize, Clone)]
pub struct MonthOut {
    pub label: String,
    pub tokens: i64,
}

#[derive(Serialize, Clone)]
pub struct ProjectStat {
    pub name: String,
    pub prompts: usize,
    pub sessions: usize,
    pub tokens: i64,
}

#[derive(Serialize, Clone)]
#[serde(rename_all = "camelCase")]
pub struct PromptOut {
    pub date: String,
    pub clock: String,
    pub agent: String,
    pub preview: String,
    pub days_ago: i64,
}

#[derive(Serialize, Clone)]
#[serde(rename_all = "camelCase")]
pub struct SessionOut {
    pub title: String,
    pub agent: String,
    pub project: String,
    pub prompts: usize,
    pub duration_secs: f64,
    pub tokens: i64,
}

#[derive(Serialize, Clone)]
pub struct Persona {
    pub title: String,
    pub emoji: String,
    pub blurb: String,
    pub tags: Vec<String>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Report {
    pub year: Option<i32>,
    pub period: PeriodInfo,
    /// The previous week/month up to the same point, for the change chips.
    pub previous: Option<PeriodTotals>,
    pub years: Vec<i32>,
    pub today: String,
    pub tokens: TokensOut,
    /// What `tokens` would cost at each model's official API list price.
    pub cost: Cost,
    pub agents: Vec<AgentStat>,
    pub models: Vec<ModelStat>,
    pub session_count: usize,
    pub prompt_count: usize,
    pub char_count: usize,
    pub tool_call_count: usize,
    pub subagent_count: usize,
    pub skill_count: usize,
    pub tool_categories: Vec<NamedCount>,
    pub raw_tools: Vec<NamedCount>,
    pub skills: Vec<NamedCount>,
    pub subagents: Vec<NamedCount>,
    pub days: Vec<DayOut>,
    pub active_days: usize,
    pub longest_streak: usize,
    pub streak_start: Option<String>,
    pub streak_end: Option<String>,
    pub busiest_day: Option<DayOut>,
    /// Bars for the period: months of a year, days of a week or month.
    pub series: Vec<MonthOut>,
    pub daily: Vec<DailyOut>,
    pub hourly: Vec<usize>,
    pub weekday: Vec<usize>,
    pub peak_hour: usize,
    pub projects: Vec<ProjectStat>,
    pub first_prompt: Option<PromptOut>,
    pub late_night: Option<PromptOut>,
    pub late_night_count: usize,
    pub longest_session: Option<SessionOut>,
    pub persona: Persona,
    pub heatmap_start: String,
    pub heatmap_end: String,
}

pub fn available_years(scan: &ScanResult) -> Vec<i32> {
    let mut ys: HashSet<i32> = HashSet::new();
    ys.extend(scan.usage.iter().map(|u| date_of(day_of(u.time)).year()));
    ys.extend(scan.prompts.iter().map(|p| date_of(day_of(p.time)).year()));
    let mut v: Vec<i32> = ys.into_iter().filter(|y| *y > 2000).collect();
    v.sort();
    v
}

fn agent_entry<'a>(m: &'a mut HashMap<&'static str, AgentStat>, a: Agent) -> &'a mut AgentStat {
    m.entry(a.id).or_insert_with(|| AgentStat { id: a.id.into(), name: a.name.into(), color: a.color.into(), tokens: 0, sessions: 0, prompts: 0 })
}

fn prompt_out(p: &Prompt) -> PromptOut {
    let d = day_of(p.time);
    let m = minute_of(p.time);
    PromptOut { date: date_str(d), clock: format!("{:02}:{:02}", m / 60, m % 60), agent: p.agent.name.to_string(), preview: p.preview.clone(), days_ago: today() - d }
}

pub fn build(scan: &ScanResult, period: Period) -> Report {
    let year = period.year();
    let now = today();
    let range = period.range(now);
    let in_range = |t: f64| -> Option<DayKey> {
        let d = day_of(t);
        match range {
            Some((lo, hi)) if d < lo || d > hi => None,
            _ => Some(d),
        }
    };

    let mut tokens = Tokens::default();
    let mut agent_stats: HashMap<&'static str, AgentStat> = HashMap::new();
    let mut model_stats: HashMap<String, (i64, usize, f64)> = HashMap::new();
    let mut prices: HashMap<String, ModelPrice> = HashMap::new();
    let mut cost = Cost::default();
    let mut model_agent_tokens: HashMap<String, HashMap<&'static str, (i64, Agent)>> = HashMap::new();
    let mut days: HashMap<DayKey, DayOut> = HashMap::new();
    let mut session_tokens: HashMap<&str, i64> = HashMap::new();
    let mut session_span: HashMap<&str, (f64, f64)> = HashMap::new();

    for u in &scan.usage {
        let Some(d) = in_range(u.time) else { continue };
        let total = u.tokens.total();
        tokens.add(&u.tokens);
        agent_entry(&mut agent_stats, u.agent).tokens += total;
        let name = pretty_model_name(&u.model);
        let mut c = prices.entry(name.clone()).or_insert_with(|| ModelPrice::of(&name)).cost(&u.tokens);
        if let Some(recorded) = u.cost {
            c.scale_to(recorded);
        }
        cost.add(&c);
        let e = model_stats.entry(name.clone()).or_default();
        e.0 += total;
        e.1 += 1;
        e.2 += c.total();
        let ma = model_agent_tokens.entry(name).or_default().entry(u.agent.id).or_insert((0, u.agent));
        ma.0 += total;
        days.entry(d).or_default().tokens += total;
        *session_tokens.entry(&u.session).or_default() += total;
        let span = session_span.entry(&u.session).or_insert((u.time, u.time));
        span.0 = span.0.min(u.time);
        span.1 = span.1.max(u.time);
    }
    let mut models: Vec<ModelStat> = model_stats
        .into_iter()
        .filter(|(_, (t, _, _))| *t > 0)
        .map(|(name, (t, calls, cost))| {
            let top = model_agent_tokens[&name].values().max_by_key(|(t, _)| *t).map(|(_, a)| *a).unwrap_or(CLAUDE_CODE);
            ModelStat { name, agent: top.name.into(), color: top.color.into(), tokens: t, calls, cost }
        })
        .collect();
    models.sort_by(|a, b| b.tokens.cmp(&a.tokens));

    // Prompts, sessions, rhythm
    let (mut prompt_count, mut char_count) = (0, 0);
    let mut hourly = vec![0usize; 24];
    let mut weekday = vec![0usize; 7];
    let mut session_prompts: HashMap<&str, usize> = HashMap::new();
    let mut first_prompt: Option<&Prompt> = None;
    let mut late_night: Option<&Prompt> = None;
    let mut late_night_count = 0;
    for p in &scan.prompts {
        let Some(d) = in_range(p.time) else { continue };
        prompt_count += 1;
        char_count += p.chars;
        agent_entry(&mut agent_stats, p.agent).prompts += 1;
        *session_prompts.entry(&p.session).or_default() += 1;
        days.entry(d).or_default().prompts += 1;
        hourly[hour_of(p.time)] += 1;
        weekday[date_of(d).weekday().num_days_from_monday() as usize] += 1;
        if first_prompt.map_or(true, |f| p.time < f.time) {
            first_prompt = Some(p);
        }
        let minute = minute_of(p.time);
        if minute < 5 * 60 {
            late_night_count += 1;
            if late_night.map_or(true, |ln| minute > minute_of(ln.time)) {
                late_night = Some(p);
            }
        }
        let span = session_span.entry(&p.session).or_insert((p.time, p.time));
        span.0 = span.0.min(p.time);
        span.1 = span.1.max(p.time);
    }

    // Conversations the agent lists but whose transcript isn't local (cloud sessions, Zed) still count.
    let mut conversations: HashSet<&str> = session_prompts.keys().copied().collect();
    for (key, info) in &scan.sessions {
        if session_prompts.contains_key(key.as_str()) {
            continue;
        }
        let Some(d) = info.start.and_then(|st| in_range(st)) else { continue };
        conversations.insert(key);
        days.entry(d).or_default().sessions += 1;
    }
    for key in &conversations {
        if let Some(a) = scan.sessions.get(*key).map(|s| s.agent).or_else(|| agent_owning(key)) {
            agent_entry(&mut agent_stats, a).sessions += 1;
        }
    }
    let mut agents: Vec<AgentStat> = agent_stats.into_values().filter(|a| a.tokens > 0 || a.prompts > 0 || a.sessions > 0).collect();
    agents.sort_by(|a, b| (b.tokens, b.prompts, b.sessions).cmp(&(a.tokens, a.prompts, a.sessions)));

    // Projects & longest session
    let mut projects: HashMap<String, ProjectStat> = HashMap::new();
    for key in &conversations {
        let name = scan.sessions.get(*key).map(|s| s.project.clone()).unwrap_or_else(|| UNKNOWN_PROJECT.into());
        let e = projects.entry(name.clone()).or_insert(ProjectStat { name, prompts: 0, sessions: 0, tokens: 0 });
        e.prompts += session_prompts.get(key).copied().unwrap_or(0);
        e.sessions += 1;
    }
    for (key, t) in &session_tokens {
        let name = scan.sessions.get(*key).map(|s| s.project.clone()).unwrap_or_else(|| UNKNOWN_PROJECT.into());
        if let Some(p) = projects.get_mut(&name) {
            p.tokens += t;
        }
    }
    let mut projects: Vec<ProjectStat> = projects.into_values().filter(|p| p.name != UNKNOWN_PROJECT).collect();
    projects.sort_by(|a, b| (b.prompts, b.tokens).cmp(&(a.prompts, a.tokens)));

    let longest_session = session_prompts
        .iter()
        .max_by_key(|(k, n)| (**n, session_tokens.get(*k).copied().unwrap_or(0)))
        .map(|(k, n)| {
            let info = scan.sessions.get(*k);
            let agent = info.map(|s| s.agent).or_else(|| agent_owning(k)).unwrap_or(CLAUDE_CODE);
            let project = info.map(|s| s.project.clone()).unwrap_or_else(|| UNKNOWN_PROJECT.into());
            let span = session_span.get(*k).copied().unwrap_or((0.0, 0.0));
            SessionOut {
                title: info.and_then(|s| s.title.clone()).unwrap_or_else(|| project.clone()),
                agent: agent.name.into(),
                project,
                prompts: *n,
                duration_secs: span.1 - span.0,
                tokens: session_tokens.get(*k).copied().unwrap_or(0),
            }
        });

    // Tools
    let (mut tool_call_count, mut skill_count, mut subagent_count) = (0, 0, 0);
    let (mut cats, mut raw, mut skills, mut subs): (HashMap<String, usize>, HashMap<String, usize>, HashMap<String, usize>, HashMap<String, usize>) = Default::default();
    for t in &scan.tools {
        if in_range(t.time).is_none() {
            continue;
        }
        match t.kind {
            ToolKind::Tool => {
                tool_call_count += 1;
                *raw.entry(t.name.clone()).or_default() += 1;
                *cats.entry(tool_category(&t.name)).or_default() += 1;
            }
            ToolKind::Skill => {
                skill_count += 1;
                let short = t.name.rsplit(':').next().unwrap_or(&t.name).to_string();
                *skills.entry(short).or_default() += 1;
            }
            ToolKind::Subagent => {
                subagent_count += 1;
                *subs.entry(t.name.clone()).or_default() += 1;
            }
        }
    }
    let ranked = |m: HashMap<String, usize>| -> Vec<NamedCount> {
        let mut v: Vec<NamedCount> = m.into_iter().map(|(name, count)| NamedCount { name, count }).collect();
        v.sort_by(|a, b| b.count.cmp(&a.count).then(a.name.cmp(&b.name)));
        v
    };

    // Calendar
    let mut active: Vec<DayKey> = days.iter().filter(|(_, d)| d.tokens > 0 || d.prompts > 0 || d.sessions > 0).map(|(k, _)| *k).collect();
    active.sort();
    let (mut longest_streak, mut streak_start, mut run, mut run_start, mut prev) = (0usize, 0i64, 0usize, 0i64, i64::MIN);
    for &d in &active {
        if d == prev + 1 {
            run += 1;
        } else {
            run = 1;
            run_start = d;
        }
        if run > longest_streak {
            longest_streak = run;
            streak_start = run_start;
        }
        prev = d;
    }
    let busiest_day = days.iter().max_by_key(|(_, d)| (d.tokens, d.prompts)).map(|(k, d)| DayOut { date: date_str(*k), ..d.clone() });

    let daily: Vec<DailyOut> = match range.filter(|_| period.is_short()) {
        Some((lo, hi)) => (lo..=hi)
            .map(|k| {
                let d = days.get(&k).cloned().unwrap_or_default();
                let label = if period.is_week() { format!("周{}", WEEKDAYS[weekday_index(k)]) } else { date_of(k).day().to_string() };
                DailyOut { date: date_str(k), label, tokens: d.tokens, prompts: d.prompts, sessions: d.sessions, is_today: k == now, is_future: k > now }
            })
            .collect(),
        None => vec![],
    };

    let series: Vec<MonthOut> = match period {
        _ if period.is_short() => daily.iter().map(|d| MonthOut { label: d.label.clone(), tokens: d.tokens }).collect(),
        Period::Year { .. } => {
            let mut m = vec![0i64; 12];
            for (k, d) in &days {
                m[date_of(*k).month0() as usize] += d.tokens;
            }
            m.into_iter().enumerate().map(|(i, t)| MonthOut { label: format!("{}月", i + 1), tokens: t }).collect()
        }
        _ => {
            let mut m: HashMap<i32, i64> = HashMap::new();
            for (k, d) in &days {
                let date = date_of(*k);
                *m.entry(date.year() * 12 + date.month0() as i32).or_default() += d.tokens;
            }
            match (m.keys().min().copied(), m.keys().max().copied()) {
                (Some(lo), Some(hi)) => (lo..=hi).map(|i| MonthOut { label: format!("{}/{}", (i / 12) % 100, i % 12 + 1), tokens: m.get(&i).copied().unwrap_or(0) }).collect(),
                _ => vec![],
            }
        }
    };

    let (heat_lo, heat_hi) = match range {
        Some(r) => r,
        None => {
            let hi = active.last().copied().unwrap_or(today()).max(today());
            let wd = date_of(hi).weekday().num_days_from_monday() as i64;
            (hi - 52 * 7 - wd, hi)
        }
    };

    let peak_hour = (0..24).max_by_key(|h| (hourly[*h], 24 - h)).unwrap_or(0);
    let mut day_list: Vec<DayOut> = days.into_iter().filter(|(_, d)| d.tokens > 0 || d.prompts > 0 || d.sessions > 0)
        .map(|(k, d)| DayOut { date: date_str(k), ..d }).collect();
    day_list.sort_by(|a, b| a.date.cmp(&b.date));

    let mut r = Report {
        year,
        period: PeriodInfo::new(&period, now),
        previous: period.comparison(now).map(|(span, _)| totals(scan, span)),
        years: available_years(scan),
        today: date_str(today()),
        tokens: TokensOut { input: tokens.input, output: tokens.output, cache_read: tokens.cache_read, cache_write: tokens.cache_write, total: tokens.total() },
        cost,
        agents,
        models,
        session_count: conversations.len(),
        prompt_count,
        char_count,
        tool_call_count,
        subagent_count,
        skill_count,
        tool_categories: ranked(cats),
        raw_tools: ranked(raw).into_iter().take(30).collect(),
        skills: ranked(skills),
        subagents: ranked(subs),
        active_days: active.len(),
        longest_streak,
        streak_start: (longest_streak > 0).then(|| date_str(streak_start)),
        streak_end: (longest_streak > 0).then(|| date_str(streak_start + longest_streak as i64 - 1)),
        busiest_day,
        days: day_list,
        series,
        daily,
        hourly,
        weekday,
        peak_hour,
        projects: projects.into_iter().take(10).collect(),
        first_prompt: first_prompt.map(prompt_out),
        late_night: late_night.map(prompt_out),
        late_night_count,
        longest_session,
        persona: Persona { title: String::new(), emoji: String::new(), blurb: String::new(), tags: vec![] },
        heatmap_start: date_str(heat_lo),
        heatmap_end: date_str(heat_hi),
    };
    r.persona = persona(&r);
    r
}

pub fn tool_category(name: &str) -> String {
    let n = name.to_lowercase();
    if n.starts_with("mcp__") {
        let server = name.split("__").nth(1).unwrap_or(name);
        let s = server.to_lowercase();
        if n.contains("update_plan") || n.contains("todo") { return "列计划".into() }
        if s.contains("computer") { return "操作电脑".into() }
        if s.contains("browser") || s.contains("chrome") || s.contains("playwright") { return "操控浏览器".into() }
        if s.contains("keenable") || s.contains("search") || s.contains("tavily") || s.contains("firecrawl") { return "上网查资料".into() }
        if s.contains("ccd") { return "管理会话与界面".into() }
        if s.contains("memory") { return "记忆读写".into() }
        return format!("MCP · {server}");
    }
    let exact = match n.as_str() {
        "bash" | "exec_command" | "shell" | "local_shell" | "write_stdin" | "bashoutput" | "killshell" | "execute"
        | "run_terminal_cmd" | "monitor" | "taskoutput" => Some("跑终端命令"),
        "read" | "read_file" | "view_image" | "notebookread" | "readmcpresourcetool" | "ls" | "list" => Some("读文件"),
        "edit" | "multiedit" | "apply_patch" | "notebookedit" | "patch" | "str_replace_editor" | "create" | "write" | "write_file" => Some("写/改代码"),
        "grep" | "glob" | "find" | "search" | "codebase_search" | "file_search" | "rg" => Some("搜索代码"),
        "websearch" | "webfetch" | "web_search" | "web_fetch" | "webfetch_tool" | "fetch" | "web__run" | "web_run" | "search_query" => Some("上网查资料"),
        "agent" | "task" | "spawn_agent" | "send_input" | "wait" | "sendmessage" | "send_message" => Some("派子 agent"),
        "todowrite" | "update_plan" | "todoread" | "taskcreate" | "taskupdate" => Some("列计划"),
        "skill" => Some("调用技能"),
        "toolsearch" | "list_mcp_resources" => Some("找工具"),
        "askuserquestion" | "request_user_input" => Some("向你提问"),
        "artifact" | "sendusefile" | "senduserfile" | "show_widget" => Some("做页面/产物"),
        _ => None,
    };
    if let Some(e) = exact {
        return e.into();
    }
    // Other agents name the same actions differently (run_command, view_file, fs_write…).
    let has = |parts: &[&str]| parts.iter().any(|p| n.contains(p));
    if has(&["web", "url", "browse", "fetch"]) { return "上网查资料".into() }
    if has(&["subagent", "spawn", "delegate"]) { return "派子 agent".into() }
    if has(&["todo", "plan"]) { return "列计划".into() }
    if has(&["shell", "command", "bash", "terminal", "exec", "process"]) { return "跑终端命令".into() }
    if has(&["write", "edit", "replace", "patch", "create_file", "str_replace", "insert"]) { return "写/改代码".into() }
    if has(&["grep", "search", "find", "glob"]) { return "搜索代码".into() }
    if has(&["read", "view", "list_dir", "cat", "open_file"]) { return "读文件".into() }
    if has(&["browser", "click", "screenshot", "navigate"]) { return "操控浏览器".into() }
    name.to_string()
}

fn persona(r: &Report) -> Persona {
    let prompts = r.prompt_count.max(1) as f64;
    let night_share = r.late_night_count as f64 / prompts;
    let tools_per_prompt = r.tool_call_count as f64 / prompts;
    let avg_chars = r.char_count as f64 / prompts;
    let total = r.tokens.total.max(1) as f64;
    let multi_agent = r.agents.iter().filter(|a| a.tokens as f64 / total > 0.05).count();
    let peak = r.peak_hour;
    let mut tags: Vec<String> = vec![];
    if night_share > 0.08 { tags.push("夜猫子".into()) }
    if (5..10).contains(&peak) { tags.push("早起鸟".into()) }
    if tools_per_prompt > 12.0 { tags.push("放手派".into()) }
    if avg_chars > 220.0 { tags.push("长文输入".into()) } else if avg_chars < 40.0 { tags.push("惜字如金".into()) }
    if r.agents.len() >= 8 { tags.push(format!("{} 个 agent 收集者", r.agents.len())) } else if multi_agent >= 2 { tags.push("多 agent 并用".into()) }
    if r.subagent_count > 30 { tags.push("子 agent 指挥家".into()) }
    if r.longest_streak >= 7 { tags.push(format!("连续 {} 天打卡", r.longest_streak)) }
    if r.skill_count > 20 { tags.push("技能收藏家".into()) }
    tags.truncate(4);
    let (title, emoji, blurb) = if night_share > 0.15 {
        ("深夜炼金术士", "🌙", "别人睡着的时候，你在和 AI 把想法炼成代码。凌晨的灵感，最贵也最真。")
    } else if tools_per_prompt > 15.0 {
        ("放手型指挥官", "🧭", "你一句话，AI 跑几十步。你更像在带一支小队，而不是在聊天。")
    } else if multi_agent >= 3 {
        ("多面驯兽师", "🧩", "每个 agent 都有自己的脾气，你知道什么时候该派谁上场。")
    } else if avg_chars > 300.0 {
        ("长篇布道者", "📜", "你给 AI 的上下文比大多数人的需求文档还详细。好的回答来自好的问题。")
    } else if (5..10).contains(&peak) {
        ("晨光早鸟", "🌅", "一天最清醒的时段，你留给了和 AI 一起做事。")
    } else if r.longest_streak >= 14 {
        ("长跑型搭档", "🏃", "不是三分钟热度。你和 AI 的合作，是日复一日的节奏。")
    } else {
        ("稳健协作者", "✨", "问得清楚，用得克制，产出稳定。你把 AI 当成了真正的同事。")
    };
    Persona { title: title.into(), emoji: emoji.into(), blurb: blurb.into(), tags }
}
