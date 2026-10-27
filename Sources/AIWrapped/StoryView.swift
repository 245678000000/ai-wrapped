import AppKit
import SwiftUI

/// Background + slide + chrome for one page; shared by the live story and PNG snapshots.
struct StoryPage: View {
    let slides: [Slide]
    let index: Int
    let ctx: StoryContext

    var body: some View {
        ZStack {
            MeshBackground(palette: slides[index].palette)
                .id(index)
                .transition(.opacity)
            SlideView(slide: slides[index], ctx: ctx)
                .id("slide-\(index)")
                .transition(.asymmetric(insertion: .opacity.combined(with: .offset(x: 40)),
                                        removal: .opacity.combined(with: .offset(x: -40))))
            VStack {
                ProgressSegments(count: slides.count, index: index)
                    .padding(.leading, 90)
                    .padding(.trailing, 28)
                    .padding(.top, 18)
                Spacer()
            }
        }
    }
}

struct StoryView: View {
    let report: Report
    @EnvironmentObject private var model: AppModel
    @State private var keyMonitor: Any?

    private var slides: [Slide] { Slide.list(for: report) }

    var body: some View {
        let ctx = StoryContext(
            report: report,
            years: model.years,
            selectYear: { model.select(year: $0) },
            next: { go(+1) },
            restart: { go(to: 0) },
            rescan: { model.start() }
        )
        let index = min(model.slideIndex, slides.count - 1)
        ZStack {
            StoryPage(slides: slides, index: index, ctx: ctx)
                .contentShape(Rectangle())
                .gesture(SpatialTapGesture().onEnded { value in
                    guard slides[index] != .summary && slides[index] != .cover else { return }
                    go(value.location.x < 260 ? -1 : +1)
                })
            VStack {
                Spacer()
                bottomBar(index: index)
            }
        }
        .onAppear { installKeys() }
        .onDisappear { removeKeys() }
    }

    private func bottomBar(index: Int) -> some View {
        HStack(spacing: 14) {
            Text("AI WRAPPED · \(report.title)")
                .font(.system(size: 12, weight: .semibold)).tracking(2)
                .opacity(0.5)
            Spacer()
            Text("\(index + 1) / \(slides.count)")
                .font(.system(size: 13, weight: .semibold)).monospacedDigit()
                .opacity(0.6)
            navButton("chevron.left", disabled: index == 0) { go(-1) }
            navButton("chevron.right", disabled: index == slides.count - 1) { go(+1) }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 28)
        .padding(.bottom, 22)
    }

    private func navButton(_ icon: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .bold))
                .frame(width: 38, height: 38)
                .background(Circle().fill(.white.opacity(0.14)))
                .overlay(Circle().strokeBorder(.white.opacity(0.2)))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.35 : 1)
    }

    private func go(_ delta: Int) { go(to: model.slideIndex + delta) }

    private func go(to target: Int) {
        let clamped = max(0, min(slides.count - 1, target))
        guard clamped != model.slideIndex else { return }
        withAnimation(.easeInOut(duration: 0.55)) { model.slideIndex = clamped }
    }

    private func installKeys() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.modifierFlags.intersection([.command, .option, .control]).isEmpty else { return event }
            switch event.keyCode {
            case 124, 49, 36, 125: go(+1); return nil   // → space return ↓
            case 123, 126: go(-1); return nil           // ← ↑
            default: return event
            }
        }
    }

    private func removeKeys() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }
}

struct ProgressSegments: View {
    let count: Int
    let index: Int

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<count, id: \.self) { i in
                Capsule()
                    .fill(.white.opacity(i < index ? 0.75 : i == index ? 1 : 0.22))
                    .frame(height: 3)
            }
        }
        .animation(.easeInOut(duration: 0.4), value: index)
    }
}
