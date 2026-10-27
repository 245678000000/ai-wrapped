import Foundation

/// Reads Claude-Code-format transcripts: Claude Code itself (~/.claude/projects, CLI and the
/// desktop Code tab) and agents built on the same format (Qoder, Qoder CN, 千问办公).
///
/// Each streamed content block is written as its own line carrying the same message id
/// and usage, and forked/resumed sessions copy earlier lines into new files, so usage,
/// prompts and tool calls are all de-duplicated by id across every file.
struct ClaudeFormatScanner {
    let agent: AgentKind
    let roots: [URL]

    struct FileOut {
        var usage: [String: UsageRecord] = [:]
        var anonUsage: [UsageRecord] = []
        var prompts: [String: PromptRecord] = [:]
        var tools: [String: ToolRecord] = [:]
        var sessions: [String: SessionInfo] = [:]
    }

    static var claudeRoot: URL {
        if let dir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] {
            return URL(fileURLWithPath: dir).appendingPathComponent("projects")
        }
        return home.appendingPathComponent(".claude/projects")
    }

    static let claudeCode = ClaudeFormatScanner(agent: .claudeCode, roots: [claudeRoot])
    static let qoderCN = ClaudeFormatScanner(agent: .qoderCN, roots: [home.appendingPathComponent(".qoder-cn/projects")])
    static let qoder = ClaudeFormatScanner(agent: .qoder, roots: [home.appendingPathComponent(".qoder/projects")])
    // 千问办公 migrated from QoderWork CN and kept the old folder; ids overlap and de-duplicate.
    static let qwenWork = ClaudeFormatScanner(agent: .qwenWork, roots: [
        home.appendingPathComponent(".qwenworkcn/projects"), home.appendingPathComponent(".qoderworkcn/projects"),
    ])
    static let all: [ClaudeFormatScanner] = [.claudeCode, .qoderCN, .qoder, .qwenWork]

    func files() -> [URL] { roots.flatMap { jsonlFiles(under: $0) } }

    private static let pAssistant = BytePattern("\"type\":\"assistant\"")
    private static let pUser = BytePattern("\"type\":\"user\"")
    private static let pToolResult = BytePattern("\"toolUseResult\"")
    private static let pTitle = BytePattern("\"type\":\"custom-title\"")

    func scan(_ url: URL) -> FileOut {
        var out = FileOut()
        let fallbackSession = url.deletingPathExtension().lastPathComponent

        func ensureSession(_ key: String, cwd: String?) {
            if out.sessions[key] == nil {
                out.sessions[key] = SessionInfo(agent: agent, key: key,
                                                project: projectName(fromCwd: cwd), title: nil)
            } else if cwd != nil, out.sessions[key]?.project == "未知目录" {
                out.sessions[key]?.project = projectName(fromCwd: cwd)
            }
        }

        forEachLine(ofFile: url) { line in
            let isAssistant = Self.pAssistant.occurs(in: line)
            let isUser = !isAssistant && Self.pUser.occurs(in: line) && !Self.pToolResult.occurs(in: line)
            let isTitle = !isAssistant && !isUser && Self.pTitle.occurs(in: line)
            guard isAssistant || isUser || isTitle, let obj = parseJSONObject(line) else { return }

            let session = obj["sessionId"] as? String ?? fallbackSession
            let key = agent.id + ":" + session
            let type = obj["type"] as? String

            if type == "custom-title" {
                if let title = obj["customTitle"] as? String, !title.isEmpty {
                    ensureSession(key, cwd: nil)
                    out.sessions[key]?.title = title
                }
                return
            }

            let time = parseISO8601(obj["timestamp"] as? String) ?? 0
            guard time > 0, let msg = obj["message"] as? [String: Any] else { return }
            ensureSession(key, cwd: obj["cwd"] as? String)

            if type == "assistant" {
                let model = msg["model"] as? String ?? "unknown"
                if model != "<synthetic>", let u = msg["usage"] as? [String: Any] {
                    let t = TokenCounts(
                        input: i64(u["input_tokens"]),
                        output: i64(u["output_tokens"]),
                        cacheRead: i64(u["cache_read_input_tokens"]),
                        cacheWrite: i64(u["cache_creation_input_tokens"])
                    )
                    let rec = UsageRecord(agent: agent, model: model, time: time, tokens: t, session: key)
                    if let id = msg["id"] as? String {
                        if let old = out.usage[id], old.tokens.total >= t.total {} else { out.usage[id] = rec }
                    } else {
                        out.anonUsage.append(rec)
                    }
                }
                if let content = msg["content"] as? [[String: Any]] {
                    for block in content where block["type"] as? String == "tool_use" {
                        guard let name = block["name"] as? String else { continue }
                        let id = block["id"] as? String ?? UUID().uuidString
                        let input = block["input"] as? [String: Any]
                        out.tools[id] = ToolRecord(agent: agent, name: name, kind: .tool, time: time)
                        if name == "Skill", let skill = input?["skill"] as? String {
                            out.tools[id + "#skill"] = ToolRecord(agent: agent, name: skill, kind: .skill, time: time)
                        }
                        if name == "Agent" || name == "Task" {
                            let sub = input?["subagent_type"] as? String ?? "general-purpose"
                            out.tools[id + "#agent"] = ToolRecord(agent: agent, name: sub, kind: .subagent, time: time)
                        }
                    }
                }
                return
            }

            // A prompt the user actually typed: main chain only, not tool results or harness notes.
            guard type == "user",
                  obj["isSidechain"] as? Bool != true,
                  obj["isMeta"] as? Bool != true,
                  obj["isCompactSummary"] as? Bool != true else { return }

            var texts: [String] = []
            var hasImage = false
            var hasToolResult = false
            if let s = msg["content"] as? String {
                texts = [s]
            } else if let blocks = msg["content"] as? [[String: Any]] {
                for b in blocks {
                    switch b["type"] as? String {
                    case "text": if let t = b["text"] as? String { texts.append(t) }
                    case "image": hasImage = true
                    case "tool_result": hasToolResult = true
                    default: break
                    }
                }
            }
            let parts = texts
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && !isAutomatedPrompt($0) }
            guard !parts.isEmpty || (hasImage && !hasToolResult) else { return }

            var text = parts.joined(separator: "\n")
            if text.hasPrefix("<command-name>"),
               let end = text.range(of: "</command-name>") {
                text = String(text[text.index(text.startIndex, offsetBy: 14)..<end.lowerBound])
            }
            let clean = cleanPromptText(text)
            let uuid = obj["uuid"] as? String ?? UUID().uuidString
            out.prompts[uuid] = PromptRecord(
                agent: agent, session: key, time: time,
                chars: clean.count, preview: String(clean.prefix(160))
            )
        }
        return out
    }

    func merge(_ outs: [FileOut]) -> ScanResult {
        var usage: [String: UsageRecord] = [:]
        var prompts: [String: PromptRecord] = [:]
        var tools: [String: ToolRecord] = [:]
        var result = ScanResult()
        for o in outs {
            for (k, v) in o.usage {
                if let old = usage[k], old.tokens.total >= v.tokens.total { continue }
                usage[k] = v
            }
            result.usage += o.anonUsage
            prompts.merge(o.prompts) { a, _ in a }
            tools.merge(o.tools) { a, _ in a }
            for (k, v) in o.sessions {
                if var existing = result.sessions[k] {
                    if existing.title == nil { existing.title = v.title }
                    if existing.project == "未知目录" { existing.project = v.project }
                    result.sessions[k] = existing
                } else {
                    result.sessions[k] = v
                }
            }
        }
        result.usage += usage.values
        result.prompts = Array(prompts.values)
        result.tools = Array(tools.values)
        return result
    }
}
