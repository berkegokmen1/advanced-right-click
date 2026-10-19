import Foundation

/// Derived files get an unused name. In-place replacements and user-requested
/// renames continue to use strict collision checks in the recovery store.
struct OutputNameAllocator {
    private var reserved = Set<String>()
    mutating func next(_ proposed: URL, directory: Bool) -> URL {
        let parent = proposed.deletingLastPathComponent()
        let ext = directory ? "" : proposed.pathExtension
        let stem = directory || ext.isEmpty ? proposed.lastPathComponent : proposed.deletingPathExtension().lastPathComponent
        var candidate = proposed
        var number = 2
        while FileManager.default.fileExists(atPath: candidate.path) || (try? FileManager.default.destinationOfSymbolicLink(atPath: candidate.path)) != nil || reserved.contains(key(candidate)) {
            let name = stem + " \(number)" + (ext.isEmpty ? "" : "." + ext)
            candidate = parent.appendingPathComponent(name, isDirectory: directory)
            number += 1
        }
        reserved.insert(key(candidate))
        return candidate
    }
    private func key(_ url: URL) -> String { url.standardizedFileURL.path.precomposedStringWithCanonicalMapping.lowercased() }
}
