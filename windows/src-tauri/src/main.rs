// Release builds are GUI apps on Windows (no console window).
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod model;
mod period;
mod pricing;
mod report;
mod scan;
mod util;

use base64::Engine;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use tauri::{Emitter, State};
use tauri_plugin_dialog::DialogExt;

#[derive(Default)]
struct AppState {
    scan: Mutex<Option<Arc<model::ScanResult>>>,
    /// Where the next exported video goes, picked in the save dialog.
    video_path: Mutex<Option<PathBuf>>,
    /// `--export-video PATH`: the page exports the default report there on its own, then the app quits.
    auto_export: Option<PathBuf>,
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

/// `period` is `{kind: "year", year: 2026}`, `{kind: "all"}`, `{kind: "thisWeek"}`, `{kind: "lastWeek"}` or `{kind: "thisMonth"}`.
#[tauri::command]
fn get_report(period: period::Period, state: State<'_, AppState>) -> Result<report::Report, String> {
    let scan = state.scan.lock().unwrap().clone().ok_or("还没有扫描")?;
    Ok(report::build(&scan, period))
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

/// Asks where to save the short video; the page renders it only once a place is chosen.
#[tauri::command]
async fn pick_video_path(app: tauri::AppHandle, state: State<'_, AppState>, file_name: String) -> Result<bool, String> {
    let picked = tauri::async_runtime::spawn_blocking(move || {
        app.dialog().file().set_file_name(&file_name).add_filter("MP4 视频", &["mp4"]).blocking_save_file()
    })
    .await
    .map_err(|e| e.to_string())?;
    let path = picked.and_then(|p| p.into_path().ok());
    let chosen = path.is_some();
    *state.video_path.lock().unwrap() = path;
    Ok(chosen)
}

/// Writes the MP4 the page encoded (sent as raw bytes) to the picked place and shows it in Explorer.
#[tauri::command]
fn save_video(request: tauri::ipc::Request<'_>, state: State<'_, AppState>) -> Result<(), String> {
    let tauri::ipc::InvokeBody::Raw(bytes) = request.body() else { return Err("没有收到视频数据".into()) };
    let path = match &state.auto_export {
        Some(path) => path.clone(),
        None => state.video_path.lock().unwrap().take().ok_or("还没有选择保存位置")?,
    };
    std::fs::write(&path, bytes).map_err(|e| e.to_string())?;
    #[cfg(windows)]
    if state.auto_export.is_none() {
        let _ = std::process::Command::new("explorer").arg("/select,").arg(&path).spawn();
    }
    Ok(())
}

#[tauri::command]
fn is_auto_export(state: State<'_, AppState>) -> bool {
    state.auto_export.is_some()
}

/// Ends an `--export-video` run; a failure is written next to the video for CI to report.
#[tauri::command]
fn finish_auto_export(app: tauri::AppHandle, state: State<'_, AppState>, error: Option<String>) {
    if let (Some(path), Some(error)) = (&state.auto_export, &error) {
        let _ = std::fs::write(format!("{}.error.txt", path.display()), error);
    }
    app.exit(if error.is_some() { 1 } else { 0 });
}

/// Headless modes: `--dump` prints a summary, `--dump-json PATH` writes the report (used by CI).
/// `--period week|lastweek|month`, `--year 2026` or `--all` pick the period; the default is the
/// latest year with data.
fn run_cli(args: &[String]) -> bool {
    let value_after = |flag: &str| args.iter().position(|a| a == flag).and_then(|i| args.get(i + 1)).cloned();
    let json_path = value_after("--dump-json");
    if json_path.is_none() && !args.iter().any(|a| a == "--dump") {
        return false;
    }
    let began = std::time::Instant::now();
    let scan = scan::scan_all(|_, _| {});
    let years = report::available_years(&scan);
    use period::Period;
    let period = match value_after("--period").as_deref() {
        Some("week") => Period::ThisWeek,
        Some("lastweek") => Period::LastWeek,
        Some("month") => Period::ThisMonth,
        _ if args.iter().any(|a| a == "--all") => Period::All,
        _ => value_after("--year").and_then(|y| y.parse().ok()).or(years.last().copied()).map(|year| Period::Year { year }).unwrap_or(Period::All),
    };
    let r = report::build(&scan, period);
    eprintln!("scanned in {:.2}s, years {:?}", began.elapsed().as_secs_f64(), years);
    match json_path {
        Some(path) => std::fs::write(&path, serde_json::to_string_pretty(&r).unwrap()).expect("write report"),
        None => {
            println!("records: usage={} prompts={} tools={} sessions={}", scan.usage.len(), scan.prompts.len(), scan.tools.len(), scan.sessions.len());
            println!("== {} {}", r.period.label, r.period.range_text);
            if let Some(p) = &r.previous {
                println!("compare {}: tokens={} sessions={} prompts={} activeDays={}", r.period.comparison_label, p.tokens, p.sessions, p.prompts, p.active_days);
            }
            if !r.daily.is_empty() {
                println!("daily: {}", r.daily.iter().map(|d| format!("{}={}/{}", &d.date[5..], d.tokens, d.prompts)).collect::<Vec<_>>().join(" "));
            }
            let t = &r.tokens;
            println!("tokens total={} in={} out={} cacheR={} cacheW={}", t.total, t.input, t.output, t.cache_read, t.cache_write);
            let c = &r.cost;
            println!("cost ${:.2} in={:.2} out={:.2} cacheR={:.2} cacheW={:.2} saved={:.2}", c.total(), c.input, c.output, c.cache_read, c.cache_write, c.cache_savings);
            println!("sessions={} prompts={} chars={} activeDays={} streak={}", r.session_count, r.prompt_count, r.char_count, r.active_days, r.longest_streak);
            println!("agents:");
            for a in &r.agents {
                println!("  {} tokens={} sessions={} prompts={}", a.name, a.tokens, a.sessions, a.prompts);
            }
            println!("models:");
            for m in r.models.iter().take(6) {
                println!("  {} [{}] tokens={} calls={} cost={:.2}", m.name, m.agent, m.tokens, m.calls, m.cost);
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

/// The layout is designed at 1200×790; on smaller screens (laptops at 125–150% scaling) shrink
/// the window to fit, keeping the aspect ratio. The page scales its content to the window.
fn fit_to_screen(app: &tauri::App) {
    use tauri::Manager;
    let Some(win) = app.get_webview_window("main") else { return };
    let Ok(Some(monitor)) = win.current_monitor() else { return };
    let screen = monitor.work_area().size.to_logical::<f64>(monitor.scale_factor());
    let k = (screen.width * 0.92 / 1200.0).min(screen.height * 0.92 / 790.0);
    if k < 1.0 {
        let _ = win.set_size(tauri::LogicalSize::new((1200.0 * k).round(), (790.0 * k).round()));
        let _ = win.center();
    }
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if run_cli(&args) {
        return;
    }
    let auto_export = args.iter().position(|a| a == "--export-video").and_then(|i| args.get(i + 1)).map(PathBuf::from);
    tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .manage(AppState { auto_export, ..Default::default() })
        .setup(|app| {
            fit_to_screen(app);
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![start_scan, get_report, save_png, pick_video_path, save_video, is_auto_export, finish_auto_export])
        .run(tauri::generate_context!())
        .expect("error while running AI Wrapped");
}
