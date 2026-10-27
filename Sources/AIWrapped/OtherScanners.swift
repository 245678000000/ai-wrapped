import Foundation
import SQLite3

// MARK: - Codex (~/.codex/sessions rollouts)

enum CodexScanner {
    static var root: URL {
        if let dir = ProcessInfo.processInfo.environment["CODEX_HOME"] { return URL(fileURLWithPath: dir) }
        return home.appendingPathComponent(".codex")
    }

    static func files() -> [URL] {
        jsonlFiles(under: root.appendingPathComponent("sessions"))
            + jsonlFiles(under: root.appendingPathComponent("archived_sessions"))
    }

    private static let patterns = [
        "\"type\":\"session_meta\"", "\"type\":\"turn_context\"", "\"thread_settings_applied\"",
        "\"type\":\"token_count\"", "\"type\":\"user_message\"", "\"type\":\"UserMessage\"",
        "\"type\":\"function_call\"", "\"type\":\"custom_tool_call\"",
        "\"type\":\"local_shell_call\"", "\"type\":\"web_search_call\"",
    ].map(BytePattern.init)

    private static let nestedTool = try! NSRegularExpression(pattern: #"tools\.([A-Za-z_][A-Za-z0-9_]*)\s*\("#)

    private struct Totals { var input: Int64 = 0, cached: Int64 = 0, cacheWrite: Int64 = 0, output: Int64 = 0, total: Int64 = 0 }

    /// Returns the session id alongside the result so archived duplicates can be dropped.
    static func scan(_ url: URL) -> (String, ScanResult) {
        var result = ScanResult()
        var sessionId = url.deletingPathExtension().lastPathComponent
        var cwd: String?
        var userFacing = true
        var subagentName: String?
        var startTime = 0.0
        var model = "unknown"
        var prev = Totals()
        var eventPrompts: [PromptRecord] = []
        var itemPrompts: [PromptRecord] = []
        var key: String { "codex:" + sessionId }

        func prompt(_ raw: String, _ time: Double) -> PromptRecord? {
            var text = raw
            if let r = text.range(of: "## My request:") { text = String(text[r.upperBound...]) }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, !isAutomatedPrompt(text) else { return nil }
            let clean = cleanPromptText(text)
            return PromptRecord(agent: .codex, session: key, time: time, chars: clean.count, preview: String(clean.prefix(160)))
        }

        forEachLine(ofFile: url) { line in
            guard patterns.contains(where: { $0.occurs(in: line) }),
                  let obj = parseJSONObject(line),
                  let payload = obj["payload"] as? [String: Any] else { return }
            let time = parseISO8601(obj["timestamp"] as? String) ?? 0

            switch obj["type"] as? String {
            case "session_meta":
                if let id = payload["id"] as? String { sessionId = id }
                cwd = payload["cwd"] as? String
                startTime = parseISO8601(payload["timestamp"] as? String) ?? time
                let threadSource = payload["thread_source"] as? String
                if let source = payload["source"] as? [String: Any], let sub = source["subagent"] {
                    userFacing = false
                    if let spawn = (sub as? [String: Any])?["thread_spawn"] as? [String: Any] {
                        subagentName = spawn["agent_role"] as? String ?? "子任务 agent"
                    } else {
                        subagentName = threadSource == "guardian_review" ? "自动审查" : "子任务 agent"
                    }
                } else if let threadSource, threadSource != "user" {
                    userFacing = false
                    subagentName = threadSource == "guardian_review" ? "自动审查" : threadSource
                }

            case "turn_context":
                if let m = payload["model"] as? String { model = m }

            case "event_msg":
                switch payload["type"] as? String {
                case "thread_settings_applied":
                    if let m = (payload["thread_settings"] as? [String: Any])?["model"] as? String { model = m }
                case "token_count":
                    guard let info = payload["info"] as? [String: Any],
                          let tu = info["total_token_usage"] as? [String: Any] else { return }
                    let cur = Totals(input: i64(tu["input_tokens"]), cached: i64(tu["cached_input_tokens"]),
                                     cacheWrite: i64(tu["cache_write_input_tokens"]),
                                     output: i64(tu["output_tokens"]), total: i64(tu["total_tokens"]))
                    guard cur.total != prev.total else { return }
                    // Totals are cumulative per thread; a drop means the counter restarted.
                    let base = cur.total > prev.total ? prev : Totals()
                    prev = cur
                    let dIn = cur.input - base.input, dCached = cur.cached - base.cached
                    let dWrite = cur.cacheWrite - base.cacheWrite, dOut = cur.output - base.output
                    let t = TokenCounts(input: max(0, dIn - dCached - dWrite), output: max(0, dOut),
                                        cacheRead: max(0, dCached), cacheWrite: max(0, dWrite))
                    if t.total > 0 {
                        result.usage.append(UsageRecord(agent: .codex, model: model, time: time, tokens: t, session: key))
                    }
                case "user_message":
                    if let m = payload["message"] as? String, let p = prompt(m, time) { eventPrompts.append(p) }
                case "item_completed":
                    guard let item = payload["item"] as? [String: Any], item["type"] as? String == "UserMessage" else { return }
                    let text = (item["content"] as? [[String: Any]] ?? [])
                        .compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
                        .joined(separator: "\n")
                    if let p = prompt(text, time) { itemPrompts.append(p) }
                default: break
                }

            case "response_item":
                let ptype = payload["type"] as? String
                switch ptype {
                case "function_call", "custom_tool_call":
                    guard let name = payload["name"] as? String else { return }
                    if name == "exec", let input = payload["input"] as? String {
                        let ns = input as NSString
                        let matches = nestedTool.matches(in: input, range: NSRange(location: 0, length: ns.length))
                        if matches.isEmpty {
                            result.tools.append(ToolRecord(agent: .codex, name: name, kind: .tool, time: time))
                        }
                        for m in matches {
                            result.tools.append(ToolRecord(agent: .codex, name: ns.substring(with: m.range(at: 1)), kind: .tool, time: time))
                        }
                    } else {
                        result.tools.append(ToolRecord(agent: .codex, name: name, kind: .tool, time: time))
                    }
                case "local_shell_call":
                    result.tools.append(ToolRecord(agent: .codex, name: "shell", kind: .tool, time: time))
                case "web_search_call":
                    result.tools.append(ToolRecord(agent: .codex, name: "web_search", kind: .tool, time: time))
                default: break
                }
            default: break
            }
        }

        // Re-key records created before session_meta told us the real id.
        for i in result.usage.indices { result.usage[i].session = key }
        if userFacing {
            result.prompts = eventPrompts.isEmpty ? itemPrompts : eventPrompts
            for i in result.prompts.indices { result.prompts[i].session = key }
        } else if let subagentName, startTime > 0 {
            result.tools.append(ToolRecord(agent: .codex, name: subagentName, kind: .subagent, time: startTime))
        }
        result.sessions[key] = SessionInfo(agent: .codex, key: key, project: projectName(fromCwd: cwd), title: nil)
        return (sessionId, result)
    }
}

// MARK: - Factory Droid (~/.factory/sessions)

enum DroidScanner {
    static var root: URL { home.appendingPathComponent(".factory/sessions") }

    static func files() -> [URL] { jsonlFiles(under: root) }

    static func scan(_ url: URL) -> ScanResult {
        var result = ScanResult()
        var sessionId = url.deletingPathExtension().lastPathComponent
        var cwd: String?
        var title: String?
        var lastTime = 0.0
        var prompts: [PromptRecord] = []

        forEachLine(ofFile: url) { line in
            guard let obj = parseJSONObject(line) else { return }
            switch obj["type"] as? String {
            case "session_start":
                if let id = obj["id"] as? String { sessionId = id }
                cwd = obj["cwd"] as? String
                if let t = obj["title"] as? String, t != "New Session" { title = t }
            case "message":
                guard let time = parseISO8601(obj["timestamp"] as? String),
                      let msg = obj["message"] as? [String: Any] else { return }
                lastTime = max(lastTime, time)
                let blocks = msg["content"] as? [[String: Any]] ?? []
                if msg["role"] as? String == "user" {
                    let text = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty && !isAutomatedPrompt($0) }
                        .joined(separator: "\n")
                    guard !text.isEmpty else { return }
                    let clean = cleanPromptText(text)
                    prompts.append(PromptRecord(agent: .droid, session: "", time: time, chars: clean.count, preview: String(clean.prefix(160))))
                } else {
                    for b in blocks where b["type"] as? String == "tool_use" {
                        if let name = b["name"] as? String {
                            result.tools.append(ToolRecord(agent: .droid, name: name, kind: .tool, time: time))
                        }
                    }
                }
            default: break
            }
        }

        let key = "droid:" + sessionId
        result.prompts = prompts.map { var p = $0; p.session = key; return p }
        result.sessions[key] = SessionInfo(agent: .droid, key: key, project: projectName(fromCwd: cwd), title: title)

        let settingsURL = url.deletingPathExtension().appendingPathExtension("settings.json")
        if let data = try? Data(contentsOf: settingsURL),
           let settings = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let tu = settings["tokenUsage"] as? [String: Any] {
            let t = TokenCounts(input: i64(tu["inputTokens"]),
                                output: i64(tu["outputTokens"]) + i64(tu["thinkingTokens"]),
                                cacheRead: i64(tu["cacheReadTokens"]),
                                cacheWrite: i64(tu["cacheCreationTokens"]))
            let time = lastTime > 0 ? lastTime
                : ((try? settingsURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?.timeIntervalSince1970 ?? 0)
            if t.total > 0, time > 0 {
                result.usage.append(UsageRecord(agent: .droid, model: settings["model"] as? String ?? "unknown",
                                                time: time, tokens: t, session: key))
            }
        }
        return result
    }
}

// MARK: - OpenCode family (OpenCode, and ZCode which shares its storage layout)

/// OpenCode and ZCode keep sessions in near-identical SQLite schemas: `session`, `message`
/// (JSON `data` with role, tokens, model) and `part` (prompt text, tool calls).
struct OpenCodeFamilyScanner {
    let agent: AgentKind
    let dbPath: String

    static let opencode = OpenCodeFamilyScanner(
        agent: .opencode, dbPath: home.appendingPathComponent(".local/share/opencode/opencode.db").path)
    static let zcode = OpenCodeFamilyScanner(
        agent: .zcode, dbPath: home.appendingPathComponent(".zcode/cli/db/db.sqlite").path)
    static let mimo = OpenCodeFamilyScanner(
        agent: .mimo, dbPath: home.appendingPathComponent(".local/share/mimocode/mimocode.db").path)
    static let all: [OpenCodeFamilyScanner] = [.opencode, .zcode, .mimo]

    func scan() -> ScanResult {
        var result = ScanResult()
        guard FileManager.default.fileExists(atPath: dbPath) else { return result }
        var db: OpaquePointer?
        let uri = "file:" + (dbPath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? dbPath) + "?mode=ro"
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return result
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 2000)

        func query(_ sql: String, _ row: (OpaquePointer) -> Void) {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return }
            defer { sqlite3_finalize(stmt) }
            while sqlite3_step(stmt) == SQLITE_ROW { row(stmt) }
        }
        func text(_ s: OpaquePointer, _ i: Int32) -> String? {
            guard let c = sqlite3_column_text(s, i) else { return nil }
            return String(cString: c)
        }
        func seconds(_ s: OpaquePointer, _ i: Int32) -> Double { Double(sqlite3_column_int64(s, i)) / 1000 }

        var sessionColumns = Set<String>()
        query("PRAGMA table_info(session)") { s in if let name = text(s, 1) { sessionColumns.insert(name) } }
        let taskType = sessionColumns.contains("task_type") ? "task_type" : "NULL"
        let prefix = agent.rawValue + ":"

        var subSessions = Set<String>()
        query("SELECT id, directory, title, parent_id, time_created, \(taskType) FROM session") { s in
            guard let id = text(s, 0) else { return }
            let key = prefix + id
            let title = text(s, 2)
            let untitled = title?.isEmpty ?? true || title!.hasPrefix("New session")
            result.sessions[key] = SessionInfo(agent: agent, key: key, project: projectName(fromCwd: text(s, 1)),
                                               title: untitled ? nil : title)
            if text(s, 3) != nil {
                subSessions.insert(id)
                let name = text(s, 5) == "workflow_child" ? "工作流子任务" : "子任务 agent"
                result.tools.append(ToolRecord(agent: agent, name: name, kind: .subagent, time: seconds(s, 4)))
            }
        }

        var userMessages: [String: (session: String, time: Double)] = [:]
        query("""
            SELECT id, session_id, time_created, json_extract(data,'$.role'),
                   coalesce(json_extract(data,'$.modelID'), json_extract(data,'$.modelId')),
                   json_extract(data,'$.tokens.input'), json_extract(data,'$.tokens.output'),
                   json_extract(data,'$.tokens.reasoning'), json_extract(data,'$.tokens.cache.read'),
                   json_extract(data,'$.tokens.cache.write'), json_extract(data,'$.tokens.total'),
                   json_extract(data,'$.semantics.origin')
            FROM message
            """) { s in
            guard let id = text(s, 0), let session = text(s, 1) else { return }
            let time = seconds(s, 2)
            let key = prefix + session
            if text(s, 3) == "user" {
                // ZCode injects reminders and notifications as hidden "user" turns.
                let origin = text(s, 11)
                if !subSessions.contains(session), origin == nil || origin == "real_user" {
                    userMessages[id] = (key, time)
                }
                return
            }
            let input = sqlite3_column_int64(s, 5), output = sqlite3_column_int64(s, 6)
            let reasoning = sqlite3_column_int64(s, 7), cacheRead = sqlite3_column_int64(s, 8)
            let cacheWrite = sqlite3_column_int64(s, 9), total = sqlite3_column_int64(s, 10)
            // ZCode folds cache reads into `input` (total = input + output); OpenCode and MiMo
            // keep them separate. `tokens.total` tells us which.
            let separate = input + output + reasoning + cacheRead + cacheWrite
            let folded = total > 0 && cacheRead + cacheWrite > 0 && abs(total - (input + output)) < abs(total - separate)
            let t = TokenCounts(input: folded ? max(0, input - cacheRead - cacheWrite) : input,
                                output: folded ? max(output, total - input) : output + reasoning,
                                cacheRead: cacheRead, cacheWrite: cacheWrite)
            if t.total > 0 {
                result.usage.append(UsageRecord(agent: agent, model: text(s, 4) ?? "unknown", time: time, tokens: t, session: key))
            }
        }

        var promptText: [String: String] = [:]
        query("""
            SELECT message_id, json_extract(data,'$.type'), json_extract(data,'$.tool'),
                   substr(json_extract(data,'$.text'), 1, 4000), time_created,
                   json_extract(data,'$.synthetic'),
                   coalesce(json_extract(data,'$.state.input.skill'), json_extract(data,'$.state.input.name'))
            FROM part
            """) { s in
            guard let mid = text(s, 0) else { return }
            switch text(s, 1) {
            case "tool":
                guard let tool = text(s, 2) else { return }
                result.tools.append(ToolRecord(agent: agent, name: tool, kind: .tool, time: seconds(s, 4)))
                if tool.lowercased() == "skill", let skill = text(s, 6) {
                    result.tools.append(ToolRecord(agent: agent, name: skill, kind: .skill, time: seconds(s, 4)))
                }
            case "text":
                if userMessages[mid] != nil, sqlite3_column_int64(s, 5) == 0, let t = text(s, 3) {
                    promptText[mid, default: ""] += t
                }
            default: break
            }
        }

        for (mid, info) in userMessages {
            let clean = cleanPromptText(promptText[mid] ?? "")
            guard !clean.isEmpty, !isAutomatedPrompt(clean) else { continue }
            result.prompts.append(PromptRecord(agent: agent, session: info.session, time: info.time,
                                               chars: clean.count, preview: String(clean.prefix(160))))
        }
        return result
    }
}

// MARK: - Orchestration

enum LocalScanner {
    struct Job {
        let label: String
        let weight: Int64
        let run: () -> ScanResult
    }

    private static func size(_ files: [URL]) -> Int64 { files.reduce(0) { $0 + fileSize($1) } }

    static func jobs() -> [Job] {
        var jobs: [Job] = []
        for scanner in ClaudeFormatScanner.all {
            let files = scanner.files().sorted { fileSize($0) > fileSize($1) }
            guard !files.isEmpty else { continue }
            jobs.append(Job(label: scanner.agent.displayName, weight: size(files)) {
                let outs = Locked([ClaudeFormatScanner.FileOut?](repeating: nil, count: files.count))
                DispatchQueue.concurrentPerform(iterations: files.count) { i in
                    let out = scanner.scan(files[i])
                    outs.with { $0[i] = out }
                }
                return scanner.merge(outs.with { $0.compactMap { $0 } })
            })
        }

        let codexFiles = CodexScanner.files().sorted { fileSize($0) > fileSize($1) }
        jobs.append(Job(label: "Codex", weight: size(codexFiles)) {
            let outs = Locked([(String, ScanResult)?](repeating: nil, count: codexFiles.count))
            DispatchQueue.concurrentPerform(iterations: codexFiles.count) { i in
                let out = CodexScanner.scan(codexFiles[i])
                outs.with { $0[i] = out }
            }
            var result = ScanResult()
            var seen = Set<String>()
            for case let (id, r)? in outs.with({ $0 }) where seen.insert(id).inserted { result.merge(r) }
            return result
        })

        let droidFiles = DroidScanner.files()
        jobs.append(Job(label: "Factory Droid", weight: size(droidFiles)) {
            var result = ScanResult()
            for f in droidFiles { result.merge(DroidScanner.scan(f)) }
            return result
        })

        for scanner in OpenCodeFamilyScanner.all {
            jobs.append(Job(label: scanner.agent.displayName, weight: fileSize(URL(fileURLWithPath: scanner.dbPath))) { scanner.scan() })
        }

        let mb: Int64 = 1_000_000
        jobs += [
            Job(label: "WorkBuddy", weight: 20 * mb) { BuddyScanner.workbuddy.scan() },
            Job(label: "CodeBuddy", weight: mb) { BuddyScanner.codebuddy.scan() },
            Job(label: "Grok Build", weight: 190 * mb) { GrokScanner.scan() },
            Job(label: "Pi", weight: 15 * mb) { PiScanner.scanPi() },
            Job(label: "MiniMax Code", weight: mb) { PiScanner.scanMiniMax() },
            Job(label: "Accio", weight: mb) { AccioScanner.scan() },
            Job(label: "Kiro", weight: 20 * mb) { KiroScanner.scan() },
            Job(label: "Antigravity", weight: 60 * mb) { AntigravityScanner.scan() },
            Job(label: "Cursor", weight: 400 * mb) { CursorScanner.scan() },
            Job(label: "DeepSeek Harness", weight: 10 * mb) { DSHScanner.scan() },
            Job(label: "Agent Cowork", weight: mb) { CoworkScanner.scan() },
            Job(label: "Copilot CLI", weight: mb) { SmallAppScanners.copilot() },
            Job(label: "Ollama", weight: mb) { SmallAppScanners.ollama() },
            Job(label: "ChatWise", weight: mb) { SmallAppScanners.chatwise() },
            Job(label: "Zed", weight: mb) { SmallAppScanners.zed() },
        ]
        return jobs
    }

    /// Scans every supported agent in parallel. `progress` is called from background threads.
    static func scanAll(progress: @escaping (Double, String) -> Void) -> ScanResult {
        progress(0, "正在查找本机的 agent")
        let jobs = jobs()
        let total = max(1, jobs.reduce(Int64(0)) { $0 + max($1.weight, 1_000_000) })
        let state = Locked((result: ScanResult(), done: Int64(0)))
        DispatchQueue.concurrentPerform(iterations: jobs.count) { i in
            let r = jobs[i].run()
            let fraction = state.with { s -> Double in
                s.result.merge(r)
                s.done += max(jobs[i].weight, 1_000_000)
                return Double(s.done) / Double(total)
            }
            progress(min(fraction, 0.99), jobs[i].label)
        }
        progress(1, "完成")
        return state.with { $0.result }
    }
}
