import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct AIWrappedApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()

    init() {
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        Window("AI 年度报告", id: "main") {
            RootView()
                .environmentObject(model)
                .frame(minWidth: 1100, minHeight: 720)
                .onAppear {
                    NSApp.activate(ignoringOtherApps: true)
                    model.start()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1200, height: 790)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("报告") {
                Button("重新扫描") { model.start() }.keyboardShortcut("r")
                Button("回到封面") { model.slideIndex = 0 }.keyboardShortcut(.home, modifiers: [])
            }
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    enum Phase { case scanning, ready, empty }

    @Published var phase: Phase = .scanning
    @Published var progress: Double = 0
    @Published var progressLabel = "准备中"
    @Published var years: [Int] = []
    @Published var report: Report?
    @Published var slideIndex = 0
    private var scan: ScanResult?
    private var scanning = false

    func start() {
        guard !scanning else { return }
        scanning = true
        phase = .scanning
        progress = 0
        progressLabel = "准备中"
        let began = Date()
        Task.detached(priority: .userInitiated) {
            let result = LocalScanner.scanAll { p, label in
                Task { @MainActor in
                    self.progress = max(self.progress, p)
                    self.progressLabel = label
                }
            }
            let years = Report.availableYears(result)
            // Let the loading screen breathe for a moment even on a fast scan.
            let elapsed = Date().timeIntervalSince(began)
            if elapsed < 1.4 { try? await Task.sleep(nanoseconds: UInt64((1.4 - elapsed) * 1e9)) }
            await MainActor.run { self.finish(result, years: years) }
        }
    }

    private func finish(_ result: ScanResult, years: [Int]) {
        scanning = false
        scan = result
        self.years = years
        let current = Calendar.current.component(.year, from: Date())
        select(year: years.contains(current) ? current : years.last)
    }

    func select(year: Int?) {
        guard let scan else { return }
        let r = Report.build(scan, year: year)
        withAnimation(.easeInOut(duration: 0.5)) {
            report = r
            slideIndex = 0
            phase = r.isEmpty ? .empty : .ready
        }
    }
}

struct RootView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ZStack {
            switch model.phase {
            case .scanning:
                LoadingView(progress: model.progress, label: model.progressLabel)
                    .transition(.opacity)
            case .empty:
                EmptyStateView()
                    .transition(.opacity)
            case .ready:
                if let report = model.report {
                    StoryView(report: report)
                        .transition(.opacity)
                }
            }
        }
        .background(Color(hex: 0x07040F))
        .ignoresSafeArea()
    }
}

struct LoadingView: View {
    let progress: Double
    let label: String
    @State private var pulse = false

    var body: some View {
        ZStack {
            MeshBackground(palette: .cover)
            VStack(spacing: 26) {
                Image(systemName: "sparkles")
                    .font(.system(size: 54, weight: .semibold))
                    .symbolEffect(.pulse, options: .repeating)
                Text("正在翻阅你和 AI 的聊天记录…")
                    .font(.heading(30))
                VStack(spacing: 10) {
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.15))
                        Capsule().fill(.white)
                            .frame(width: max(8, 420 * progress))
                            .animation(.easeOut(duration: 0.3), value: progress)
                    }
                    .frame(width: 420, height: 8)
                    Text("\(label) · \(Int(progress * 100))%")
                        .font(.system(size: 14, weight: .medium)).monospacedDigit()
                        .opacity(0.7)
                }
                // Verbatim: a literal with two "~" would render as Markdown strikethrough.
                Label { Text(verbatim: "只在本机读取 ~/.claude、~/.codex 等 20 多个 agent 的目录，不会上传任何内容") }
                    icon: { Image(systemName: "lock.fill") }
                    .font(.system(size: 13)).opacity(0.55)
                    .padding(.top, 20)
            }
            .foregroundStyle(.white)
        }
    }
}

struct EmptyStateView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ZStack {
            MeshBackground(palette: .summary)
            VStack(spacing: 18) {
                Image(systemName: "tray").font(.system(size: 54))
                Text("没有找到本地的 agent 记录").font(.heading(30))
                Text("目前支持 Claude Code、Codex、ZCode、Factory Droid 和 OpenCode。\n用它们聊过之后再回来看看吧。")
                    .multilineTextAlignment(.center).opacity(0.7)
                Button("重新扫描") { model.start() }
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 8)
            }
            .foregroundStyle(.white)
        }
    }
}
