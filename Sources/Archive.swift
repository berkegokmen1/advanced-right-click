import Foundation

/// Validate the central directory before invoking the system extractor. ZIP64,
/// links, encryption, ambiguous names and expansion bombs are intentionally rejected.
enum SafeZIP {
    static func validate(_ url: URL) throws {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        func fail() -> AppError { .message("This ZIP uses unsupported or unsafe entries. No files were extracted.") }
        func u16(_ at: Int) throws -> Int {
            guard at >= 0, at + 2 <= data.count else { throw fail() }
            return Int(data[at]) | (Int(data[at + 1]) << 8)
        }
        func u32(_ at: Int) throws -> Int {
            guard at >= 0, at + 4 <= data.count else { throw fail() }
            return Int(data[at]) | (Int(data[at + 1]) << 8) | (Int(data[at + 2]) << 16) | (Int(data[at + 3]) << 24)
        }
        guard data.count >= 22 else { throw fail() }
        let lower = max(0, data.count - 65_557)
        var end: Int?
        for index in stride(from: data.count - 22, through: lower, by: -1) {
            if try u32(index) == 0x06054b50, index + 22 + (try u16(index + 20)) == data.count { end = index; break }
        }
        guard let end else { throw fail() }
        let count = try u16(end + 10)
        guard try u16(end + 4) == 0, try u16(end + 6) == 0, try u16(end + 8) == count,
              count > 0, count < 10_000, count != 0xffff else { throw fail() }
        let directorySize = try u32(end + 12), directoryStart = try u32(end + 16)
        guard directoryStart + directorySize == end else { throw fail() }
        var offset = directoryStart, expanded = 0
        var seen = Set<String>()
        for _ in 0..<count {
            guard try u32(offset) == 0x02014b50 else { throw fail() }
            let flags = try u16(offset + 8), method = try u16(offset + 10)
            let size = try u32(offset + 24), nameLength = try u16(offset + 28)
            let extraLength = try u16(offset + 30), commentLength = try u16(offset + 32)
            let attributes = try u32(offset + 38), localOffset = try u32(offset + 42)
            let mode = (attributes >> 16) & 0xf000
            guard flags & 1 == 0, [0, 8].contains(method), [0, 0x4000, 0x8000].contains(mode), size != 0xffffffff,
                  try u16(offset + 34) == 0, offset + 46 + nameLength + extraLength + commentLength <= end else { throw fail() }
            let rawName = data.subdata(in: (offset + 46)..<(offset + 46 + nameLength))
            guard let name = String(data: rawName, encoding: .utf8), !name.isEmpty, !name.hasPrefix("/"), !name.contains("\\"), !name.contains(":"),
                  !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  !name.split(separator: "/", omittingEmptySubsequences: false).dropLast(name.hasSuffix("/") ? 1 : 0).contains(where: { $0 == ".." || $0 == "." || $0.isEmpty }) else { throw fail() }
            let normalized = name.trimmingCharacters(in: CharacterSet(charactersIn: "/")).precomposedStringWithCanonicalMapping.lowercased()
            guard seen.insert(normalized).inserted, try u32(localOffset) == 0x04034b50 else { throw fail() }
            let localNameLength = try u16(localOffset + 26), localExtra = try u16(localOffset + 28)
            guard localNameLength == nameLength, localOffset + 30 + localNameLength + localExtra <= directoryStart,
                  data.subdata(in: (localOffset + 30)..<(localOffset + 30 + localNameLength)) == rawName else { throw fail() }
            expanded += size
            guard expanded <= 2_147_483_648 else { throw AppError.message("This ZIP expands beyond the 2 GB extraction limit.") }
            offset += 46 + nameLength + extraLength + commentLength
        }
        guard offset == end else { throw fail() }
    }
}

func runTool(_ executable: String, _ arguments: [String], directory: URL? = nil, cancelled: () -> Bool = { false }) throws -> String {
    let process = Process(); process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments; process.currentDirectoryURL = directory
    let pipe = Pipe(); process.standardOutput = pipe; process.standardError = pipe
    // Read concurrently so a verbose subprocess cannot fill its pipe and deadlock.
    let lock = NSLock(); var output = Data()
    pipe.fileHandleForReading.readabilityHandler = { handle in
        let data = handle.availableData
        lock.lock(); if output.count < 4_194_304 { output.append(data) }; lock.unlock()
    }
    defer { pipe.fileHandleForReading.readabilityHandler = nil }
    try process.run()
    while process.isRunning {
        if cancelled() { process.terminate(); process.waitUntilExit(); throw CancellationError() }
        Thread.sleep(forTimeInterval: 0.05)
    }
    process.waitUntilExit()
    pipe.fileHandleForReading.readabilityHandler = nil
    let tail = pipe.fileHandleForReading.readDataToEndOfFile()
    lock.lock(); output.append(tail); let text = String(decoding: output, as: UTF8.self); lock.unlock()
    guard process.terminationStatus == 0 else { throw AppError.message(text.isEmpty ? "The system tool could not finish this operation." : String(text.prefix(2000))) }
    return text
}
