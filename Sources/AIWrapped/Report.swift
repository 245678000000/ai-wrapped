import Foundation

struct NamedCount: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let count: Int
}

struct AgentStat: Identifiable {
    var id: AgentKind { agent }
    let agent: AgentKind
    var tokens: Int64 = 0
    var sessions: Int = 0
    var prompts: Int = 0
}

struct ModelStat: Identifiable {
    var id: String { name }
    let name: String
    var agent: AgentKind
    var tokens: Int64
    var calls: Int
}

struct ProjectStat: Identifiable {
    var id: String { name }
    let name: String
    var prompts: Int = 0
    var sessions: Int = 0
    var tokens: Int64 = 0
}

struct DayStat {
    var tokens: Int64 = 0
    var prompts: Int = 0
    var sessions: Int = 0
    var isActive: Bool { tokens > 0 || prompts > 0 || sessions > 0 }
}

struct SessionHighlight {
    let info: SessionInfo
    let prompts: Int
    let duration: Double
    let tokens: Int64
}

struct Persona {
    let title: String
    let symbol: String
    let blurb: String
    let tags: [String]
}

/// Local calendar day number (days since 1970-01-01 in the user's time zone).
typealias DayKey = Int

enum LocalTime {
    static let tz = TimeZone.current
    static var utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    static func localSeconds(_ t: Double) -> Double {
        t + Double(tz.secondsFromGMT(for: Date(timeIntervalSince1970: t)))
    }
    static func day(_ t: Double) -> DayKey { Int(floor(localSeconds(t) / 86400)) }
    static func hour(_ t: Double) -> Int { Int(localSeconds(t).truncatingRemainder(dividingBy: 86400) / 3600) }
    static func minuteOfDay(_ t: Double) -> Int { Int(localSeconds(t).truncatingRemainder(dividingBy: 86400) / 60) }
    static func components(_ day: DayKey) -> DateComponents {
        utc.dateComponents([.year, .month, .day, .weekday], from: Date(timeIntervalSince1970: Double(day) * 86400))
    }
    static func year(_ day: DayKey) -> Int { components(day).year ?? 0 }
    static func dayKey(year: Int, month: Int, day: Int) -> DayKey {
        let d = utc.date(from: DateComponents(year: year, month: month, day: day))!
        return Int(d.timeIntervalSince1970 / 86400)
    }
    static var today: DayKey { day(Date().timeIntervalSince1970) }
}

struct Report {
    let period: Period
    var year: Int? { period.year }
    var title: String {
        switch period {
        case .year(let y): return String(y)
        case .all: return "全部"
        default: return period.label
        }
    }

    var tokens = TokenCounts()
    var agents: [AgentStat] = []
    var models: [ModelStat] = []
    var sessionCount = 0
    var promptCount = 0
    var charCount = 0
    var toolCallCount = 0
    var subagentCount = 0
    var skillCount = 0
    var toolCategories: [NamedCount] = []
    var rawTools: [NamedCount] = []
    var skills: [NamedCount] = []
    var subagents: [NamedCount] = []

    var days: [DayKey: DayStat] = [:]
    var firstDay: DayKey = 0
    var lastDay: DayKey = 0
    var activeDays = 0
    var longestStreak = 0
    var streakStart: DayKey = 0
    var busiestDay: (day: DayKey, stat: DayStat)?
    /// Bars for the period: months of a year, days of a week or month.
    var series: [(label: String, tokens: Int64)] = []
    /// Every day of a week or month, including empty and future ones.
    var daily: [(day: DayKey, stat: DayStat)] = []
    /// The previous week/month up to the same point, for "比上周 ↑ 32%".
    var previous: PeriodTotals?
    var comparisonLabel = ""
    var hourly = [Int](repeating: 0, count: 24)
    var weekday = [Int](repeating: 0, count: 7) // Monday first
    var projects: [ProjectStat] = []
    var firstPrompt: PromptRecord?
    var lateNight: PromptRecord?
    var lateNightCount = 0
    var longestSession: SessionHighlight?
    var persona = Persona(title: "", symbol: "sparkles", blurb: "", tags: [])

    var topAgent: AgentStat? { agents.first }
    var topModel: ModelStat? { models.first }
    var peakHour: Int { hourly.indices.max { hourly[$0] < hourly[$1] } ?? 0 }
    var isEmpty: Bool { tokens.total == 0 && promptCount == 0 }

    static func availableYears(_ scan: ScanResult) -> [Int] {
        var ys = Set<Int>()
        for u in scan.usage { ys.insert(LocalTime.year(LocalTime.day(u.time))) }
        for p in scan.prompts { ys.insert(LocalTime.year(LocalTime.day(p.time))) }
        return ys.filter { $0 > 2000 }.sorted()
    }

    // swiftlint:disable:next function_body_length
    static func build(_ scan: ScanResult, period: Period) -> Report {
        var r = Report(period: period)
        let range = period.range()
        func inRange(_ t: Double) -> DayKey? {
            let d = LocalTime.day(t)
            if let range, !range.contains(d) { return nil }
            return d
        }

        // Tokens, agents, models, days
        var agentStats: [AgentKind: AgentStat] = [:]
        var modelStats: [String: ModelStat] = [:]
        var modelAgentTokens: [String: [AgentKind: Int64]] = [:]
        var sessionTokens: [String: Int64] = [:]
        var sessionSpan: [String: (Double, Double)] = [:]
        for u in scan.usage {
            guard let d = inRange(u.time) else { continue }
            r.tokens += u.tokens
            agentStats[u.agent, default: AgentStat(agent: u.agent)].tokens += u.tokens.total
            let name = prettyModelName(u.model)
            modelStats[name, default: ModelStat(name: name, agent: u.agent, tokens: 0, calls: 0)].tokens += u.tokens.total
            modelStats[name]?.calls += 1
            modelAgentTokens[name, default: [:]][u.agent, default: 0] += u.tokens.total
            r.days[d, default: DayStat()].tokens += u.tokens.total
            sessionTokens[u.session, default: 0] += u.tokens.total
            let span = sessionSpan[u.session] ?? (u.time, u.time)
            sessionSpan[u.session] = (min(span.0, u.time), max(span.1, u.time))
        }
        for (name, byAgent) in modelAgentTokens {
            if let top = byAgent.max(by: { $0.value < $1.value }) { modelStats[name]?.agent = top.key }
        }
        r.models = modelStats.values.filter { $0.tokens > 0 }.sorted { $0.tokens > $1.tokens }

        // Prompts, sessions, rhythm
        var sessionPrompts: [String: Int] = [:]
        for p in scan.prompts {
            guard let d = inRange(p.time) else { continue }
            r.promptCount += 1
            r.charCount += p.chars
            agentStats[p.agent, default: AgentStat(agent: p.agent)].prompts += 1
            sessionPrompts[p.session, default: 0] += 1
            r.days[d, default: DayStat()].prompts += 1
            r.hourly[LocalTime.hour(p.time)] += 1
            let wd = LocalTime.components(d).weekday ?? 1 // 1 = Sunday
            r.weekday[(wd + 5) % 7] += 1
            if r.firstPrompt == nil || p.time < r.firstPrompt!.time { r.firstPrompt = p }
            let minute = LocalTime.minuteOfDay(p.time)
            if minute < 5 * 60 {
                r.lateNightCount += 1
                if let ln = r.lateNight {
                    if minute > LocalTime.minuteOfDay(ln.time) { r.lateNight = p }
                } else {
                    r.lateNight = p
                }
            }
            let span = sessionSpan[p.session] ?? (p.time, p.time)
            sessionSpan[p.session] = (min(span.0, p.time), max(span.1, p.time))
        }
        // Conversations the agent lists but whose transcript isn't local (cloud sessions, Zed) still count.
        var conversations = Set(sessionPrompts.keys)
        for (key, info) in scan.sessions where sessionPrompts[key] == nil {
            guard let start = info.start, let d = inRange(start) else { continue }
            conversations.insert(key)
            r.days[d, default: DayStat()].sessions += 1
        }
        r.sessionCount = conversations.count
        for key in conversations {
            if let agent = scan.sessions[key]?.agent ?? AgentKind.owning(key) {
                agentStats[agent, default: AgentStat(agent: agent)].sessions += 1
            }
        }
        r.agents = agentStats.values
            .filter { $0.tokens > 0 || $0.prompts > 0 || $0.sessions > 0 }
            .sorted { ($0.tokens, $0.prompts, $0.sessions) > ($1.tokens, $1.prompts, $1.sessions) }

        // Projects & longest session
        var projects: [String: ProjectStat] = [:]
        for key in conversations {
            let name = scan.sessions[key]?.project ?? "未知目录"
            projects[name, default: ProjectStat(name: name)].prompts += sessionPrompts[key] ?? 0
            projects[name]?.sessions += 1
        }
        for (key, tokens) in sessionTokens {
            let name = scan.sessions[key]?.project ?? "未知目录"
            if projects[name] != nil { projects[name]?.tokens += tokens }
        }
        r.projects = projects.values
            .filter { $0.name != "未知目录" }
            .sorted { ($0.prompts, $0.tokens) > ($1.prompts, $1.tokens) }

        if let best = sessionPrompts.max(by: { ($0.value, sessionTokens[$0.key] ?? 0) < ($1.value, sessionTokens[$1.key] ?? 0) }) {
            let info = scan.sessions[best.key]
                ?? SessionInfo(agent: AgentKind.owning(best.key) ?? .claudeCode, key: best.key, project: "未知目录", title: nil)
            let span = sessionSpan[best.key] ?? (0, 0)
            r.longestSession = SessionHighlight(info: info, prompts: best.value, duration: span.1 - span.0,
                                                tokens: sessionTokens[best.key] ?? 0)
        }

        // Tools
        var cats: [String: Int] = [:], raw: [String: Int] = [:], skills: [String: Int] = [:], subs: [String: Int] = [:]
        for t in scan.tools {
            guard inRange(t.time) != nil else { continue }
            switch t.kind {
            case .tool:
                r.toolCallCount += 1
                raw[t.name, default: 0] += 1
                cats[toolCategory(t.name), default: 0] += 1
            case .skill:
                r.skillCount += 1
                let short = t.name.split(separator: ":").last.map(String.init) ?? t.name
                skills[short, default: 0] += 1
            case .subagent:
                r.subagentCount += 1
                subs[t.name, default: 0] += 1
            }
        }
        func ranked(_ d: [String: Int]) -> [NamedCount] {
            d.map { NamedCount(name: $0.key, count: $0.value) }.sorted { ($0.count, $1.name) > ($1.count, $0.name) }
        }
        r.toolCategories = ranked(cats)
        r.rawTools = ranked(raw)
        r.skills = ranked(skills)
        r.subagents = ranked(subs)

        // Calendar
        let active = r.days.filter { $0.value.isActive }.keys.sorted()
        r.activeDays = active.count
        r.firstDay = active.first ?? LocalTime.today
        r.lastDay = active.last ?? LocalTime.today
        var run = 0, prev = Int.min, runStart = 0
        for d in active {
            if d == prev + 1 { run += 1 } else { run = 1; runStart = d }
            if run > r.longestStreak { r.longestStreak = run; r.streakStart = runStart }
            prev = d
        }
        r.busiestDay = r.days.max { ($0.value.tokens, $0.value.prompts) < ($1.value.tokens, $1.value.prompts) }
            .map { ($0.key, $0.value) }

        switch period {
        case .year:
            var months = [Int64](repeating: 0, count: 12)
            for (d, s) in r.days { months[(LocalTime.components(d).month ?? 1) - 1] += s.tokens }
            r.series = months.enumerated().map { ("\($0.offset + 1)月", $0.element) }
        case .all:
            var months: [Int: Int64] = [:]
            for (d, s) in r.days {
                let c = LocalTime.components(d)
                months[(c.year ?? 0) * 12 + (c.month ?? 1) - 1, default: 0] += s.tokens
            }
            if let lo = months.keys.min(), let hi = months.keys.max() {
                r.series = (lo...hi).map { m in ("\(m / 12 % 100)/\(m % 12 + 1)", months[m] ?? 0) }
            }
        case .thisWeek, .lastWeek, .thisMonth:
            r.daily = range!.map { ($0, r.days[$0] ?? DayStat()) }
            r.series = r.daily.map { d in
                (period.isWeek ? "周" + Fmt.weekdayName(LocalTime.weekdayIndex(d.day)) : "\(LocalTime.components(d.day).day ?? 0)", d.stat.tokens)
            }
        }
        if let cmp = period.comparison() {
            r.previous = PeriodTotals.of(scan, in: cmp.range)
            r.comparisonLabel = cmp.label
        }

        r.persona = makePersona(r)
        return r
    }

    static func toolCategory(_ name: String) -> String {
        let n = name.lowercased()
        if n.hasPrefix("mcp__") {
            let parts = name.components(separatedBy: "__")
            let server = parts.count > 1 ? parts[1] : name
            let s = server.lowercased()
            if n.contains("update_plan") || n.contains("todo") { return "列计划" }
            if s.contains("computer") { return "操作电脑" }
            if s.contains("browser") || s.contains("chrome") || s.contains("playwright") { return "操控浏览器" }
            if s.contains("keenable") || s.contains("search") || s.contains("tavily") || s.contains("firecrawl") { return "上网查资料" }
            if s.contains("ccd") { return "管理会话与界面" }
            if s.contains("memory") { return "记忆读写" }
            return "MCP · " + server
        }
        switch n {
        case "bash", "exec_command", "shell", "local_shell", "write_stdin", "bashoutput", "killshell", "execute", "run_terminal_cmd", "monitor", "taskoutput":
            return "跑终端命令"
        case "read", "read_file", "view_image", "notebookread", "readmcpresourcetool", "ls", "list":
            return "读文件"
        case "edit", "multiedit", "apply_patch", "notebookedit", "patch", "str_replace_editor", "create", "write", "write_file":
            return "写/改代码"
        case "grep", "glob", "find", "search", "codebase_search", "file_search", "rg":
            return "搜索代码"
        case "websearch", "webfetch", "web_search", "web_fetch", "webfetch_tool", "fetch", "web__run", "web_run", "search_query":
            return "上网查资料"
        case "agent", "task", "spawn_agent", "send_input", "wait", "sendmessage", "send_message":
            return "派子 agent"
        case "todowrite", "update_plan", "todoread", "taskcreate", "taskupdate":
            return "列计划"
        case "skill": return "调用技能"
        case "toolsearch", "list_mcp_resources": return "找工具"
        case "askuserquestion", "request_user_input": return "向你提问"
        case "artifact", "sendusefile", "senduserfile", "show_widget": return "做页面/产物"
        default: break
        }
        // Other agents name the same actions differently (run_command, view_file, fs_write…).
        func has(_ parts: String...) -> Bool { parts.contains { n.contains($0) } }
        if has("web", "url", "browse", "fetch") { return "上网查资料" }
        if has("subagent", "spawn", "delegate") { return "派子 agent" }
        if has("todo", "plan") { return "列计划" }
        if has("shell", "command", "bash", "terminal", "exec", "process") { return "跑终端命令" }
        if has("write", "edit", "replace", "patch", "create_file", "str_replace", "insert") { return "写/改代码" }
        if has("grep", "search", "find", "glob") { return "搜索代码" }
        if has("read", "view", "list_dir", "cat", "open_file") { return "读文件" }
        if has("browser", "click", "screenshot", "navigate") { return "操控浏览器" }
        return name
    }

    static func makePersona(_ r: Report) -> Persona {
        let prompts = max(1, r.promptCount)
        let nightShare = Double(r.lateNightCount) / Double(prompts)
        let toolsPerPrompt = Double(r.toolCallCount) / Double(prompts)
        let avgChars = Double(r.charCount) / Double(prompts)
        let total = max(1, r.tokens.total)
        let multiAgent = r.agents.filter { Double($0.tokens) / Double(total) > 0.05 }.count
        let peak = r.peakHour
        var tags: [String] = []
        if nightShare > 0.08 { tags.append("夜猫子") }
        if peak >= 5 && peak < 10 { tags.append("早起鸟") }
        if toolsPerPrompt > 12 { tags.append("放手派") }
        if avgChars > 220 { tags.append("长文输入") } else if avgChars < 40 { tags.append("惜字如金") }
        if r.agents.count >= 8 { tags.append("\(r.agents.count) 个 agent 收集者") } else if multiAgent >= 2 { tags.append("多 agent 并用") }
        if r.subagentCount > 30 { tags.append("子 agent 指挥家") }
        if r.longestStreak >= 7 { tags.append("连续 \(r.longestStreak) 天打卡") }
        if r.skillCount > 20 { tags.append("技能收藏家") }

        let persona: Persona
        if nightShare > 0.15 {
            persona = Persona(title: "深夜炼金术士", symbol: "moon.stars.fill",
                              blurb: "别人睡着的时候，你在和 AI 把想法炼成代码。凌晨的灵感，最贵也最真。", tags: tags)
        } else if toolsPerPrompt > 15 {
            persona = Persona(title: "放手型指挥官", symbol: "steeringwheel",
                              blurb: "你一句话，AI 跑几十步。你更像在带一支小队，而不是在聊天。", tags: tags)
        } else if multiAgent >= 3 {
            persona = Persona(title: "多面驯兽师", symbol: "square.stack.3d.up.fill",
                              blurb: "每个 agent 都有自己的脾气，你知道什么时候该派谁上场。", tags: tags)
        } else if avgChars > 300 {
            persona = Persona(title: "长篇布道者", symbol: "text.book.closed.fill",
                              blurb: "你给 AI 的上下文比大多数人的需求文档还详细。好的回答来自好的问题。", tags: tags)
        } else if peak >= 5 && peak < 10 {
            persona = Persona(title: "晨光早鸟", symbol: "sunrise.fill",
                              blurb: "一天最清醒的时段，你留给了和 AI 一起做事。", tags: tags)
        } else if r.longestStreak >= 14 {
            persona = Persona(title: "长跑型搭档", symbol: "figure.run",
                              blurb: "不是三分钟热度。你和 AI 的合作，是日复一日的节奏。", tags: tags)
        } else {
            persona = Persona(title: "稳健协作者", symbol: "sparkles",
                              blurb: "问得清楚，用得克制，产出稳定。你把 AI 当成了真正的同事。", tags: tags)
        }
        return Persona(title: persona.title, symbol: persona.symbol, blurb: persona.blurb, tags: Array(tags.prefix(4)))
    }
}
