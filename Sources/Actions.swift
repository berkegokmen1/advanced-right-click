import Foundation
import UniformTypeIdentifiers

struct ActionDefinition: Identifiable, Hashable {
    let id: String
    let title: String
    let subtitle: String
    let symbol: String
    let category: String
    let needsOptions: Bool
    let kind: Kind
    enum Kind { case image, pdf, document, media, video, any, folder, pair, archive }

    func accepts(_ urls: [URL]) -> Bool { accepts(SelectionContext(urls)) }

    func accepts(_ selection: SelectionContext) -> Bool {
        guard !selection.items.isEmpty, selection.items.count <= 500 else { return false }
        let items = selection.items
        let files = items.allSatisfy { !$0.isDirectory && !$0.isSymbolicLink }
        let images = files && items.allSatisfy(\.isImage)
        let documents = files && items.allSatisfy { $0.isImage || $0.isPDF }
        // Paths and names work for any selection; processing actions never follow links.
        if ["path", "name", "markdown"].contains(id) { return true }
        guard !items.contains(where: \.isSymbolicLink) else { return false }
        switch id {
        case "png", "jpeg", "heic":
            return images && items.contains { !matchesOutputFormat($0.url) }
        case "contact": return images && (2...100).contains(items.count)
        case "pdf": return documents && (items.count > 1 || items[0].isImage)
        case "contents": return files && items.allSatisfy { $0.isText && ($0.size ?? 0) <= 5_242_880 }
        case "zipEach": return items.count > 1
        case "zip": return Set(items.map { $0.url.deletingLastPathComponent().standardizedFileURL.path }).count == 1
        default: break
        }
        switch kind {
        case .image: return images
        case .pdf: return files && items.allSatisfy(\.isPDF)
        case .document: return documents
        case .media: return files && items.allSatisfy { Self.mediaExtensions.contains($0.ext) }
        case .video: return files && items.allSatisfy { ["mov", "mp4", "m4v"].contains($0.ext) }
        case .any: return true
        case .folder: return items.count == 1 && items[0].isDirectory && !items[0].isPackage
        case .pair: return items.count == 2 && files
        case .archive: return files && items.allSatisfy { $0.ext == "zip" }
        }
    }
    func matchesOutputFormat(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        switch id { case "png": return ext == "png"; case "jpeg": return ["jpg", "jpeg"].contains(ext); case "heic": return ["heic", "heif"].contains(ext); default: return false }
    }
    func title(for urls: [URL]) -> String {
        let count = urls.count
        if count == 1 {
            switch id {
            case "rename": return "Rename…"
            case "zip": return "Create ZIP"
            case "pdf": return "Create PDF"
            case "resize": return "Resize image…"
            case "split": return "Split PDF into pages"
            case "audio": return SelectionContext.Item(urls[0]).isVideo ? "Extract audio" : "Convert to M4A"
            default: return title
            }
        }
        switch id {
        case "png", "jpeg", "heic":
            let affected = urls.filter { !matchesOutputFormat($0) }.count
            let format = id == "png" ? "PNG" : id == "jpeg" ? "JPEG" : "HEIC"
            return "Convert \(affected) image\(affected == 1 ? "" : "s") to \(format)"
        case "rename": return "Rename \(count) items…"
        case "zip": return "Compress \(count) items together"
        case "zipEach": return "Create \(count) separate ZIPs"
        case "pdf": return "Combine \(count) items into PDF"
        case "contact": return "Contact sheet from \(count) images"
        case "resize": return "Resize \(count) images…"
        case "compress": return "Fit \(count) images to file size…"
        case "rotate": return "Rotate \(count) images right"
        case "metadata": return "Remove metadata from \(count) images"
        case "upload": return "Prepare \(count) images for upload"
        case "path": return "Copy \(count) paths"
        case "name": return "Copy \(count) filenames"
        case "markdown": return "Copy \(count) Markdown links"
        case "contents": return "Copy contents of \(count) text files"
        case "compare": return "Compare these 2 files"
        default:
            if title.hasSuffix("…") { return String(title.dropLast()) + " (\(count) files)…" }
            return title + " (\(count) files)"
        }
    }
    static let imageExtensions: Set<String> = ["heic", "heif", "jpg", "jpeg", "png", "tiff", "tif", "bmp", "webp", "avif"]
    static let mediaExtensions: Set<String> = ["mov", "mp4", "m4v", "m4a", "mp3", "wav", "aiff", "aac", "caf"]
    static let categories = ["Images", "Documents", "Media", "Organize", "Copy & share", "Folders"]
    static let all: [ActionDefinition] = [
        .init(id: "png", title: "Convert to PNG", subtitle: "Replace the source; keep the original for undo", symbol: "photo", category: "Images", needsOptions: false, kind: .image),
        .init(id: "jpeg", title: "Convert to JPEG", subtitle: "A smaller, widely compatible image", symbol: "photo.on.rectangle", category: "Images", needsOptions: false, kind: .image),
        .init(id: "heic", title: "Convert to HEIC", subtitle: "Efficient image storage for Apple devices", symbol: "photo.badge.checkmark", category: "Images", needsOptions: false, kind: .image),
        .init(id: "resize", title: "Resize images…", subtitle: "Fit a maximum dimension without upscaling", symbol: "arrow.up.left.and.arrow.down.right", category: "Images", needsOptions: true, kind: .image),
        .init(id: "compress", title: "Fit a file size…", subtitle: "Make a JPEG under your chosen size", symbol: "arrow.down.right.and.arrow.up.left", category: "Images", needsOptions: true, kind: .image),
        .init(id: "rotate", title: "Rotate right", subtitle: "Turn images 90° clockwise", symbol: "rotate.right", category: "Images", needsOptions: false, kind: .image),
        .init(id: "metadata", title: "Remove image metadata", subtitle: "Remove GPS, EXIF and IPTC; keep the color profile", symbol: "location.slash", category: "Images", needsOptions: false, kind: .image),
        .init(id: "upload", title: "Prepare for upload", subtitle: "JPEG · 1600px · no embedded location or camera data", symbol: "arrow.up.forward.square", category: "Images", needsOptions: false, kind: .image),
        .init(id: "contact", title: "Create contact sheet", subtitle: "A labeled grid of your selected images", symbol: "square.grid.3x3", category: "Images", needsOptions: false, kind: .image),
        .init(id: "pdf", title: "Combine into PDF", subtitle: "Merge images or PDFs in filename order", symbol: "doc.on.doc", category: "Documents", needsOptions: true, kind: .document),
        .init(id: "split", title: "Split PDF into pages", subtitle: "Create a new folder of individual page PDFs", symbol: "rectangle.split.3x1", category: "Documents", needsOptions: true, kind: .pdf),
        .init(id: "extract", title: "Extract PDF pages…", subtitle: "Save a page range as a separate PDF", symbol: "doc.badge.arrow.up", category: "Documents", needsOptions: true, kind: .pdf),
        .init(id: "pdfrotate", title: "Rotate PDF pages", subtitle: "Turn every page 90° clockwise", symbol: "rotate.right", category: "Documents", needsOptions: true, kind: .pdf),
        .init(id: "pdfcompress", title: "Compress PDF…", subtitle: "Rasterize pages at 120 dpi; keep only smaller results", symbol: "doc.zipper", category: "Documents", needsOptions: true, kind: .pdf),
        .init(id: "ocr", title: "Copy text", subtitle: "Read image text locally or extract PDF text", symbol: "text.viewfinder", category: "Documents", needsOptions: false, kind: .document),
        .init(id: "links", title: "Copy detected links", subtitle: "Extract web links from image or PDF text", symbol: "link", category: "Documents", needsOptions: false, kind: .document),
        .init(id: "searchable", title: "Create searchable PDF", subtitle: "Add a selectable text layer using on-device OCR", symbol: "doc.text.magnifyingglass", category: "Documents", needsOptions: true, kind: .document),
        .init(id: "mp4", title: "Convert to MP4", subtitle: "Export a compatible video alongside the original", symbol: "film", category: "Media", needsOptions: false, kind: .video),
        .init(id: "audio", title: "Extract audio", subtitle: "Save an M4A alongside the original", symbol: "waveform", category: "Media", needsOptions: false, kind: .media),
        .init(id: "mute", title: "Mute video", subtitle: "Create a copy without audio tracks", symbol: "speaker.slash", category: "Media", needsOptions: false, kind: .video),
        .init(id: "trim", title: "Trim media…", subtitle: "Export a precise start and end range", symbol: "scissors", category: "Media", needsOptions: true, kind: .media),
        .init(id: "gif", title: "Create GIF…", subtitle: "A short, silent 480px animation", symbol: "play.rectangle", category: "Media", needsOptions: true, kind: .video),
        .init(id: "rename", title: "Batch rename…", subtitle: "Replace text, add a prefix or number files", symbol: "character.cursor.ibeam", category: "Organize", needsOptions: true, kind: .any),
        .init(id: "zip", title: "Compress together", subtitle: "Create one ZIP alongside the selection", symbol: "archivebox", category: "Organize", needsOptions: false, kind: .any),
        .init(id: "zipEach", title: "Compress individually", subtitle: "Create a ZIP for each selected item", symbol: "square.stack.3d.up", category: "Organize", needsOptions: false, kind: .any),
        .init(id: "unzip", title: "Extract ZIP", subtitle: "Extract safely into a new named folder", symbol: "shippingbox", category: "Organize", needsOptions: false, kind: .archive),
        .init(id: "compare", title: "Compare two files", subtitle: "View properties, text or images side by side", symbol: "rectangle.split.2x1", category: "Organize", needsOptions: false, kind: .pair),
        .init(id: "path", title: "Copy path", subtitle: "Full paths, one per line", symbol: "point.topleft.down.to.point.bottomright.curvepath", category: "Copy & share", needsOptions: false, kind: .any),
        .init(id: "name", title: "Copy filename", subtitle: "Just the names, including extensions", symbol: "textformat", category: "Copy & share", needsOptions: false, kind: .any),
        .init(id: "markdown", title: "Copy Markdown link", subtitle: "Local file links ready to paste into notes", symbol: "link", category: "Copy & share", needsOptions: false, kind: .any),
        .init(id: "contents", title: "Copy text file contents", subtitle: "Copy UTF-8 text without opening an editor", symbol: "doc.on.clipboard", category: "Copy & share", needsOptions: false, kind: .any),
        .init(id: "largest", title: "Find largest files", subtitle: "Inspect the top 100 files in this folder", symbol: "chart.bar.xaxis", category: "Folders", needsOptions: false, kind: .folder),
        .init(id: "duplicates", title: "Find identical duplicates", subtitle: "Compare file contents; review before taking action", symbol: "doc.on.doc.fill", category: "Folders", needsOptions: false, kind: .folder),
        .init(id: "organize", title: "Organize by file type", subtitle: "Move loose files into named type folders", symbol: "folder.badge.gearshape", category: "Folders", needsOptions: false, kind: .folder),
        .init(id: "organizeDate", title: "Organize by month", subtitle: "Group loose files by modification month", symbol: "calendar", category: "Folders", needsOptions: false, kind: .folder),
        .init(id: "newfile", title: "New file from template…", subtitle: "Create a text, Markdown or checklist file", symbol: "doc.badge.plus", category: "Folders", needsOptions: true, kind: .folder),
        .init(id: "pastefile", title: "Paste clipboard as file…", subtitle: "Save clipboard text or an image in this folder", symbol: "clipboard", category: "Folders", needsOptions: true, kind: .folder),
        .init(id: "terminal", title: "Open Terminal here", subtitle: "Start a Terminal window in this folder", symbol: "terminal", category: "Folders", needsOptions: false, kind: .folder)
    ]
    static func find(_ id: String) -> ActionDefinition? { all.first { $0.id == id } }
}

struct SelectionContext {
    struct Item {
        let url: URL
        let isDirectory: Bool
        let isPackage: Bool
        let isSymbolicLink: Bool
        let isText: Bool
        let size: Int?
        var ext: String { url.pathExtension.lowercased() }
        var isImage: Bool { !isDirectory && ActionDefinition.imageExtensions.contains(ext) }
        var isPDF: Bool { !isDirectory && ext == "pdf" }
        var isVideo: Bool { !isDirectory && ["mov", "mp4", "m4v"].contains(ext) }
        init(_ url: URL) {
            self.url = url
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .contentTypeKey, .fileSizeKey])
            isDirectory = values?.isDirectory ?? url.hasDirectoryPath
            isPackage = values?.isPackage ?? ["app", "bundle", "framework", "appex", "photoslibrary"].contains(url.pathExtension.lowercased())
            isSymbolicLink = values?.isSymbolicLink ?? false
            size = values?.fileSize
            let contentType = values?.contentType ?? UTType(filenameExtension: url.pathExtension)
            let textExtensions: Set<String> = ["txt", "md", "markdown", "json", "csv", "tsv", "swift", "py", "js", "ts", "tsx", "jsx", "css", "scss", "html", "htm", "xml", "yaml", "yml", "toml", "ini", "conf", "log", "sh", "zsh", "bash", "c", "h", "cpp", "m", "mm", "sql", "rs", "go", "rb", "java", "kt", "tex", "svg"]
            isText = !isDirectory && (contentType?.conforms(to: .text) == true || textExtensions.contains(url.pathExtension.lowercased()) || ["Makefile", "Dockerfile", ".gitignore", ".env"].contains(url.lastPathComponent))
        }
    }
    let items: [Item]
    init(_ urls: [URL]) { items = urls.map(Item.init) }
}

enum FinderSelection {
    static func urls(selected: [URL], targeted: URL?, background: Bool) -> [URL] {
        if background { return targeted.map { [URL(fileURLWithPath: $0.path, isDirectory: true)] } ?? [] }
        return selected.isEmpty ? targeted.map { [$0] } ?? [] : selected
    }
}

struct ActionOptions: Codable {
    var dimension = 1600
    var targetMB = 5.0
    var search = ""
    var replacement = ""
    var prefix = ""
    var numberFiles = false
    var lowercase = false
    var startPage = 1
    var endPage = 1
    var startSeconds = 0.0
    var endSeconds = 5.0
    var filename = "Untitled.md"
    var template = "Markdown"

    func renamed(_ url: URL, index: Int) throws -> String {
        var stem = url.deletingPathExtension().lastPathComponent
        if !search.isEmpty { stem = stem.replacingOccurrences(of: search, with: replacement) }
        if lowercase { stem = stem.lowercased() }
        stem = prefix + (numberFiles ? String(format: "%03d-", index + 1) : "") + stem
        let name = stem + (url.pathExtension.isEmpty ? "" : "." + url.pathExtension)
        try validateFilename(name)
        return name
    }
}

func validateFilename(_ name: String) throws {
    guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains(":"), !name.contains("\0"), name.utf8.count <= 240 else {
        throw AppError.message("Choose a filename under 240 bytes without / or : characters.")
    }
}

enum AppError: LocalizedError {
    case message(String)
    var errorDescription: String? { switch self { case .message(let text): return text } }
}

struct ActionRequest {
    let action: String
    let urls: [URL]
    var url: URL? {
        var components = URLComponents()
        components.scheme = "advancedrightclick"; components.host = "run"
        components.queryItems = [URLQueryItem(name: "action", value: action)] + urls.map { URLQueryItem(name: "file", value: $0.path) }
        return components.url
    }
    init(action: String, urls: [URL]) { self.action = action; self.urls = urls }
    init?(url: URL) {
        guard url.scheme == "advancedrightclick", url.host == "run", let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let action = c.queryItems?.first(where: { $0.name == "action" })?.value,
              ["show", "settings", "history", "undo", "cancel"].contains(action) || ActionDefinition.find(action) != nil else { return nil }
        let paths = c.queryItems?.filter { $0.name == "file" }.compactMap(\.value) ?? []
        guard paths.count <= 500, paths.allSatisfy({ $0.hasPrefix("/") && !$0.contains("\0") }) else { return nil }
        self.action = action; self.urls = paths.map { URL(fileURLWithPath: $0).standardizedFileURL }
    }
}
