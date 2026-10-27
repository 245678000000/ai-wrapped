import Foundation

/// An agent whose local logs we know how to read. `id` prefixes every session key.
struct AgentKind: Hashable, Comparable {
    let id: String
    let displayName: String
    let tint: UInt32?

    init(_ id: String, _ displayName: String, tint: UInt32? = nil) {
        self.id = id
        self.displayName = displayName
        self.tint = tint
    }

    var rawValue: String { id }

    static func == (a: Self, b: Self) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }
    static func < (a: Self, b: Self) -> Bool { a.displayName < b.displayName }

    static let claudeCode = AgentKind("claudeCode", "Claude Code", tint: 0xFF8A5B)
    static let codex = AgentKind("codex", "Codex", tint: 0x5BE7C4)
    static let zcode = AgentKind("zcode", "ZCode", tint: 0x6FB6FF)
    static let droid = AgentKind("droid", "Factory Droid", tint: 0xFFC857)
    static let opencode = AgentKind("opencode", "OpenCode", tint: 0xC3A6FF)
    static let mimo = AgentKind("mimo", "MiMo Code", tint: 0xFF9F43)
    static let qoderCN = AgentKind("qoderCN", "Qoder CN", tint: 0x2EE6A6)
    static let qoder = AgentKind("qoder", "Qoder", tint: 0x1FC8A0)
    static let qwenWork = AgentKind("qwenWork", "千问办公", tint: 0x8B7CFF)
    static let workbuddy = AgentKind("workbuddy", "WorkBuddy", tint: 0x4DA3FF)
    static let codebuddy = AgentKind("codebuddy", "CodeBuddy", tint: 0x5E8BFF)
    static let grok = AgentKind("grok", "Grok Build", tint: 0xE8E8E8)
    static let pi = AgentKind("pi", "Pi", tint: 0xF7A8D8)
    static let minimax = AgentKind("minimax", "MiniMax Code", tint: 0xFF6B9A)
    static let accio = AgentKind("accio", "Accio", tint: 0xFFB27A)
    static let kiro = AgentKind("kiro", "Kiro", tint: 0xA98BFF)
    static let antigravity = AgentKind("antigravity", "Antigravity", tint: 0x7FD1FF)
    static let cursor = AgentKind("cursor", "Cursor", tint: 0xB8F06A)
    static let dsh = AgentKind("dsh", "DeepSeek Harness", tint: 0x5C8DFF)
    static let cowork = AgentKind("cowork", "Agent Cowork", tint: 0xFFD27F)
    static let copilot = AgentKind("copilot", "Copilot CLI", tint: 0xB0C4DE)
    static let ollama = AgentKind("ollama", "Ollama", tint: 0xD9D9D9)
    static let chatwise = AgentKind("chatwise", "ChatWise", tint: 0x9AE6B4)
    static let zed = AgentKind("zed", "Zed", tint: 0x84A9FF)

    static let all: [AgentKind] = [
        .claudeCode, .codex, .zcode, .droid, .opencode, .mimo, .qoderCN, .qoder, .qwenWork, .workbuddy,
        .codebuddy, .grok, .pi, .minimax, .accio, .kiro, .antigravity, .cursor, .dsh, .cowork, .copilot,
        .ollama, .chatwise, .zed,
    ]

    /// Agent owning a session key such as "codex:01a1…".
    static func owning(_ sessionKey: String) -> AgentKind? {
        guard let colon = sessionKey.firstIndex(of: ":") else { return nil }
        let id = String(sessionKey[..<colon])
        return all.first { $0.id == id }
    }
}

struct TokenCounts: Hashable {
    var input: Int64 = 0       // uncached input
    var output: Int64 = 0      // includes reasoning / thinking
    var cacheRead: Int64 = 0
    var cacheWrite: Int64 = 0

    var total: Int64 { input + output + cacheRead + cacheWrite }

    static func += (l: inout TokenCounts, r: TokenCounts) {
        l.input += r.input
        l.output += r.output
        l.cacheRead += r.cacheRead
        l.cacheWrite += r.cacheWrite
    }
}

struct UsageRecord {
    var agent: AgentKind
    var model: String
    var time: Double
    var tokens: TokenCounts
    var session: String
    /// USD the agent itself reported for this usage, when it records one (Grok Build).
    var cost: Double?
}

struct PromptRecord {
    var agent: AgentKind
    var session: String
    var time: Double
    var chars: Int
    var preview: String
}

enum ToolKind { case tool, skill, subagent }

struct ToolRecord {
    var agent: AgentKind
    var name: String
    var kind: ToolKind
    var time: Double
}

struct SessionInfo {
    var agent: AgentKind
    var key: String
    var project: String
    var title: String?
    /// Set when the agent's own session list says this was a conversation started at this
    /// time, so it counts even if its transcript isn't stored locally (e.g. cloud sessions).
    var start: Double? = nil
}

struct ScanResult {
    var usage: [UsageRecord] = []
    var prompts: [PromptRecord] = []
    var tools: [ToolRecord] = []
    var sessions: [String: SessionInfo] = [:]

    mutating func merge(_ o: ScanResult) {
        usage += o.usage
        prompts += o.prompts
        tools += o.tools
        for (k, v) in o.sessions {
            guard var existing = sessions[k] else { sessions[k] = v; continue }
            if existing.title == nil { existing.title = v.title }
            if existing.project == "未知目录" { existing.project = v.project }
            if existing.start == nil { existing.start = v.start }
            sessions[k] = existing
        }
    }

    var isEmpty: Bool { usage.isEmpty && prompts.isEmpty }
}

/// Thread-safe box used while fanning file scans out across cores.
final class Locked<T> {
    private var value: T
    private let lock = NSLock()
    init(_ value: T) { self.value = value }
    func with<R>(_ body: (inout T) -> R) -> R {
        lock.lock(); defer { lock.unlock() }
        return body(&value)
    }
}
