// Release builds are GUI apps on Windows (no console window).
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod model;
mod report;
mod scan;
mod util;

use base64::Engine;
use std::sync::{Arc, Mutex};
use tauri::{Emitter, State};
use tauri_plugin_dialog::DialogExt;

#[derive(Default)]
struct AppState {
    scan: Mutex<Option<Arc<model::ScanResult>>>,
}

#[derive(Clone, serde::Serialize)]
struct Progress {
    fraction: f64,
    label: String,
}

/// Scans every agent on a worker thread, streaming progress as "scan-progress" events.
#[tauri::command]
async fn start_scan(app: tauri::AppHandle, state: State<'_, AppState>) -> Result<Vec<i32>, String> {
    let handle = app.clone();
    let result = tauri::async_runtime::spawn_blocking(move || {
        scan::scan_all(|fraction, label| {
            let _ = handle.emit("scan-progress", Progress { fraction, label: label.to_string() });
        })
    })
    .await
    .map_err(|e| e.to_string())?;
    let years = report::available_years(&result);
    *state.scan.lock().unwrap() = Some(Arc::new(result));
    Ok(years)
}

#[tauri::command]
fn get_report(year: Option<i32>, state: State<'_, AppState>) -> Result<report::Report, String> {
    let scan = state.scan.lock().unwrap().clone().ok_or("还没有扫描")?;
    Ok(report::build(&scan, year))
}

/// Saves the share card (a PNG data URL rendered by the page) where the user picks.
#[tauri::command]
async fn save_png(app: tauri::AppHandle, data_url: String, file_name: String) -> Result<bool, String> {
    let b64 = data_url.split_once(',').map(|(_, b)| b).unwrap_or(&data_url);
    let bytes = base64::engine::general_purpose::STANDARD.decode(b64).map_err(|e| e.to_string())?;
    let picked = tauri::async_runtime::spawn_blocking(move || {
        app.dialog().file().set_file_name(&file_name).add_filter("PNG 图片", &["png"]).blocking_save_file()
    })
    .await
    .map_err(|e| e.to_string())?;
    let Some(path) = picked.and_then(|p| p.into_path().ok()) else { return Ok(false) };
    std::fs::write(path, bytes).map_err(|e| e.to_string())?;
    Ok(true)
}

/// Headless modes: `--dump` prints a summary, `--dump-json PATH` writes the report (used by CI).
/// `--year 2026` or `--all` pick the period; the default is the latest year with data.
fn run_cli(args: &[String]) -> bool {
    let value_after = |flag: &str| args.iter().position(|a| a == flag).and_then(|i| args.get(i + 1)).cloned();
    let json_path = value_after("--dump-json");
    if json_path.is_none() && !args.iter().any(|a| a == "--dump") {
        return false;
    }
    let began = std::time::Instant::now();
    let scan = scan::scan_all(|_, _| {});
    let years = report::available_years(&scan);
    let year = if args.iter().any(|a| a == "--all") { None } else { value_after("--year").and_then(|y| y.parse().ok()).or(years.last().copied()) };
    let r = report::build(&scan, year);
    eprintln!("scanned in {:.2}s, years {:?}", began.elapsed().as_secs_f64(), years);
    match json_path {
        Some(path) => std::fs::write(&path, serde_json::to_string_pretty(&r).unwrap()).expect("write report"),
        None => {
            println!("records: usage={} prompts={} tools={} sessions={}", scan.usage.len(), scan.prompts.len(), scan.tools.len(), scan.sessions.len());
            println!("== {}", year.map(|y| y.to_string()).unwrap_or("全部".into()));
            let t = &r.tokens;
            println!("tokens total={} in={} out={} cacheR={} cacheW={}", t.total, t.input, t.output, t.cache_read, t.cache_write);
            println!("sessions={} prompts={} chars={} activeDays={} streak={}", r.session_count, r.prompt_count, r.char_count, r.active_days, r.longest_streak);
            println!("agents:");
            for a in &r.agents {
                println!("  {} tokens={} sessions={} prompts={}", a.name, a.tokens, a.sessions, a.prompts);
            }
            println!("models:");
            for m in r.models.iter().take(6) {
                println!("  {} [{}] tokens={} calls={}", m.name, m.agent, m.tokens, m.calls);
            }
            println!("tool calls={} skills={} subagents={}", r.tool_call_count, r.skill_count, r.subagent_count);
            println!("categories: {}", r.tool_categories.iter().take(10).map(|c| format!("{}={}", c.name, c.count)).collect::<Vec<_>>().join(", "));
            println!("projects: {}", r.projects.iter().take(6).map(|p| format!("{}({}/{})", p.name, p.prompts, p.sessions)).collect::<Vec<_>>().join(", "));
            println!("peak hour {} weekday {:?}", r.peak_hour, r.weekday);
            if let Some(p) = &r.first_prompt {
                println!("first: {} {} {} {}", p.date, p.clock, p.agent, p.preview.chars().take(40).collect::<String>());
            }
            if let Some(s) = &r.longest_session {
                println!("longest: {} {} rounds", s.title, s.prompts);
            }
            println!("persona: {} {:?}", r.persona.title, r.persona.tags);
        }
    }
    true
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if run_cli(&args) {
        return;
    }
    tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .manage(AppState::default())
        .invoke_handler(tauri::generate_handler![start_scan, get_report, save_png])
        .run(tauri::generate_context!())
        .expect("error while running AI Wrapped");
}
