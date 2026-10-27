//! Official API list prices in USD per million tokens (standard tier, short context, checked
//! October 2026), used to put a dollar figure next to the token counts. Matched by model family
//! on the display name, the same rules as the macOS app; models without a public price get a
//! mid-range default.

use crate::model::Tokens;
use serde::Serialize;

#[derive(Clone, Copy)]
pub struct ModelPrice {
    input: f64,
    cache_read: f64,
    cache_write: f64,
    output: f64,
}

/// Cache writes at 1.25× input: Anthropic's 5-minute cache write and OpenAI's cache write.
fn p(input: f64, read: f64, output: f64) -> ModelPrice {
    ModelPrice { input, cache_read: read, cache_write: input * 1.25, output }
}

/// Providers without a cache-write premium bill those tokens as plain input.
fn flat(input: f64, read: f64, output: f64) -> ModelPrice {
    ModelPrice { input, cache_read: read, cache_write: input, output }
}

/// Estimated USD spend, split the same way as `Tokens`.
#[derive(Serialize, Clone, Copy, Default)]
#[serde(rename_all = "camelCase")]
pub struct Cost {
    pub input: f64,
    pub output: f64,
    pub cache_read: f64,
    pub cache_write: f64,
    /// What the cache reads would have cost more as plain input.
    pub cache_savings: f64,
}

impl Cost {
    pub fn total(&self) -> f64 {
        self.input + self.output + self.cache_read + self.cache_write
    }
    pub fn add(&mut self, o: &Cost) {
        self.input += o.input;
        self.output += o.output;
        self.cache_read += o.cache_read;
        self.cache_write += o.cache_write;
        self.cache_savings += o.cache_savings;
    }
    /// Keeps the split but matches a cost the agent recorded itself.
    pub fn scale_to(&mut self, recorded: f64) {
        let total = self.total();
        let k = if total > 0.0 { recorded / total } else { 0.0 };
        for v in [&mut self.input, &mut self.output, &mut self.cache_read, &mut self.cache_write, &mut self.cache_savings] {
            *v *= k;
        }
    }
}

impl ModelPrice {
    pub fn cost(&self, t: &Tokens) -> Cost {
        Cost {
            input: t.input as f64 * self.input / 1e6,
            output: t.output as f64 * self.output / 1e6,
            cache_read: t.cache_read as f64 * self.cache_read / 1e6,
            cache_write: t.cache_write as f64 * self.cache_write / 1e6,
            cache_savings: t.cache_read as f64 * (self.input - self.cache_read).max(0.0) / 1e6,
        }
    }

    pub fn of(name: &str) -> ModelPrice {
        let n = name.to_lowercase();
        let v = version(&n);
        let has = |s: &str| n.contains(s);

        if has("fable") || has("mythos") {
            return p(10.0, if v >= 5.1 { 0.25 } else { 1.0 }, 50.0);
        }
        if has("opus") {
            return if v >= 5.5 { p(4.0, 0.2, 20.0) } else if v >= 4.5 { p(5.0, 0.5, 25.0) } else { p(15.0, 1.5, 75.0) };
        }
        if has("sonnet") {
            return if v >= 5.0 { p(2.0, 0.2, 10.0) } else { p(3.0, 0.3, 15.0) };
        }
        if has("haiku") {
            return if v >= 5.0 { p(0.1, 0.01, 0.5) } else if v >= 4.5 { p(1.0, 0.1, 5.0) } else { p(0.8, 0.08, 4.0) };
        }
        if has("claude") {
            return p(3.0, 0.3, 15.0);
        }

        if has("grok") {
            let base = if v >= 4.6 { flat(2.0, 0.5, 6.0) } else if v >= 4.5 { flat(2.0, 0.3, 6.0) } else { flat(1.25, 0.2, 2.5) };
            // Grok Fast (Cursor and Grok Build only) is the same model at twice the rates.
            return if has("fast") { flat(base.input * 2.0, base.cache_read * 2.0, base.output * 2.0) } else { base };
        }
        if has("gpt") || has("codex") {
            if has("astra") {
                return p(10.0, 1.0, 50.0);
            }
            if has("luna") {
                return p(0.1, 0.01, 0.5);
            }
            if has("terra") {
                return if v >= 6.0 { p(1.0, 0.05, 5.0) } else { p(2.0, 0.2, 12.0) };
            }
            return if v >= 6.1 {
                p(2.0, 0.1, 10.0)
            } else if v >= 6.0 || v == 0.0 {
                p(2.0, 0.2, 10.0)
            } else if v >= 5.6 {
                p(4.0, 0.4, 20.0)
            } else if v >= 5.5 {
                p(5.0, 0.5, 30.0)
            } else if v >= 5.0 {
                p(1.25, 0.125, 10.0)
            } else {
                p(2.0, 0.5, 8.0)
            };
        }
        if has("glm") {
            if has("flashx") {
                return flat(0.37, 0.075, 1.25);
            }
            return if has("flash") { flat(0.15, 0.03, 0.5) } else { flat(1.4, 0.26, 4.4) };
        }
        if has("deepseek") {
            return if has("pro") { flat(0.66, 0.022, 1.98) } else { flat(0.22, 0.007, 0.66) };
        }
        if has("mimo") {
            return if has("pro") || has(" x ") { flat(0.435, 0.0036, 0.87) } else { flat(0.14, 0.0028, 0.28) };
        }
        if has("gemini") {
            if has("pro") {
                return flat(2.0, 0.2, 12.0);
            }
            return if has("lite") { flat(0.25, 0.025, 1.5) } else { flat(0.5, 0.05, 3.0) };
        }
        if has("minimax") {
            return p(0.3, 0.03, 1.2);
        }
        if has("kimi") {
            return flat(0.6, 0.15, 2.5);
        }
        if has("cursor") {
            return flat(1.25, 0.25, 6.0);
        }
        p(1.0, 0.1, 4.0)
    }
}

/// The first version number in a display name: "GPT-6.1 Sol" → 6.1, "Claude 4.5 Opus" → 4.5.
fn version(name: &str) -> f64 {
    let start = match name.find(|c: char| c.is_ascii_digit()) {
        Some(i) => i,
        None => return 0.0,
    };
    let rest = &name[start..];
    let mut end = rest.find(|c: char| !c.is_ascii_digit()).unwrap_or(rest.len());
    // One fractional part at most, as in "6.1" (not "6.1.2").
    if rest[end..].starts_with('.') && rest[end + 1..].starts_with(|c: char| c.is_ascii_digit()) {
        end += 1 + rest[end + 1..].find(|c: char| !c.is_ascii_digit()).unwrap_or(rest.len() - end - 1);
    }
    rest[..end].parse().unwrap_or(0.0)
}
