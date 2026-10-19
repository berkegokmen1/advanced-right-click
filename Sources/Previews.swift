import SwiftUI
import AppKit
import AVKit
import AVFoundation
import PDFKit

private let previewAccent = Color.accentColor

@MainActor final class MediaPreview: ObservableObject {
    let player = AVPlayer()
    @Published var duration = 0.0
    @Published var current = 0.0
    @Published var playing = false
    @Published var hasVideo = false
    @Published var frames: [NSImage] = []
    @Published var waveform: [Float] = []
    @Published var error: String?
    private var observer: Any?
    private var start = 0.0
    private var end = 0.0
    private var generation = UUID()
    private var assets: [AVURLAsset] = []
    private var waveformTask: Task<[Float], Never>?

    init() {
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.04, preferredTimescale: 600), queue: .main) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.current = time.seconds.isFinite ? time.seconds : 0
                if self.playing && self.current >= self.end - 0.015 {
                    self.player.pause(); self.playing = false
                }
            }
        }
    }
    deinit { if let observer { player.removeTimeObserver(observer) } }
    func prepare(_ urls: [URL]) async {
        do {
            var shortest = Double.greatestFiniteMagnitude
            assets = urls.map { AVURLAsset(url: $0) }
            for asset in assets {
                let time = try await asset.load(.duration).seconds
                guard time.isFinite, time > 0 else { throw AppError.message("This media has no playable duration.") }
                shortest = min(shortest, time)
                try Task.checkCancellation()
            }
            duration = shortest
        } catch { if !(error is CancellationError) { self.error = error.localizedDescription } }
    }
    func show(_ url: URL, muted: Bool) async {
        let request = UUID(); generation = request
        waveformTask?.cancel()
        player.pause(); playing = false; frames = []; waveform = []; error = nil
        do {
            let asset = AVURLAsset(url: url)
            let videos = try await asset.loadTracks(withMediaType: .video)
            try Task.checkCancellation()
            guard request == generation else { return }
            hasVideo = !videos.isEmpty
            let item = AVPlayerItem(asset: asset); item.forwardPlaybackEndTime = CMTime(seconds: end, preferredTimescale: 600)
            player.replaceCurrentItem(with: item); player.isMuted = muted; seek(start)
            if hasVideo {
                let generator = AVAssetImageGenerator(asset: asset)
                generator.appliesPreferredTrackTransform = true; generator.maximumSize = CGSize(width: 120, height: 80)
                var images: [NSImage] = []
                for index in 0..<8 {
                    let result = try await generator.image(at: CMTime(seconds: duration * Double(index) / 8, preferredTimescale: 600))
                    try Task.checkCancellation()
                    images.append(NSImage(cgImage: result.image, size: .zero))
                }
                guard request == generation else { return }; frames = images
            } else {
                let length = duration
                let task = Task.detached(priority: .utility) { Self.audioWaveform(url, duration: length) }
                waveformTask = task
                let samples = await task.value
                try Task.checkCancellation()
                guard request == generation else { return }; waveform = samples
            }
        } catch {
            guard request == generation else { return }
            // Playback can still work when a codec cannot supply thumbnails.
            if player.currentItem == nil && !(error is CancellationError) { self.error = "Preview unavailable for this file." }
        }
    }
    func rangeChanged(start: Double, end: Double) {
        self.start = start; self.end = end
        player.currentItem?.forwardPlaybackEndTime = CMTime(seconds: end, preferredTimescale: 600)
        player.pause(); playing = false
    }
    func seek(_ seconds: Double) {
        current = min(duration, max(0, seconds))
        player.seek(to: CMTime(seconds: current, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }
    func toggle() {
        if playing { player.pause(); playing = false; return }
        if current < start || current >= end - 0.04 { seek(start) }
        playing = true; player.play()
    }
    func stop() {
        generation = UUID(); waveformTask?.cancel(); waveformTask = nil
        for asset in assets { asset.cancelLoading() }; assets = []
        player.pause(); playing = false; player.replaceCurrentItem(with: nil)
    }

    nonisolated private static func audioWaveform(_ url: URL, duration: Double) -> [Float] {
        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .audio).first, let reader = try? AVAssetReader(asset: asset) else { return [] }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMIsFloatKey: true, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsNonInterleaved: false, AVNumberOfChannelsKey: 1, AVSampleRateKey: 8000])
        guard reader.canAdd(output) else { return [] }; reader.add(output)
        guard reader.startReading() else { return [] }
        var peaks = [Float](repeating: 0, count: 100)
        while let sample = output.copyNextSampleBuffer() {
            if Task.isCancelled { reader.cancelReading(); return [] }
            let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            var pointer: UnsafeMutablePointer<Int8>?, length = 0
            guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer) == kCMBlockBufferNoErr, let pointer else { continue }
            let floats = UnsafeRawPointer(pointer).assumingMemoryBound(to: Float.self)
            for index in 0..<(length / 4) {
                let bin = Int((time + Double(index) / 8000) / duration * 100)
                if (0..<100).contains(bin) { peaks[bin] = max(peaks[bin], abs(floats[index])) }
            }
            if time > duration { break }
        }
        reader.cancelReading()
        let peak = peaks.max() ?? 0
        return peak > 0 ? peaks.map { $0 / peak } : peaks
    }
}

struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView(); view.player = player; view.controlsStyle = .none
        view.videoGravity = .resizeAspect; view.showsFullScreenToggleButton = false
        return view
    }
    func updateNSView(_ view: AVPlayerView, context: Context) { view.player = player }
    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) { view.player = nil }
}

struct MediaOptionsPreview: View {
    let urls: [URL]
    let gif: Bool
    @Binding var options: ActionOptions
    @Binding var ready: Bool
    @StateObject private var preview = MediaPreview()
    @State private var selected = 0
    @State private var startText = "00:00.00"
    @State private var endText = "00:05.00"
    private var range: PreviewRange { PreviewRange(duration: preview.duration, maximumLength: gif ? 15 : preview.duration) }
    var body: some View {
        VStack(spacing: 10) {
            if urls.count > 1 {
                Picker("Preview", selection: $selected) { ForEach(urls.indices, id: \.self) { Text(urls[$0].lastPathComponent).tag($0) } }.controlSize(.small)
            }
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.92))
                if preview.hasVideo { PlayerSurface(player: preview.player).clipShape(RoundedRectangle(cornerRadius: 8)) }
                else if preview.duration > 0 {
                    WaveformView(peaks: preview.waveform).foregroundStyle(.white.opacity(0.75)).padding(16)
                }
                if preview.duration == 0 && preview.error == nil { ProgressView().controlSize(.small) }
                if let error = preview.error { Text(error).font(.caption).foregroundStyle(.white).padding() }
            }.frame(height: preview.hasVideo ? 176 : 90)
            if preview.duration > 0 {
                RangeTimeline(start: options.startSeconds, end: options.endSeconds, duration: preview.duration, current: preview.current, frames: preview.frames,
                    setStart: { setStart($0) }, setEnd: { setEnd($0) }, seek: { preview.seek($0) })
                HStack(spacing: 12) {
                    timeField("Start", text: $startText, commit: { if let value = PreviewRange.seconds(startText) { setStart(value) }; syncTimes() })
                    timeField("End", text: $endText, commit: { if let value = PreviewRange.seconds(endText) { setEnd(value) }; syncTimes() })
                    Spacer(minLength: 0)
                    VStack(alignment: .trailing, spacing: 4) { Text("Selected").font(.caption).foregroundStyle(.secondary); Text(PreviewRange.timestamp(options.endSeconds - options.startSeconds)).monospacedDigit() }.font(.system(size: 11))
                }
                HStack {
                    Button { preview.toggle() } label: { Image(systemName: preview.playing ? "pause.fill" : "play.fill"); Text(preview.playing ? "Pause" : "Play selection") }.controlSize(.small)
                    Spacer()
                    Text(PreviewRange.timestamp(preview.current)).monospacedDigit().font(.caption).foregroundStyle(.secondary)
                    if gif { Text("GIF · 8 fps").font(.caption).foregroundStyle(.secondary) }
                }
                if urls.count > 1 { Text("Range applies to all \(urls.count) files.").font(.caption).foregroundStyle(.secondary) }
            }
        }
        .task {
            await preview.prepare(urls)
            guard preview.duration > 0, !Task.isCancelled else { return }
            options.startSeconds = 0; options.endSeconds = min(preview.duration, gif ? 5 : preview.duration)
            preview.rangeChanged(start: options.startSeconds, end: options.endSeconds); syncTimes(); ready = true
        }
        .task(id: "\(selected)-\(preview.duration)") {
            if preview.duration > 0 { await preview.show(urls[selected], muted: gif) }
        }
        .onDisappear { preview.stop(); ready = false }
    }
    func timeField(_ label: String, text: Binding<String>, commit: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextField(label, text: text).font(.system(size: 11, design: .monospaced)).frame(width: 78).onSubmit(commit)
                .onChange(of: text.wrappedValue) { value in
                    if let seconds = PreviewRange.seconds(value) { if label == "Start" { setStart(seconds, sync: false) } else { setEnd(seconds, sync: false) } }
                    validateTimes()
                }
        }
    }
    func setStart(_ value: Double, sync: Bool = true) {
        if gif {
            let proposed = min(max(0, value), preview.duration - range.minimumLength)
            let length = min(15, options.endSeconds - options.startSeconds)
            if proposed >= options.endSeconds { options.endSeconds = min(preview.duration, proposed + length) }
            if options.endSeconds - proposed > 15 { options.endSeconds = proposed + 15 }
        }
        options.startSeconds = range.start(value, end: options.endSeconds)
        preview.rangeChanged(start: options.startSeconds, end: options.endSeconds); preview.seek(options.startSeconds)
        if sync { syncTimes() }
    }
    func setEnd(_ value: Double, sync: Bool = true) {
        if gif {
            let proposed = min(preview.duration, max(range.minimumLength, value))
            let length = min(15, options.endSeconds - options.startSeconds)
            if proposed <= options.startSeconds { options.startSeconds = max(0, proposed - length) }
            if proposed - options.startSeconds > 15 { options.startSeconds = proposed - 15 }
        }
        options.endSeconds = range.end(value, start: options.startSeconds)
        preview.rangeChanged(start: options.startSeconds, end: options.endSeconds); preview.seek(max(options.startSeconds, options.endSeconds - 0.04))
        if sync { syncTimes() }
    }
    func syncTimes() {
        startText = PreviewRange.timestamp(options.startSeconds); endText = PreviewRange.timestamp(options.endSeconds)
        validateTimes()
    }
    func validateTimes() {
        guard let start = PreviewRange.seconds(startText), let end = PreviewRange.seconds(endText) else { ready = false; return }
        ready = abs(start - options.startSeconds) < 0.011 && abs(end - options.endSeconds) < 0.011
    }
}

struct WaveformView: View {
    let peaks: [Float]
    var body: some View {
        Canvas { context, size in
            guard !peaks.isEmpty else { return }
            let step = size.width / CGFloat(peaks.count)
            for (index, peak) in peaks.enumerated() {
                let height = max(2, CGFloat(peak) * size.height)
                context.fill(Path(roundedRect: CGRect(x: CGFloat(index) * step, y: (size.height - height) / 2, width: max(1, step - 1), height: height), cornerRadius: 1), with: .foreground)
            }
        }.overlay { if peaks.isEmpty { Image(systemName: "waveform").font(.system(size: 30)).foregroundStyle(.secondary) } }
    }
}

struct RangeTimeline: View {
    let start: Double, end: Double, duration: Double, current: Double
    let frames: [NSImage]
    let setStart: (Double) -> Void, setEnd: (Double) -> Void, seek: (Double) -> Void
    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width - 16
            let left = CGFloat(start / duration) * width + 8
            let right = CGFloat(end / duration) * width + 8
            ZStack(alignment: .topLeading) {
                HStack(spacing: 0) { ForEach(frames.indices, id: \.self) { Image(nsImage: frames[$0]).resizable().scaledToFill().frame(width: width / CGFloat(max(1, frames.count)), height: 36).clipped() } }
                    .frame(width: width, height: 36).background(Color(nsColor: .controlBackgroundColor)).cornerRadius(4).offset(x: 8, y: 4)
                Rectangle().fill(.black.opacity(0.45)).frame(width: max(0, left - 8), height: 36).offset(x: 8, y: 4)
                Rectangle().fill(.black.opacity(0.45)).frame(width: max(0, width + 8 - right), height: 36).offset(x: right, y: 4)
                Rectangle().strokeBorder(previewAccent, lineWidth: 2).frame(width: max(1, right - left), height: 40).offset(x: left, y: 2)
                Rectangle().fill(.white).frame(width: 2, height: 36).offset(x: min(width + 8, max(8, CGFloat(current / duration) * width + 8)), y: 4)
            }.contentShape(Rectangle()).gesture(DragGesture(minimumDistance: 0).onChanged { seek(min(duration, max(0, Double(($0.location.x - 8) / width) * duration))) })
            handle("Start", value: start, x: left, width: width, set: setStart)
            handle("End", value: end, x: right, width: width, set: setEnd)
        }.frame(height: 44).coordinateSpace(name: "timeline")
    }
    func handle(_ label: String, value: Double, x: CGFloat, width: CGFloat, set: @escaping (Double) -> Void) -> some View {
        RoundedRectangle(cornerRadius: 3).fill(previewAccent).frame(width: 14, height: 44)
            .overlay { Capsule().fill(.white).frame(width: 2, height: 14) }.offset(x: x - 7)
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("timeline")).onChanged { set(min(duration, max(0, Double(($0.location.x - 8) / width) * duration))) })
            .accessibilityElement().accessibilityLabel("\(label) time").accessibilityValue(PreviewRange.timestamp(value))
            .accessibilityAdjustableAction { direction in set(value + (direction == .increment ? 0.1 : -0.1)) }
    }
}

struct PDFPreviewSource {
    let url: URL
    let document: PDFDocument
}

struct PDFOptionsPreview: View {
    let urls: [URL]
    let action: String
    @Binding var options: ActionOptions
    @Binding var ready: Bool
    @State private var sources: [PDFPreviewSource] = []
    @State private var pages: [PDFPage] = []
    @State private var selectedSource = 0
    @State private var current = 0
    @State private var anchor = 0
    @State private var limit = 1
    @State private var error: String?
    private var combined: Bool { action == "pdf" || action == "searchable" }
    var body: some View {
        VStack(spacing: 9) {
            if !combined && sources.count > 1 {
                Picker("Preview", selection: $selectedSource) { ForEach(sources.indices, id: \.self) { Text(sources[$0].url.lastPathComponent).tag($0) } }.controlSize(.small)
            }
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor))
                if pages.indices.contains(current) {
                    Image(nsImage: thumbnail(pages[current], size: CGSize(width: 600, height: 440))).resizable().scaledToFit().padding(8)
                } else if let error { Text(error).font(.caption).foregroundStyle(.secondary).padding() }
                else { ProgressView().controlSize(.small) }
            }.frame(height: 202)
            if !pages.isEmpty {
                HStack {
                    Button { current = max(0, current - 1) } label: { Image(systemName: "chevron.left") }.disabled(current == 0)
                    Spacer()
                    Text("Page \(current + 1) of \(pages.count)").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    Spacer()
                    Button { current = min(pages.count - 1, current + 1) } label: { Image(systemName: "chevron.right") }.disabled(current == pages.count - 1)
                }.buttonStyle(.borderless)
                ScrollViewReader { proxy in
                    ScrollView(.horizontal) {
                        LazyHStack(spacing: 7) {
                            ForEach(pages.indices, id: \.self) { index in
                                Button { choose(index) } label: {
                                    VStack(spacing: 3) {
                                        Image(nsImage: thumbnail(pages[index], size: CGSize(width: 90, height: 100))).resizable().scaledToFit().frame(width: 36, height: 44)
                                        Text("\(index + 1)").font(.system(size: 9)).monospacedDigit()
                                    }.padding(4).background(isSelected(index) ? previewAccent.opacity(0.14) : .clear).cornerRadius(4)
                                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(index == current ? previewAccent : .clear, lineWidth: 1.5))
                                }.buttonStyle(.plain).id(index).accessibilityLabel("Page \(index + 1)").accessibilityAddTraits(isSelected(index) ? .isSelected : [])
                            }
                        }.padding(2)
                    }.frame(height: 70)
                    .onChange(of: current) { index in withAnimation { proxy.scrollTo(index, anchor: .center) } }
                }
                if action == "extract" {
                    HStack {
                        Text("Pages \(options.startPage)–\(options.endPage)").font(.caption).monospacedDigit()
                        Spacer()
                        Button("Set start") { options.startPage = current + 1; options.endPage = max(options.startPage, options.endPage) }.controlSize(.small).disabled(current >= limit)
                        Button("Set end") { options.endPage = current + 1; options.startPage = min(options.startPage, options.endPage) }.controlSize(.small).disabled(current >= limit)
                        Button("All") { options.startPage = 1; options.endPage = limit; current = 0; anchor = 0 }.controlSize(.small)
                    }
                    Text("Select a page, then set start or end.").font(.caption).foregroundStyle(.secondary)
                    if sources.count > 1 { Text("Same range in all \(sources.count) PDFs (up to page \(limit)).").font(.caption).foregroundStyle(.secondary) }
                } else if action == "pdfcompress" {
                    Text("Pages become images; text, links and forms are removed. Original saved for Undo.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else if action == "split" {
                    Text("Save \(sources.reduce(0) { $0 + $1.document.pageCount }) pages as separate PDFs.").font(.caption).foregroundStyle(.secondary)
                } else if action == "pdfrotate" { Text("Rotate all pages 90° right.").font(.caption).foregroundStyle(.secondary) }
            }
        }
        .task {
            let ordered = urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            let result = await Task.detached(priority: .userInitiated) { () -> [PDFPreviewSource]? in
                var loaded: [PDFPreviewSource] = []
                for url in ordered {
                    if Task.isCancelled { return nil }
                    if url.pathExtension.lowercased() == "pdf" {
                        guard let document = PDFDocument(url: url), !document.isLocked, (1...500).contains(document.pageCount) else { return nil }
                        loaded.append(PDFPreviewSource(url: url, document: document))
                    } else {
                        guard let image = try? ImageTools.load(url, dimension: 1200), let page = PDFPage(image: NSImage(cgImage: image, size: .zero)) else { return nil }
                        let document = PDFDocument(); document.insert(page, at: 0); loaded.append(PDFPreviewSource(url: url, document: document))
                    }
                }
                return loaded
            }.value
            guard !Task.isCancelled else { return }
            guard let result, !result.isEmpty else { error = "Cannot preview this selection. Use unlocked PDFs with 1–500 pages."; return }
            sources = result; limit = result.map { $0.document.pageCount }.min() ?? 1
            options.startPage = 1; options.endPage = limit; updatePages(); ready = true
        }
        .onChange(of: selectedSource) { _ in updatePages() }
        .onDisappear { ready = false }
    }
    func updatePages() {
        let visible = combined ? sources : [sources[selectedSource]]
        pages = visible.flatMap { source in (0..<source.document.pageCount).compactMap { source.document.page(at: $0) } }; current = 0
    }
    func thumbnail(_ page: PDFPage, size: CGSize) -> NSImage {
        if action == "pdfrotate", let rotated = page.copy() as? PDFPage {
            rotated.rotation = (rotated.rotation + 90) % 360
            return rotated.thumbnail(of: size, for: .mediaBox)
        }
        return page.thumbnail(of: size, for: .mediaBox)
    }
    func isSelected(_ index: Int) -> Bool { action == "extract" ? (options.startPage...options.endPage).contains(index + 1) : true }
    func choose(_ index: Int) {
        current = index
        guard action == "extract", index < limit else { return }
        if NSEvent.modifierFlags.contains(.shift) {
            options.startPage = min(anchor, index) + 1; options.endPage = max(anchor, index) + 1
        } else { anchor = index }
    }
}
