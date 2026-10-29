import AVFoundation
import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Timeline

/// The report as a short video: the same pages as the app, each playing its entrance and then
/// crossfading into the next. Animations read the frame's time (`\.videoTime`), so every frame
/// renders on its own.
struct VideoTimeline {
    /// The app's page size, rendered at 1.6× for a 1920×1264 video.
    static let size = CGSize(width: 1200, height: 790)
    static let scale = 1.6
    static let fps = 30
    /// Crossfade between consecutive pages, in seconds.
    static let fade = 0.5
    /// The video opens on a cover that has already settled, so its first frame works as a thumbnail.
    static let coverLead = 1.4

    let ctx: StoryContext
    let slides: [Slide]
    let pages: [(start: Double, duration: Double)]
    let duration: Double

    init(_ r: Report, years: [Int]) {
        ctx = StoryContext(report: r, years: years)
        slides = Slide.list(for: r)
        var t = 0.0
        var out: [(Double, Double)] = []
        for s in slides {
            let length = Self.length(of: s)
            out.append((t, length))
            t += length - Self.fade
        }
        pages = out
        duration = t + Self.fade
    }

    /// Long enough for a page's entrance and count-ups to finish and be read.
    private static func length(of s: Slide) -> Double {
        switch s {
        case .cover: return 2.6
        case .summary: return 5.0
        case .week, .tokens, .agents, .rhythm, .persona: return 4.2
        default: return 3.8
        }
    }

    var frameCount: Int { Int((duration * Double(Self.fps)).rounded(.up)) }
}

// MARK: - Frame

/// One frame of the video at `time` seconds.
struct VideoFrame: View {
    let timeline: VideoTimeline
    let time: Double

    var body: some View {
        let pages = timeline.pages
        let last = pages.count - 1
        let current = pages.lastIndex { time >= $0.start } ?? 0
        let visible = pages.indices.filter { time >= pages[$0].start && (time < pages[$0].start + pages[$0].duration || $0 == last) }
        ZStack {
            // The outgoing page stays underneath while the next one fades in over it.
            ForEach(visible, id: \.self) { i in
                StoryPage(slides: timeline.slides, index: i, ctx: timeline.ctx)
                    .environment(\.videoTime, time - pages[i].start + (i == 0 ? VideoTimeline.coverLead : 0))
                    .opacity(i == 0 ? 1 : min(1, (time - pages[i].start) / VideoTimeline.fade))
            }
            VStack {
                Spacer()
                HStack {
                    Text("AI WRAPPED · \(timeline.ctx.report.title)")
                        .font(.system(size: 12, weight: .semibold)).tracking(2)
                        .opacity(0.5)
                    Spacer()
                    Text("\(current + 1) / \(pages.count)")
                        .font(.system(size: 13, weight: .semibold)).monospacedDigit()
                        .opacity(0.6)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 28)
                .padding(.bottom, 26)
            }
        }
        .frame(width: VideoTimeline.size.width, height: VideoTimeline.size.height)
        .clipped()
        .environment(\.isSnapshot, true)
    }
}

// MARK: - Export

@MainActor
enum VideoExporter {
    enum Failure: LocalizedError {
        case writer(String)
        var errorDescription: String? {
            switch self { case .writer(let s): return s }
        }
    }

    /// Asks where to save, named like the PNG card ("AI年度报告-2026.mp4").
    static func chooseDestination(for r: Report) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        let kind = r.period.isWeek ? "AI周报" : r.period.isShort ? "AI月报" : "AI年度报告"
        panel.nameFieldStringValue = "\(kind)-\(r.period.fileTag).mp4"
        panel.canCreateDirectories = true
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Renders every frame on the main thread and encodes a 30 fps H.264 MP4.
    static func export(_ r: Report, years: [Int], to url: URL, progress: (Double) -> Void) async throws {
        let timeline = VideoTimeline(r, years: years)
        let width = Int(VideoTimeline.size.width * VideoTimeline.scale)
        let height = Int(VideoTimeline.size.height * VideoTimeline.scale)

        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 8_000_000,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoExpectedSourceFrameRateKey: VideoTimeline.fps,
                AVVideoMaxKeyFrameIntervalKey: VideoTimeline.fps * 2,
            ],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? Failure.writer("无法创建视频文件") }
        writer.startSession(atSourceTime: .zero)

        let renderer = ImageRenderer(content: VideoFrame(timeline: timeline, time: 0))
        renderer.scale = VideoTimeline.scale
        let frames = timeline.frameCount
        for i in 0..<frames {
            renderer.content = VideoFrame(timeline: timeline, time: Double(i) / Double(VideoTimeline.fps))
            guard let image = renderer.cgImage, let pool = adaptor.pixelBufferPool,
                  let buffer = pixelBuffer(image, pool: pool, width: width, height: height)
            else {
                writer.cancelWriting()
                throw Failure.writer("第 \(i) 帧渲染失败")
            }
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: CMTimeScale(VideoTimeline.fps))) else {
                throw writer.error ?? Failure.writer("写入视频失败")
            }
            progress(Double(i + 1) / Double(frames))
            // Let the window repaint the progress now and then.
            if i % 4 == 0 { await Task.yield() }
        }
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? Failure.writer("写入视频失败") }
    }

    private static func pixelBuffer(_ image: CGImage, pool: CVPixelBufferPool, width: Int, height: Int) -> CVPixelBuffer? {
        var out: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out) == kCVReturnSuccess, let buffer = out else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }
}
