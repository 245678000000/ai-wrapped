import AppKit
import SwiftUI

// MARK: - Snapshot flag (render final animation state, used for PNG export)

private struct SnapshotKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    var isSnapshot: Bool {
        get { self[SnapshotKey.self] }
        set { self[SnapshotKey.self] = newValue }
    }
}

// MARK: - Video time (render one frame of a page's entrance, used for video export)

private struct VideoTimeKey: EnvironmentKey { static let defaultValue: Double? = nil }

extension EnvironmentValues {
    /// Seconds since the page appeared while rendering video frames. Animated views read their
    /// state from it instead of animating.
    var videoTime: Double? {
        get { self[VideoTimeKey.self] }
        set { self[VideoTimeKey.self] = newValue }
    }
}

/// How far a spring started `delay` seconds into the page has come by `t`, 0…1.
func settled(_ t: Double, delay: Double, response: Double) -> Double {
    let x = min(1, max(0, (t - delay) / (response * 1.25)))
    return 1 - pow(1 - x, 3)
}

// MARK: - Color

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }
}

struct Palette {
    let mesh: [Color]
    let accent: Color

    init(_ hexes: [UInt32], accent: UInt32) {
        mesh = hexes.map { Color(hex: $0) }
        self.accent = Color(hex: accent)
    }

    static let cover = Palette([0x0E0624, 0x2A0B52, 0x12052E, 0x5B1AA8, 0xE04F8B, 0x3D0E7A, 0x1A0838, 0xF08A4B, 0x2B0A4F], accent: 0xFFB36B)
    static let first = Palette([0x03141F, 0x07344A, 0x04202E, 0x0B4F6C, 0x1FA4A9, 0x0A3550, 0x021018, 0x2C7DA0, 0x06283A], accent: 0x7FE7E0)
    static let tokens = Palette([0x2A0A05, 0x6B1A0E, 0x3A0C08, 0xB23A1B, 0xF2733A, 0x7A1E12, 0x3D0B07, 0xE2A23B, 0x5A140C], accent: 0xFFD08A)
    static let talk = Palette([0x031A14, 0x0A4033, 0x05261D, 0x0F6B4F, 0x2EC4A0, 0x0B5040, 0x021511, 0x6FBF7A, 0x073326], accent: 0xB8F5C9)
    static let agents = Palette([0x070B2E, 0x16207A, 0x0A0F3F, 0x2B3BD1, 0x6C7BFF, 0x1A238F, 0x05082A, 0x9D5CFF, 0x10176A], accent: 0xB8C1FF)
    static let models = Palette([0x2A0716, 0x6E1340, 0x3A0A20, 0xB0245E, 0xFF6F91, 0x7D1A48, 0x2C0715, 0xF59A85, 0x5A0F35], accent: 0xFFD1DC)
    static let tools = Palette([0x07170A, 0x15401C, 0x0A2210, 0x246B2C, 0x8CCB52, 0x1C5224, 0x051208, 0xC9DB5A, 0x123A18], accent: 0xE6FF8A)
    static let rhythm = Palette([0x040516, 0x121A4A, 0x070A24, 0x26307A, 0x5B4BD6, 0x1A2160, 0x02030E, 0x2F7FD8, 0x0D1440], accent: 0x9DB8FF)
    static let calendar = Palette([0x0A0F14, 0x17252E, 0x0D161C, 0x1E3A3A, 0x22875A, 0x183032, 0x060A0D, 0x2DB37E, 0x12221F], accent: 0x7CFFC4)
    static let projects = Palette([0x1F0507, 0x5C0F14, 0x2E070A, 0x9E1B22, 0xF2552F, 0x701219, 0x1A0405, 0xE8952A, 0x4A0C10], accent: 0xFFC78A)
    static let persona = Palette([0x0B0420, 0x3A0E6E, 0x081230, 0x7B2FF7, 0xE0237C, 0x4361EE, 0x10062A, 0x3BB4E0, 0x2A0E55], accent: 0xFFFFFF)
    // Weekly/monthly mode: a night-sky indigo with teal light, kin to the yearly purples.
    static let weeklyCover = Palette([0x0A0820, 0x1A1550, 0x0B1030, 0x3B2C9E, 0x2FB5C9, 0x22357A, 0x070618, 0x8B5CF6, 0x161340], accent: 0x9EF0FF)
    static let weekly = Palette([0x060F1F, 0x0E2A4A, 0x0A1830, 0x1C4E80, 0x2E8FB8, 0x183A66, 0x050C18, 0x5B4FD6, 0x0F2240], accent: 0x8FE3FF)
    static let summary = Palette([0x07040F, 0x1C0B36, 0x0A0A1E, 0x2E1460, 0x5A1F6E, 0x1E2A66, 0x05030C, 0x183A5C, 0x150A2C], accent: 0xFFFFFF)
}

extension AgentKind {
    var color: Color {
        if let tint { return Color(hex: tint) }
        let fallback: [UInt32] = [0x9EE6FF, 0xF7A8D8, 0xB8F06A, 0xFFD27F, 0x9AA8FF, 0x7FE7C4, 0xFFA07A, 0xD7B4FF]
        var h: UInt32 = 5381
        for b in id.utf8 { h = (h &* 33) &+ UInt32(b) }
        return Color(hex: fallback[Int(h % UInt32(fallback.count))])
    }
}

// MARK: - Background

enum Grain {
    static let image: Image = {
        let w = 160, h = 160
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        for i in 0..<(w * h) {
            let v = UInt8.random(in: 0...255)
            bytes[i * 4] = v; bytes[i * 4 + 1] = v; bytes[i * 4 + 2] = v; bytes[i * 4 + 3] = 255
        }
        let cg = bytes.withUnsafeMutableBytes { ptr -> CGImage in
            let ctx = CGContext(data: ptr.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            return ctx.makeImage()!
        }
        return Image(decorative: cg, scale: 1)
    }()
}

struct MeshBackground: View {
    let palette: Palette
    var animated = true
    @Environment(\.isSnapshot) private var snapshot
    @Environment(\.videoTime) private var videoTime

    var body: some View {
        Group {
            if animated, let videoTime {
                mesh(t: 2.4 + videoTime * 1.2)
            } else if snapshot || !animated {
                mesh(t: 2.4)
            } else {
                TimelineView(.animation(minimumInterval: 1 / 30)) { ctx in
                    mesh(t: ctx.date.timeIntervalSinceReferenceDate)
                }
            }
        }
        .overlay(Grain.image.resizable(resizingMode: .tile).opacity(0.06).blendMode(.overlay))
        .overlay(LinearGradient(colors: [.black.opacity(0.25), .clear, .black.opacity(0.35)], startPoint: .top, endPoint: .bottom))
    }

    private func mesh(t: Double) -> some View {
        func s(_ speed: Double, _ phase: Double, _ amp: Float) -> Float { Float(sin(t * speed + phase)) * amp }
        let points: [SIMD2<Float>] = [
            [0, 0], [0.5 + s(0.23, 0, 0.18), 0], [1, 0],
            [0, 0.5 + s(0.19, 1, 0.2)], [0.5 + s(0.31, 2, 0.2), 0.5 + s(0.27, 3, 0.2)], [1, 0.5 + s(0.21, 4, 0.2)],
            [0, 1], [0.5 + s(0.25, 5, 0.18), 1], [1, 1],
        ]
        return MeshGradient(width: 3, height: 3, points: points, colors: palette.mesh, smoothsColors: true)
    }
}

// MARK: - Motion

struct Reveal: ViewModifier {
    let delay: Double
    @State private var shown = false
    @Environment(\.isSnapshot) private var snapshot
    @Environment(\.videoTime) private var videoTime

    func body(content: Content) -> some View {
        let p = videoTime.map { settled($0, delay: delay, response: 0.75) } ?? (shown || snapshot ? 1 : 0)
        content
            .opacity(p)
            .offset(y: (1 - p) * 26)
            .blur(radius: (1 - p) * 10)
            .onAppear {
                withAnimation(.spring(response: 0.75, dampingFraction: 0.86).delay(delay)) { shown = true }
            }
    }
}

extension View {
    func reveal(_ delay: Double = 0) -> some View { modifier(Reveal(delay: delay)) }
}

private struct AnimatedNumberText: View, Animatable {
    var value: Double
    let format: (Double) -> String
    var animatableData: Double {
        get { value }
        set { value = newValue }
    }
    var body: some View { Text(format(value)).monospacedDigit() }
}

/// A number that counts up from zero when it appears.
struct CountUp: View {
    let target: Double
    var delay: Double = 0.2
    var duration: Double = 1.6
    let format: (Double) -> String
    @State private var value: Double = 0
    @Environment(\.isSnapshot) private var snapshot
    @Environment(\.videoTime) private var videoTime

    var body: some View {
        AnimatedNumberText(value: videoTime.map { target * countCurve($0) } ?? (snapshot ? target : value), format: format)
            .onAppear {
                withAnimation(.timingCurve(0.16, 1, 0.3, 1, duration: duration).delay(delay)) { value = target }
            }
    }

    /// Close to the live timing curve: a fast start and a long settle.
    private func countCurve(_ t: Double) -> Double {
        let x = min(1, max(0, (t - delay) / duration))
        return 1 - pow(1 - x, 5)
    }
}

/// Horizontal bar that grows to `fraction` of the available width.
struct GrowBar: View {
    let fraction: Double
    var color: Color = .white
    var height: CGFloat = 14
    var delay: Double = 0.3
    @State private var grown = false
    @Environment(\.isSnapshot) private var snapshot
    @Environment(\.videoTime) private var videoTime

    var body: some View {
        let g = videoTime.map { settled($0, delay: delay, response: 1.0) } ?? (grown || snapshot ? 1 : 0)
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.1))
                Capsule()
                    .fill(LinearGradient(colors: [color.opacity(0.75), color], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(height, geo.size.width * min(1, max(0, fraction)) * g))
                    .opacity(min(1, g * 3))
            }
        }
        .frame(height: height)
        .onAppear {
            withAnimation(.spring(response: 1.0, dampingFraction: 0.85).delay(delay)) { grown = true }
        }
    }
}

// MARK: - Building blocks

struct Eyebrow: View {
    let text: String
    var accent: Color = .white
    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(accent).frame(width: 7, height: 7)
            Text(text)
                .font(.system(size: 13, weight: .semibold))
                .tracking(3.5)
                .foregroundStyle(.white.opacity(0.75))
        }
    }
}

struct GlassCard<Content: View>: View {
    var padding: CGFloat = 22
    @ViewBuilder let content: Content
    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(.white.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.white.opacity(0.14), lineWidth: 1))
    }
}

struct Chip: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 15, weight: .semibold))
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(Capsule().fill(.white.opacity(0.12)))
            .overlay(Capsule().strokeBorder(.white.opacity(0.22), lineWidth: 1))
    }
}

extension Font {
    static func display(_ size: CGFloat) -> Font { .system(size: size, weight: .black, design: .rounded) }
    static func heading(_ size: CGFloat) -> Font { .system(size: size, weight: .bold) }
}

// MARK: - Formatting

enum Fmt {
    static func scale(for v: Double) -> (divisor: Double, unit: String, digits: Int) {
        if v >= 1e8 { return (1e8, "亿", 2) }
        if v >= 1e7 { return (1e4, "万", 0) }
        if v >= 1e4 { return (1e4, "万", 1) }
        return (1, "", 0)
    }

    /// Number portion only, using the unit chosen for `reference` so count-ups don't jump units.
    static func scaled(_ v: Double, like reference: Double) -> String {
        let s = scale(for: reference)
        if s.divisor == 1 { return grouped(Int(v.rounded())) }
        return String(format: "%.\(s.digits)f", v / s.divisor)
    }

    static func unit(_ reference: Double) -> String { scale(for: reference).unit }

    static func big(_ v: Double) -> String { scaled(v, like: v) + unit(v) }
    static func big(_ v: Int64) -> String { big(Double(v)) }
    static func big(_ v: Int) -> String { big(Double(v)) }

    static func grouped(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    /// "$3,512", "$42.37", "$1.25M"; precision follows `reference` so count-ups keep their shape.
    static func usd(_ v: Double, like reference: Double? = nil) -> String {
        let ref = reference ?? v
        if ref >= 1e6 { return String(format: "$%.2fM", v / 1e6) }
        if ref >= 100 { return "$" + grouped(Int(v.rounded())) }
        if v > 0 && v < 0.01 { return "<$0.01" }
        return String(format: "$%.2f", v)
    }

    static func percent(_ part: Double, of whole: Double) -> String {
        guard whole > 0 else { return "0%" }
        let p = part / whole * 100
        return p >= 10 || p == 0 ? "\(Int(p.rounded()))%" : String(format: "%.1f%%", p)
    }

    static func day(_ d: DayKey, withYear: Bool = false) -> String {
        let c = LocalTime.components(d)
        let md = "\(c.month ?? 0) 月 \(c.day ?? 0) 日"
        return withYear ? "\(c.year ?? 0) 年 " + md : md
    }

    static func shortDay(_ d: DayKey) -> String {
        let c = LocalTime.components(d)
        return "\(c.month ?? 0)/\(c.day ?? 0)"
    }

    static func clock(_ t: Double) -> String {
        let m = LocalTime.minuteOfDay(t)
        return String(format: "%02d:%02d", m / 60, m % 60)
    }

    static func duration(_ s: Double) -> String {
        let minutes = Int(s / 60)
        if minutes < 60 { return "\(max(1, minutes)) 分钟" }
        let hours = minutes / 60
        if hours < 48 { return "\(hours) 小时 \(minutes % 60) 分" }
        return "\(hours / 24) 天 \(hours % 24) 小时"
    }

    static func weekdayName(_ i: Int) -> String { ["一", "二", "三", "四", "五", "六", "日"][i] }
}
