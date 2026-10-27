import AppKit
import SwiftUI

/// Headless entry points: `--dump` prints the numbers, `--snapshot DIR` renders every
/// slide to PNG, `--icon PATH` renders the 1024px app icon.
enum CLI {
    static func scanAndBuild(year: Int?) -> (ScanResult, Report) {
        let began = Date()
        let scan = LocalScanner.scanAll { _, _ in }
        let years = Report.availableYears(scan)
        let y = CommandLine.arguments.contains("--all") ? nil : (year ?? years.last)
        let report = Report.build(scan, year: y)
        FileHandle.standardError.write("scanned in \(String(format: "%.2f", Date().timeIntervalSince(began)))s, years \(years)\n".data(using: .utf8)!)
        return (scan, report)
    }

    static func dump(year: Int?) {
        let (scan, r) = scanAndBuild(year: year)
        print("records: usage=\(scan.usage.count) prompts=\(scan.prompts.count) tools=\(scan.tools.count) sessions=\(scan.sessions.count)")
        print("== \(r.title)")
        print("tokens total=\(r.tokens.total) in=\(r.tokens.input) out=\(r.tokens.output) cacheR=\(r.tokens.cacheRead) cacheW=\(r.tokens.cacheWrite)")
        print("sessions=\(r.sessionCount) prompts=\(r.promptCount) chars=\(r.charCount) activeDays=\(r.activeDays) streak=\(r.longestStreak)")
        print("agents:"); r.agents.forEach { print("  \($0.agent.displayName) tokens=\($0.tokens) sessions=\($0.sessions) prompts=\($0.prompts)") }
        print("models:"); r.models.prefix(8).forEach { print("  \($0.name) [\($0.agent.displayName)] tokens=\($0.tokens) calls=\($0.calls)") }
        print("tool calls=\(r.toolCallCount) skills=\(r.skillCount) subagents=\(r.subagentCount)")
        print("categories:", r.toolCategories.prefix(12).map { "\($0.name)=\($0.count)" }.joined(separator: ", "))
        print("raw tools:", r.rawTools.prefix(15).map { "\($0.name)=\($0.count)" }.joined(separator: ", "))
        print("skills:", r.skills.prefix(8).map { "\($0.name)=\($0.count)" }.joined(separator: ", "))
        print("subagents:", r.subagents.prefix(8).map { "\($0.name)=\($0.count)" }.joined(separator: ", "))
        print("projects:", r.projects.prefix(8).map { "\($0.name)(\($0.prompts)/\($0.sessions))" }.joined(separator: ", "))
        print("hourly:", r.hourly, "peak", r.peakHour)
        print("weekday:", r.weekday)
        print("monthly:", r.monthly.map { "\($0.label)=\(Fmt.big($0.tokens))" }.joined(separator: " "))
        if let p = r.firstPrompt { print("first:", Fmt.day(LocalTime.day(p.time), withYear: true), Fmt.clock(p.time), p.agent.displayName, p.preview.prefix(60)) }
        if let p = r.lateNight { print("late:", Fmt.clock(p.time), p.preview.prefix(60), "count", r.lateNightCount) }
        if let b = r.busiestDay { print("busiest:", Fmt.day(b.day, withYear: true), b.stat.tokens, b.stat.prompts) }
        if let s = r.longestSession { print("longest:", s.info.title ?? s.info.project, s.prompts, Fmt.duration(s.duration)) }
        print("persona:", r.persona.title, r.persona.tags)
    }

    @MainActor
    static func snapshot(to dir: String, year: Int?) {
        let (scan, r) = scanAndBuild(year: year)
        let slides = Slide.list(for: r)
        let ctx = StoryContext(report: r, years: Report.availableYears(scan))
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for (i, s) in slides.enumerated() {
            let view = StoryPage(slides: slides, index: i, ctx: ctx)
                .frame(width: 1200, height: 790)
                .environment(\.isSnapshot, true)
            write(view, to: "\(dir)/\(String(format: "%02d", i))-\(s).png", scale: 1)
        }
        if let data = CardExporter.png(r) {
            try? data.write(to: URL(fileURLWithPath: "\(dir)/card.png"))
        }
        print("wrote \(slides.count) slides to \(dir)")
    }

    @MainActor
    static func renderIcon(to path: String) {
        write(AppIcon().environment(\.isSnapshot, true), to: path, scale: 1)
    }

    @MainActor
    private static func write<V: View>(_ view: V, to path: String, scale: CGFloat) {
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        guard let cg = renderer.cgImage,
              let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else {
            print("failed to render \(path)")
            return
        }
        try? data.write(to: URL(fileURLWithPath: path))
    }
}

struct AppIcon: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 186, style: .continuous)
                .fill(.clear)
                .background(MeshBackground(palette: .cover, animated: false))
                .clipShape(RoundedRectangle(cornerRadius: 186, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 186, style: .continuous).strokeBorder(.white.opacity(0.18), lineWidth: 4))
            HStack(alignment: .bottom, spacing: 34) {
                ForEach([0.38, 0.62, 0.48, 0.86], id: \.self) { h in
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .fill(LinearGradient(colors: [.white, Color(hex: 0xFFD3A8)], startPoint: .top, endPoint: .bottom))
                        .frame(width: 92, height: 470 * h)
                }
            }
            .offset(y: 70)
            Image(systemName: "sparkle")
                .font(.system(size: 210, weight: .bold))
                .foregroundStyle(.white)
                .shadow(color: Color(hex: 0xE04F8B), radius: 40)
                .offset(x: 196, y: -230)
        }
        .frame(width: 824, height: 824)
        .shadow(color: .black.opacity(0.35), radius: 24, y: 12)
        .frame(width: 1024, height: 1024)
    }
}
