import AppKit
import ImageIO
import UniformTypeIdentifiers
import PDFKit
import Vision
import CoreText
import AVFoundation

final class OperationControl {
    private let lock = NSLock()
    private var value = false
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func cancel() { lock.lock(); value = true; lock.unlock() }
    func check() throws { if cancelled { throw CancellationError() } }
}

struct ActionResult {
    var record: HistoryRecord?
    var text: String?
    var report: String?
    var outputs: [URL] = []
}

struct RecognizedLine { var text: String; var bounds: CGRect }

enum ImageTools {
    static func load(_ url: URL, dimension: Int? = nil) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw AppError.message("Cannot read \(url.lastPathComponent).") }
        guard CGImageSourceGetCount(source) == 1 else { throw AppError.message("\(url.lastPathComponent) contains multiple images or animation frames. Convert a single-frame image to preserve all content.") }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0, height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        guard width > 0, height > 0, width <= 100_000, height <= 100_000, Int64(width) * Int64(height) <= 150_000_000 else { throw AppError.message("This image exceeds the 150-megapixel processing limit.") }
        let size = min(dimension ?? max(width, height), max(width, height))
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: size] as CFDictionary) else { throw AppError.message("Cannot decode this image.") }
        return image
    }
    static func rotated(_ image: CGImage) throws -> CGImage {
        guard let context = CGContext(data: nil, width: image.height, height: image.width, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw AppError.message("Not enough memory to rotate this image.") }
        context.translateBy(x: 0, y: CGFloat(image.width)); context.rotate(by: -.pi / 2)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let result = context.makeImage() else { throw AppError.message("Could not rotate this image.") }; return result
    }
    static func encoded(_ image: CGImage, type: UTType, quality: Double = 0.85, metadataFrom source: URL? = nil) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { throw AppError.message("This macOS version cannot encode \(type.preferredFilenameExtension ?? type.identifier).") }
        var pixels = image
        if type == .jpeg {
            guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw AppError.message("Not enough memory to encode this image.") }
            context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height)); pixels = context.makeImage()!
        }
        var properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality, kCGImagePropertyOrientation: 1]
        if let source, let original = CGImageSourceCreateWithURL(source as CFURL, nil), let metadata = CGImageSourceCopyPropertiesAtIndex(original, 0, nil) as? [CFString: Any] {
            for key in [kCGImagePropertyExifDictionary, kCGImagePropertyGPSDictionary, kCGImagePropertyIPTCDictionary, kCGImagePropertyTIFFDictionary] { properties[key] = metadata[key] }
            // Pixels have been oriented; do not retain TIFF's old orientation tag.
            if var tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] { tiff.removeValue(forKey: kCGImagePropertyTIFFOrientation); properties[kCGImagePropertyTIFFDictionary] = tiff }
        }
        CGImageDestinationAddImage(destination, pixels, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw AppError.message("The image encoder could not finish.") }
        return data as Data
    }
    static func fitSize(_ url: URL, bytes: Int, control: OperationControl) throws -> Data {
        var dimension = 6000
        while dimension >= 64 {
            try control.check()
            let image = try load(url, dimension: dimension)
            var low = 0.05, high = 0.95, best: Data?
            for _ in 0..<8 {
                try control.check()
                let quality = (low + high) / 2
                let data = try encoded(image, type: .jpeg, quality: quality)
                if data.count <= bytes { best = data; low = quality } else { high = quality }
            }
            if let best { return best }
            dimension = Int(Double(min(image.width > image.height ? image.width : image.height, dimension)) * 0.75)
        }
        throw AppError.message("Could not fit the requested file size. Choose a larger limit.")
    }
    static func recognize(_ image: CGImage) throws -> [RecognizedLine] {
        let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate; request.usesLanguageCorrection = true
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { observation in observation.topCandidates(1).first.map { RecognizedLine(text: $0.string, bounds: observation.boundingBox) } }
    }
}

final class ActionEngine {
    let store: HistoryStore
    init(store: HistoryStore) { self.store = store }
    func perform(_ action: ActionDefinition, urls input: [URL], options: ActionOptions, control: OperationControl, progress: @escaping (String, Double) -> Void) throws -> ActionResult {
        guard input.count <= 500, action.accepts(input) else { throw AppError.message("Choose files supported by this action (up to 500 items).") }
        let urls = input.filter { !action.matchesOutputFormat($0) }.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        for url in urls {
            guard try ["path", "name", "markdown"].contains(action.id) || url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw AppError.message("Choose original files rather than symbolic links.") }
            let state = store.root.resolvingSymlinksInPath().standardizedFileURL
            let item = url.resolvingSymlinksInPath().standardizedFileURL
            guard !item.path.hasPrefix(state.path + "/"), item != state,
                  !(action.id == "rename" && state.path.hasPrefix(item.path + "/")) else { throw AppError.message("Recovery files and folders containing them cannot be modified by this action.") }
        }
        try control.check()
        if ["path", "name", "markdown", "contents"].contains(action.id) {
            let text = try urls.map { url -> String in
                switch action.id {
                case "path": return url.path
                case "name": return url.lastPathComponent
                case "markdown": return "[\(url.lastPathComponent.replacingOccurrences(of: "]", with: "\\]"))](\(url.absoluteString))"
                default:
                    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    guard size <= 5_242_880 else { throw AppError.message("Text files must be 5 MB or smaller.") }
                    return try String(contentsOf: url, encoding: .utf8)
                }
            }.joined(separator: "\n")
            return ActionResult(text: text)
        }
        if action.id == "ocr" || action.id == "links" {
            var text = ""
            for (index, url) in urls.enumerated() {
                try control.check(); progress("Reading \(url.lastPathComponent)", Double(index) / Double(urls.count))
                text += try documentText(url, control: control) + "\n"
            }
            if action.id == "links" {
                let detector = try NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
                var seen = Set<String>()
                text = detector.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap(\.url).map(\.absoluteString).filter { seen.insert($0).inserted }.joined(separator: "\n")
            }
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AppError.message("No \(action.id == "links" ? "links" : "text") found. The clipboard was left unchanged.") }
            return ActionResult(text: text)
        }
        if action.id == "largest" || action.id == "duplicates" { return try inspectFolder(urls[0], duplicates: action.id == "duplicates", control: control, progress: progress) }
        if action.id == "compare" { return ActionResult(outputs: urls) }
        if action.id == "terminal" { return ActionResult(outputs: urls) }
        var record = try store.begin(action.title(for: urls).replacingOccurrences(of: "…", with: ""))
        var mutations: [Mutation] = []
        var outputNames = OutputNameAllocator()
        func add(_ stage: URL, destination: URL, replacing source: URL? = nil) throws {
            let directory = (try? stage.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            let output = source == nil ? outputNames.next(destination, directory: directory) : destination
            mutations.append(try store.prepare(kind: source == nil ? .create : .replace, source: source, destination: output, staged: stage, record: record, index: mutations.count, cancelled: { control.cancelled }))
        }
        func stage(_ ext: String = "data") -> URL { store.stageURL(record, name: "result-\(UUID().uuidString).\(ext)") }
        func sibling(_ source: URL, _ suffix: String, _ ext: String) -> URL { source.deletingLastPathComponent().appendingPathComponent(source.deletingPathExtension().lastPathComponent + suffix).appendingPathExtension(ext) }
        do {
            switch action.id {
            case "png", "jpeg", "heic", "resize", "compress", "rotate", "metadata", "upload":
                guard options.dimension >= 16 && options.dimension <= 20_000, options.targetMB.isFinite && options.targetMB >= 0.01 && options.targetMB <= 500 else { throw AppError.message("Choose a dimension from 16–20,000 px and a size from 0.01–500 MB.") }
                for (index, source) in urls.enumerated() {
                    try control.check(); progress("Processing \(source.lastPathComponent)", Double(index) / Double(urls.count) * 0.7)
                    let defaultType = UTType(filenameExtension: source.pathExtension).flatMap { [UTType.png, .jpeg, .heic, .tiff].contains($0) ? $0 : nil } ?? .png
                    let type: UTType = action.id == "png" ? .png : ["jpeg", "compress", "upload"].contains(action.id) ? .jpeg : action.id == "heic" ? .heic : defaultType
                    let ext = type == .jpeg ? "jpg" : type.preferredFilenameExtension!
                    var image = try ImageTools.load(source, dimension: action.id == "resize" ? options.dimension : action.id == "upload" ? 1600 : nil)
                    if action.id == "rotate" { image = try ImageTools.rotated(image) }
                    let stripped = ["metadata", "upload", "compress"].contains(action.id)
                    let data = try action.id == "compress" ? ImageTools.fitSize(source, bytes: Int(options.targetMB * 1_000_000), control: control) : ImageTools.encoded(image, type: type, metadataFrom: stripped ? nil : source)
                    let output = stage(ext); try data.write(to: output)
                    let destination = source.pathExtension.lowercased() == ext || (type == .jpeg && source.pathExtension.lowercased() == "jpeg") || (type == .tiff && source.pathExtension.lowercased() == "tif") ? source : source.deletingPathExtension().appendingPathExtension(ext)
                    try add(output, destination: destination, replacing: source)
                }
            case "pdf", "split", "extract", "pdfrotate", "pdfcompress", "searchable":
                if action.id == "pdf" || action.id == "searchable" {
                    let output = stage("pdf")
                    if action.id == "searchable" { try searchablePDF(urls, to: output, control: control, progress: progress) }
                    else {
                        let combined = PDFDocument()
                        for source in urls {
                            try control.check()
                            if source.pathExtension.lowercased() == "pdf" {
                                let doc = try pdf(source)
                                for index in 0..<doc.pageCount { if let page = doc.page(at: index)?.copy() as? PDFPage { combined.insert(page, at: combined.pageCount) } }
                            } else {
                                let image = try ImageTools.load(source)
                                if let page = PDFPage(image: NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))) { combined.insert(page, at: combined.pageCount) }
                            }
                        }
                        guard combined.pageCount > 0, combined.write(to: output) else { throw AppError.message("Could not create the PDF.") }
                    }
                    let name = action.id == "searchable" ? "Searchable.pdf" : urls.count == 1 ? urls[0].deletingPathExtension().lastPathComponent + ".pdf" : "Combined.pdf"
                    let destination = urls[0].deletingLastPathComponent().appendingPathComponent(name)
                    try add(output, destination: destination)
                } else {
                    for source in urls {
                        try control.check(); let doc = try pdf(source)
                        if action.id == "split" {
                            let directory = stage("pages"); try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                            for index in 0..<doc.pageCount {
                                try control.check(); let pageDoc = PDFDocument(); pageDoc.insert(doc.page(at: index)!, at: 0)
                                guard pageDoc.write(to: directory.appendingPathComponent(String(format: "Page-%03d.pdf", index + 1))) else { throw AppError.message("Could not write a PDF page.") }
                            }
                            try add(directory, destination: source.deletingLastPathComponent().appendingPathComponent(source.deletingPathExtension().lastPathComponent + " Pages"))
                        } else {
                            let output = stage("pdf")
                            if action.id == "extract" {
                                guard options.startPage >= 1, options.endPage >= options.startPage, options.endPage <= doc.pageCount else { throw AppError.message("Choose a valid page range from 1 to \(doc.pageCount).") }
                                let extracted = PDFDocument()
                                for index in (options.startPage - 1)..<options.endPage { extracted.insert(doc.page(at: index)!, at: extracted.pageCount) }
                                guard extracted.write(to: output) else { throw AppError.message("Could not write the PDF.") }
                                try add(output, destination: sibling(source, "-pages-\(options.startPage)-\(options.endPage)", "pdf"))
                            } else if action.id == "pdfrotate" {
                                for index in 0..<doc.pageCount { doc.page(at: index)!.rotation = (doc.page(at: index)!.rotation + 90) % 360 }
                                guard doc.write(to: output) else { throw AppError.message("Could not write the PDF.") }
                                try add(output, destination: source, replacing: source)
                            } else {
                                guard let context = CGContext(output as CFURL, mediaBox: nil, nil) else { throw AppError.message("Could not create the compressed PDF.") }
                                var closed = false
                                defer { if !closed { context.closePDF() } }
                                for index in 0..<doc.pageCount {
                                    try control.check(); let page = doc.page(at: index)!
                                    let pageSize = page.bounds(for: .mediaBox).size
                                    let scale = min(120.0 / 72.0, 1200.0 / max(pageSize.width, pageSize.height))
                                    let image = try render(page, scale: scale)
                                    let jpeg = try ImageTools.encoded(image, type: .jpeg, quality: 0.45)
                                    guard let jpegSource = CGImageSourceCreateWithData(jpeg as CFData, nil), let jpegImage = CGImageSourceCreateImageAtIndex(jpegSource, 0, nil) else { throw AppError.message("Could not compress this PDF.") }
                                    let pageBounds = page.bounds(for: .mediaBox)
                                    var bounds = CGRect(x: 0, y: 0, width: pageBounds.width, height: pageBounds.height)
                                    if page.rotation % 180 != 0 { bounds.size = CGSize(width: bounds.height, height: bounds.width) }
                                    let box = NSData(bytes: &bounds, length: MemoryLayout<CGRect>.size)
                                    context.beginPDFPage([kCGPDFContextMediaBox: box] as CFDictionary)
                                    context.draw(jpegImage, in: bounds)
                                    context.endPDFPage()
                                }
                                context.closePDF()
                                closed = true
                                let oldSize = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                                let newSize = try output.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                                guard newSize < oldSize else { throw AppError.message("This PDF is already smaller than the compressed result. The original was kept.") }
                                try add(output, destination: source, replacing: source)
                            }
                        }
                    }
                }
            case "contact":
                let output = stage("png"); try contactSheet(urls, to: output, control: control)
                try add(output, destination: urls[0].deletingLastPathComponent().appendingPathComponent("Contact Sheet.png"))
            case "rename":
                for (index, source) in urls.enumerated() {
                    let name = try options.renamed(source, index: index)
                    let dest = source.deletingLastPathComponent().appendingPathComponent(name)
                    if source.path == dest.path { continue }
                    guard source.path.lowercased() != dest.path.lowercased() else { throw AppError.message("Case-only renames are not supported by this version.") }
                    mutations.append(try store.prepare(kind: .move, source: source, destination: dest, record: record, index: index, cancelled: { control.cancelled }))
                }
            case "zip", "zipEach":
                let groups = action.id == "zipEach" ? urls.map { [$0] } : [urls]
                for group in groups {
                    try control.check()
                    let parent = group[0].deletingLastPathComponent()
                    guard group.allSatisfy({ $0.deletingLastPathComponent() == parent }) else { throw AppError.message("Choose files from the same folder to compress together.") }
                    let output = stage("zip")
                    _ = try runTool("/usr/bin/zip", ["-qry", output.path, "--"] + group.map(\.lastPathComponent), directory: parent, cancelled: { control.cancelled })
                    let destination = group.count == 1 ? group[0].appendingPathExtension("zip") : parent.appendingPathComponent("Archive.zip")
                    try add(output, destination: destination)
                }
            case "unzip":
                for source in urls {
                    let snapshot = stage("zip"); try FileManager.default.copyItem(at: source, to: snapshot)
                    try SafeZIP.validate(snapshot)
                    let output = stage("folder"); try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                    _ = try runTool("/usr/bin/unzip", ["-qq", "-n", snapshot.path, "-d", output.path], cancelled: { control.cancelled })
                    _ = try FileDigest.hash(output, cancelled: { control.cancelled })
                    try add(output, destination: source.deletingPathExtension())
                }
            case "organize", "organizeDate":
                let parent = urls[0]
                let children = try FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey], options: .skipsHiddenFiles).sorted { $0.lastPathComponent < $1.lastPathComponent }
                var groups: [String: [URL]] = [:]
                for file in children {
                    let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey])
                    guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
                    let name: String
                    if action.id == "organizeDate" { let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM"; name = formatter.string(from: values.contentModificationDate ?? Date()) }
                    else { name = file.pathExtension.isEmpty ? "No Extension" : file.pathExtension.uppercased() }
                    try validateFilename(name); groups[name, default: []].append(file)
                }
                for name in groups.keys.sorted() {
                    let destinationFolder = parent.appendingPathComponent(name, isDirectory: true)
                    if !FileManager.default.fileExists(atPath: destinationFolder.path) {
                        // Stage the entire group and back up each original, making folder creation and moves reversible.
                        let output = stage("group"); try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                        // Empty folders are created separately; their digest must remain empty after undoing moves.
                        mutations.append(try store.prepare(kind: .directory, destination: destinationFolder, staged: output, record: record, index: mutations.count, cancelled: { control.cancelled }))
                    } else {
                        let values = try destinationFolder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                        guard values.isDirectory == true, values.isSymbolicLink != true else { throw AppError.message("The \(name) destination is not a regular folder.") }
                    }
                    for source in groups[name]! { mutations.append(try store.prepare(kind: .move, source: source, destination: destinationFolder.appendingPathComponent(source.lastPathComponent), record: record, index: mutations.count, cancelled: { control.cancelled })) }
                }
            case "newfile", "pastefile":
                try validateFilename(options.filename)
                let output = stage(); var destination = urls[0].appendingPathComponent(options.filename)
                if action.id == "newfile" {
                    let text = options.template == "Checklist" ? "# Checklist\n\n- [ ] First task\n" : options.template == "Plain text" ? "" : "# \(destination.deletingPathExtension().lastPathComponent)\n\n"
                    try Data(text.utf8).write(to: output)
                } else {
                    var contents: Data?
                    DispatchQueue.main.sync {
                        if let text = NSPasteboard.general.string(forType: .string) { contents = Data(text.utf8) }
                        else if let image = NSImage(pasteboard: .general), let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) { contents = bitmap.representation(using: .png, properties: [:]); destination = destination.deletingPathExtension().appendingPathExtension("png") }
                    }
                    guard let contents else { throw AppError.message("Copy text or an image first.") }
                    try contents.write(to: output)
                }
                try add(output, destination: destination)
            case "mp4", "audio", "mute", "trim", "gif":
                for source in urls {
                    try control.check(); let audioOnly = !["mov", "mp4", "m4v"].contains(source.pathExtension.lowercased())
                    let ext = action.id == "audio" || (action.id == "trim" && audioOnly) ? "m4a" : action.id == "gif" ? "gif" : "mp4"
                    let output = stage(ext)
                    try exportMedia(source, to: output, action: action.id, options: options, control: control)
                    let suffix = action.id == "audio" ? "-audio" : action.id == "mute" ? "-muted" : action.id == "trim" ? "-trimmed" : action.id == "gif" ? "-clip" : "-converted"
                    try add(output, destination: sibling(source, suffix, ext))
                }
            default: throw AppError.message("Unknown action.")
            }
            guard !mutations.isEmpty else { throw AppError.message("No files need to change with these settings.") }
            record.mutations = mutations
            record = try store.commit(record, cancelled: { control.cancelled }) { index, total in progress("Saving \(index) of \(total)", 0.7 + Double(index) / Double(total) * 0.3) }
            return ActionResult(record: record, outputs: record.outputURLs)
        } catch {
            // Reload the on-disk state: commit may already have rolled the batch back.
            if let current = try? store.records().first(where: { $0.id == record.id }), current.state == .preparing {
                record.state = .failed; record.detail = error.localizedDescription; try? store.save(record)
            }
            throw error
        }
    }

    func pdf(_ url: URL) throws -> PDFDocument {
        guard let document = PDFDocument(url: url), !document.isLocked, document.pageCount > 0, document.pageCount <= 500 else { throw AppError.message("Use an unlocked PDF with 1–500 pages.") }
        return document
    }
    func render(_ page: PDFPage, scale: Double = 2) throws -> CGImage {
        let rect = page.bounds(for: .mediaBox)
        guard rect.width > 0, rect.height > 0, rect.width * rect.height * scale * scale < 100_000_000 else { throw AppError.message("This PDF page is too large to render.") }
        let thumb = page.thumbnail(of: NSSize(width: rect.width * scale, height: rect.height * scale), for: .mediaBox)
        var proposed = CGRect(origin: .zero, size: thumb.size)
        guard let image = thumb.cgImage(forProposedRect: &proposed, context: nil, hints: nil) else { throw AppError.message("Cannot render a PDF page.") }; return image
    }
    func documentText(_ url: URL, control: OperationControl) throws -> String {
        if url.pathExtension.lowercased() != "pdf" { return try ImageTools.recognize(ImageTools.load(url, dimension: 4000)).map(\.text).joined(separator: "\n") }
        let doc = try pdf(url); var text: [String] = []
        for index in 0..<doc.pageCount {
            try control.check(); let page = doc.page(at: index)!
            if let existing = page.string, !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { text.append(existing) }
            else { text.append(try ImageTools.recognize(render(page)).map(\.text).joined(separator: "\n")) }
        }
        return text.joined(separator: "\n\n")
    }
    func searchablePDF(_ urls: [URL], to output: URL, control: OperationControl, progress: (String, Double) -> Void) throws {
        guard let context = CGContext(output as CFURL, mediaBox: nil, nil) else { throw AppError.message("Cannot create this PDF.") }
        for (index, url) in urls.enumerated() {
            try control.check(); progress("Recognizing \(url.lastPathComponent)", Double(index) / Double(urls.count) * 0.7)
            let document = url.pathExtension.lowercased() == "pdf" ? try pdf(url) : nil
            for pageIndex in 0..<(document?.pageCount ?? 1) {
                try control.check()
                let page = document?.page(at: pageIndex)
                let image = try page.map { try render($0) } ?? ImageTools.load(url, dimension: 6000)
                // Rasterize the visible page so rotated and cropped inputs match the OCR coordinates.
                let width = page?.bounds(for: .mediaBox).width ?? CGFloat(image.width) * 0.5
                let height = width * CGFloat(image.height) / CGFloat(image.width)
                var bounds = CGRect(x: 0, y: 0, width: width, height: height)
                let data = NSData(bytes: &bounds, length: MemoryLayout<CGRect>.size)
                context.beginPDFPage([kCGPDFContextMediaBox: data] as CFDictionary)
                context.draw(image, in: bounds)
                for line in try ImageTools.recognize(image) {
                    let box = CGRect(x: line.bounds.minX * width, y: line.bounds.minY * height, width: line.bounds.width * width, height: line.bounds.height * height)
                    let font = CTFontCreateWithName("Helvetica" as CFString, max(1, box.height * 0.85), nil)
                    let attributed = NSAttributedString(string: line.text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
                    let textLine = CTLineCreateWithAttributedString(attributed)
                    let measured = CGFloat(CTLineGetTypographicBounds(textLine, nil, nil, nil))
                    context.saveGState(); context.setTextDrawingMode(.invisible); context.textMatrix = .identity
                    context.translateBy(x: box.minX, y: box.minY); context.scaleBy(x: measured > 0 ? box.width / measured : 1, y: 1)
                    context.textPosition = .zero; CTLineDraw(textLine, context); context.restoreGState()
                }
                context.endPDFPage()
            }
        }
        context.closePDF()
    }
    func contactSheet(_ urls: [URL], to output: URL, control: OperationControl) throws {
        guard urls.count <= 100 else { throw AppError.message("Choose up to 100 images for one contact sheet.") }
        let columns = min(4, urls.count), cell = 300, rowHeight = 270, rows = (urls.count + columns - 1) / columns
        let width = columns * cell, height = rows * rowHeight
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw AppError.message("Not enough memory for the contact sheet.") }
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        for (index, url) in urls.enumerated() {
            try control.check(); let image = try ImageTools.load(url, dimension: 560)
            let factor = min(280.0 / Double(image.width), 220.0 / Double(image.height))
            let x = Double(index % columns * cell), y = Double(height - (index / columns + 1) * rowHeight)
            context.draw(image, in: CGRect(x: x + (300 - Double(image.width) * factor) / 2, y: y + 42, width: Double(image.width) * factor, height: Double(image.height) * factor))
            let label = CTLineCreateWithAttributedString(NSAttributedString(string: String(url.lastPathComponent.prefix(35)), attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.black]))
            context.textMatrix = .identity; context.textPosition = CGPoint(x: x + 12, y: y + 18); CTLineDraw(label, context)
        }
        guard let image = context.makeImage() else { throw AppError.message("Could not draw the contact sheet.") }
        try ImageTools.encoded(image, type: .png).write(to: output)
    }
    func inspectFolder(_ root: URL, duplicates: Bool, control: OperationControl, progress: (String, Double) -> Void) throws -> ActionResult {
        var files: [(URL, Int)] = []; var skipped = 0; var scanned = 0
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey], options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, _ in skipped += 1; return true }) else { throw AppError.message("Cannot read this folder.") }
        for case let url as URL in enumerator {
            try control.check(); scanned += 1
            if scanned > 50_000 { throw AppError.message("This folder exceeds the 50,000-item scan limit. Choose a smaller folder.") }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
            if values.isSymbolicLink == true { enumerator.skipDescendants(); continue }
            if values.isUbiquitousItem == true && values.ubiquitousItemDownloadingStatus != .current { skipped += 1; continue }
            if values.isRegularFile == true { files.append((url, values.fileSize ?? 0)) }
            if scanned % 100 == 0 { progress("Scanned \(scanned) items", 0.2) }
        }
        let formatter = ByteCountFormatter()
        var lines = ["\(duplicates ? "Identical duplicates" : "Largest files") in \(root.path)", "\(files.count) files checked · \(skipped) items unavailable or not downloaded", ""]
        if duplicates {
            let sizes = Dictionary(grouping: files, by: { $0.1 }).values.filter { $0.count > 1 }
            var hashes: [String: [URL]] = [:]
            for group in sizes { for (url, _) in group { try control.check(); progress("Checking \(url.lastPathComponent)", 0.5); hashes[try FileDigest.hash(url, cancelled: { control.cancelled }), default: []].append(url) } }
            let matches = hashes.values.filter { $0.count > 1 }.sorted { $0[0].path < $1[0].path }
            for (index, group) in matches.enumerated() { lines.append("Group \(index + 1)"); lines.append(contentsOf: group.map(\.path)); lines.append("") }
            if matches.isEmpty { lines.append("No identical duplicates found.") }
            lines.append("No files were moved or deleted.")
        } else {
            for (url, size) in files.sorted(by: { $0.1 > $1.1 }).prefix(100) { lines.append("\(formatter.string(fromByteCount: Int64(size)))\t\(url.path)") }
        }
        return ActionResult(report: lines.joined(separator: "\n"))
    }
    func exportMedia(_ source: URL, to output: URL, action: String, options: ActionOptions, control: OperationControl) throws {
        let asset = AVURLAsset(url: source)
        let duration = CMTimeGetSeconds(asset.duration)
        guard duration.isFinite, duration > 0 else { throw AppError.message("Cannot read this media file.") }
        if action == "gif" {
            guard options.startSeconds >= 0, options.endSeconds > options.startSeconds, options.endSeconds <= duration, options.endSeconds - options.startSeconds <= 15 else { throw AppError.message("Choose a GIF range up to 15 seconds within the video.") }
            let frames = Int(ceil((options.endSeconds - options.startSeconds) * 8))
            guard let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.gif.identifier as CFString, frames, nil) else { throw AppError.message("Cannot create a GIF.") }
            CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
            let generator = AVAssetImageGenerator(asset: asset); generator.appliesPreferredTrackTransform = true; generator.maximumSize = CGSize(width: 480, height: 480)
            for index in 0..<frames {
                try control.check(); let image = try generator.copyCGImage(at: CMTime(seconds: options.startSeconds + Double(index) / 8, preferredTimescale: 600), actualTime: nil)
                CGImageDestinationAddImage(destination, image, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.125]] as CFDictionary)
            }
            guard CGImageDestinationFinalize(destination) else { throw AppError.message("GIF encoding failed.") }; return
        }
        var exportAsset: AVAsset = asset
        if action == "mute" {
            guard let sourceTrack = asset.tracks(withMediaType: .video).first else { throw AppError.message("Choose a video to mute.") }
            let composition = AVMutableComposition()
            guard let track = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw AppError.message("Cannot create the video track.") }
            try track.insertTimeRange(CMTimeRange(start: .zero, duration: asset.duration), of: sourceTrack, at: .zero)
            track.preferredTransform = sourceTrack.preferredTransform; exportAsset = composition
        }
        let audioOutput = action == "audio" || (action == "trim" && asset.tracks(withMediaType: .video).isEmpty)
        if !audioOutput, asset.tracks(withMediaType: .video).isEmpty { throw AppError.message("Choose a video for this action. Audio can be converted with Extract audio.") }
        guard let exporter = AVAssetExportSession(asset: exportAsset, presetName: audioOutput ? AVAssetExportPresetAppleM4A : AVAssetExportPresetHighestQuality) else { throw AppError.message("This media format cannot be exported.") }
        exporter.outputURL = output; exporter.outputFileType = audioOutput ? .m4a : .mp4; exporter.shouldOptimizeForNetworkUse = true
        if action == "trim" {
            guard options.startSeconds.isFinite, options.endSeconds.isFinite, options.startSeconds >= 0, options.endSeconds > options.startSeconds, options.endSeconds <= duration else { throw AppError.message("Choose a valid range within the video's \(Int(duration)) seconds.") }
            exporter.timeRange = CMTimeRange(start: CMTime(seconds: options.startSeconds, preferredTimescale: 600), end: CMTime(seconds: options.endSeconds, preferredTimescale: 600))
        }
        let semaphore = DispatchSemaphore(value: 0)
        exporter.exportAsynchronously { semaphore.signal() }
        while semaphore.wait(timeout: .now() + 0.1) == .timedOut { if control.cancelled { exporter.cancelExport() } }
        try control.check()
        guard exporter.status == .completed else { throw exporter.error ?? AppError.message("Export could not finish.") }
    }
}
