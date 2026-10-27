use std::collections::HashMap;

/// An agent whose local logs we know how to read. `id` prefixes every session key.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct Agent {
    pub id: &'static str,
    pub name: &'static str,
    pub color: &'static str,
}

macro_rules! agents {
    ($($konst:ident = $id:literal, $name:literal, $color:literal;)*) => {
        $(pub const $konst: Agent = Agent { id: $id, name: $name, color: $color };)*
        pub const ALL_AGENTS: &[Agent] = &[$($konst),*];
    };
}

agents! {
    CLAUDE_CODE = "claudeCode", "Claude Code", "#FF8A5B";
    CODEX = "codex", "Codex", "#5BE7C4";
    ZCODE = "zcode", "ZCode", "#6FB6FF";
    DROID = "droid", "Factory Droid", "#FFC857";
    OPENCODE = "opencode", "OpenCode", "#C3A6FF";
    MIMO = "mimo", "MiMo Code", "#FF9F43";
    QODER_CN = "qoderCN", "Qoder CN", "#2EE6A6";
    QODER = "qoder", "Qoder", "#1FC8A0";
    QWEN_WORK = "qwenWork", "千问办公", "#8B7CFF";
    WORKBUDDY = "workbuddy", "WorkBuddy", "#4DA3FF";
    CODEBUDDY = "codebuddy", "CodeBuddy", "#5E8BFF";
    GROK = "grok", "Grok Build", "#E8E8E8";
    PI = "pi", "Pi", "#F7A8D8";
    MINIMAX = "minimax", "MiniMax Code", "#FF6B9A";
    ACCIO = "accio", "Accio", "#FFB27A";
    KIRO = "kiro", "Kiro", "#A98BFF";
    ANTIGRAVITY = "antigravity", "Antigravity", "#7FD1FF";
    CURSOR = "cursor", "Cursor", "#B8F06A";
    DSH = "dsh", "DeepSeek Harness", "#5C8DFF";
    COWORK = "cowork", "Agent Cowork", "#FFD27F";
    COPILOT = "copilot", "Copilot CLI", "#B0C4DE";
    OLLAMA = "ollama", "Ollama", "#D9D9D9";
    CHATWISE = "chatwise", "ChatWise", "#9AE6B4";
    ZED = "zed", "Zed", "#84A9FF";
}

/// Agent owning a session key such as "codex:01a1…".
pub fn agent_owning(key: &str) -> Option<Agent> {
    let id = key.split(':').next()?;
    ALL_AGENTS.iter().copied().find(|a| a.id == id)
}

#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Tokens {
    pub input: i64, // uncached input
    pub output: i64, // includes reasoning / thinking
    pub cache_read: i64,
    pub cache_write: i64,
}

impl Tokens {
    pub fn total(&self) -> i64 {
        self.input + self.output + self.cache_read + self.cache_write
    }
    pub fn add(&mut self, o: &Tokens) {
        self.input += o.input;
        self.output += o.output;
        self.cache_read += o.cache_read;
        self.cache_write += o.cache_write;
    }
}

#[derive(Clone, Debug)]
pub struct Usage {
    pub agent: Agent,
    pub model: String,
    pub time: f64,
    pub tokens: Tokens,
    pub session: String,
}

#[derive(Clone, Debug)]
pub struct Prompt {
    pub agent: Agent,
    pub session: String,
    pub time: f64,
    pub chars: usize,
    pub preview: String,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ToolKind {
    Tool,
    Skill,
    Subagent,
}

#[derive(Clone, Debug)]
pub struct Tool {
    pub name: String,
    pub kind: ToolKind,
    pub time: f64,
}

#[derive(Clone, Debug)]
pub struct Session {
    pub agent: Agent,
    pub project: String,
    pub title: Option<String>,
    /// Set when the agent's own session list says this conversation started then, so it
    /// counts even if its transcript isn't stored locally (cloud sessions, Zed).
    pub start: Option<f64>,
}

pub const UNKNOWN_PROJECT: &str = "未知目录";

#[derive(Default, Debug)]
pub struct ScanResult {
    pub usage: Vec<Usage>,
    pub prompts: Vec<Prompt>,
    pub tools: Vec<Tool>,
    pub sessions: HashMap<String, Session>,
}

impl ScanResult {
    pub fn merge(&mut self, o: ScanResult) {
        self.usage.extend(o.usage);
        self.prompts.extend(o.prompts);
        self.tools.extend(o.tools);
        for (k, v) in o.sessions {
            match self.sessions.get_mut(&k) {
                None => {
                    self.sessions.insert(k, v);
                }
                Some(e) => {
                    if e.title.is_none() {
                        e.title = v.title;
                    }
                    if e.project == UNKNOWN_PROJECT {
                        e.project = v.project;
                    }
                    if e.start.is_none() {
                        e.start = v.start;
                    }
                }
            }
        }
    }
}
