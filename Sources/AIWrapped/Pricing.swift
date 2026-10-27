import Foundation

/// Official API list prices in USD per million tokens (standard tier, short context, checked
/// October 2026), used to put a dollar figure next to the token counts. Matched by model family
/// on the display name; models without a public price get a mid-range default.
struct ModelPrice {
    let input: Double
    let cacheRead: Double
    let cacheWrite: Double
    let output: Double

    /// `write` defaults to 1.25× input: Anthropic's 5-minute cache write and OpenAI's cache write.
    init(_ input: Double, read: Double, write: Double? = nil, _ output: Double) {
        self.input = input
        self.cacheRead = read
        self.cacheWrite = write ?? input * 1.25
        self.output = output
    }

    /// Providers without a cache-write premium bill those tokens as plain input.
    static func flat(_ input: Double, read: Double, _ output: Double) -> ModelPrice {
        ModelPrice(input, read: read, write: input, output)
    }

    func cost(_ t: TokenCounts) -> CostBreakdown {
        CostBreakdown(input: Double(t.input) * input / 1e6,
                      output: Double(t.output) * output / 1e6,
                      cacheRead: Double(t.cacheRead) * cacheRead / 1e6,
                      cacheWrite: Double(t.cacheWrite) * cacheWrite / 1e6,
                      cacheSavings: Double(t.cacheRead) * max(0, input - cacheRead) / 1e6)
    }

    static func of(_ name: String) -> ModelPrice {
        let n = name.lowercased()
        let v = version(n)
        func has(_ s: String) -> Bool { n.contains(s) }

        if has("fable") || has("mythos") { return ModelPrice(10, read: v >= 5.1 ? 0.25 : 1, 50) }
        if has("opus") { return v >= 5.5 ? ModelPrice(4, read: 0.2, 20) : v >= 4.5 ? ModelPrice(5, read: 0.5, 25) : ModelPrice(15, read: 1.5, 75) }
        if has("sonnet") { return v >= 5 ? ModelPrice(2, read: 0.2, 10) : ModelPrice(3, read: 0.3, 15) }
        if has("haiku") { return v >= 5 ? ModelPrice(0.1, read: 0.01, 0.5) : v >= 4.5 ? ModelPrice(1, read: 0.1, 5) : ModelPrice(0.8, read: 0.08, 4) }
        if has("claude") { return ModelPrice(3, read: 0.3, 15) }

        if has("grok") {
            let base = v >= 4.6 ? flat(2, read: 0.5, 6) : v >= 4.5 ? flat(2, read: 0.3, 6) : flat(1.25, read: 0.2, 2.5)
            // Grok Fast (Cursor and Grok Build only) is the same model at twice the rates.
            return has("fast") ? flat(base.input * 2, read: base.cacheRead * 2, base.output * 2) : base
        }
        if has("gpt") || has("codex") {
            if has("astra") { return ModelPrice(10, read: 1, 50) }
            if has("luna") { return ModelPrice(0.1, read: 0.01, 0.5) }
            if has("terra") { return v >= 6 ? ModelPrice(1, read: 0.05, 5) : ModelPrice(2, read: 0.2, 12) }
            if v >= 6.1 { return ModelPrice(2, read: 0.1, 10) }
            if v >= 6 || v == 0 { return ModelPrice(2, read: 0.2, 10) }
            if v >= 5.6 { return ModelPrice(4, read: 0.4, 20) }
            if v >= 5.5 { return ModelPrice(5, read: 0.5, 30) }
            return v >= 5 ? ModelPrice(1.25, read: 0.125, 10) : ModelPrice(2, read: 0.5, 8)
        }
        if has("glm") {
            if has("flashx") { return flat(0.37, read: 0.075, 1.25) }
            return has("flash") ? flat(0.15, read: 0.03, 0.5) : flat(1.4, read: 0.26, 4.4)
        }
        if has("deepseek") { return has("pro") ? flat(0.66, read: 0.022, 1.98) : flat(0.22, read: 0.007, 0.66) }
        if has("mimo") { return has("pro") || has(" x ") ? flat(0.435, read: 0.0036, 0.87) : flat(0.14, read: 0.0028, 0.28) }
        if has("gemini") {
            if has("pro") { return flat(2, read: 0.2, 12) }
            return has("lite") ? flat(0.25, read: 0.025, 1.5) : flat(0.5, read: 0.05, 3)
        }
        if has("minimax") { return ModelPrice(0.3, read: 0.03, 1.2) }
        if has("kimi") { return flat(0.6, read: 0.15, 2.5) }
        if has("cursor") { return flat(1.25, read: 0.25, 6) }
        return ModelPrice(1, read: 0.1, 4)
    }

    /// The first version number in a display name: "GPT-6.1 Sol" → 6.1, "Claude 4.5 Opus" → 4.5.
    private static func version(_ name: String) -> Double {
        guard let r = name.range(of: #"\d+(\.\d+)?"#, options: .regularExpression) else { return 0 }
        return Double(name[r]) ?? 0
    }
}

/// Estimated USD spend, split the same way as `TokenCounts`.
struct CostBreakdown {
    var input = 0.0
    var output = 0.0
    var cacheRead = 0.0
    var cacheWrite = 0.0
    /// What the cache reads would have cost more as plain input.
    var cacheSavings = 0.0

    var total: Double { input + output + cacheRead + cacheWrite }

    /// Keeps the split but matches a cost the agent recorded itself.
    mutating func scale(to recorded: Double) {
        let k = total > 0 ? recorded / total : 0
        input *= k; output *= k; cacheRead *= k; cacheWrite *= k; cacheSavings *= k
    }

    static func += (l: inout CostBreakdown, r: CostBreakdown) {
        l.input += r.input
        l.output += r.output
        l.cacheRead += r.cacheRead
        l.cacheWrite += r.cacheWrite
        l.cacheSavings += r.cacheSavings
    }
}
