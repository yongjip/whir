import Foundation

/// Streaming, memory-safe line reader. Codex session files can be 250MB+, so we
/// never load a whole file into memory — read in 1MB chunks and split on `\n`.
/// Supports resuming from a byte offset (incremental scans) and reports
/// `safeOffset`: the absolute byte position after the last newline-terminated
/// line. An unterminated trailing line (a file mid-write) is returned for
/// parsing but does NOT advance safeOffset, so it is re-read once completed.
final class LineReader {
    private let handle: FileHandle
    private var buffer = [UInt8]()
    private var pos = 0
    private var atEOF = false
    private let chunkSize = 1 << 20
    private let newline: UInt8 = 0x0A
    private(set) var safeOffset: Int

    init?(path: String, startOffset: Int = 0) {
        guard let h = FileHandle(forReadingAtPath: path) else { return nil }
        handle = h
        safeOffset = startOffset
        if startOffset > 0 {
            do { try h.seek(toOffset: UInt64(startOffset)) }
            catch { try? h.close(); return nil }
        }
    }
    deinit { try? handle.close() }

    /// Returns each line with whether it was newline-terminated. Only terminated
    /// lines advance `safeOffset`; callers must skip unterminated lines so a
    /// mid-write final record isn't counted now and again once completed.
    func next() -> (line: String, terminated: Bool)? {
        while true {
            if let nl = indexOfNewline() {
                let line = Array(buffer[pos..<nl])
                safeOffset += (nl - pos) + 1
                pos = nl + 1
                return (String(decoding: line, as: UTF8.self), true)
            }
            if pos > 0 { buffer.removeFirst(pos); pos = 0 }   // compact unread tail to front
            if atEOF {
                if pos >= buffer.count { return nil }
                let line = String(decoding: buffer[pos...], as: UTF8.self)
                pos = buffer.count                            // unterminated tail: don't advance safeOffset
                return (line, false)
            }
            let chunk = handle.readData(ofLength: chunkSize)
            if chunk.isEmpty { atEOF = true } else { buffer.append(contentsOf: chunk) }
        }
    }

    private func indexOfNewline() -> Int? {
        var i = pos
        while i < buffer.count {
            if buffer[i] == newline { return i }
            i += 1
        }
        return nil
    }
}

// MARK: - JSON helpers (logs have variable, version-dependent shapes — read defensively)

@inline(__always) func jsonObject(_ line: String) -> [String: Any]? {
    guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) else { return nil }
    return obj as? [String: Any]
}

extension Dictionary where Key == String, Value == Any {
    func dict(_ key: String) -> [String: Any]? { self[key] as? [String: Any] }
    func str(_ key: String) -> String? { self[key] as? String }
    func int(_ key: String) -> Int {
        switch self[key] {
        case let n as NSNumber: return n.intValue   // JSONSerialization numbers bridge to NSNumber
        case let i as Int: return i
        case let d as Double: return Int(d)
        default: return 0
        }
    }
}

// MARK: - filesystem

/// Recursively walk a directory, yielding files whose name matches `suffix`.
func files(under root: String, suffix: String) -> [String] {
    let fm = FileManager.default
    guard let en = fm.enumerator(atPath: root) else { return [] }
    var out: [String] = []
    for case let rel as String in en where rel.hasSuffix(suffix) {
        out.append((root as NSString).appendingPathComponent(rel))
    }
    return out
}

/// Stable identity, size, and mtime — to detect growth vs rotation/truncation,
/// and (via mtime) an in-place edit that preserves byte length.
func fileIdentity(_ path: String) -> (inode: String, size: Int, mtime: Double)? {
    guard let a = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
    let inode = (a[.systemFileNumber] as? Int).map(String.init) ?? ""
    let size = (a[.size] as? Int) ?? 0
    let mtime = (a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
    return (inode, size, mtime)
}

public func homePath(_ rel: String) -> String {
    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(rel).path
}
