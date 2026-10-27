import SwiftUI

/// What a slide can ask the surrounding story to do.
struct StoryContext {
    var report: Report
    var years: [Int] = []
    var select: (Period) -> Void = { _ in }
    var next: () -> Void = {}
    var restart: () -> Void = {}
    var rescan: () -> Void = {}
}

enum Slide: Hashable {
    case cover, week, first, tokens, conversations, agents, models, tools, rhythm, calendar, projects, persona, summary

    /// Weekly and monthly reports wear their own night-sky colors on the cover.
    func palette(for r: Report) -> Palette {
        switch self {
        case .cover: return r.period.isShort ? .weeklyCover : .cover
        case .week: return .weekly
        case .first: return .first
        case .tokens: return .tokens
        case .conversations: return .talk
        case .agents: return .agents
        case .models: return .models
        case .tools: return .tools
        case .rhythm: return .rhythm
        case .calendar: return .calendar
        case .projects: return .projects
        case .persona: return .persona
        case .summary: return .summary
        }
    }

    static func list(for r: Report) -> [Slide] {
        // A week or month is a lighter read: the summary up front, no year-scale pages.
        if r.period.isShort {
            guard !r.isEmpty else { return [.cover, .week] }
            var s: [Slide] = [.cover, .week, .tokens]
            if r.promptCount > 0 { s.append(.conversations) }
            if !r.agents.isEmpty { s.append(.agents) }
            if !r.models.isEmpty { s.append(.models) }
            if r.toolCallCount > 0 { s.append(.tools) }
            if r.promptCount > 0 { s.append(.rhythm) }
            if !r.projects.isEmpty { s.append(.projects) }
            s.append(.summary)
            return s
        }
        var s: [Slide] = [.cover]
        if r.firstPrompt != nil { s.append(.first) }
        s.append(.tokens)
        if r.promptCount > 0 { s.append(.conversations) }
        if !r.agents.isEmpty { s.append(.agents) }
        if !r.models.isEmpty { s.append(.models) }
        if r.toolCallCount > 0 { s.append(.tools) }
        if r.promptCount > 0 { s.append(.rhythm) }
        s.append(.calendar)
        if !r.projects.isEmpty { s.append(.projects) }
        s += [.persona, .summary]
        return s
    }
}

struct SlideView: View {
    let slide: Slide
    let ctx: StoryContext

    var body: some View {
        Group {
            switch slide {
            case .cover: CoverSlide(ctx: ctx)
            case .week: WeekSlide(r: ctx.report)
            case .first: FirstSlide(r: ctx.report)
            case .tokens: TokensSlide(r: ctx.report)
            case .conversations: ConversationsSlide(r: ctx.report)
            case .agents: AgentsSlide(r: ctx.report)
            case .models: ModelsSlide(r: ctx.report)
            case .tools: ToolsSlide(r: ctx.report)
            case .rhythm: RhythmSlide(r: ctx.report)
            case .calendar: CalendarSlide(r: ctx.report)
            case .projects: ProjectsSlide(r: ctx.report)
            case .persona: PersonaSlide(r: ctx.report)
            case .summary: SummarySlide(ctx: ctx)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 72)
        .padding(.top, 58)
        .padding(.bottom, 76)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Cover

struct CoverSlide: View {
    let ctx: StoryContext
    var r: Report { ctx.report }
    var p: Period { r.period }
    @Environment(\.isSnapshot) private var snapshot

    var body: some View {
        let palette = Slide.cover.palette(for: r)
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Eyebrow(text: p.isShort ? "AI WRAPPED · \(p.isWeek ? "WEEKLY" : "MONTHLY")" : "AI WRAPPED", accent: palette.accent)
                    .reveal(0)
                Spacer()
                periodMenu.reveal(0.1)
            }
            Spacer(minLength: 20)
            Text("你的").font(.heading(40)).opacity(0.85).reveal(0.15)
            Text(p.isShort ? p.rangeText() : (r.year.map(String.init) ?? "ALL TIME"))
                .font(.display(p.isWeek ? 136 : (r.year == nil && !p.isShort ? 150 : 200)))
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .foregroundStyle(LinearGradient(colors: heroColors, startPoint: .topLeading, endPoint: .bottomTrailing))
                .shadow(color: heroGlow.opacity(0.5), radius: 40)
                .padding(.vertical, p.isWeek ? -8 : -18)
                .reveal(0.25)
            Text(p.isShort ? "\(p.label) · \(p.reportName)" : p.reportName)
                .font(.system(size: 60, weight: .heavy))
                .padding(.top, p.isWeek ? 8 : 0)
                .reveal(0.35)
            Text(subtitle)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.white.opacity(0.75))
                .padding(.top, 14)
                .reveal(0.5)
            Spacer(minLength: 20)
            HStack(spacing: 14) {
                Button(action: ctx.next) {
                    HStack(spacing: 10) {
                        Text(p.isShort ? "看看\(p.label)" : "开始回顾")
                        Image(systemName: "arrow.right")
                    }
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(p.isShort ? Color(hex: 0x10204A) : Color(hex: 0x2A0B52))
                    .padding(.horizontal, 28)
                    .padding(.vertical, 15)
                    .background(Capsule().fill(.white))
                    .shadow(color: .black.opacity(0.25), radius: 20, y: 8)
                }
                .buttonStyle(.plain)
                switchButton
                Text("← → 或空格翻页")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
                    .padding(.leading, 4)
            }
            .reveal(0.65)
        }
    }

    private var heroColors: [Color] {
        p.isShort ? [.white, Color(hex: 0xBFF4FF), Color(hex: 0xC4B5FF)] : [.white, Color(hex: 0xFFD3A8), Color(hex: 0xFF8FB8)]
    }
    private var heroGlow: Color { p.isShort ? Color(hex: 0x2FB5C9) : Color(hex: 0xE04F8B) }
    private var defaultYear: Period { ctx.years.last.map(Period.year) ?? .all }

    /// Jumps between the year report and this week's summary.
    private var switchButton: some View {
        Button { ctx.select(p.isShort ? defaultYear : .thisWeek) } label: {
            Label(p.isShort ? "回到年度报告" : "本周小结", systemImage: p.isShort ? "sparkles" : "calendar.badge.clock")
                .font(.system(size: 16, weight: .semibold))
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                .background(Capsule().fill(.white.opacity(0.12)))
                .overlay(Capsule().strokeBorder(.white.opacity(0.22)))
        }
        .buttonStyle(.plain)
    }

    private var menuLabel: some View {
        Label(p.label, systemImage: "calendar")
            .font(.system(size: 14, weight: .semibold))
    }

    @ViewBuilder private var periodMenu: some View {
        if snapshot {
            // Menus are AppKit-backed and can't be rendered offscreen.
            menuLabel
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Capsule().fill(.white.opacity(0.12)))
        } else {
            Menu {
                Button("本周") { ctx.select(.thisWeek) }
                Button("上周") { ctx.select(.lastWeek) }
                Button("本月") { ctx.select(.thisMonth) }
                Divider()
                ForEach(ctx.years.reversed(), id: \.self) { y in
                    Button("\(String(y)) 年") { ctx.select(.year(y)) }
                }
                Button("全部时间") { ctx.select(.all) }
                Divider()
                Button("重新扫描本地记录") { ctx.rescan() }
            } label: {
                menuLabel
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Capsule().fill(.white.opacity(0.12)))
        }
    }

    var subtitle: String {
        let names = r.agents.prefix(3).map(\.agent.displayName).joined(separator: "、")
        let lead = r.agents.count > 3 ? "\(names) 等 \(r.agents.count) 个 agent，" : (names.isEmpty ? "" : names + "，")
        guard p.isShort else { return "\(lead)\(Fmt.grouped(r.sessionCount)) 次对话，都在这里了。数据只在本机读取。" }
        if r.isEmpty { return "\(p.phrase)还没有和 AI 聊过。去开个头吧。" }
        let elapsed = p.elapsedDays() ?? 0
        let total = r.daily.count
        let note: String
        switch p {
        case .thisWeek where elapsed < total: note = "本周才过了 \(elapsed) 天，周日晚上再来看完整版。"
        case .thisMonth where elapsed < total: note = "这个月才过了 \(elapsed) 天。"
        default: note = "数据只在本机读取。"
        }
        return "\(lead)\(Fmt.grouped(r.sessionCount)) 次对话。\(note)"
    }
}

// MARK: - First words

struct FirstSlide: View {
    let r: Report

    var body: some View {
        let p = r.firstPrompt!
        let day = LocalTime.day(p.time)
        let since = LocalTime.today - day
        VStack(alignment: .leading, spacing: 0) {
            Eyebrow(text: "第一句话", accent: Palette.first.accent).reveal(0)
            Spacer(minLength: 16)
            Text(r.year == nil ? "故事从这一天开始" : "\(r.title) 年的故事，从这一天开始")
                .font(.heading(32)).opacity(0.9).reveal(0.1)
            Text(Fmt.day(day, withYear: r.year == nil))
                .font(.display(120))
                .foregroundStyle(LinearGradient(colors: [.white, Palette.first.accent], startPoint: .top, endPoint: .bottom))
                .padding(.vertical, -6)
                .reveal(0.2)
            Text("\(Fmt.clock(p.time))，你对 \(p.agent.displayName) 说：")
                .font(.system(size: 22, weight: .medium)).opacity(0.8)
                .padding(.top, 6)
                .reveal(0.35)
            GlassCard(padding: 28) {
                HStack(alignment: .top, spacing: 16) {
                    Text("“").font(.system(size: 64, weight: .black, design: .serif)).opacity(0.4).padding(.top, -14)
                    Text(p.preview.isEmpty ? "（一张图片）" : p.preview)
                        .font(.system(size: 24, weight: .medium, design: .serif))
                        .lineSpacing(6)
                        .lineLimit(3)
                }
            }
            .frame(maxWidth: 820)
            .padding(.top, 20)
            .reveal(0.5)
            Spacer(minLength: 16)
            Text(since > 0 ? "到今天，已经过去 \(since) 天。" : "就在今天。")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Palette.first.accent)
                .reveal(0.7)
        }
    }
}

// MARK: - Tokens

struct TokensSlide: View {
    let r: Report

    var body: some View {
        let total = Double(r.tokens.total)
        let parts: [(String, Int64, Color)] = [
            ("缓存读取", r.tokens.cacheRead, Color(hex: 0xFFD08A)),
            ("缓存写入", r.tokens.cacheWrite, Color(hex: 0xFF9F5A)),
            ("输入", r.tokens.input, Color(hex: 0xFF6B6B)),
            ("输出", r.tokens.output, Color(hex: 0xFFF3E0)),
        ]
        VStack(alignment: .leading, spacing: 0) {
            Eyebrow(text: "TOKENS", accent: Palette.tokens.accent).reveal(0)
            Spacer(minLength: 12)
            Text("\(r.period.phrase)，你和 AI 一共消耗了")
                .font(.heading(30)).opacity(0.9).reveal(0.1)
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                CountUp(target: total, delay: 0.3, duration: 2.0) { Fmt.scaled($0, like: total) }
                    .font(.display(150))
                    .foregroundStyle(LinearGradient(colors: [.white, Palette.tokens.accent], startPoint: .top, endPoint: .bottom))
                Text("\(Fmt.unit(total)) tokens").font(.system(size: 44, weight: .heavy)).opacity(0.9)
            }
            .padding(.vertical, -10)
            .reveal(0.2)

            // Composition bar
            GeometryReader { geo in
                HStack(spacing: 3) {
                    ForEach(parts.indices, id: \.self) { i in
                        let f = total > 0 ? Double(parts[i].1) / total : 0
                        if f > 0.002 {
                            RoundedRectangle(cornerRadius: 6).fill(parts[i].2)
                                .frame(width: max(6, (geo.size.width - 9) * f))
                        }
                    }
                }
            }
            .frame(height: 22)
            .padding(.top, 22)
            .reveal(0.45)
            HStack(spacing: 26) {
                ForEach(parts.indices, id: \.self) { i in
                    HStack(spacing: 8) {
                        Circle().fill(parts[i].2).frame(width: 9, height: 9)
                        Text(parts[i].0).opacity(0.75)
                        Text(Fmt.big(parts[i].1)).fontWeight(.bold)
                    }
                }
            }
            .font(.system(size: 15))
            .padding(.top, 12)
            .reveal(0.55)

            Spacer(minLength: 18)
            HStack(spacing: 18) {
                GlassCard {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("≈ \(Fmt.big(max(1, total / 730_000))) 部《红楼梦》").font(.system(size: 26, weight: .heavy))
                        Text("按一部约 73 万字、一字约一个 token 粗算").font(.system(size: 14)).opacity(0.65)
                    }
                }
                GlassCard {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("AI 亲手写下 \(Fmt.big(r.tokens.output))").font(.system(size: 26, weight: .heavy))
                        Text("≈ \(Fmt.big(max(1, Double(r.tokens.output) / 30_000))) 篇 3 万字的毕业论文").font(.system(size: 14)).opacity(0.65)
                    }
                }
                GlassCard {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(Fmt.percent(Double(r.tokens.cacheRead), of: total)) 是缓存").font(.system(size: 26, weight: .heavy))
                        Text("AI 反复“重读”上下文的部分，便宜又省时").font(.system(size: 14)).opacity(0.65)
                    }
                }
            }
            .reveal(0.75)
        }
    }
}

// MARK: - Conversations

struct ConversationsSlide: View {
    let r: Report

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Eyebrow(text: "对话", accent: Palette.talk.accent).reveal(0)
            Spacer(minLength: 12)
            Text("你们聊了很多").font(.heading(32)).opacity(0.9).reveal(0.1)
            HStack(alignment: .top, spacing: 56) {
                stat(Double(r.sessionCount), "次对话", 0.2)
                stat(Double(r.promptCount), "条消息由你发出", 0.35)
                stat(Double(r.charCount), "个字由你敲下", 0.5)
            }
            .padding(.top, 26)
            Spacer(minLength: 18)
            HStack(alignment: .top, spacing: 18) {
                GlassCard {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("活跃 \(r.activeDays) 天").font(.system(size: 26, weight: .heavy))
                        Text(r.longestStreak > 1
                             ? "最长连续 \(r.longestStreak) 天：\(Fmt.shortDay(r.streakStart)) – \(Fmt.shortDay(r.streakStart + r.longestStreak - 1))"
                             : "每一天都是新的开始")
                            .font(.system(size: 14)).opacity(0.7)
                    }
                }
                GlassCard {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("平均每次 \(String(format: "%.1f", Double(r.promptCount) / Double(max(1, r.sessionCount)))) 轮").font(.system(size: 26, weight: .heavy))
                        Text("每条消息平均 \(r.charCount / max(1, r.promptCount)) 字").font(.system(size: 14)).opacity(0.7)
                    }
                }
                GlassCard {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("≈ \(Fmt.big(max(1, r.charCount / 800))) 篇高考作文").font(.system(size: 26, weight: .heavy))
                        Text("按每篇 800 字算，你写给 AI 的字").font(.system(size: 14)).opacity(0.7)
                    }
                }
            }
            .reveal(0.7)
        }
    }

    func stat(_ v: Double, _ label: String, _ delay: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                CountUp(target: v, delay: delay + 0.1) { Fmt.scaled($0, like: v) }
                    .font(.display(96))
                Text(Fmt.unit(v)).font(.system(size: 34, weight: .heavy))
            }
            Text(label).font(.system(size: 19, weight: .semibold)).opacity(0.75)
        }
        .reveal(delay)
    }
}

// MARK: - Agents

struct AgentsSlide: View {
    let r: Report

    var body: some View {
        let top = r.agents[0]
        let total = Double(max(1, r.tokens.total))
        let byTokens = Array(r.agents.filter { $0.tokens > 0 }.prefix(5))
        let byTalks = Array(r.agents.sorted { ($0.sessions, $0.prompts) > ($1.sessions, $1.prompts) }.prefix(5))
        let shown = Set(byTokens.map(\.agent) + byTalks.map(\.agent))
        let rest = r.agents.filter { !shown.contains($0.agent) }.sorted { $0.sessions > $1.sessions }
        let chattiest = r.agents.max { $0.prompts < $1.prompts }
        VStack(alignment: .leading, spacing: 0) {
            Eyebrow(text: "AGENTS", accent: Palette.agents.accent).reveal(0)
            Spacer(minLength: 10)
            Text(r.agents.count > 1 ? "你一共用过 \(r.agents.count) 个 agent，头号搭档是" : "你的头号搭档是")
                .font(.heading(30)).opacity(0.9).reveal(0.1)
            Text(top.agent.displayName)
                .font(.display(top.agent.displayName.count > 12 ? 76 : 96))
                .lineLimit(1).minimumScaleFactor(0.6)
                .foregroundStyle(LinearGradient(colors: [.white, top.agent.color], startPoint: .topLeading, endPoint: .bottomTrailing))
                .padding(.vertical, -6)
                .reveal(0.2)
            Group {
                if let chattiest, chattiest.agent != top.agent, chattiest.prompts > top.prompts {
                    Text("承包了 \(Fmt.percent(Double(top.tokens), of: total)) 的 tokens · 但和你聊得最多的是 \(chattiest.agent.displayName)：\(Fmt.grouped(chattiest.prompts)) 条消息")
                } else {
                    Text("承包了 \(Fmt.percent(Double(top.tokens), of: total)) 的 tokens 和 \(Fmt.percent(Double(top.prompts), of: Double(max(1, r.promptCount)))) 的消息")
                }
            }
            .font(.system(size: 19, weight: .medium)).opacity(0.75)
            .reveal(0.3)
            Spacer(minLength: 16)
            HStack(alignment: .top, spacing: 40) {
                ranking("按 token 用量", byTokens, delay: 0.4) { (Double($0.tokens), Fmt.big($0.tokens)) }
                ranking("按对话次数", byTalks, delay: 0.5) { (Double($0.sessions), "\(Fmt.grouped($0.sessions)) 次") }
            }
            if !rest.isEmpty {
                (Text("还用过（对话次数）  ").foregroundStyle(.white.opacity(0.55))
                 + Text(rest.map { "\($0.agent.displayName) \($0.sessions)" }.joined(separator: " · ")))
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(2)
                    .padding(.top, 18)
                    .reveal(0.7)
            }
        }
    }

    func ranking(_ title: String, _ rows: [AgentStat], delay: Double, value: @escaping (AgentStat) -> (Double, String)) -> some View {
        let maxV = rows.map { value($0).0 }.max() ?? 1
        return VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.system(size: 14, weight: .semibold)).tracking(2).opacity(0.6)
            ForEach(Array(rows.enumerated()), id: \.element.id) { i, a in
                HStack(spacing: 14) {
                    Text(a.agent.displayName)
                        .font(.system(size: 17, weight: .bold)).lineLimit(1)
                        .frame(width: 150, alignment: .leading)
                    GrowBar(fraction: value(a).0 / max(1, maxV), color: a.agent.color, height: 14, delay: delay + Double(i) * 0.08)
                    Text(value(a).1)
                        .font(.system(size: 15, weight: .heavy)).monospacedDigit()
                        .frame(width: 76, alignment: .trailing)
                }
                .reveal(delay + Double(i) * 0.08)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Models

struct ModelsSlide: View {
    let r: Report

    var body: some View {
        let top = r.models[0]
        let total = Double(max(1, r.tokens.total))
        let rest = Array(r.models.dropFirst().prefix(5))
        VStack(alignment: .leading, spacing: 0) {
            Eyebrow(text: "MODELS", accent: Palette.models.accent).reveal(0)
            Spacer(minLength: 12)
            Text("出场最多的模型").font(.heading(32)).opacity(0.9).reveal(0.1)
            Text(top.name)
                .font(.display(top.name.count > 16 ? 76 : 100))
                .lineLimit(1).minimumScaleFactor(0.5)
                .foregroundStyle(LinearGradient(colors: [.white, Palette.models.accent], startPoint: .top, endPoint: .bottom))
                .padding(.vertical, -4)
                .reveal(0.2)
            Text("\(Fmt.percent(Double(top.tokens), of: total)) 的 tokens 交给了它 · 在 \(top.agent.displayName) 里被调用 \(Fmt.grouped(top.calls)) 次")
                .font(.system(size: 20, weight: .medium)).opacity(0.75)
                .reveal(0.3)
            Spacer(minLength: 18)
            if !rest.isEmpty {
                Text("还有它们").font(.system(size: 15, weight: .semibold)).tracking(2).opacity(0.6).reveal(0.4)
                    .padding(.bottom, 12)
                VStack(spacing: 14) {
                    ForEach(Array(rest.enumerated()), id: \.element.id) { i, m in
                        HStack(spacing: 18) {
                            Text("\(i + 2)").font(.display(22)).opacity(0.5).frame(width: 28, alignment: .leading)
                            Text(m.name).font(.system(size: 19, weight: .bold)).lineLimit(1)
                                .frame(width: 260, alignment: .leading)
                            GrowBar(fraction: Double(m.tokens) / Double(max(1, rest[0].tokens)), color: m.agent.color,
                                    height: 12, delay: 0.5 + Double(i) * 0.08)
                            Text(Fmt.big(m.tokens)).font(.system(size: 16, weight: .semibold)).monospacedDigit()
                                .frame(width: 90, alignment: .trailing)
                            Text(m.agent.displayName).font(.system(size: 13)).opacity(0.55)
                                .frame(width: 110, alignment: .leading)
                        }
                        .reveal(0.45 + Double(i) * 0.08)
                    }
                }
            }
        }
    }
}

// MARK: - Tools

struct ToolsSlide: View {
    let r: Report

    var body: some View {
        let cats = Array(r.toolCategories.prefix(7))
        VStack(alignment: .leading, spacing: 0) {
            Eyebrow(text: "TOOLS", accent: Palette.tools.accent).reveal(0)
            Spacer(minLength: 10)
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                CountUp(target: Double(r.toolCallCount), delay: 0.2) { Fmt.scaled($0, like: Double(r.toolCallCount)) }
                    .font(.display(110))
                    .foregroundStyle(LinearGradient(colors: [.white, Palette.tools.accent], startPoint: .top, endPoint: .bottom))
                Text("\(Fmt.unit(Double(r.toolCallCount)))次动手").font(.system(size: 40, weight: .heavy))
            }
            .reveal(0.1)
            Text("你说一句话，AI 平均要调用 \(String(format: "%.1f", Double(r.toolCallCount) / Double(max(1, r.promptCount)))) 次工具")
                .font(.system(size: 20, weight: .medium)).opacity(0.75)
                .reveal(0.2)
            Spacer(minLength: 18)
            HStack(alignment: .top, spacing: 36) {
                VStack(alignment: .leading, spacing: 13) {
                    Text("AI 最常替你干的活").font(.system(size: 15, weight: .semibold)).tracking(2).opacity(0.6)
                    ForEach(Array(cats.enumerated()), id: \.element.id) { i, c in
                        HStack(spacing: 14) {
                            Text(c.name).font(.system(size: 17, weight: .bold)).lineLimit(1)
                                .frame(width: 150, alignment: .leading)
                            GrowBar(fraction: Double(c.count) / Double(max(1, cats[0].count)),
                                    color: Palette.tools.accent, height: 12, delay: 0.4 + Double(i) * 0.06)
                            Text(Fmt.big(c.count)).font(.system(size: 15, weight: .semibold)).monospacedDigit()
                                .frame(width: 64, alignment: .trailing)
                        }
                        .reveal(0.35 + Double(i) * 0.06)
                    }
                }
                .frame(maxWidth: .infinity)
                VStack(spacing: 16) {
                    if !r.skills.isEmpty {
                        GlassCard {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("用了 \(r.skillCount) 次技能").font(.system(size: 22, weight: .heavy))
                                ForEach(r.skills.prefix(3)) { s in
                                    HStack {
                                        Text(s.name).lineLimit(1)
                                        Spacer()
                                        Text("×\(s.count)").monospacedDigit().opacity(0.7)
                                    }
                                    .font(.system(size: 15, weight: .medium))
                                }
                            }
                        }
                    }
                    GlassCard {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("派出 \(r.subagentCount) 个子 agent").font(.system(size: 22, weight: .heavy))
                            if r.subagents.isEmpty {
                                Text("你习惯亲力亲为").font(.system(size: 15)).opacity(0.7)
                            }
                            ForEach(r.subagents.prefix(3)) { s in
                                HStack {
                                    Text(s.name).lineLimit(1)
                                    Spacer()
                                    Text("×\(s.count)").monospacedDigit().opacity(0.7)
                                }
                                .font(.system(size: 15, weight: .medium))
                            }
                        }
                    }
                }
                .frame(width: 330)
                .reveal(0.6)
            }
        }
    }
}

// MARK: - Rhythm

struct RhythmSlide: View {
    let r: Report

    var body: some View {
        let peak = r.peakHour
        HStack(alignment: .center, spacing: 40) {
            VStack(alignment: .leading, spacing: 0) {
                Eyebrow(text: "作息", accent: Palette.rhythm.accent).reveal(0)
                Spacer(minLength: 12)
                Text("你最常在").font(.heading(30)).opacity(0.9).reveal(0.1)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(peak)").font(.display(130))
                    Text("点").font(.system(size: 44, weight: .heavy))
                }
                .foregroundStyle(LinearGradient(colors: [.white, Palette.rhythm.accent], startPoint: .top, endPoint: .bottom))
                .padding(.vertical, -10)
                .reveal(0.2)
                Text("找 AI 帮忙 · \(peakLabel(peak))").font(.system(size: 22, weight: .semibold)).opacity(0.85).reveal(0.3)

                WeekdayBars(values: r.weekday)
                    .frame(height: 96)
                    .padding(.top, 26)
                    .reveal(0.45)
                Spacer(minLength: 16)
                if let ln = r.lateNight {
                    GlassCard {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("最晚的一次：凌晨 \(Fmt.clock(ln.time))")
                                .font(.system(size: 20, weight: .heavy))
                            Text("“\(ln.preview.isEmpty ? "（一张图片）" : ln.preview)”")
                                .font(.system(size: 16, weight: .medium, design: .serif))
                                .lineLimit(2).opacity(0.85)
                            Text("\(Fmt.day(LocalTime.day(ln.time))) · 凌晨 0–5 点你一共发了 \(r.lateNightCount) 条消息")
                                .font(.system(size: 13)).opacity(0.6)
                        }
                    }
                    .frame(maxWidth: 560)
                    .reveal(0.6)
                } else {
                    Text("凌晨 0–5 点，你从不打扰 AI。作息满分。")
                        .font(.system(size: 18, weight: .semibold)).opacity(0.8).reveal(0.6)
                }
            }
            RadialClock(values: r.hourly, accent: Palette.rhythm.accent)
                .frame(width: 380, height: 380)
                .reveal(0.3)
        }
    }

    func peakLabel(_ h: Int) -> String {
        switch h {
        case 0..<5: return "夜深人静的时候"
        case 5..<9: return "清晨，脑子最清醒"
        case 9..<12: return "上午的黄金时间"
        case 12..<14: return "午饭前后也不停"
        case 14..<18: return "下午火力全开"
        case 18..<22: return "下班后的第二战场"
        default: return "夜色正浓"
        }
    }
}

struct WeekdayBars: View {
    let values: [Int]
    @State private var grown = false
    @Environment(\.isSnapshot) private var snapshot

    var body: some View {
        let maxV = Double(max(1, values.max() ?? 1))
        let top = values.indices.max { values[$0] < values[$1] } ?? 0
        HStack(alignment: .bottom, spacing: 12) {
            ForEach(0..<7, id: \.self) { i in
                VStack(spacing: 6) {
                    Spacer(minLength: 0)
                    RoundedRectangle(cornerRadius: 5)
                        .fill(i == top ? Palette.rhythm.accent : .white.opacity(0.35))
                        .frame(width: 30, height: max(4, 66 * ((grown || snapshot) ? Double(values[i]) / maxV : 0)))
                    Text("周" + Fmt.weekdayName(i)).font(.system(size: 12, weight: .medium)).opacity(i == top ? 1 : 0.6)
                }
            }
        }
        .onAppear { withAnimation(.spring(response: 0.9, dampingFraction: 0.8).delay(0.5)) { grown = true } }
    }
}

struct RadialBars: Shape {
    var values: [Double] // 0...1
    var progress: Double
    var inner: CGFloat

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let outerMax = min(rect.width, rect.height) / 2
        let n = values.count
        func point(_ radius: CGFloat, _ angle: Double) -> CGPoint {
            CGPoint(x: c.x + radius * CGFloat(cos(angle)), y: c.y + radius * CGFloat(sin(angle)))
        }
        for (i, v) in values.enumerated() {
            let gap = 0.12 / Double(n)
            let a0 = (Double(i) / Double(n) + gap / 2) * 2 * .pi - .pi / 2
            let a1 = (Double(i + 1) / Double(n) - gap / 2) * 2 * .pi - .pi / 2
            let r = inner + 4 + (outerMax - inner - 4) * CGFloat(max(0.03, v) * progress)
            // Trace the wedge as polylines so arc direction never depends on the flipped y-axis.
            let steps = 8
            p.move(to: point(inner, a0))
            for s in 0...steps { p.addLine(to: point(r, a0 + (a1 - a0) * Double(s) / Double(steps))) }
            for s in stride(from: steps, through: 0, by: -1) { p.addLine(to: point(inner, a0 + (a1 - a0) * Double(s) / Double(steps))) }
            p.closeSubpath()
        }
        return p
    }
}

struct RadialClock: View {
    let values: [Int]
    let accent: Color
    @State private var progress = 0.0
    @Environment(\.isSnapshot) private var snapshot

    var body: some View {
        let maxV = Double(max(1, values.max() ?? 1))
        let norm = values.map { Double($0) / maxV }
        let peak = values.indices.max { values[$0] < values[$1] } ?? 0
        let peakOnly = norm.enumerated().map { $0.offset == peak ? $0.element : 0 }
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            let inner = size * 0.2
            ZStack {
                Circle().strokeBorder(.white.opacity(0.08), lineWidth: 1)
                Circle().strokeBorder(.white.opacity(0.06), lineWidth: 1).padding(size * 0.25)
                RadialBars(values: norm, progress: snapshot ? 1 : progress, inner: inner)
                    .fill(.white.opacity(0.4))
                RadialBars(values: peakOnly, progress: snapshot ? 1 : progress, inner: inner)
                    .fill(accent)
                    .shadow(color: accent.opacity(0.8), radius: 14)
                ForEach([0, 6, 12, 18], id: \.self) { h in
                    let angle = Double(h) / 24 * 2 * .pi - .pi / 2
                    Text("\(h)")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .opacity(0.6)
                        .position(x: size / 2 + cos(angle) * (inner - 18), y: size / 2 + sin(angle) * (inner - 18))
                }
                Image(systemName: peak >= 6 && peak < 18 ? "sun.max.fill" : "moon.stars.fill")
                    .font(.system(size: 22))
                    .opacity(0.8)
            }
            .frame(width: size, height: size)
        }
        .onAppear { withAnimation(.spring(response: 1.4, dampingFraction: 0.8).delay(0.4)) { progress = 1 } }
    }
}

// MARK: - Calendar

struct CalendarSlide: View {
    let r: Report

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Eyebrow(text: "日历", accent: Palette.calendar.accent).reveal(0)
            Spacer(minLength: 12)
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                CountUp(target: Double(r.activeDays), delay: 0.2) { "\(Int($0.rounded()))" }
                    .font(.display(120))
                    .foregroundStyle(LinearGradient(colors: [.white, Palette.calendar.accent], startPoint: .top, endPoint: .bottom))
                Text("个活跃日").font(.system(size: 40, weight: .heavy))
            }
            .padding(.vertical, -8)
            .reveal(0.1)
            Text(r.longestStreak > 1 ? "最长一口气连续了 \(r.longestStreak) 天" : "每一天都算数")
                .font(.system(size: 20, weight: .medium)).opacity(0.75)
                .reveal(0.2)
            Spacer(minLength: 16)
            Heatmap(r: r).frame(height: 162).reveal(0.35)
            Spacer(minLength: 16)
            HStack(alignment: .bottom, spacing: 18) {
                if let b = r.busiestDay {
                    GlassCard {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("最忙的一天").font(.system(size: 14, weight: .semibold)).opacity(0.65)
                            Text(Fmt.day(b.day, withYear: r.year == nil)).font(.system(size: 30, weight: .heavy))
                            Text("\(Fmt.big(b.stat.tokens)) tokens · 你发了 \(b.stat.prompts) 条消息")
                                .font(.system(size: 15)).opacity(0.75)
                        }
                    }
                    .frame(width: 340)
                }
                MonthlyBars(months: r.series, accent: Palette.calendar.accent).frame(height: 112)
            }
            .reveal(0.5)
        }
    }
}

struct Heatmap: View {
    let r: Report

    var body: some View {
        let range = dayRange()
        let start = range.lowerBound - weekdayIndex(range.lowerBound)
        let weeks = (range.upperBound - start) / 7 + 1
        let values = r.days.mapValues { $0.tokens }
        let sorted = values.values.filter { $0 > 0 }.sorted()
        func level(_ v: Int64) -> Int {
            guard v > 0, !sorted.isEmpty else { return 0 }
            let idx = sorted.firstIndex { $0 >= v } ?? sorted.count - 1
            let q = Double(idx) / Double(max(1, sorted.count - 1))
            return q < 0.25 ? 1 : q < 0.5 ? 2 : q < 0.8 ? 3 : 4
        }
        let colors: [Color] = [.white.opacity(0.07), Palette.calendar.accent.opacity(0.3), Palette.calendar.accent.opacity(0.5),
                               Palette.calendar.accent.opacity(0.75), Palette.calendar.accent]
        return GeometryReader { geo in
            let cell = min((geo.size.width - CGFloat(weeks - 1) * 3) / CGFloat(weeks), (geo.size.height - 18 - 18) / 7)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 3) {
                    ForEach(0..<weeks, id: \.self) { w in
                        VStack(spacing: 3) {
                            ForEach(0..<7, id: \.self) { d in
                                let day = start + w * 7 + d
                                RoundedRectangle(cornerRadius: cell * 0.25)
                                    .fill(range.contains(day) ? colors[level(values[day] ?? 0)] : .clear)
                                    .frame(width: cell, height: cell)
                            }
                        }
                    }
                }
                HStack(spacing: 6) {
                    Text("少").font(.system(size: 11)).opacity(0.6)
                    ForEach(0..<5) { i in RoundedRectangle(cornerRadius: 2).fill(colors[i]).frame(width: 10, height: 10) }
                    Text("多").font(.system(size: 11)).opacity(0.6)
                    Spacer()
                    Text("\(Fmt.day(range.lowerBound, withYear: true)) – \(Fmt.day(range.upperBound, withYear: true))")
                        .font(.system(size: 11)).opacity(0.6)
                }
            }
        }
    }

    func dayRange() -> ClosedRange<DayKey> {
        if let y = r.year {
            let lo = LocalTime.dayKey(year: y, month: 1, day: 1)
            let hi = LocalTime.dayKey(year: y, month: 12, day: 31)
            return lo...hi
        }
        let hi = max(r.lastDay, LocalTime.today)
        return (hi - 52 * 7 - weekdayIndex(hi))...hi
    }

    func weekdayIndex(_ d: DayKey) -> Int { ((LocalTime.components(d).weekday ?? 1) + 5) % 7 }
}

struct MonthlyBars: View {
    let months: [(label: String, tokens: Int64)]
    let accent: Color
    @State private var grown = false
    @Environment(\.isSnapshot) private var snapshot

    var body: some View {
        let maxV = Double(max(1, months.map(\.tokens).max() ?? 1))
        let peak = months.indices.max { months[$0].tokens < months[$1].tokens } ?? 0
        let showEvery = max(1, months.count / 12)
        GeometryReader { geo in
            HStack(alignment: .bottom, spacing: 4) {
                ForEach(months.indices, id: \.self) { i in
                    VStack(spacing: 5) {
                        Spacer(minLength: 0)
                        RoundedRectangle(cornerRadius: 4)
                            .fill(i == peak ? accent : .white.opacity(0.3))
                            .frame(height: max(3, (geo.size.height - 20) * ((grown || snapshot) ? Double(months[i].tokens) / maxV : 0)))
                        Text(i % showEvery == 0 ? months[i].label : " ")
                            .font(.system(size: 10, weight: .medium)).opacity(i == peak ? 1 : 0.55)
                            .lineLimit(1).fixedSize()
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .onAppear { withAnimation(.spring(response: 1, dampingFraction: 0.8).delay(0.6)) { grown = true } }
    }
}

// MARK: - Projects

struct ProjectsSlide: View {
    let r: Report

    var body: some View {
        let top = Array(r.projects.prefix(5))
        VStack(alignment: .leading, spacing: 0) {
            Eyebrow(text: "项目", accent: Palette.projects.accent).reveal(0)
            Spacer(minLength: 12)
            Text("你在这些地方花了最多心思").font(.heading(32)).opacity(0.9).reveal(0.1)
            Spacer(minLength: 18)
            HStack(alignment: .top, spacing: 36) {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(Array(top.enumerated()), id: \.element.id) { i, p in
                        HStack(alignment: .center, spacing: 20) {
                            Text("\(i + 1)")
                                .font(.display(i == 0 ? 54 : 34))
                                .foregroundStyle(i == 0 ? Palette.projects.accent : .white.opacity(0.5))
                                .frame(width: 54, alignment: .leading)
                            VStack(alignment: .leading, spacing: 6) {
                                Text(p.name).font(.system(size: i == 0 ? 30 : 22, weight: .heavy)).lineLimit(1)
                                Text("\(Fmt.grouped(p.prompts)) 条消息 · \(p.sessions) 次对话 · \(Fmt.big(p.tokens)) tokens")
                                    .font(.system(size: 14)).opacity(0.65)
                            }
                        }
                        .reveal(0.2 + Double(i) * 0.09)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if let s = r.longestSession {
                    GlassCard(padding: 26) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("聊得最久的一次").font(.system(size: 14, weight: .semibold)).opacity(0.65)
                            Text(s.info.title ?? s.info.project)
                                .font(.system(size: 26, weight: .heavy)).lineLimit(3)
                            Text("\(s.info.agent.displayName) · \(s.info.project)")
                                .font(.system(size: 14)).opacity(0.7).lineLimit(1)
                            Divider().overlay(.white.opacity(0.2)).padding(.vertical, 4)
                            row("来回", "\(s.prompts) 轮")
                            row("跨度", Fmt.duration(s.duration))
                            row("消耗", "\(Fmt.big(s.tokens)) tokens")
                        }
                    }
                    .frame(width: 340)
                    .reveal(0.6)
                }
            }
        }
    }

    func row(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).opacity(0.65)
            Spacer()
            Text(v).fontWeight(.bold)
        }
        .font(.system(size: 16))
    }
}

// MARK: - Persona

struct PersonaSlide: View {
    let r: Report

    var body: some View {
        VStack(spacing: 0) {
            Eyebrow(text: "年度 AI 人格", accent: Palette.persona.accent).reveal(0)
            Spacer(minLength: 10)
            Image(systemName: r.persona.symbol)
                .font(.system(size: 76, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .shadow(color: Color(hex: 0xF72585).opacity(0.7), radius: 30)
                .reveal(0.15)
            Text(r.persona.title)
                .font(.display(112))
                .foregroundStyle(LinearGradient(colors: [.white, Color(hex: 0xFFC6E5), Color(hex: 0x9EE6FF)],
                                                startPoint: .leading, endPoint: .trailing))
                .padding(.top, 8)
                .reveal(0.3)
            Text(r.persona.blurb)
                .font(.system(size: 22, weight: .medium))
                .multilineTextAlignment(.center)
                .lineSpacing(6)
                .frame(maxWidth: 660)
                .opacity(0.85)
                .padding(.top, 10)
                .reveal(0.45)
            HStack(spacing: 12) {
                ForEach(r.persona.tags, id: \.self) { Chip(text: $0) }
            }
            .padding(.top, 28)
            .reveal(0.6)
            Spacer(minLength: 10)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Summary

struct SummarySlide: View {
    let ctx: StoryContext
    @State private var toast: String?

    var body: some View {
        HStack(spacing: 48) {
            ShareCard(r: ctx.report)
                .scaleEffect(0.82)
                .frame(width: ShareCard.size.width * 0.82, height: ShareCard.size.height * 0.82)
                .shadow(color: .black.opacity(0.5), radius: 40, y: 20)
                .reveal(0.1)
            VStack(alignment: .leading, spacing: 18) {
                Eyebrow(text: "就是这样", accent: .white)
                Text("这是你的\n\(summaryName)")
                    .font(.heading(40))
                    .lineSpacing(4)
                Text(ctx.report.period.isWeek ? "保存成图片，下周再来看看有没有进步。"
                     : ctx.report.period.isShort ? "保存成图片，下个月再来对比。" : "保存成图片发给朋友，或者明年再来对比。")
                    .font(.system(size: 17)).opacity(0.7)
                VStack(alignment: .leading, spacing: 12) {
                    action("保存为图片…", "square.and.arrow.down", primary: true) {
                        if CardExporter.save(ctx.report) { flash("已保存") }
                    }
                    action("复制图片", "doc.on.doc") {
                        CardExporter.copy(ctx.report)
                        flash("已复制到剪贴板")
                    }
                    action("从头再看一遍", "arrow.counterclockwise", action: ctx.restart)
                }
                .padding(.top, 8)
                Text(toast ?? " ")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color(hex: 0x9EE6FF))
                Spacer().frame(height: 4)
                Label("所有数据均在本机读取与计算，没有上传任何内容", systemImage: "lock.fill")
                    .font(.system(size: 13)).opacity(0.55)
            }
            .reveal(0.3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var summaryName: String {
        let p = ctx.report.period
        switch p {
        case .year(let y): return "\(String(y)) 年 AI 年度报告"
        case .all: return "全部 AI 年度报告"
        case .thisWeek, .lastWeek: return "\(p.label) AI 周报"
        case .thisMonth: return "\(p.badge()) AI 月报"
        }
    }

    func flash(_ s: String) {
        withAnimation { toast = s }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { withAnimation { toast = nil } }
    }

    func action(_ title: String, _ icon: String, primary: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(primary ? Color(hex: 0x1C0B36) : .white)
                .padding(.horizontal, 22)
                .padding(.vertical, 13)
                .frame(width: 230, alignment: .leading)
                .background(Capsule().fill(primary ? AnyShapeStyle(.white) : AnyShapeStyle(.white.opacity(0.12))))
                .overlay(Capsule().strokeBorder(.white.opacity(primary ? 0 : 0.2)))
        }
        .buttonStyle(.plain)
    }
}
