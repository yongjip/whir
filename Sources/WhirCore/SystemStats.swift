import Foundation
import Darwin

/// A point-in-time read of overall system load.
public struct SystemSnapshot: Sendable {
    public var cpu: Double          // 0...1 busy fraction (all cores)
    public var ramUsed: UInt64      // bytes
    public var ramTotal: UInt64
    public var diskUsed: Int64
    public var diskTotal: Int64

    public init(cpu: Double = 0, ramUsed: UInt64 = 0, ramTotal: UInt64 = 0,
                diskUsed: Int64 = 0, diskTotal: Int64 = 0) {
        self.cpu = cpu; self.ramUsed = ramUsed; self.ramTotal = ramTotal
        self.diskUsed = diskUsed; self.diskTotal = diskTotal
    }
    public var ramFraction: Double { ramTotal > 0 ? Double(ramUsed) / Double(ramTotal) : 0 }
    public var diskFraction: Double { diskTotal > 0 ? Double(diskUsed) / Double(diskTotal) : 0 }
}

/// Samples CPU / RAM / disk via Mach host statistics and volume capacity.
/// CPU is a delta between calls, so call `cpu()` once to prime, then sample.
public final class SystemSampler {
    private var prev: (busy: UInt64, total: UInt64)?
    private var lastCPU: Double = 0
    public init() {}

    public func cpu() -> Double {
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { p in
            p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return lastCPU }
        func u(_ v: natural_t) -> UInt64 { UInt64(v) }
        let busy = u(info.cpu_ticks.0) &+ u(info.cpu_ticks.1) &+ u(info.cpu_ticks.3)  // user+system+nice
        let total = busy &+ u(info.cpu_ticks.2)                                       // + idle
        defer { prev = (busy, total) }
        guard let p = prev, total > p.total else { return lastCPU }
        lastCPU = Double(busy - p.busy) / Double(total - p.total)
        return lastCPU
    }

    public func memory() -> (used: UInt64, total: UInt64) {
        let total = ProcessInfo.processInfo.physicalMemory
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &stats) { p in
            p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return (0, total) }
        let page = UInt64(vm_page_size)
        // Activity-Monitor-style "used" ≈ active + wired + compressed.
        let used = (UInt64(stats.active_count) + UInt64(stats.wire_count)
                    + UInt64(stats.compressor_page_count)) * page
        return (used, total)
    }

    public func disk() -> (used: Int64, total: Int64) {
        let url = URL(fileURLWithPath: "/")
        let v = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey])
        let total = Int64(v?.volumeTotalCapacity ?? 0)
        let avail = Int64(v?.volumeAvailableCapacity ?? 0)
        return (max(total - avail, 0), total)
    }

    public func sample() -> SystemSnapshot {
        let c = cpu(); let m = memory(); let d = disk()
        return SystemSnapshot(cpu: c, ramUsed: m.used, ramTotal: m.total, diskUsed: d.used, diskTotal: d.total)
    }
}
