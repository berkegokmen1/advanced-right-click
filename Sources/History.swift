import Foundation
import CryptoKit
import Darwin

struct FileDigest {
    static func hash(_ url: URL, cancelled: () -> Bool = { false }) throws -> String {
        var hasher = SHA256()
        func visit(_ item: URL, relative: String) throws {
            if cancelled() { throw CancellationError() }
            let values = try item.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey])
            guard values.isSymbolicLink != true else { throw AppError.message("Symbolic links are not modified: \(item.lastPathComponent)") }
            hasher.update(data: Data(relative.utf8)); hasher.update(data: Data([0]))
            if values.isDirectory == true {
                hasher.update(data: Data([1]))
                for child in try FileManager.default.contentsOfDirectory(at: item, includingPropertiesForKeys: nil).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                    try visit(child, relative: relative + "/" + child.lastPathComponent)
                }
            } else if values.isRegularFile == true {
                hasher.update(data: Data([2]))
                let handle = try FileHandle(forReadingFrom: item)
                defer { try? handle.close() }
                while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
                    if cancelled() { throw CancellationError() }
                    hasher.update(data: data)
                }
            } else { throw AppError.message("Only regular files and folders are supported.") }
        }
        try visit(url, relative: "")
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

struct Mutation: Codable {
    enum Kind: String, Codable { case replace, create, move, directory }
    var kind: Kind
    var source: String?
    var destination: String
    var staged: String?
    var backup: String?
    var originalDigest: String?
    var resultDigest: String
    var applied = false
    var reverted = false
}

struct HistoryRecord: Codable, Identifiable {
    enum State: String, Codable { case preparing, applying, complete, undoing, undone, failed }
    var id: UUID
    var title: String
    var date: Date
    var state: State
    var mutations: [Mutation]
    var detail: String?
    var outputURLs: [URL] { mutations.map { URL(fileURLWithPath: $0.destination) } }
    var requiresRecovery: Bool { state == .applying || state == .undoing }
}

/// One serialized engine owns this store. A disk lock also excludes another running copy.
final class HistoryStore {
    let root: URL
    let fm = FileManager.default
    private var lockHandle: Int32 = -1
    init(root: URL) throws {
        self.root = root
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        lockHandle = Darwin.open(root.appendingPathComponent("store.lock").path, O_CREAT | O_RDWR, 0o600)
        guard lockHandle >= 0, flock(lockHandle, LOCK_EX | LOCK_NB) == 0 else {
            if lockHandle >= 0 { Darwin.close(lockHandle); lockHandle = -1 }
            throw AppError.message("Another copy of Advanced Right Click is using this history. Quit that copy first.")
        }
    }
    deinit { if lockHandle >= 0 { flock(lockHandle, LOCK_UN); Darwin.close(lockHandle) } }
    func folder(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }
    func save(_ record: HistoryRecord) throws {
        let directory = folder(record.id)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(record).write(to: directory.appendingPathComponent("record.json"), options: .atomic)
    }
    func records() throws -> [HistoryRecord] {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey]).filter { UUID(uuidString: $0.lastPathComponent) != nil }.compactMap { dir in
            let path = dir.appendingPathComponent("record.json")
            guard fm.fileExists(atPath: path.path) else { return nil }
            do { return try decoder.decode(HistoryRecord.self, from: Data(contentsOf: path)) }
            catch { throw AppError.message("Recovery history is unreadable at \(path.path). Keep this folder and its backups. \(error.localizedDescription)") }
        }.sorted { $0.date > $1.date }
    }
    func begin(_ title: String) throws -> HistoryRecord {
        let record = HistoryRecord(id: UUID(), title: title, date: Date(), state: .preparing, mutations: [])
        try save(record); return record
    }
    func stageURL(_ record: HistoryRecord, name: String) -> URL { folder(record.id).appendingPathComponent(name) }
    func prepare(kind: Mutation.Kind, source: URL? = nil, destination: URL, staged: URL? = nil, record: HistoryRecord, index: Int, cancelled: () -> Bool) throws -> Mutation {
        var mutation = Mutation(kind: kind, source: source?.path, destination: destination.path, staged: staged?.path, resultDigest: "")
        if let source {
            mutation.originalDigest = try FileDigest.hash(source, cancelled: cancelled)
            if kind == .replace {
                let backup = stageURL(record, name: "original-\(index)")
                try fm.copyItem(at: source, to: backup)
                guard try FileDigest.hash(backup, cancelled: cancelled) == mutation.originalDigest else { throw AppError.message("The source changed while it was being backed up. Try again.") }
                mutation.backup = backup.path
            }
        }
        if let staged { mutation.resultDigest = try FileDigest.hash(staged, cancelled: cancelled) }
        else { mutation.resultDigest = mutation.originalDigest ?? "" }
        return mutation
    }
    private func exists(_ path: String) -> Bool { fm.fileExists(atPath: path) || (try? fm.destinationOfSymbolicLink(atPath: path)) != nil }
    private func matches(_ path: String, _ digest: String?) throws -> Bool {
        guard exists(path), let digest else { return false }
        return try FileDigest.hash(URL(fileURLWithPath: path)) == digest
    }
    private func install(_ staged: String, at destination: String, replacing: Bool) throws {
        let target = URL(fileURLWithPath: destination)
        let temp = target.deletingLastPathComponent().appendingPathComponent(".advanced-right-click-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: temp) }
        try fm.copyItem(atPath: staged, toPath: temp.path)
        if replacing {
            // Preserve the document identifier used by Finder's selection/bookmarks.
            // A raw rename leaves Finder pointing at the removed file after resize.
            _ = try fm.replaceItemAt(target, withItemAt: temp, backupItemName: nil, options: [])
            return
        }
        let result = renamex_np(temp.path, target.path, UInt32(RENAME_EXCL))
        guard result == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "Could not install \(target.lastPathComponent): \(String(cString: strerror(errno)))"]) }
    }
    func commit(_ input: HistoryRecord, cancelled: () -> Bool, progress: (Int, Int) -> Void) throws -> HistoryRecord {
        var record = input
        let destinations = record.mutations.map { $0.destination.precomposedStringWithCanonicalMapping.lowercased() }
        guard Set(destinations).count == destinations.count else { throw AppError.message("Two outputs would have the same name. Change your names and try again.") }
        let sources = Set(record.mutations.compactMap(\.source))
        for mutation in record.mutations {
            if let source = mutation.source {
                guard try matches(source, mutation.originalDigest) else { throw AppError.message("\(URL(fileURLWithPath: source).lastPathComponent) changed during preparation. Nothing was replaced.") }
            }
            if mutation.destination != mutation.source && exists(mutation.destination) { throw AppError.message("An item named \(URL(fileURLWithPath: mutation.destination).lastPathComponent) already exists. Nothing was overwritten.") }
            // Avoid cyclic renames and outputs that replace another selected source.
            if mutation.destination != mutation.source && sources.contains(mutation.destination) { throw AppError.message("An output conflicts with another selected source.") }
        }
        record.state = .applying; try save(record)
        do {
            for index in record.mutations.indices {
                if cancelled() { throw CancellationError() }
                let mutation = record.mutations[index]
                if let source = mutation.source, try !matches(source, mutation.originalDigest) { throw AppError.message("A source changed before it could be updated.") }
                switch mutation.kind {
                case .create, .directory: try install(mutation.staged!, at: mutation.destination, replacing: false)
                case .replace:
                    try install(mutation.staged!, at: mutation.destination, replacing: mutation.destination == mutation.source)
                    if let source = mutation.source, source != mutation.destination {
                        guard try matches(source, mutation.originalDigest) else { throw AppError.message("The original changed; both files have been kept for recovery.") }
                        try fm.removeItem(atPath: source)
                    }
                case .move:
                    guard renamex_np(mutation.source!, mutation.destination, UInt32(RENAME_EXCL)) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
                }
                record.mutations[index].applied = true
                try save(record); progress(index + 1, record.mutations.count)
            }
            record.state = .complete; try save(record); return record
        } catch {
            // Leave the journal intact if safe restoration is blocked by external edits.
            do { _ = try undo(record) } catch { throw AppError.message("The operation stopped and needs recovery from History: \(error.localizedDescription)") }
            throw error
        }
    }
    func undo(_ input: HistoryRecord) throws -> HistoryRecord {
        var record = input
        guard record.state == .complete || record.requiresRecovery else { throw AppError.message("This operation has already been restored or made no changes.") }
        // Check the entire batch before removing any output.
        for mutation in record.mutations where !mutation.reverted {
            if mutation.kind == .directory, exists(mutation.destination) {
                let children = try fm.contentsOfDirectory(atPath: mutation.destination)
                let planned = Set(record.mutations.filter { URL(fileURLWithPath: $0.destination).deletingLastPathComponent().path == mutation.destination }.map { URL(fileURLWithPath: $0.destination).lastPathComponent })
                guard Set(children).isSubset(of: planned) else { throw AppError.message("New files were added to an organized folder. Move them elsewhere before restoring.") }
                continue
            }
            if exists(mutation.destination) {
                let resultMatches = try matches(mutation.destination, mutation.resultDigest)
                let untouched = try mutation.source == mutation.destination && matches(mutation.destination, mutation.originalDigest)
                guard resultMatches || untouched else { throw AppError.message("\(URL(fileURLWithPath: mutation.destination).lastPathComponent) changed after this action. Move the edited file elsewhere before restoring; it has been kept.") }
            } else if mutation.applied && record.state == .complete {
                throw AppError.message("An output was moved or deleted. Restore it to its original location before undoing this action.")
            }
            if let source = mutation.source, source != mutation.destination, exists(source), try !matches(source, mutation.originalDigest) {
                throw AppError.message("Another item now uses the original name. Move it elsewhere before restoring.")
            }
            if mutation.kind == .replace {
                guard let backup = mutation.backup, try matches(backup, mutation.originalDigest) else { throw AppError.message("An original backup is missing or changed. Keep the history folder for recovery.") }
            }
        }
        record.state = .undoing; try save(record)
        for index in record.mutations.indices.reversed() {
            let mutation = record.mutations[index]
            if mutation.reverted { continue }
            switch mutation.kind {
            case .create:
                if exists(mutation.destination) { try fm.removeItem(atPath: mutation.destination) }
            case .directory:
                if exists(mutation.destination) {
                    guard try fm.contentsOfDirectory(atPath: mutation.destination).isEmpty else { throw AppError.message("An organized folder is no longer empty. Its contents were kept.") }
                    try fm.removeItem(atPath: mutation.destination)
                }
            case .replace:
                let source = mutation.source!
                if try !matches(source, mutation.originalDigest) {
                    try install(mutation.backup!, at: source, replacing: source == mutation.destination)
                }
                if source != mutation.destination && exists(mutation.destination) { try fm.removeItem(atPath: mutation.destination) }
            case .move:
                let source = mutation.source!
                if !exists(source), exists(mutation.destination) {
                    guard renamex_np(mutation.destination, source, UInt32(RENAME_EXCL)) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
                } else if exists(source), exists(mutation.destination) {
                    throw AppError.message("Both the original and renamed item exist. Review them before recovery.")
                } else if !exists(source) { throw AppError.message("Both paths are missing. Restore the moved item before retrying.") }
            }
            record.mutations[index].reverted = true; try save(record)
        }
        record.state = .undone; try save(record); return record
    }
    func forget(_ record: HistoryRecord) throws {
        guard record.state == .undone || record.state == .failed || record.state == .preparing else { throw AppError.message("Restore this operation before deleting its backups.") }
        try fm.removeItem(at: folder(record.id))
    }
}
