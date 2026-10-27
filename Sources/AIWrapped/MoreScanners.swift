import Foundation

private let appSupport = home.appendingPathComponent("Library/Application Support")

// MARK: - WorkBuddy / CodeBuddy (Tencent; OpenAI-Agents-style JSONL)

struct BuddyScanner {
    let agent: AgentKind
    let root: URL

    static let workbuddy = BuddyScanner(agent: .workbuddy, root: home.appendingPathComponent(".workbuddy"))
    static let codebuddy = BuddyScanner(agent: .codebuddy, root: home.appendingPathComponent(".codebuddy"))

    func scan() -> ScanResult {
        let c = Collector(agent)
        for file in jsonlFiles(under: root.appendingPathComponent("projects")) {
            let fallback = file.deletingPathExtension().lastPathComponent
            forEachJSONLine(ofFile: file) { d in
                let session = d["sessionId"] as? String ?? fallback
                let time = anyTime(d["timestamp"])
                let cwd = d["cwd"] as? String
                let provider = d["providerData"] as? [String: Any]
                switch d["type"] as? String {
                case "ai-title":
                    c.session(session, cwd: cwd, title: d["aiTitle"] as? String)
                case "message":
                    c.session(session, cwd: cwd)
                    if d["role"] as? String == "user" {
                        c.prompt(session, time, plainText(d["content"]), id: d["id"] as? String)
                    }
                case "function_call":
                    c.tool(d["name"] as? String, time, id: d["callId"] as? String ?? d["id"] as? String)
                default: break
                }
                // Every item of one model response repeats its usage; count it once per response.
                if let raw = (provider?["rawUsage"] as? [String: Any]) ?? (d["usage"] as? [String: Any]) {
                    let model = provider?["requestModelName"] as? String ?? provider?["model"] as? String
                    let id = provider?["messageId"] as? String ?? d["messageId"] as? String ?? d["id"] as? String
                    c.usage(session, time, model: model, normalizeUsage(raw), id: id)
                }
            }
        }
        // WorkBuddy's own index also lists cloud conversations whose transcripts aren't stored locally.
        if let db = ReadOnlyDB(root.appendingPathComponent("workbuddy.db").path) {
            db.rows("SELECT id, cwd, coalesce(custom_title, title), created_at, deleted_at FROM sessions") { r in
                guard let id = r.text(0), r.isNull(4) || r.int(4) <= 0 else { return }
                c.session(id, cwd: r.text(1), title: r.text(2), start: anyTime(NSNumber(value: r.int(3))))
            }
        }
        return c.result
    }
}

// MARK: - Grok Build (~/.grok/sessions/<cwd>/<id>/updates.jsonl, ACP session updates)

enum GrokScanner {
    static func scan() -> ScanResult {
        let c = Collector(.grok)
        let root = home.appendingPathComponent(".grok/sessions")
        for file in files(under: root, where: { $0.lastPathComponent == "updates.jsonl" }) {
            let cwd = file.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent.removingPercentEncoding
            var prompts: [String: (session: String, time: Double?, text: String)] = [:]
            var promptOrder: [String] = []
            forEachJSONLine(ofFile: file) { d in
                guard let params = d["params"] as? [String: Any],
                      let session = params["sessionId"] as? String,
                      let update = params["update"] as? [String: Any] else { return }
                let time = anyTime(params.at("_meta.agentTimestampMs")) ?? anyTime(d["timestamp"])
                c.session(session, cwd: cwd)
                switch update["sessionUpdate"] as? String {
                case "user_message_chunk":
                    let index = update.at("_meta.promptIndex").map { "\($0)" } ?? params.str("_meta.promptId") ?? "\(promptOrder.count)"
                    let key = session + "#" + index
                    if prompts[key] == nil { prompts[key] = (session, time, ""); promptOrder.append(key) }
                    prompts[key]?.text += update.str("content.text") ?? ""
                case "tool_call":
                    let name = update.str("_meta.x.ai/tool.name") ?? (update["_meta"] as? [String: Any]).flatMap { ($0["x.ai/tool"] as? [String: Any])?["name"] as? String }
                        ?? update["title"] as? String
                    c.tool(name, time, id: update["toolCallId"] as? String)
                default: break
                }
                // Each completed turn reports that turn's usage, broken down per model.
                if update["sessionUpdate"] as? String == "turn_completed", let usage = update["usage"] as? [String: Any] {
                    let perModel = usage["modelUsage"] as? [String: [String: Any]] ?? ["grok": usage]
                    let turn = params.str("_meta.eventId") ?? UUID().uuidString
                    for (model, raw) in perModel {
                        c.usage(session, time, model: model, normalizeUsage(raw), id: turn + "|" + model)
                    }
                }
            }
            for key in promptOrder { if let p = prompts[key] { c.prompt(p.session, p.time, p.text, id: key) } }
        }
        return c.result
    }
}

// MARK: - Pi and MiniMax Code (both run the pi agent runtime)

enum PiScanner {
    static func message(_ m: [String: Any], session: String, fallbackTime: Double?, model: String?, id: String?, c: Collector) {
        let time = anyTime(m["timestamp"]) ?? fallbackTime
        switch m["role"] as? String {
        case "user":
            c.prompt(session, time, plainText(m["content"]), id: id)
        case "assistant":
            let mdl = m["model"] as? String ?? model
            if let u = m["usage"] as? [String: Any] { c.usage(session, time, model: mdl, normalizeUsage(u), id: id) }
            for b in m["content"] as? [[String: Any]] ?? [] where b["type"] as? String == "toolCall" {
                c.tool(b["name"] as? String, time, id: b["id"] as? String)
            }
        default: break
        }
    }

    static func scanPi() -> ScanResult {
        let c = Collector(.pi)
        for file in jsonlFiles(under: home.appendingPathComponent(".pi/agent/sessions")) {
            var session = file.deletingPathExtension().lastPathComponent
            var model: String?
            forEachJSONLine(ofFile: file) { d in
                switch d["type"] as? String {
                case "session":
                    if let id = d["id"] as? String { session = id }
                    c.session(session, cwd: d["cwd"] as? String)
                case "model_change":
                    model = d["modelId"] as? String ?? model
                case "message":
                    if let m = d["message"] as? [String: Any] {
                        message(m, session: session, fallbackTime: anyTime(d["timestamp"]), model: model, id: d["id"] as? String, c: c)
                    }
                default: break
                }
            }
        }
        return c.result
    }

    static func scanMiniMax() -> ScanResult {
        let c = Collector(.minimax)
        let root = home.appendingPathComponent(".minimax/v2/sessions")
        // "root" sessions only carry the injected agent context; the user's chats are "branch" sessions.
        for file in files(under: root, where: { $0.lastPathComponent == "ledger.jsonl" }) {
            forEachJSONLine(ofFile: file) { d in
                guard let session = d["sessionId"] as? String else { return }
                switch d["kind"] as? String {
                case "session.created", "session.metadata_updated":
                    let rec = d["record"] as? [String: Any]
                    c.session(session, cwd: rec?["workspaceDir"] as? String,
                              title: (rec?["title"] as? String).flatMap { $0 == "Main" ? nil : $0 })
                case "message.pi_history_appended":
                    let event = d["eventId"] as? String ?? UUID().uuidString
                    for (i, m) in ((d["messages"] as? [[String: Any]]) ?? []).enumerated() {
                        message(m, session: session, fallbackTime: nil, model: nil, id: "\(event)#\(i)", c: c)
                    }
                default: break
                }
            }
        }
        return c.result
    }
}

// MARK: - Accio (~/.accio/accounts/*/…/*.messages.jsonl)

enum AccioScanner {
    static func scan() -> ScanResult {
        let c = Collector(.accio)
        let root = home.appendingPathComponent(".accio/accounts")
        for file in files(under: root, where: { $0.lastPathComponent.hasSuffix(".messages.jsonl") }) {
            let isSub = file.path.contains("/subagent-sessions/")
            let session = file.lastPathComponent.replacingOccurrences(of: ".messages.jsonl", with: "")
            var first: Double?
            forEachJSONLine(ofFile: file) { d in
                let time = anyTime(d["timestamp"])
                if first == nil { first = time }
                let meta = d["metadata"] as? [String: Any]
                switch d["role"] as? String {
                case "user":
                    if !isSub { c.prompt(session, time, plainText(d["content"]), id: d["id"] as? String) }
                case "assistant":
                    if let u = meta?["usage"] as? [String: Any] {
                        c.usage(session, time, model: meta?["model"] as? String ?? d["model"] as? String, normalizeUsage(u), id: d["id"] as? String)
                    }
                    for call in d["toolCalls"] as? [[String: Any]] ?? [] {
                        c.tool(call["name"] as? String, time, id: call["id"] as? String)
                    }
                default: break
                }
            }
            if isSub { c.tool("子任务 agent", first, kind: .subagent) }
        }
        return c.result
    }
}

// MARK: - Kiro (CLI sessions + Kiro Crew dashboard chats)

enum KiroScanner {
    static func scan() -> ScanResult {
        let c = Collector(.kiro)
        let cli = home.appendingPathComponent(".kiro/sessions/cli")
        for meta in files(under: cli, where: { $0.pathExtension == "json" }) {
            guard let data = try? Data(contentsOf: meta),
                  let d = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let id = d["session_id"] as? String else { continue }
            let created = anyTime(d["created_at"])
            let isSub = d["session_created_reason"] as? String == "subagent"
            c.session(id, cwd: d["cwd"] as? String, title: d["title"] as? String)
            let turns = d.dict("session_state.conversation_metadata")?["user_turn_metadatas"] as? [[String: Any]] ?? []
            var turnTimes: [Double] = []
            for (i, t) in turns.enumerated() {
                let time = anyTime(t["end_timestamp"]) ?? created
                if let time { turnTimes.append(time) }
                let model = t["model"] as? String ?? (t["model"] as? [String: Any])?["model_name"] as? String
                c.usage(id, time, model: model, normalizeUsage(t), id: "\(id)#\(i)")
            }
            if isSub { c.tool("子任务 agent", created, kind: .subagent) }
            var promptIndex = 0
            forEachJSONLine(ofFile: meta.deletingPathExtension().appendingPathExtension("jsonl")) { line in
                let body = line["data"] as? [String: Any]
                switch line["kind"] as? String {
                case "Prompt":
                    let time = promptIndex < turnTimes.count ? turnTimes[promptIndex] : (turnTimes.last ?? created)
                    promptIndex += 1
                    if !isSub { c.prompt(id, time, plainText(body?["content"]), id: body?["message_id"] as? String) }
                case "AssistantMessage":
                    let time = promptIndex > 0 && promptIndex - 1 < turnTimes.count ? turnTimes[promptIndex - 1] : created
                    for b in body?["content"] as? [[String: Any]] ?? [] where b["kind"] as? String == "toolUse" {
                        let use = b["data"] as? [String: Any]
                        c.tool(use?["name"] as? String, time, id: use?["toolUseId"] as? String)
                    }
                default: break
                }
            }
        }
        // Kiro Crew's dashboard chats hold what the user typed to the crew.
        for file in jsonlFiles(under: home.appendingPathComponent(".kiro/crew/sessions")) {
            let id = "crew-" + file.deletingPathExtension().lastPathComponent
            var created: Double?
            forEachJSONLine(ofFile: file) { d in
                if d["_type"] as? String == "metadata" {
                    created = anyTime(d["created_at"])
                    c.session(id, cwd: d["project"] as? String, title: d["title"] as? String)
                } else if d["role"] as? String == "user" {
                    c.prompt(id, anyTime(d["ts"]) ?? created, plainText(d["content"]))
                }
            }
        }
        return c.result
    }
}

// MARK: - Antigravity (brain/<id>/.system_generated/logs/transcript.jsonl + summaries index)

enum AntigravityScanner {
    static func scan() -> ScanResult {
        let c = Collector(.antigravity)
        let gemini = home.appendingPathComponent(".gemini")
        let apps = ["antigravity", "antigravity-cli", "antigravity-ide"]
        var workspace: [String: String] = [:]
        var nested = Set<String>()
        for app in apps {
            guard let db = ReadOnlyDB(gemini.appendingPathComponent("\(app)/conversation_summaries.db").path) else { continue }
            db.rows("SELECT conversation_id, workspace_uris, nesting_depth, coalesce(nullif(title,''), preview), last_user_input_time FROM conversation_summaries") { r in
                guard let id = r.text(0) else { return }
                if let w = r.text(1)?.data(using: .utf8),
                   let first = ((try? JSONSerialization.jsonObject(with: w)) as? [String])?.first,
                   let path = URL(string: first)?.path {
                    workspace[id] = path
                }
                if r.int(2) > 0 { nested.insert(id); return }
                c.session(id, cwd: workspace[id], title: r.text(3), start: parseISO8601(r.text(4)))
            }
        }
        for app in apps {
            let brain = gemini.appendingPathComponent("\(app)/brain")
            for id in (try? FileManager.default.contentsOfDirectory(atPath: brain.path)) ?? [] {
                let t = brain.appendingPathComponent("\(id)/.system_generated/logs/transcript.jsonl")
                guard FileManager.default.fileExists(atPath: t.path) else { continue }
                let isSub = nested.contains(id)
                var first: Double?
                forEachJSONLine(ofFile: t) { d in
                    let time = anyTime(d["created_at"])
                    if first == nil { first = time }
                    switch d["type"] as? String {
                    case "USER_INPUT":
                        if !isSub, d["source"] as? String == "USER_EXPLICIT" {
                            c.session(id, cwd: workspace[id])
                            c.prompt(id, time, d["content"] as? String ?? "", id: "\(id)#\(d["step_index"] ?? "")")
                        }
                    case "PLANNER_RESPONSE":
                        for call in d["tool_calls"] as? [[String: Any]] ?? [] { c.tool(call["name"] as? String, time) }
                    default: break
                    }
                }
                if isSub { c.tool("子任务 agent", first, kind: .subagent) }
            }
        }
        return c.result
    }
}

// MARK: - Cursor (IDE chats in state.vscdb + cursor-agent CLI transcripts)

enum CursorScanner {
    static func scan() -> ScanResult {
        let c = Collector(.cursor)
        let user = appSupport.appendingPathComponent("Cursor/User")

        // Which workspace folder each composer belongs to.
        var folder: [String: String] = [:]
        let wsRoot = user.appendingPathComponent("workspaceStorage")
        for ws in (try? FileManager.default.contentsOfDirectory(at: wsRoot, includingPropertiesForKeys: nil)) ?? [] {
            guard let wdata = try? Data(contentsOf: ws.appendingPathComponent("workspace.json")),
                  let wj = (try? JSONSerialization.jsonObject(with: wdata)) as? [String: Any],
                  let f = wj["folder"] as? String, let path = URL(string: f)?.path,
                  let db = ReadOnlyDB(ws.appendingPathComponent("state.vscdb").path) else { continue }
            db.rows("SELECT value FROM ItemTable WHERE key = 'composer.composerData'") { r in
                for comp in r.json(0)?["allComposers"] as? [[String: Any]] ?? [] {
                    if let id = comp["composerId"] as? String { folder[id] = path }
                }
            }
        }

        var composerModel: [String: String] = [:]
        var composerCreated: [String: Double] = [:]
        if let db = ReadOnlyDB(user.appendingPathComponent("globalStorage/state.vscdb").path) {
            db.rows("""
                SELECT key, json_extract(value,'$.name'), json_extract(value,'$.createdAt'),
                       json_extract(value,'$.modelConfig.modelName')
                FROM cursorDiskKV WHERE key LIKE 'composerData:%' AND json_valid(value)
                """) { r in
                guard let key = r.text(0) else { return }
                let id = String(key.dropFirst("composerData:".count))
                composerModel[id] = r.text(3).flatMap { $0 == "default" ? nil : $0 }
                composerCreated[id] = anyTime(NSNumber(value: r.int(2)))
                c.session(id, cwd: folder[id], title: r.text(1))
            }
            db.rows("""
                SELECT key, json_extract(value,'$.type'), substr(json_extract(value,'$.text'),1,4000),
                       json_extract(value,'$.createdAt'), json_extract(value,'$.tokenCount.inputTokens'),
                       json_extract(value,'$.tokenCount.outputTokens'), json_extract(value,'$.toolFormerData.name'),
                       json_extract(value,'$.modelInfo.modelName')
                FROM cursorDiskKV WHERE key LIKE 'bubbleId:%' AND json_valid(value)
                """) { r in
                guard let parts = r.text(0)?.split(separator: ":"), parts.count >= 3 else { return }
                let composer = String(parts[1]), bubble = String(parts[2])
                let time = anyTime(r.text(3)) ?? composerCreated[composer]
                if r.int(1) == 1 {
                    c.prompt(composer, time, r.text(2) ?? "", id: bubble)
                } else {
                    let model = r.text(7).flatMap { $0 == "default" ? nil : $0 } ?? composerModel[composer] ?? "Cursor Auto"
                    c.usage(composer, time, model: model, TokenCounts(input: r.int(4), output: r.int(5)), id: bubble)
                    c.tool(r.text(6), time, id: bubble)
                }
            }
        }

        // Agent transcripts mirror IDE composers (which carry real timestamps), and the same one is
        // written under every project it touched; only read conversations the IDE doesn't have.
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "EEEE, MMM d, yyyy, h:mm a"
        let projects = home.appendingPathComponent(".cursor/projects")
        for file in files(under: projects, where: { $0.pathExtension == "jsonl" && $0.path.contains("/agent-transcripts/") }) {
            let id = file.deletingPathExtension().lastPathComponent
            if composerCreated[id] != nil { continue }
            let projectDir = file.pathComponents.drop { $0 != "projects" }.dropFirst().first ?? ""
            let cwd = "/" + projectDir.replacingOccurrences(of: "-", with: "/")
            var time = modificationTime(file)
            var index = 0
            forEachJSONLine(ofFile: file) { d in
                let content = d.at("message.content")
                if d["role"] as? String == "user" {
                    let text = plainText(content)
                    if let open = text.range(of: "<timestamp>"), let close = text.range(of: "</timestamp>") {
                        var s = String(text[open.upperBound..<close.lowerBound])
                        var tz = TimeZone.current
                        if let paren = s.range(of: " (UTC") {
                            let offset = s[paren.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: ")"))
                            if let hours = Int(offset.replacingOccurrences(of: "+", with: "")) {
                                tz = TimeZone(secondsFromGMT: hours * 3600) ?? tz
                            }
                            s = String(s[..<paren.lowerBound])
                        }
                        stamp.timeZone = tz
                        if let date = stamp.date(from: s) { time = date.timeIntervalSince1970 }
                    }
                    c.session(id, cwd: projectDir == "empty-window" ? nil : cwd)
                    c.prompt(id, time, text, id: "\(id)#\(index)")
                    index += 1
                } else {
                    for b in content as? [[String: Any]] ?? [] where b["type"] as? String == "tool_use" {
                        c.tool(b["name"] as? String, time)
                    }
                }
            }
        }
        return c.result
    }
}

// MARK: - DeepSeek Harness (~/.dsh/sessions/**/session*.jsonl.zstd)

enum DSHScanner {
    static func scan() -> ScanResult {
        let c = Collector(.dsh)
        let root = home.appendingPathComponent(".dsh/sessions")
        let all = files(under: root) { $0.lastPathComponent.hasPrefix("session") && ($0.path.hasSuffix(".jsonl") || $0.path.hasSuffix(".jsonl.zstd")) }
        let paths = Set(all.map(\.path))
        for file in all {
            // A session upgraded in place keeps the old log next to the `.v4` one; read only one.
            if file.lastPathComponent.contains(".v4."),
               paths.contains(file.path.replacingOccurrences(of: ".v4.", with: ".")) { continue }
            let data = file.pathExtension == "zstd" ? zstdDecompress(file) : try? Data(contentsOf: file)
            guard let data else { continue }
            var session = file.deletingLastPathComponent().lastPathComponent
            var model: String?
            var depth = 0
            var first: Double?
            forEachJSONLine(data) { d in
                let time = anyTime(d["time"] ?? d["time0"])
                if first == nil { first = time }
                let body = d["data"] as? [String: Any]
                switch d["type"] as? String {
                case "session":
                    if let id = d["id"] as? String { session = id }
                    depth = (d["delegationDepth"] as? NSNumber)?.intValue ?? 0
                    c.session(session, cwd: d["cwd"] as? String)
                case "session/title":
                    c.session(session, title: body?["title"] as? String)
                case "request/context":
                    model = body?["model"] as? String ?? model
                case "request/header":
                    model = body?.str("header.config.model") ?? model
                case "user/message":
                    if depth == 0, body?.str("source.kind") == "user" {
                        c.prompt(session, time, plainText(body?["content"]), id: body?["id"] as? String)
                    }
                case "tool/call":
                    c.tool(body?["name"] as? String, time, id: body?["callId"] as? String)
                default: break
                }
                if let u = (body?["usage"] as? [String: Any]) ?? body?.dict("message.usage") {
                    c.usage(session, time, model: model, normalizeUsage(u), id: "\(session)#\(d["seq"] ?? d["seq0"] ?? "")")
                }
            }
            if depth > 0 { c.tool("子任务 agent", first, kind: .subagent) }
        }
        return c.result
    }
}

// MARK: - Agent Cowork (Claude Agent SDK desktop app)

enum CoworkScanner {
    static func scan() -> ScanResult {
        let c = Collector(.cowork)
        guard let db = ReadOnlyDB(appSupport.appendingPathComponent("agent-cowork/sessions.db").path) else { return c.result }
        var model: [String: String] = [:]
        db.rows("SELECT session_id, data, created_at FROM messages ORDER BY created_at") { r in
            guard let s = r.text(0), let d = r.json(1) else { return }
            let time = anyTime(NSNumber(value: r.int(2)))
            switch d["type"] as? String {
            case "user_prompt":
                c.prompt(s, time, d["prompt"] as? String ?? "")
            case "system":
                if d["subtype"] as? String == "init" {
                    c.session(s, cwd: d["cwd"] as? String)
                    model[s] = d["model"] as? String
                }
            case "result":
                // The run summary carries the run's total usage; per-message usage is only in stream deltas.
                if let u = d["usage"] as? [String: Any] {
                    c.usage(s, time, model: model[s], normalizeUsage(u), id: d["uuid"] as? String)
                }
            default: break
            }
        }
        return c.result
    }
}

// MARK: - Small local chat apps

enum SmallAppScanners {
    static func copilot() -> ScanResult {
        let c = Collector(.copilot)
        guard let db = ReadOnlyDB(home.appendingPathComponent(".copilot/session-store.db").path) else { return c.result }
        db.rows("SELECT id, cwd, summary FROM sessions") { r in
            if let id = r.text(0) { c.session(id, cwd: r.text(1) == "/" ? nil : r.text(1), title: r.text(2)) }
        }
        db.rows("SELECT session_id, user_message, timestamp, id FROM turns") { r in
            if let s = r.text(0) { c.prompt(s, anyTime(r.text(2)), r.text(1) ?? "", id: "turn-\(r.int(3))") }
        }
        return c.result
    }

    static func ollama() -> ScanResult {
        let c = Collector(.ollama)
        guard let db = ReadOnlyDB(appSupport.appendingPathComponent("Ollama/db.sqlite").path) else { return c.result }
        if db.columns("chats").contains("title") {
            db.rows("SELECT id, title FROM chats") { r in if let id = r.text(0) { c.session(id, title: r.text(1)) } }
        }
        db.rows("SELECT chat_id, role, content, created_at, id FROM messages") { r in
            guard let chat = r.text(0), r.text(1) == "user" else { return }
            c.prompt(chat, anyTime(r.text(3)) ?? anyTime(NSNumber(value: r.int(3))), r.text(2) ?? "", id: r.text(4))
        }
        return c.result
    }

    static func chatwise() -> ScanResult {
        let c = Collector(.chatwise)
        guard let db = ReadOnlyDB(appSupport.appendingPathComponent("app.chatwise/app.db").path) else { return c.result }
        db.rows("SELECT chatId, role, content, createdAt, id FROM message") { r in
            guard let chat = r.text(0), r.text(1) == "user" else { return }
            c.prompt(chat, anyTime(NSNumber(value: r.int(3))), r.text(2) ?? "", id: r.text(4))
        }
        return c.result
    }

    /// Zed stores thread bodies zstd-compressed; the index rows are enough to count conversations.
    static func zed() -> ScanResult {
        let c = Collector(.zed)
        guard let db = ReadOnlyDB(appSupport.appendingPathComponent("Zed/threads/threads.db").path) else { return c.result }
        let hasFolders = db.columns("threads").contains("folder_paths")
        db.rows("SELECT id, summary, created_at, \(hasFolders ? "folder_paths" : "NULL"), parent_id FROM threads") { r in
            guard let id = r.text(0), r.isNull(4) else { return }
            let folder = r.text(3)?.split(whereSeparator: { $0 == "\n" || $0 == "," })
                .first.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "[]\" ")) }
            c.session(id, cwd: folder, title: r.text(1), start: parseISO8601(r.text(2)))
        }
        return c.result
    }
}
