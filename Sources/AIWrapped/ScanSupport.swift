import Foundation
import SQLite3

// MARK: - Fast line + byte helpers

struct BytePattern {
    let bytes: [UInt8]
    init(_ s: String) { bytes = Array(s.utf8) }

    @inline(__always)
    func occurs(in line: UnsafeRawBufferPointer) -> Bool {
        guard let base = line.baseAddress, line.count >= bytes.count else { return false }
        return bytes.withUnsafeBytes { p in
            memmem(base, line.count, p.baseAddress!, p.count) != nil
        }
    }
}

/// Calls `body` with each newline-delimited line of a (memory-mapped) file.
func forEachLine(ofFile url: URL, _ body: (UnsafeRawBufferPointer) -> Void) {
    guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return }
    data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
        guard let base = buf.baseAddress else { return }
        let n = buf.count
        var start = 0
        while start < n {
            let end: Int
            if let nl = memchr(base + start, 0x0A, n - start) {
                end = UnsafeRawPointer(nl) - base
            } else {
                end = n
            }
            if end > start {
                body(UnsafeRawBufferPointer(start: base + start, count: end - start))
            }
            start = end + 1
        }
    }
}

@inline(__always)
func parseJSONObject(_ line: UnsafeRawBufferPointer) -> [String: Any]? {
    guard let base = line.baseAddress else { return nil }
    let data = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: base), count: line.count, deallocator: .none)
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

@inline(__always)
func i64(_ v: Any?) -> Int64 { (v as? NSNumber)?.int64Value ?? 0 }

// MARK: - Timestamps

/// Parses "2026-10-21T03:06:10.587Z" (or with a ±hh:mm offset) into epoch seconds
/// without going through a DateFormatter — this runs hundreds of thousands of times.
func parseISO8601(_ s: String?) -> Double? {
    guard let s else { return nil }
    let u = Array(s.utf8)
    guard u.count >= 19 else { return nil }
    func num(_ a: Int, _ b: Int) -> Int {
        var v = 0
        for i in a..<b { v = v * 10 + Int(u[i] &- 48) }
        return v
    }
    let y = num(0, 4), mo = num(5, 7), d = num(8, 10)
    let h = num(11, 13), mi = num(14, 16), se = num(17, 19)
    var i = 19
    var frac = 0.0
    if i < u.count, u[i] == 46 { // "."
        var scale = 0.1
        i += 1
        while i < u.count, u[i] >= 48, u[i] <= 57 {
            frac += Double(u[i] - 48) * scale
            scale *= 0.1
            i += 1
        }
    }
    var offset = 0
    if i + 5 < u.count, u[i] == 43 || u[i] == 45 { // "+hh:mm" / "-hh:mm"
        let sign = u[i] == 43 ? 1 : -1
        let oh = num(i + 1, i + 3), om = num(i + 4, i + 6)
        offset = sign * (oh * 3600 + om * 60)
    }
    // days-from-civil (Howard Hinnant)
    let yy = mo <= 2 ? y - 1 : y
    let era = (yy >= 0 ? yy : yy - 399) / 400
    let yoe = yy - era * 400
    let mp = (mo + 9) % 12
    let doy = (153 * mp + 2) / 5 + d - 1
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
    let days = era * 146097 + doe - 719468
    return Double(days * 86400 + h * 3600 + mi * 60 + se - offset) + frac
}

// MARK: - Naming

func projectName(fromCwd cwd: String?) -> String {
    guard let cwd, !cwd.isEmpty else { return "未知目录" }
    if cwd.contains("/scratch-workspaces/") { return "临时会话" }
    let home = NSHomeDirectory()
    if cwd == home || cwd == home + "/" { return "主目录 ~" }
    let last = URL(fileURLWithPath: cwd).lastPathComponent
    if last == "new-chat" || last.hasPrefix("new-chat-") { return "临时会话" }
    return last
}

/// "claude-opus-5-5" → "Claude Opus 5.5", "auto/gpt-6-astra" → "GPT-6 Astra".
func prettyModelName(_ raw: String) -> String {
    var s = raw
    if let slash = s.lastIndex(of: "/") { s = String(s[s.index(after: slash)...]) }
    if let at = s.firstIndex(of: "@") { s = String(s[..<at]) }
    if s.isEmpty || s == "unknown" { return "未知模型" }
    let parts = s.split(whereSeparator: { $0 == "-" || $0 == "_" }).map(String.init)
    var out: [String] = []
    var numberRun: [String] = []
    func flush() {
        if !numberRun.isEmpty { out.append(numberRun.joined(separator: ".")); numberRun = [] }
    }
    for p in parts {
        let isDate = p.count >= 6 && p.allSatisfy(\.isNumber)
        if isDate { continue }
        if p.first?.isNumber == true && p.allSatisfy({ $0.isNumber || $0 == "." }) {
            numberRun.append(p)
            continue
        }
        flush()
        switch p.lowercased() {
        case "gpt": out.append("GPT")
        case "glm": out.append("GLM")
        case "kimi": out.append("Kimi")
        case "deepseek": out.append("DeepSeek")
        case "qwen": out.append("Qwen")
        default: out.append(p.prefix(1).uppercased() + p.dropFirst())
        }
    }
    flush()
    if out.first == "GPT" || out.first == "GLM", out.count > 1 {
        out[0] = out[0] + "-" + out[1]
        out.remove(at: 1)
    }
    return out.joined(separator: " ")
}

func cleanPromptText(_ text: String) -> String {
    var t = text
    // Some agents wrap what the user typed in a tag; keep only the inside.
    for tag in ["user_query", "USER_REQUEST", "user_request"] {
        if let open = t.range(of: "<\(tag)>"), let close = t.range(of: "</\(tag)>", range: open.upperBound..<t.endIndex) {
            t = String(t[open.upperBound..<close.lowerBound])
        }
    }
    if let open = t.range(of: "<timestamp>"), let close = t.range(of: "</timestamp>", range: open.upperBound..<t.endIndex) {
        t.removeSubrange(open.lowerBound..<close.upperBound)
    }
    // Drop pasted blocks and inline reminders from previews; they aren't what the user typed.
    for tag in ["pasted_content", "system-reminder"] {
        while let open = t.range(of: "<\(tag)"),
              let close = t.range(of: "</\(tag)>", range: open.upperBound..<t.endIndex) {
            t.replaceSubrange(open.lowerBound..<close.upperBound, with: " ")
        }
    }
    return t.replacingOccurrences(of: "\n", with: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

let automatedPromptPrefixes = [
    "<system-reminder", "<local-command", "Caveat:", "[Request interrupted",
    "<task-notification", "<side-sessions-event", "<ci-monitor-event",
    "This session is being continued", "<environment_context", "<user_instructions",
    "# AGENTS.md", "<turn_aborted", "[AGENT SYSTEM PROMPT]", "<system_reminder", "<environment_details",
    "The TodoWrite tool hasn't been used",
]

func isAutomatedPrompt(_ t: String) -> Bool {
    automatedPromptPrefixes.contains { t.hasPrefix($0) }
}

func fileSize(_ url: URL) -> Int64 {
    Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
}

func jsonlFiles(under root: URL) -> [URL] {
    guard let e = FileManager.default.enumerator(
        at: root, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
        options: [.skipsHiddenFiles]
    ) else { return [] }
    var out: [URL] = []
    for case let url as URL in e where url.pathExtension == "jsonl" {
        out.append(url)
    }
    return out
}

let home = URL(fileURLWithPath: NSHomeDirectory())

// MARK: - Shared helpers for the many agent formats

/// Normalizes any of the usage shapes agents write (Anthropic, OpenAI, Grok, Pi, Kiro…) into
/// `TokenCounts`. Some formats fold cache reads into `input`; when a total is present we pick
/// whichever interpretation adds up to it, otherwise we go by the key family.
func normalizeUsage(_ u: [String: Any]) -> TokenCounts? {
    func pick(_ keys: [String]) -> Int64? {
        for k in keys { if let v = u[k] as? NSNumber { return v.int64Value } }
        return nil
    }
    let input = pick(["input_tokens", "inputTokens", "prompt_tokens", "promptTokens", "input", "tokensIn",
                      "input_token_count", "inputTokenCount", "promptTokenCount"]) ?? 0
    var output = pick(["output_tokens", "outputTokens", "completion_tokens", "completionTokens", "output", "tokensOut",
                       "output_token_count", "outputTokenCount", "candidatesTokenCount"]) ?? 0
    var cacheRead = pick(["cache_read_input_tokens", "cachedReadTokens", "cacheReadTokens", "cacheRead", "cache_read",
                          "cached_input_tokens", "cachedTokens", "cached_tokens", "cacheReads",
                          "cache_read_input_token_count", "cachedContentTokenCount"]) ?? 0
    var nestedCache = false
    if cacheRead == 0 {
        for key in ["prompt_tokens_details", "input_tokens_details"] {
            if let d = u[key] as? [String: Any], let c = d["cached_tokens"] as? NSNumber {
                cacheRead = c.int64Value
                nestedCache = true
            }
        }
    }
    let cacheWrite = pick(["cache_creation_input_tokens", "cacheCreationTokens", "cacheWriteTokens", "cacheWrite",
                           "cache_write", "cache_creation_tokens", "cacheWrites", "cache_write_input_token_count"]) ?? 0
    var reasoning = pick(["reasoning_tokens", "reasoningTokens", "reasoning", "thoughtsTokenCount"]) ?? 0
    if reasoning == 0, let d = u["completion_tokens_details"] as? [String: Any], let r = d["reasoning_tokens"] as? NSNumber {
        reasoning = r.int64Value
    }
    guard input + output + cacheRead + cacheWrite > 0 else { return nil }

    var folded: Bool
    var addReasoning = false
    if let total = pick(["total_tokens", "totalTokens", "total", "totalTokenCount"]), total > 0 {
        let separate = input + output + cacheRead + cacheWrite
        let candidates: [(Int64, Bool, Bool)] = [
            (separate, false, false), (input + output, true, false),
            (separate + reasoning, false, true), (input + output + reasoning, true, true),
        ]
        let best = candidates.min { abs(total - $0.0) < abs(total - $1.0) }!
        folded = best.1 && cacheRead + cacheWrite > 0
        addReasoning = best.2 && reasoning > 0
    } else {
        folded = nestedCache || u["prompt_tokens"] != nil || u["cached_input_tokens"] != nil
    }
    if addReasoning { output += reasoning }
    let uncached = folded ? max(0, input - cacheRead - cacheWrite) : input
    return TokenCounts(input: uncached, output: output, cacheRead: cacheRead, cacheWrite: cacheWrite)
}

/// ISO-8601 strings, or epoch seconds / milliseconds as numbers or strings.
func anyTime(_ v: Any?) -> Double? {
    func epoch(_ d: Double) -> Double? {
        if d > 1e14 { return d / 1e6 }   // microseconds
        if d > 1e11 { return d / 1000 }
        return d > 1e9 ? d : nil
    }
    if let n = v as? NSNumber { return epoch(n.doubleValue) }
    if let s = v as? String {
        if let d = Double(s) { return epoch(d) }
        return parseISO8601(s)
    }
    return nil
}

func stripReminderBlocks(_ text: String) -> String {
    var t = text
    while let open = t.range(of: "<system-reminder"),
          let close = t.range(of: "</system-reminder>", range: open.upperBound..<t.endIndex) {
        t.removeSubrange(open.lowerBound..<close.upperBound)
    }
    return t.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Text of a message's content: a string, or the text blocks of a block array.
func plainText(_ content: Any?, skipAutomated: Bool = true) -> String {
    if let s = content as? String { return stripReminderBlocks(s) }
    if let d = content as? [String: Any] { return (d["text"] as? String) ?? "" }
    guard let blocks = content as? [Any] else { return "" }
    return blocks.compactMap { item -> String? in
        if let s = item as? String { return s }
        guard let b = item as? [String: Any] else { return nil }
        let type = (b["type"] ?? b["kind"]) as? String
        guard type == nil || ["text", "input_text", "output_text"].contains(type!) else { return nil }
        // Several agents put injected context and the user's words in one block.
        let text = stripReminderBlocks((b["text"] ?? b["data"]) as? String ?? "")
        return text.isEmpty || (skipAutomated && isAutomatedPrompt(text)) ? nil : text
    }.joined(separator: "\n")
}

/// Accumulates one agent's records, namespacing session keys and de-duplicating by id.
final class Collector {
    let agent: AgentKind
    private(set) var result = ScanResult()
    private var seenPrompts = Set<String>()
    private var usageByID: [String: Int] = [:]
    private var seenTools = Set<String>()

    init(_ agent: AgentKind) { self.agent = agent }

    func key(_ session: String) -> String { agent.id + ":" + session }

    func session(_ id: String, cwd: String? = nil, title: String? = nil, start: Double? = nil) {
        let k = key(id)
        var s = result.sessions[k] ?? SessionInfo(agent: agent, key: k, project: projectName(fromCwd: cwd), title: nil)
        if s.project == "未知目录", cwd != nil { s.project = projectName(fromCwd: cwd) }
        if let title, !title.isEmpty, s.title == nil { s.title = title }
        if let start, s.start == nil || start < s.start! { s.start = start }
        result.sessions[k] = s
    }

    func prompt(_ session: String, _ time: Double?, _ raw: String, id: String? = nil) {
        guard let time, time > 0 else { return }
        if let id, !seenPrompts.insert(id).inserted { return }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isAutomatedPrompt(trimmed) else { return }
        let clean = cleanPromptText(trimmed)
        guard !clean.isEmpty else { return }
        if result.sessions[key(session)] == nil { self.session(session) }
        result.prompts.append(PromptRecord(agent: agent, session: key(session), time: time,
                                           chars: clean.count, preview: String(clean.prefix(160))))
    }

    /// With an `id`, later records for the same id replace earlier ones when they are larger.
    func usage(_ session: String, _ time: Double?, model: String?, _ t: TokenCounts?, id: String? = nil) {
        guard let time, time > 0, let t, t.total > 0 else { return }
        let rec = UsageRecord(agent: agent, model: model ?? "unknown", time: time, tokens: t, session: key(session))
        if let id {
            if let i = usageByID[id] {
                if result.usage[i].tokens.total < t.total { result.usage[i] = rec }
                return
            }
            usageByID[id] = result.usage.count
        }
        result.usage.append(rec)
    }

    func tool(_ name: String?, _ time: Double?, kind: ToolKind = .tool, id: String? = nil) {
        guard let name, !name.isEmpty, let time, time > 0 else { return }
        if let id, !seenTools.insert(id).inserted { return }
        result.tools.append(ToolRecord(agent: agent, name: name, kind: kind, time: time))
    }
}

/// Read-only SQLite access that also works while the owning app holds the database open.
final class ReadOnlyDB {
    private var db: OpaquePointer?

    init?(_ path: String) {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        for mode in ["mode=ro", "immutable=1"] {
            var handle: OpaquePointer?
            if sqlite3_open_v2("file:\(encoded)?\(mode)", &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK {
                sqlite3_busy_timeout(handle, 1500)
                var probe: OpaquePointer?
                if sqlite3_prepare_v2(handle, "SELECT count(*) FROM sqlite_master", -1, &probe, nil) == SQLITE_OK,
                   sqlite3_step(probe) == SQLITE_ROW {
                    sqlite3_finalize(probe)
                    db = handle
                    return
                }
                sqlite3_finalize(probe)
            }
            sqlite3_close(handle)
        }
        return nil
    }

    deinit { sqlite3_close(db) }

    func rows(_ sql: String, _ row: (Row) -> Void) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW { row(Row(stmt: stmt)) }
    }

    func columns(_ table: String) -> Set<String> {
        var s = Set<String>()
        rows("PRAGMA table_info(\(table))") { r in if let n = r.text(1) { s.insert(n) } }
        return s
    }

    struct Row {
        let stmt: OpaquePointer
        func text(_ i: Int32) -> String? {
            guard let c = sqlite3_column_text(stmt, i) else { return nil }
            return String(cString: c)
        }
        func int(_ i: Int32) -> Int64 { sqlite3_column_int64(stmt, i) }
        func double(_ i: Int32) -> Double { sqlite3_column_double(stmt, i) }
        func isNull(_ i: Int32) -> Bool { sqlite3_column_type(stmt, i) == SQLITE_NULL }
        func json(_ i: Int32) -> [String: Any]? {
            guard let c = sqlite3_column_blob(stmt, i) else { return nil }
            let data = Data(bytes: c, count: Int(sqlite3_column_bytes(stmt, i)))
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        }
    }
}

/// Decompresses a .zstd file with the zstd CLI if it is installed (GUI apps lack Homebrew's PATH).
func zstdDecompress(_ url: URL) -> Data? {
    let candidates = ["/opt/homebrew/bin/zstd", "/usr/local/bin/zstd", "/usr/bin/zstd"]
    guard let tool = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return nil }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: tool)
    p.arguments = ["-dcq", url.path]
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return nil }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return p.terminationStatus == 0 ? data : nil
}

func forEachJSONLine(_ data: Data, _ body: ([String: Any]) -> Void) {
    data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
        guard let base = buf.baseAddress else { return }
        var start = 0
        while start < buf.count {
            let end = memchr(base + start, 0x0A, buf.count - start).map { UnsafeRawPointer($0) - base } ?? buf.count
            if end > start, let obj = parseJSONObject(UnsafeRawBufferPointer(start: base + start, count: end - start)) {
                body(obj)
            }
            start = end + 1
        }
    }
}

func forEachJSONLine(ofFile url: URL, _ body: ([String: Any]) -> Void) {
    forEachLine(ofFile: url) { line in
        if let obj = parseJSONObject(line) { body(obj) }
    }
}

func files(under root: URL, where match: (URL) -> Bool) -> [URL] {
    guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: []) else { return [] }
    var out: [URL] = []
    for case let url as URL in e where match(url) { out.append(url) }
    return out
}

func modificationTime(_ url: URL) -> Double? {
    (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?.timeIntervalSince1970
}

extension Dictionary where Key == String, Value == Any {
    /// Value at a dotted path such as "params.update.usage".
    func at(_ path: String) -> Any? {
        var cur: Any? = self
        for part in path.split(separator: ".") {
            cur = (cur as? [String: Any])?[String(part)]
        }
        return cur
    }
    func str(_ path: String) -> String? { at(path) as? String }
    func dict(_ path: String) -> [String: Any]? { at(path) as? [String: Any] }
}
