import AppKit
import ImageIO
import PDFKit
import AVFoundation
import CoreVideo

var passed = 0, failed = 0
var exercised = Set<String>()
func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws { if try !condition() { throw AppError.message(message) } }
func rejects(_ body: () throws -> Void) throws { do { try body() } catch { return }; throw AppError.message("Expected the operation to refuse this input") }
func test(_ name: String, _ body: () throws -> Void) {
    do { try body(); passed += 1; print("PASS \(name)") } catch { failed += 1; print("FAIL \(name): \(error)") }
}
let root = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("fixtures-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
defer { if failed == 0 { try? FileManager.default.removeItem(at: root) } else { print("Fixtures kept: \(root.path)") } }
func fixture(_ name: String) throws -> (URL, ActionEngine) {
    let folder = root.appendingPathComponent(name); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let store = try HistoryStore(root: folder.appendingPathComponent("history"))
    return (folder, ActionEngine(store: store))
}
func write(_ url: URL, _ text: String) throws { try Data(text.utf8).write(to: url) }
func image(_ url: URL, type: UTType = .png, width: Int = 200, height: Int = 100) throws {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(red: 0.6, green: 0.3, blue: 0.9, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    try ImageTools.encoded(context.makeImage()!, type: type).write(to: url)
}
func perform(_ engine: ActionEngine, _ id: String, _ urls: [URL], _ options: ActionOptions = ActionOptions(), control: OperationControl = OperationControl()) throws -> ActionResult {
    exercised.insert(id)
    return try engine.perform(ActionDefinition.find(id)!, urls: urls, options: options, control: control) { _, _ in }
}
func makePDF(_ url: URL) throws {
    var rect = CGRect(x: 0, y: 0, width: 300, height: 400)
    let context = CGContext(url as CFURL, mediaBox: &rect, nil)!
    for number in 1...3 {
        context.beginPDFPage(nil); context.setTextDrawingMode(.fill); context.textMatrix = .identity
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "Page \(number) https://example.com", attributes: [.font: NSFont.systemFont(ofSize: 16)]))
        context.textPosition = CGPoint(x: 25, y: 300); CTLineDraw(line, context); context.endPDFPage()
    }
    context.closePDF()
}

test("HEIC conversion replaces in place and undo restores exact original bytes") {
    let (folder, engine) = try fixture("heic"); let source = folder.appendingPathComponent("Photo.heic")
    try image(source, type: .heic); let original = try Data(contentsOf: source)
    let result = try perform(engine, "png", [source]); let output = folder.appendingPathComponent("Photo.png")
    try expect(FileManager.default.fileExists(atPath: output.path), "PNG missing")
    try expect(!FileManager.default.fileExists(atPath: source.path), "Original still visible")
    _ = try engine.store.undo(result.record!)
    try expect(Data(contentsOf: source) == original, "Original bytes not restored")
    try expect(!FileManager.default.fileExists(atPath: output.path), "Converted output not removed")
}
test("conflicting output refuses the entire batch without changing sources") {
    let (folder, engine) = try fixture("collision")
    let one = folder.appendingPathComponent("one.heic"), two = folder.appendingPathComponent("two.heic"), collision = folder.appendingPathComponent("two.png")
    try image(one, type: .heic); try image(two, type: .heic); try write(collision, "existing")
    let digest = try FileDigest.hash(one)
    try rejects { _ = try perform(engine, "png", [one, two]) }
    try expect(FileDigest.hash(one) == digest, "First source changed")
    try expect(String(contentsOf: collision, encoding: .utf8) == "existing", "Existing output overwritten")
    try expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("one.png").path), "Partial output left behind")
}
test("undo protects later edits across a whole batch") {
    let (folder, engine) = try fixture("edited")
    let one = folder.appendingPathComponent("one.png"), two = folder.appendingPathComponent("two.png")
    try image(one); try image(two)
    let result = try perform(engine, "jpeg", [one, two]); let outputs = result.outputs
    try write(outputs[1], "new work")
    try rejects { _ = try engine.store.undo(result.record!) }
    try expect(FileManager.default.fileExists(atPath: outputs[0].path), "Unchanged batch member removed before validation")
    try expect(String(contentsOf: outputs[1], encoding: .utf8) == "new work", "User edit lost")
}
test("same-format resize and rotate are reversible and respect dimensions") {
    let (folder, engine) = try fixture("resize"); let source = folder.appendingPathComponent("image.png")
    try image(source); let original = try Data(contentsOf: source)
    var options = ActionOptions(); options.dimension = 100
    let resized = try perform(engine, "resize", [source], options)
    let bitmap = try ImageTools.load(source); try expect(bitmap.width == 100 && bitmap.height == 50, "Wrong resized dimensions")
    _ = try engine.store.undo(resized.record!)
    let rotated = try perform(engine, "rotate", [source]); let rotatedImage = try ImageTools.load(source)
    try expect(rotatedImage.width == 100 && rotatedImage.height == 200, "Wrong rotated dimensions")
    _ = try engine.store.undo(rotated.record!); try expect(Data(contentsOf: source) == original, "Original changed after restore")
}
test("target size is a real upper bound") {
    let (folder, engine) = try fixture("compress"); let source = folder.appendingPathComponent("image.png"); try image(source, width: 1000, height: 700)
    var options = ActionOptions(); options.targetMB = 0.01
    let result = try perform(engine, "compress", [source], options)
    try expect(Data(contentsOf: result.outputs[0]).count <= 10_000, "Output exceeds requested limit")
}
test("upload recipe limits dimensions and strips GPS metadata") {
    let (folder, engine) = try fixture("metadata"); let source = folder.appendingPathComponent("private.jpg")
    try image(source, type: .jpeg, width: 1800, height: 900)
    let cg = try ImageTools.load(source), data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, cg, [kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 37.0, kCGImagePropertyGPSLatitudeRef: "N"], kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2026:10:18 12:00:00"]] as CFDictionary)
    try expect(CGImageDestinationFinalize(destination), "Fixture encoding failed"); try (data as Data).write(to: source)
    _ = try perform(engine, "upload", [source]); let result = try ImageTools.load(source)
    try expect(result.width == 1600 && result.height == 800, "Wrong upload dimensions")
    let metadata = CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithURL(source as CFURL, nil)!, 0, nil) as! [CFString: Any]
    let exif = metadata[kCGImagePropertyExifDictionary] as? [CFString: Any]
    try expect(metadata[kCGImagePropertyGPSDictionary] == nil && exif?[kCGImagePropertyExifDateTimeOriginal] == nil, "Private metadata retained")
}
test("PDF merge, extraction, split and rotation preserve sources") {
    let (folder, engine) = try fixture("pdf"); let source = folder.appendingPathComponent("document.pdf"); try makePDF(source)
    let original = try Data(contentsOf: source)
    var options = ActionOptions(); options.startPage = 2; options.endPage = 3
    let extraction = try perform(engine, "extract", [source], options)
    try expect(PDFDocument(url: extraction.outputs[0])?.pageCount == 2, "Wrong extracted pages")
    let split = try perform(engine, "split", [source]); try expect(FileManager.default.contentsOfDirectory(atPath: split.outputs[0].path).count == 3, "Split output missing pages")
    let merge = try perform(engine, "pdf", [source, extraction.outputs[0]]); try expect(PDFDocument(url: merge.outputs[0])?.pageCount == 5, "Merged PDF has wrong page count")
    let rotated = try perform(engine, "pdfrotate", [source]); try expect(PDFDocument(url: source)?.page(at: 0)?.rotation == 90, "PDF not rotated")
    _ = try engine.store.undo(rotated.record!); try expect(Data(contentsOf: source) == original, "PDF original bytes changed")
}
test("text and links extracted from a digital PDF") {
    let (folder, engine) = try fixture("text"); let source = folder.appendingPathComponent("document.pdf"); try makePDF(source)
    try expect(perform(engine, "ocr", [source]).text?.contains("Page 1") == true, "Text missing")
    try expect(perform(engine, "links", [source]).text?.contains("https://example.com") == true, "Link missing")
}
test("batch rename preview agrees with disk, then restores names") {
    let (folder, engine) = try fixture("rename"); let source = folder.appendingPathComponent("Photo Final.txt"); try write(source, "hello")
    var options = ActionOptions(); options.search = " Final"; options.prefix = "work-"; options.numberFiles = true; options.lowercase = true
    let preview = try options.renamed(source, index: 0); let result = try perform(engine, "rename", [source], options)
    try expect(result.outputs[0].lastPathComponent == preview, "Preview does not match output")
    _ = try engine.store.undo(result.record!); try expect(String(contentsOf: source, encoding: .utf8) == "hello", "Rename restore failed")
}
test("organize creates type folders and undoes the whole batch") {
    let (folder, engine) = try fixture("organize"); let source = folder.appendingPathComponent("file.txt"); try write(source, "hello")
    let result = try perform(engine, "organize", [folder]); try expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("TXT/file.txt").path), "File not organized")
    _ = try engine.store.undo(result.record!)
    try expect(FileManager.default.fileExists(atPath: source.path), "Original location not restored")
    try expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("TXT").path), "Empty generated folder retained")
}
test("organize refuses undo if a new file was added") {
    let (folder, engine) = try fixture("organize-edit"); try write(folder.appendingPathComponent("file.txt"), "hello")
    let result = try perform(engine, "organize", [folder]); let extra = folder.appendingPathComponent("TXT/new.txt"); try write(extra, "new")
    try rejects { _ = try engine.store.undo(result.record!) }
    try expect(String(contentsOf: extra, encoding: .utf8) == "new", "New file lost")
}
test("ZIP round trip and undo preserve original contents") {
    let (folder, engine) = try fixture("zip"); let source = folder.appendingPathComponent("note.txt"); try write(source, "archive fixture")
    let zipped = try perform(engine, "zip", [source]); try SafeZIP.validate(zipped.outputs[0])
    // Extraction's folder would otherwise have the same name as the source file.
    let archive = folder.appendingPathComponent("Bundle.zip"); try FileManager.default.moveItem(at: zipped.outputs[0], to: archive)
    let extracted = try perform(engine, "unzip", [archive]); try expect(String(contentsOf: extracted.outputs[0].appendingPathComponent("note.txt"), encoding: .utf8) == "archive fixture", "ZIP contents differ")
    _ = try engine.store.undo(extracted.record!); try expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("Bundle").path), "Extracted folder retained")
}
test("ZIP symlinks and traversal paths are rejected") {
    let (folder, _) = try fixture("unsafe-zip"); let source = folder.appendingPathComponent("file.txt"); try write(source, "x")
    let link = folder.appendingPathComponent("link"); try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: source.path)
    let zip = folder.appendingPathComponent("link.zip"); _ = try runTool("/usr/bin/zip", ["-qy", zip.path, "link"], directory: folder)
    try rejects { try SafeZIP.validate(zip) }
    let good = folder.appendingPathComponent("good.zip"); _ = try runTool("/usr/bin/zip", ["-q", good.path, "file.txt"], directory: folder)
    var bytes = try Data(contentsOf: good)
    while let range = bytes.range(of: Data("file.txt".utf8)) { bytes.replaceSubrange(range, with: Data("../x.txt".utf8)) }
    let bad = folder.appendingPathComponent("bad.zip"); try bytes.write(to: bad)
    try rejects { try SafeZIP.validate(bad) }
}
test("duplicate report matches contents, not just size or name") {
    let (folder, engine) = try fixture("duplicates")
    try write(folder.appendingPathComponent("one.txt"), "same"); try write(folder.appendingPathComponent("two.txt"), "same"); try write(folder.appendingPathComponent("other.txt"), "else")
    let result = try perform(engine, "duplicates", [folder])
    try expect(result.report?.contains("one.txt") == true && result.report?.contains("two.txt") == true, "Duplicate files missing")
    try expect(result.report?.contains("other.txt") == false, "Different file marked duplicate")
}
test("cancelled commits roll back earlier members") {
    let (folder, engine) = try fixture("cancel"); var record = try engine.store.begin("Test batch"); let token = OperationControl()
    for index in 0..<2 {
        let source = folder.appendingPathComponent("file\(index).txt"); try write(source, "original")
        let stage = engine.store.stageURL(record, name: "output\(index)"); try write(stage, "changed")
        record.mutations.append(try engine.store.prepare(kind: .replace, source: source, destination: source, staged: stage, record: record, index: index, cancelled: { false }))
    }
    try rejects { _ = try engine.store.commit(record, cancelled: { token.cancelled }) { _, _ in token.cancel() } }
    for index in 0..<2 { try expect(String(contentsOf: folder.appendingPathComponent("file\(index).txt"), encoding: .utf8) == "original", "Partial commit was not rolled back") }
}
test("crash after output installation recovers original bytes") {
    let (folder, engine) = try fixture("recovery"); let source = folder.appendingPathComponent("file.txt"); try write(source, "original")
    var record = try engine.store.begin("Interrupted action"); let stage = engine.store.stageURL(record, name: "new"); try write(stage, "changed")
    let output = folder.appendingPathComponent("converted.txt")
    record.mutations = [try engine.store.prepare(kind: .replace, source: source, destination: output, staged: stage, record: record, index: 0, cancelled: { false })]
    record.state = .applying; try engine.store.save(record)
    try FileManager.default.copyItem(at: stage, to: output)
    try FileManager.default.removeItem(at: source)
    let decoded = try engine.store.records()[0]; _ = try engine.store.undo(decoded)
    try expect(String(contentsOf: source, encoding: .utf8) == "original", "Crash recovery did not restore source")
    try expect(!FileManager.default.fileExists(atPath: output.path), "Crash recovery retained output")
}
test("second app instance cannot acquire the same history") {
    let (_, engine) = try fixture("lock")
    try rejects { _ = try HistoryStore(root: engine.store.root) }
}
test("corrupt recovery state is reported rather than silently discarded") {
    let (_, engine) = try fixture("corrupt"); let record = try engine.store.begin("Recovery")
    try write(engine.store.folder(record.id).appendingPathComponent("record.json"), "invalid")
    try rejects { _ = try engine.store.records() }
}
test("action request safely round trips filenames and rejects invalid inputs") {
    let urls = [URL(fileURLWithPath: "/tmp/a #? ü.png")]
    let request = ActionRequest(action: "png", urls: urls)
    try expect(ActionRequest(url: request.url!)?.urls == urls, "URL path round trip failed")
    try expect(ActionRequest(url: URL(string: "advancedrightclick://run?action=run-shell&file=/tmp/x")!) == nil, "Unknown action accepted")
    try expect(ActionRequest(url: URL(string: "advancedrightclick://run?action=png&file=relative")!) == nil, "Relative path accepted")
    try rejects { try validateFilename("../escaped.txt") }
}


func makeVideo(_ url: URL) throws {
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 160, AVVideoHeightKey: 120])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB, kCVPixelBufferWidthKey as String: 160, kCVPixelBufferHeightKey as String: 120])
    writer.add(input); try expect(writer.startWriting(), "Writer could not start"); writer.startSession(atSourceTime: .zero)
    for index in 0..<20 {
        let deadline = Date().addingTimeInterval(10)
        while !input.isReadyForMoreMediaData { if Date() > deadline { throw AppError.message("Video fixture timed out") }; Thread.sleep(forTimeInterval: 0.01) }
        var buffer: CVPixelBuffer?
        try expect(CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer) == kCVReturnSuccess, "Pixel buffer unavailable")
        CVPixelBufferLockBaseAddress(buffer!, [])
        let bytes = CVPixelBufferGetBaseAddress(buffer!)!.assumingMemoryBound(to: UInt8.self), row = CVPixelBufferGetBytesPerRow(buffer!)
        for y in 0..<120 { for x in 0..<160 { let i = y * row + x * 4; bytes[i] = 255; bytes[i + 1] = UInt8(index * 10); bytes[i + 2] = 100; bytes[i + 3] = 180 } }
        CVPixelBufferUnlockBaseAddress(buffer!, [])
        try expect(adaptor.append(buffer!, withPresentationTime: CMTime(value: Int64(index), timescale: 10)), "Frame append failed")
    }
    input.markAsFinished(); let done = DispatchSemaphore(value: 0); writer.finishWriting { done.signal() }
    try expect(done.wait(timeout: .now() + 15) == .success && writer.status == .completed, "Video fixture failed")
}
func makeAudio(_ url: URL) throws {
    var data = Data()
    func ascii(_ text: String) { data.append(Data(text.utf8)) }
    func u16(_ value: UInt16) { var v = value.littleEndian; data.append(Data(bytes: &v, count: 2)) }
    func u32(_ value: UInt32) { var v = value.littleEndian; data.append(Data(bytes: &v, count: 4)) }
    let samples = 44_100
    ascii("RIFF"); u32(UInt32(36 + samples * 2)); ascii("WAVEfmt "); u32(16); u16(1); u16(1); u32(44_100); u32(88_200); u16(2); u16(16); ascii("data"); u32(UInt32(samples * 2))
    for index in 0..<samples { let sample = Int16(sin(Double(index) * 440 * 2 * .pi / 44_100) * 8_000); u16(UInt16(bitPattern: sample)) }
    try data.write(to: url)
}

test("video conversion, mute, trim and GIF export create readable media") {
    let (folder, engine) = try fixture("media"); let video = folder.appendingPathComponent("clip.mov"); try makeVideo(video)
    let original = try FileDigest.hash(video)
    let converted = try perform(engine, "mp4", [video]); try expect(!AVURLAsset(url: converted.outputs[0]).tracks(withMediaType: .video).isEmpty, "Converted video has no track")
    let muted = try perform(engine, "mute", [video]); try expect(AVURLAsset(url: muted.outputs[0]).tracks(withMediaType: .audio).isEmpty, "Muted video retains audio")
    var options = ActionOptions(); options.startSeconds = 0.2; options.endSeconds = 1.2
    let trimmed = try perform(engine, "trim", [video], options); let duration = CMTimeGetSeconds(AVURLAsset(url: trimmed.outputs[0]).duration)
    try expect(abs(duration - 1) < 0.2, "Trim duration is wrong")
    let gif = try perform(engine, "gif", [video], options); try expect(CGImageSourceGetCount(CGImageSourceCreateWithURL(gif.outputs[0] as CFURL, nil)!) == 8, "GIF frame count is wrong")
    try expect(FileDigest.hash(video) == original, "Media source changed")
    _ = try engine.store.undo(trimmed.record!); try expect(!FileManager.default.fileExists(atPath: trimmed.outputs[0].path), "Undo retained trimmed video")
}
test("audio extraction produces an M4A without changing the source") {
    let (folder, engine) = try fixture("audio"); let source = folder.appendingPathComponent("tone.wav"); try makeAudio(source)
    let result = try perform(engine, "audio", [source]); let asset = AVURLAsset(url: result.outputs[0])
    try expect(!asset.tracks(withMediaType: .audio).isEmpty, "Extracted audio missing")
    try expect(FileManager.default.fileExists(atPath: source.path), "Audio source disappeared")
}
test("contact sheet and template creation are undoable") {
    let (folder, engine) = try fixture("create"); let source = folder.appendingPathComponent("image.png"); try image(source)
    let second = folder.appendingPathComponent("second.png"); try image(second)
    let sheet = try perform(engine, "contact", [source, second]); try expect(ImageTools.load(sheet.outputs[0]).width == 600, "Contact sheet dimensions wrong")
    var options = ActionOptions(); options.filename = "Tasks.md"; options.template = "Checklist"
    let created = try perform(engine, "newfile", [folder], options)
    try expect(String(contentsOf: created.outputs[0], encoding: .utf8).contains("- [ ]"), "Template missing")
    _ = try engine.store.undo(created.record!); try expect(!FileManager.default.fileExists(atPath: created.outputs[0].path), "New file retained")
}
test("animated images are refused instead of dropping frames") {
    let (folder, engine) = try fixture("animation"); let png = folder.appendingPathComponent("frame.png"); try image(png)
    let gif = folder.appendingPathComponent("animated.gif"), cg = try ImageTools.load(png)
    let destination = CGImageDestinationCreateWithURL(gif as CFURL, UTType.gif.identifier as CFString, 2, nil)!
    CGImageDestinationAddImage(destination, cg, nil); CGImageDestinationAddImage(destination, cg, nil); try expect(CGImageDestinationFinalize(destination), "GIF fixture failed")
    try rejects { _ = try perform(engine, "png", [gif]) }
    try expect(FileManager.default.fileExists(atPath: gif.path), "Animated source disappeared")
}

if ProcessInfo.processInfo.environment["ARC_TEST_VISION"] == "1" {
    test("image OCR and searchable PDF contain selectable text") {
        let (folder, engine) = try fixture("vision"); let source = folder.appendingPathComponent("scan.png")
        let image = NSImage(size: NSSize(width: 1000, height: 400)); image.lockFocus(); NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 1000, height: 400).fill()
        ("HELLO LOCAL WORLD" as NSString).draw(at: NSPoint(x: 40, y: 180), withAttributes: [.font: NSFont.systemFont(ofSize: 65), .foregroundColor: NSColor.black]); image.unlockFocus()
        let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!; try bitmap.representation(using: .png, properties: [:])!.write(to: source)
        try expect(perform(engine, "ocr", [source]).text?.contains("HELLO LOCAL WORLD") == true, "OCR missed text")
        let result = try perform(engine, "searchable", [source]); try expect(PDFDocument(url: result.outputs[0])?.string?.contains("HELLO LOCAL WORLD") == true, "Searchable text missing")
    }
}


test("remaining conversion and metadata actions restore originals") {
    let (folder, engine) = try fixture("more-images"); let source = folder.appendingPathComponent("source.png"); try image(source)
    let original = try Data(contentsOf: source)
    let converted = try perform(engine, "heic", [source]); try expect(ImageTools.load(converted.outputs[0]).width == 200, "HEIC output unreadable")
    _ = try engine.store.undo(converted.record!)
    let stripped = try perform(engine, "metadata", [source]); try expect(ImageTools.load(source).height == 100, "Metadata removal damaged pixels")
    _ = try engine.store.undo(stripped.record!); try expect(Data(contentsOf: source) == original, "Original bytes changed")
}
test("converting a mixed-format batch leaves already-matching files untouched") {
    let (folder, engine) = try fixture("matching"); let png = folder.appendingPathComponent("already.png"), jpg = folder.appendingPathComponent("convert.jpg")
    try image(png); try image(jpg, type: .jpeg); let digest = try FileDigest.hash(png)
    let result = try perform(engine, "png", [png, jpg]); try expect(result.record?.mutations.count == 1, "Already matching image was modified")
    try expect(FileDigest.hash(png) == digest, "PNG changed unnecessarily")
}
test("copy actions handle text batches and reject binary images") {
    let (folder, engine) = try fixture("copy"); let first = folder.appendingPathComponent("one.txt"), second = folder.appendingPathComponent("two.md")
    try write(first, "first"); try write(second, "second")
    try expect(perform(engine, "path", [first, second]).text?.contains(first.path) == true, "Path missing")
    try expect(perform(engine, "name", [first, second]).text == "one.txt\ntwo.md", "Filenames incorrect")
    try expect(perform(engine, "markdown", [first]).text?.contains(first.absoluteString) == true, "Markdown link missing")
    try expect(perform(engine, "contents", [first, second]).text == "first\nsecond", "Text contents incorrect")
    let png = folder.appendingPathComponent("image.png"); try image(png)
    try expect(!ActionDefinition.find("contents")!.accepts([png]), "Binary image offered as text")
}
test("mixed PDFs and images can merge, and repeated outputs get unused names") {
    let (folder, engine) = try fixture("mixed-documents"); let document = folder.appendingPathComponent("original.pdf"), png = folder.appendingPathComponent("image.png")
    try makePDF(document); try image(png)
    let first = try perform(engine, "pdf", [document, png]); let bytes = try Data(contentsOf: first.outputs[0])
    let second = try perform(engine, "pdf", [document, png])
    try expect(first.outputs[0] != second.outputs[0], "Repeated merge reused an existing name")
    try expect(Data(contentsOf: first.outputs[0]) == bytes, "Previous PDF overwritten")
    try expect(PDFDocument(url: second.outputs[0])?.pageCount == 4, "Mixed merge page count incorrect")
}
test("PDF compression produces smaller readable output and restores the original") {
    let (folder, engine) = try fixture("pdf-compression"); let png = folder.appendingPathComponent("noise.png")
    let context = CGContext(data: nil, width: 800, height: 1000, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    let data = context.data!.assumingMemoryBound(to: UInt8.self)
    var seed: UInt32 = 12345
    for y in 0..<1000 { for x in 0..<800 { let index = y * context.bytesPerRow + x * 4; for channel in 0..<3 { seed = seed &* 1664525 &+ 1013904223; data[index + channel] = UInt8(truncatingIfNeeded: seed >> 24) }; data[index + 3] = 255 } }
    try ImageTools.encoded(context.makeImage()!, type: .png).write(to: png)
    let pdf = try perform(engine, "pdf", [png]).outputs[0]; let original = try Data(contentsOf: pdf)
    let compressed = try perform(engine, "pdfcompress", [pdf])
    try expect(Data(contentsOf: pdf).count < original.count, "Compressed PDF is not smaller")
    try expect(PDFDocument(url: pdf)?.pageCount == 1, "Compressed PDF unreadable")
    _ = try engine.store.undo(compressed.record!); try expect(Data(contentsOf: pdf) == original, "Original PDF bytes not restored")
}
test("individual ZIPs extract even when the original filename already exists") {
    let (folder, engine) = try fixture("zip-each"); let first = folder.appendingPathComponent("one.txt"), second = folder.appendingPathComponent("two.txt")
    try write(first, "one"); try write(second, "two")
    let result = try perform(engine, "zipEach", [first, second]); try expect(result.outputs.count == 2, "Individual ZIP missing")
    let extracted = try perform(engine, "unzip", [result.outputs[0]])
    try expect(String(contentsOf: first, encoding: .utf8) == "one", "Existing original overwritten")
    try expect(String(contentsOf: extracted.outputs[0].appendingPathComponent("one.txt"), encoding: .utf8) == "one", "Extracted file missing")
}
test("folder reports, monthly organization, compare and Terminal requests use the selected items") {
    let (folder, engine) = try fixture("remaining-folders"); let first = folder.appendingPathComponent("one.txt"), second = folder.appendingPathComponent("two.txt")
    try write(first, "a"); try write(second, "larger file")
    let largest = try perform(engine, "largest", [folder]); try expect(largest.report?.contains(second.path) == true, "Largest-file report missing file")
    let compared = try perform(engine, "compare", [first, second]); try expect(compared.outputs == [first, second], "Comparison selection changed")
    let terminal = try perform(engine, "terminal", [folder]); try expect(terminal.outputs == [folder], "Terminal folder changed")
    let organized = try perform(engine, "organizeDate", [folder]); try expect(!FileManager.default.fileExists(atPath: first.path), "File was not organized")
    _ = try engine.store.undo(organized.record!); try expect(FileManager.default.fileExists(atPath: first.path), "Monthly organization did not restore source")
}
test("audio trim exports the requested range as playable audio") {
    let (folder, engine) = try fixture("audio-trim"); let audio = folder.appendingPathComponent("tone.wav"); try makeAudio(audio)
    var options = ActionOptions(); options.startSeconds = 0.1; options.endSeconds = 0.6
    let result = try perform(engine, "trim", [audio], options)
    let asset = AVURLAsset(url: result.outputs[0])
    try expect(!asset.tracks(withMediaType: .audio).isEmpty, "Trimmed audio missing")
    try expect(abs(CMTimeGetSeconds(asset.duration) - 0.5) < 0.1, "Trimmed audio duration incorrect")
}
test("paste clipboard text and images as files without overwriting prior output") {
    let pasteboard = NSPasteboard.general
    let originalItems = (pasteboard.pasteboardItems ?? []).map { original -> NSPasteboardItem in
        let saved = NSPasteboardItem(); for type in original.types { if let data = original.data(forType: type) { saved.setData(data, forType: type) } }; return saved
    }
    defer { pasteboard.clearContents(); if !originalItems.isEmpty { pasteboard.writeObjects(originalItems) } }
    let (folder, engine) = try fixture("clipboard"); var options = ActionOptions(); options.filename = "Clipboard.txt"
    func backgroundPerform() throws -> ActionResult {
        let lock = NSLock(); var result: Result<ActionResult, Error>?
        DispatchQueue.global().async { let value = Result { try perform(engine, "pastefile", [folder], options) }; lock.lock(); result = value; lock.unlock() }
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            lock.lock(); let value = result; lock.unlock()
            if let value { return try value.get() }
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        throw AppError.message("Clipboard test timed out")
    }
    pasteboard.clearContents(); pasteboard.setString("clipboard fixture", forType: .string)
    let text = try backgroundPerform(); try expect(String(contentsOf: text.outputs[0], encoding: .utf8) == "clipboard fixture", "Clipboard text not saved")
    let png = folder.appendingPathComponent("image.png"); try image(png)
    pasteboard.clearContents(); pasteboard.setData(try Data(contentsOf: png), forType: .png)
    let pasted = try backgroundPerform(); try expect(ImageTools.load(pasted.outputs[0]).width == 200, "Clipboard image not saved")
    try expect(String(contentsOf: text.outputs[0], encoding: .utf8) == "clipboard fixture", "Previous text output overwritten")
}

test("in-place changes preserve Finder bookmarks and file metadata") {
    let (folder, engine) = try fixture("finder-reference"); let source = folder.appendingPathComponent("reference.png"); try image(source)
    try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: source.path)
    let bookmark = try source.bookmarkData(options: .suitableForBookmarkFile, includingResourceValuesForKeys: nil, relativeTo: nil)
    var options = ActionOptions(); options.dimension = 100
    let result = try perform(engine, "resize", [source], options)
    var stale = false
    let resolved = try URL(resolvingBookmarkData: bookmark, options: .withoutUI, relativeTo: nil, bookmarkDataIsStale: &stale)
    try expect(resolved.path == source.path && FileManager.default.fileExists(atPath: resolved.path), "Finder bookmark lost the replaced item")
    let permissions = try FileManager.default.attributesOfItem(atPath: source.path)[.posixPermissions] as? NSNumber
    try expect(permissions?.intValue == 0o640, "Original file permissions changed")
    _ = try engine.store.undo(result.record!)
    let restored = try URL(resolvingBookmarkData: bookmark, options: .withoutUI, relativeTo: nil, bookmarkDataIsStale: &stale)
    try expect(restored.path == source.path, "Finder bookmark lost the restored original")
}
let required = Set(ActionDefinition.all.map(\.id))
let missing = required.subtracting(exercised)
if !missing.isEmpty { failed += 1; print("FAIL Actions not exercised: \(missing.sorted().joined(separator: ", "))") }
else { print("All \(required.count) actions exercised") }
print("\n\(passed) passed; \(failed) failed")
if failed > 0 { exit(1) }
