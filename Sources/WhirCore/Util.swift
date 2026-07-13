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
        guard let raw = nextRaw() else { return nil }
        return (raw.string, raw.terminated)
    }

    /// Like `next()` but yields the line as raw UTF-8 bytes, so callers can run a
    /// cheap byte-level `contains` before paying for String creation + JSON
    /// parsing. On multi-GB logs that prefilter dominates: Swift's Unicode-aware
    /// String.contains measured ~30x slower than a raw byte scan. The returned
    /// `bytes` view is valid only until the next read from this reader.
    func nextRaw() -> RawLine? {
        while true {
            if let nl = indexOfNewline() {
                let slice = buffer[pos..<nl]
                safeOffset += (nl - pos) + 1
                pos = nl + 1
                return RawLine(bytes: slice, terminated: true)
            }
            if pos > 0 { buffer.removeFirst(pos); pos = 0 }   // compact unread tail to front
            if atEOF {
                if pos >= buffer.count { return nil }
                let slice = buffer[pos...]
                pos = buffer.count                            // unterminated tail: don't advance safeOffset
                return RawLine(bytes: slice, terminated: false)
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

// MARK: - raw line + byte-level prefilter

/// A single log line as raw UTF-8 bytes. Callers test for a needle with the
/// byte-level `contains` (cheap) and only materialize `string` when a line is
/// relevant — avoiding String creation + Unicode-aware String.contains across
/// every line of multi-GB logs. `bytes` is a view into the reader's buffer and
/// is valid only until the next read.
struct RawLine {
    let bytes: ArraySlice<UInt8>
    let terminated: Bool
    @inline(__always) func contains(_ needle: [UInt8]) -> Bool { bytes.containsBytes(needle) }
    var string: String { String(decoding: bytes, as: UTF8.self) }
}

extension ArraySlice where Element == UInt8 {
    /// Raw byte substring search — no Unicode normalization, unlike String.contains.
    func containsBytes(_ needle: [UInt8]) -> Bool {
        let n = needle.count
        guard n > 0, count >= n else { return false }
        let first = needle[0]
        let hi = endIndex - n
        var i = startIndex
        while i <= hi {
            if self[i] == first {
                var k = 1
                while k < n && self[i &+ k] == needle[k] { k &+= 1 }
                if k == n { return true }
            }
            i &+= 1
        }
        return false
    }
}

/// Precomputed byte needles for the per-line prefilter (the JSON keys, quoted).
enum LineNeedle {
    static let tokenCount = Array("\"token_count\"".utf8)
    static let turnContext = Array("\"turn_context\"".utf8)
    static let assistant = Array("\"assistant\"".utf8)
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
    /// Optional (unlike `int`): pricing rows must be rejected, not zeroed, when malformed.
    func num(_ key: String) -> Double? {
        switch self[key] {
        case let n as NSNumber: return n.doubleValue
        case let d as Double: return d
        case let i as Int: return Double(i)
        default: return nil
        }
    }
}

// MARK: - cooperative scanning

/// How many lines the scan loops process between `await Task.yield()` calls.
/// Frequent enough to interleave with the scheduler/OS across a multi-GB scan
/// (so a single cache-miss rescan doesn't run as one uninterrupted CPU burst),
/// rare enough that yielding itself isn't overhead.
enum ScanYield { static let every = 20_000 }

// MARK: - filesystem

/// Recursively walk a directory, yielding files whose name matches `suffix`.
/// Returns nil when the directory can't be enumerated (missing / unreadable /
/// access not granted) — distinct from an empty-but-readable directory (`[]`),
/// so a transient access failure isn't mistaken for "everything was deleted"
/// and used to wipe the incremental cache.
func files(under root: String, suffix: String) -> [String]? {
    let fm = FileManager.default
    guard let en = fm.enumerator(atPath: root) else { return nil }
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
