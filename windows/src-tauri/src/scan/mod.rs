pub mod claude;
pub mod codex;
pub mod opencode;
pub mod others;

use crate::model::*;
use crate::util::*;
use rayon::prelude::*;
use std::sync::Mutex;

pub struct Job {
    pub label: String,
    pub weight: u64,
    pub run: Box<dyn Fn() -> ScanResult + Send + Sync>,
}

const MB: u64 = 1_000_000;

fn job(label: &str, weight: u64, run: impl Fn() -> ScanResult + Send + Sync + 'static) -> Job {
    Job { label: label.to_string(), weight, run: Box::new(run) }
}

pub fn jobs() -> Vec<Job> {
    let mut jobs = vec![];
    for scanner in claude::all() {
        let weight: u64 = scanner.files().iter().map(|p| file_size(p)).sum();
        if weight > 0 {
            jobs.push(job(scanner.agent.name, weight, move || scanner.scan()));
        }
    }
    let codex_weight: u64 = codex::codex_files().iter().map(|p| file_size(p)).sum();
    jobs.push(job("Codex", codex_weight, codex::scan_codex));
    jobs.push(job("Factory Droid", MB, codex::scan_droid));
    for scanner in opencode::all() {
        let weight = scanner.db_path().map(|p| file_size(&p)).unwrap_or(0);
        jobs.push(job(scanner.agent.name, weight, move || scanner.scan()));
    }
    jobs.extend([
        job("WorkBuddy", 20 * MB, || others::scan_buddy(WORKBUDDY, &home_join(".workbuddy"))),
        job("CodeBuddy", MB, || others::scan_buddy(CODEBUDDY, &home_join(".codebuddy"))),
        job("Grok Build", 190 * MB, others::scan_grok),
        job("Pi", 15 * MB, others::scan_pi),
        job("MiniMax Code", MB, others::scan_minimax),
        job("Accio", MB, others::scan_accio),
        job("Kiro", 20 * MB, others::scan_kiro),
        job("Antigravity", 60 * MB, others::scan_antigravity),
        job("Cursor", 400 * MB, others::scan_cursor),
        job("DeepSeek Harness", 10 * MB, others::scan_dsh),
        job("Agent Cowork", MB, others::scan_cowork),
        job("Copilot CLI", MB, others::scan_copilot),
        job("Ollama", MB, others::scan_ollama),
        job("ChatWise", MB, others::scan_chatwise),
        job("Zed", MB, others::scan_zed),
    ]);
    jobs
}

/// Scans every supported agent in parallel; `progress` gets (fraction, label of the agent just finished).
pub fn scan_all(progress: impl Fn(f64, &str) + Sync) -> ScanResult {
    progress(0.0, "正在查找本机的 agent");
    let jobs = jobs();
    let total = jobs.iter().map(|j| j.weight.max(MB)).sum::<u64>().max(1);
    let state = Mutex::new((ScanResult::default(), 0u64));
    jobs.par_iter().for_each(|j| {
        let r = (j.run)();
        let fraction = {
            let mut st = state.lock().unwrap();
            st.0.merge(r);
            st.1 += j.weight.max(MB);
            st.1 as f64 / total as f64
        };
        progress(fraction.min(0.99), &j.label);
    });
    progress(1.0, "完成");
    state.into_inner().unwrap().0
}
