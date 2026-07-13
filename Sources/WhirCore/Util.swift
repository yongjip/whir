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
        // libc memchr is SIMD-vectorized — measurably faster across multi-GB
        // scans than a scalar Swift loop with bounds checks.
        buffer.withUnsafeBufferPointer { buf -> Int? in
            guard pos < buf.count, let base = buf.baseAddress,
                  let hit = memchr(base + pos, 0x0A, buf.count - pos) else { return nil }
            return UnsafePointer(hit.assumingMemoryBound(to: UInt8.self)) - base
        }
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
    /// memchr skips to each first-byte candidate with SIMD; memcmp verifies.
    func containsBytes(_ needle: [UInt8]) -> Bool {
        let n = needle.count
        guard n > 0, count >= n else { return false }
        return withUnsafeBufferPointer { hay -> Bool in
            needle.withUnsafeBufferPointer { nee -> Bool in
                guard let hayBase = hay.baseAddress, let neeBase = nee.baseAddress else { return false }
                let first = Int32(neeBase.pointee)
                let endOfStarts = hayBase + (hay.count - n + 1)   // last valid match start + 1
                var search = hayBase
                while search < endOfStarts,
                      let hitRaw = memchr(search, first, endOfStarts - search) {
                    let hit = UnsafePointer(hitRaw.assumingMemoryBound(to: UInt8.self))
                    if memcmp(hit, neeBase, n) == 0 { return true }
                    search = hit + 1
                }
                return false
            }
        }
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

/// Kill switch for concurrent file scanning (A/B measured 4.6x faster full
/// scans at flat peak memory). If it ever misbehaves, turn it off without a
/// rebuild: the app honors `defaults write com.whir.Whir scan.parallel -bool
/// NO`; any process (CLI, tests) honors `WHIR_SERIAL_SCAN=1`. Width 1 runs the
/// exact same code path strictly one file at a time.
public enum ScanConfig {
    public static var parallelScanning =
        ProcessInfo.processInfo.environment["WHIR_SERIAL_SCAN"] == nil
    static var width: Int {
        parallelScanning ? max(2, ProcessInfo.processInfo.activeProcessorCount - 2) : 1
    }
}

/// Bounded-concurrency map over independent per-file scan jobs. Results arrive
/// in completion order — every caller merges by path key, so order is moot.
func scanConcurrently<J: Sendable, R: Sendable>(
    _ jobs: [J], _ work: @escaping @Sendable (J) async -> R) async -> [R] {
    await withTaskGroup(of: R.self, returning: [R].self) { group in
        var out: [R] = []
        out.reserveCapacity(jobs.count)
        var it = jobs.makeIterator()
        func addNext() { if let j = it.next() { group.addTask { await work(j) } } }
        for _ in 0..<ScanConfig.width { addNext() }
        for await r in group { out.append(r); addNext() }
        return out
    }
}

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
