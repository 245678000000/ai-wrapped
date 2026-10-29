import SwiftUI

/// The first page of a weekly or monthly report: headline numbers against the previous
/// period, a bar per day, and the period's highlights.
struct WeekSlide: View {
    let r: Report
    private var p: Period { r.period }
    private let accent = Palette.weekly.accent

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Eyebrow(text: eyebrow, accent: accent).reveal(0)
            Spacer(minLength: 12)
            Text("\(p.phrase)，你和 AI").font(.heading(32)).opacity(0.92).reveal(0.1)
            Text(basis)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
                .padding(.top, 8)
                .reveal(0.15)
            HStack(spacing: 16) {
                kpi("Tokens", Double(r.tokens.total), r.previous.map { Double($0.tokens) }, suffix: "", delay: 0.2, money: r.cost.total)
                kpi("对话", Double(r.sessionCount), r.previous.map { Double($0.sessions) }, suffix: "次", delay: 0.28)
                kpi("消息", Double(r.promptCount), r.previous.map { Double($0.prompts) }, suffix: "条", delay: 0.36)
                kpi("活跃", Double(r.activeDays), r.previous.map { Double($0.activeDays) }, suffix: "天", delay: 0.44)
            }
            .padding(.top, 24)
            Spacer(minLength: 18)
            HStack(alignment: .bottom, spacing: 28) {
                DailyChart(r: r, accent: accent)
                    .frame(maxWidth: .infinity)
                    .frame(height: 236)
                    .reveal(0.5)
                WeekHighlights(r: r, accent: accent)
                    .frame(width: 330)
                    .reveal(0.62)
            }
        }
    }

    private var eyebrow: String {
        p.isWeek ? "WEEKLY · \(p.badge()) · \(p.rangeText())" : "MONTHLY · \(p.rangeText())"
    }

    /// Says exactly what the arrows compare against.
    private var basis: String {
        let elapsed = p.elapsedDays() ?? 0
        switch p {
        case .thisWeek where elapsed == 1: return "和上周一相比"
        case .thisWeek where elapsed < 7: return "和上周同期（周一到周\(Fmt.weekdayName(elapsed - 1))）相比"
        case .thisMonth where elapsed < r.daily.count: return "和上月同期（1–\(elapsed) 日）相比"
        default: return "和\(r.comparisonLabel)相比"
        }
    }

    private func kpi(_ label: String, _ value: Double, _ previous: Double?, suffix: String, delay: Double, money: Double? = nil) -> some View {
        GlassCard(padding: 20) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(label).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white.opacity(0.65))
                    Spacer(minLength: 6)
                    if let money, money > 0 {
                        Text("≈ " + Fmt.usd(money)).font(.system(size: 14, weight: .bold, design: .rounded)).monospacedDigit()
                            .foregroundStyle(TokensSlide.gold)
                    }
                }
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    CountUp(target: value, delay: delay + 0.1) { Fmt.scaled($0, like: value) }
                        .font(.display(44))
                    Text(Fmt.unit(value) + suffix).font(.system(size: 18, weight: .heavy)).opacity(0.9)
                }
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                DeltaChip(current: value, previous: previous)
                Text(previous.map { "\(r.comparisonLabel) \(Fmt.big($0))\(suffix.isEmpty ? "" : " " + suffix)" } ?? " ")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
            }
        }
        .reveal(delay)
    }
}

/// "↑ 32%" / "↓ 12%" / "持平" / "新增", colored by direction.
struct DeltaChip: View {
    let current: Double
    let previous: Double?

    static let up = Color(hex: 0x7CF5C4)
    static let down = Color(hex: 0xFF9DB6)
    static let flat = Color.white.opacity(0.7)

    var body: some View {
        let (text, color, icon) = describe()
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 10, weight: .heavy))
            Text(text).font(.system(size: 13, weight: .bold)).monospacedDigit()
        }
        .foregroundStyle(color)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(color.opacity(0.15)))
        .overlay(Capsule().strokeBorder(color.opacity(0.35), lineWidth: 1))
    }

    private func describe() -> (String, Color, String) {
        guard let previous else { return ("—", Self.flat, "minus") }
        if previous == 0 { return current > 0 ? ("新增", Self.up, "sparkle") : ("持平", Self.flat, "equal") }
        let change = (current - previous) / previous
        if abs(change) < 0.01 { return ("持平", Self.flat, "equal") }
        let text = change >= 2 ? String(format: "%.1f 倍", current / previous) : String(format: "%.0f%%", abs(change) * 100)
        return change > 0 ? (text, Self.up, "arrow.up.right") : (text, Self.down, "arrow.down.right")
    }
}

/// One bar per day; the busiest day lit in the accent color, days still to come dashed.
struct DailyChart: View {
    let r: Report
    let accent: Color
    @State private var grown = false
    @Environment(\.isSnapshot) private var snapshot
    @Environment(\.videoTime) private var videoTime

    var body: some View {
        let isWeek = r.period.isWeek
        let g = videoTime.map { settled($0, delay: 0.6, response: 1.0) } ?? (grown || snapshot ? 1 : 0)
        let maxTokens = Double(max(1, r.daily.map(\.stat.tokens).max() ?? 1))
        let peak = r.daily.indices.max { r.daily[$0].stat.tokens < r.daily[$1].stat.tokens }
            .flatMap { r.daily[$0].stat.tokens > 0 ? $0 : nil }
        let today = LocalTime.today
        VStack(alignment: .leading, spacing: 14) {
            Text("每天的 tokens").font(.system(size: 14, weight: .semibold)).tracking(2).opacity(0.6)
            GeometryReader { geo in
                let n = CGFloat(max(1, r.daily.count))
                let gap: CGFloat = isWeek ? 14 : 4
                let barWidth = max(4, (geo.size.width - gap * (n - 1)) / n)
                let labelHeight: CGFloat = isWeek ? 36 : 16
                let maxBar = geo.size.height - labelHeight - 28
                let corner: CGFloat = isWeek ? 10 : 4
                HStack(alignment: .bottom, spacing: gap) {
                    ForEach(r.daily.indices, id: \.self) { i in
                        let d = r.daily[i]
                        let future = d.day > today
                        let isPeak = i == peak
                        let height = max(6, maxBar * CGFloat(Double(d.stat.tokens) / maxTokens))
                        VStack(spacing: 6) {
                            Spacer(minLength: 0)
                            Group {
                                if future {
                                    RoundedRectangle(cornerRadius: corner)
                                        .strokeBorder(.white.opacity(0.2), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                                        .frame(height: 26)
                                } else {
                                    RoundedRectangle(cornerRadius: corner)
                                        .fill(LinearGradient(colors: isPeak ? [accent, accent.opacity(0.5)] : [.white.opacity(0.45), .white.opacity(0.2)],
                                                             startPoint: .top, endPoint: .bottom))
                                        .shadow(color: isPeak ? accent.opacity(0.5) : .clear, radius: 12)
                                        .frame(height: 6 + (height - 6) * g)
                                }
                            }
                            .frame(width: barWidth)
                            // Floats above the bar so a narrow month bar doesn't widen its column.
                            .overlay(alignment: .top) {
                                if isPeak {
                                    Text(Fmt.big(d.stat.tokens))
                                        .font(.system(size: 13, weight: .heavy)).monospacedDigit()
                                        .foregroundStyle(accent)
                                        .fixedSize()
                                        .offset(y: -22)
                                        .opacity(g)
                                }
                            }
                            label(for: d.day, index: i, isPeak: isPeak, today: today, isWeek: isWeek)
                                .frame(height: labelHeight)
                                .opacity(future ? 0.4 : 1)
                        }
                    }
                }
            }
        }
        .onAppear { withAnimation(.spring(response: 1.0, dampingFraction: 0.82).delay(0.6)) { grown = true } }
    }

    @ViewBuilder
    private func label(for day: DayKey, index: Int, isPeak: Bool, today: DayKey, isWeek: Bool) -> some View {
        if isWeek {
            VStack(spacing: 2) {
                Text(day == today ? "今天" : "周" + Fmt.weekdayName(LocalTime.weekdayIndex(day)))
                    .font(.system(size: 13, weight: isPeak || day == today ? .bold : .medium))
                    .foregroundStyle(day == today ? accent : .white)
                Text(Fmt.shortDay(day)).font(.system(size: 11, weight: .medium)).opacity(0.5)
            }
            .fixedSize()
        } else {
            let n = LocalTime.components(day).day ?? 0
            Text(n == 1 || n % 5 == 0 || isPeak ? "\(n)" : " ")
                .font(.system(size: 10, weight: isPeak ? .bold : .medium))
                .opacity(isPeak ? 1 : 0.55)
                .fixedSize()
        }
    }
}

/// "本周之最": the agent, day, project and model that stood out.
struct WeekHighlights: View {
    let r: Report
    let accent: Color

    var body: some View {
        let total = Double(max(1, r.tokens.total))
        GlassCard(padding: 20) {
            VStack(alignment: .leading, spacing: 15) {
                Text("\(r.period.label)之最").font(.system(size: 14, weight: .semibold)).tracking(2).opacity(0.6)
                row("sparkles", "最常用的 agent", r.topAgent?.agent.displayName, dot: r.topAgent?.agent.color,
                    detail: r.topAgent.map { $0.tokens > 0 ? "\(Fmt.percent(Double($0.tokens), of: total)) tokens" : "\($0.prompts) 条消息" })
                row("flame.fill", "最忙的一天", busiestDay, dot: nil,
                    detail: r.busiestDay.flatMap { $0.stat.tokens > 0 ? Fmt.big($0.stat.tokens) : "\($0.stat.prompts) 条消息" })
                row("folder.fill", "主要项目", r.projects.first?.name, dot: nil,
                    detail: r.projects.first.map { "\($0.prompts) 条消息" })
                row("cpu", "最爱模型", r.topModel?.name, dot: nil,
                    detail: r.topModel.map { Fmt.percent(Double($0.tokens), of: total) })
            }
        }
    }

    private var busiestDay: String? {
        guard let b = r.busiestDay, b.stat.isActive else { return nil }
        if r.period.isWeek { return "周\(Fmt.weekdayName(LocalTime.weekdayIndex(b.day))) · \(Fmt.shortDay(b.day))" }
        return Fmt.day(b.day)
    }

    private func row(_ icon: String, _ title: String, _ value: String?, dot: Color?, detail: String?) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous).fill(accent.opacity(0.16))
                Image(systemName: icon).font(.system(size: 13, weight: .semibold)).foregroundStyle(accent)
            }
            .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12, weight: .medium)).opacity(0.6)
                HStack(spacing: 6) {
                    if let dot { Circle().fill(dot).frame(width: 7, height: 7) }
                    Text(value ?? "—").font(.system(size: 16, weight: .bold)).lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            Text(detail ?? "")
                .font(.system(size: 12, weight: .semibold)).monospacedDigit()
                .opacity(0.6)
                .lineLimit(1)
        }
    }
}
