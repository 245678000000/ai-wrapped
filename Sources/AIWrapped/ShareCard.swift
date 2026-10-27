import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The vertical card that gets exported as a PNG.
struct ShareCard: View {
    static let size = CGSize(width: 600, height: 780)
    let r: Report

    var body: some View {
        ZStack {
            MeshBackground(palette: short ? .weeklyCover : .persona, animated: false)
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("AI WRAPPED").font(.system(size: 13, weight: .bold)).tracking(4)
                    Spacer()
                    Text(short ? r.period.rangeText() : r.period.badge()).font(.display(18))
                }
                .opacity(0.85)

                Text(short ? "\(r.period.label) AI 人格 · \(r.period.badge())" : "年度 AI 人格")
                    .font(.system(size: 14, weight: .semibold)).opacity(0.7).padding(.top, 34)
                HStack(spacing: 14) {
                    Image(systemName: r.persona.symbol).font(.system(size: 40, weight: .semibold))
                    Text(r.persona.title).font(.display(56))
                }
                .padding(.top, 4)
                HStack(spacing: 8) {
                    ForEach(r.persona.tags.prefix(3), id: \.self) { t in
                        Text(t).font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Capsule().fill(.white.opacity(0.15)))
                    }
                }
                .padding(.top, 10)

                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 18) {
                    GridRow {
                        cell("Tokens", Fmt.big(r.tokens.total), r.tokens.total, r.previous?.tokens)
                        cell("对话", Fmt.grouped(r.sessionCount) + " 次", r.sessionCount, r.previous?.sessions)
                    }
                    GridRow {
                        cell("消息", Fmt.grouped(r.promptCount) + " 条", r.promptCount, r.previous?.prompts)
                        cell("活跃", "\(r.activeDays) 天", r.activeDays, r.previous?.activeDays)
                    }
                    GridRow {
                        cell("头号搭档", r.topAgent?.agent.displayName ?? "—")
                        cell("最爱模型", r.topModel?.name ?? "—")
                    }
                    GridRow {
                        cell("用过的 agent", "\(r.agents.count) 个")
                        cell("工具调用", Fmt.big(r.toolCallCount) + " 次")
                    }
                }
                .padding(.top, 26)

                Spacer(minLength: 16)
                MonthlyBars(months: r.series, accent: Color(hex: short ? 0x9EF0FF : 0x9EE6FF)).frame(height: 70)
                HStack {
                    Text(short
                         ? "箭头对比\(r.comparisonLabel) · 最常在 \(r.peakHour) 点出没 · 敲下 \(Fmt.big(r.charCount)) 字"
                         : "最常在 \(r.peakHour) 点出没 · 最长连续 \(r.longestStreak) 天 · 敲下 \(Fmt.big(r.charCount)) 字")
                    Spacer()
                    Text("本机生成")
                }
                .font(.system(size: 12, weight: .medium))
                .opacity(0.6)
                .padding(.top, 14)
            }
            .padding(40)
        }
        .foregroundStyle(.white)
        .frame(width: Self.size.width, height: Self.size.height)
        .clipShape(RoundedRectangle(cornerRadius: 36, style: .continuous))
        .environment(\.isSnapshot, true)
    }

    private var short: Bool { r.period.isShort }

    func cell<N: BinaryInteger>(_ k: String, _ v: String, _ current: N, _ previous: N?) -> some View {
        cell(k, v, delta: short ? DeltaChip(current: Double(current), previous: previous.map(Double.init)) : nil)
    }

    func cell(_ k: String, _ v: String, delta: DeltaChip? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(k).font(.system(size: 13, weight: .semibold)).opacity(0.65)
                Spacer(minLength: 4)
                if let delta { delta.scaleEffect(0.82, anchor: .trailing).padding(.vertical, -4) }
            }
            Text(v).font(.system(size: 26, weight: .heavy, design: .rounded)).lineLimit(1).minimumScaleFactor(0.6)
        }
        .padding(16)
        .frame(width: 242, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.white.opacity(0.1)))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.15)))
    }
}

@MainActor
enum CardExporter {
    static func image(_ r: Report) -> NSImage? {
        let renderer = ImageRenderer(content: ShareCard(r: r))
        renderer.scale = 2
        renderer.isOpaque = false
        return renderer.nsImage
    }

    static func png(_ r: Report) -> Data? {
        let renderer = ImageRenderer(content: ShareCard(r: r))
        renderer.scale = 2
        guard let cg = renderer.cgImage else { return nil }
        return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
    }

    @discardableResult
    static func save(_ r: Report) -> Bool {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        let kind = r.period.isWeek ? "AI周报" : r.period.isShort ? "AI月报" : "AI年度报告"
        panel.nameFieldStringValue = "\(kind)-\(r.period.fileTag).png"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url, let data = png(r) else { return false }
        return (try? data.write(to: url)) != nil
    }

    static func copy(_ r: Report) {
        guard let img = image(r) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([img])
    }
}
