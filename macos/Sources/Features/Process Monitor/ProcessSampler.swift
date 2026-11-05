import Darwin
import Foundation

/// One process as the Process Monitor shows it.
struct ProcessSample: Identifiable, Equatable {
    let pid: pid_t
    let ppid: pid_t
    let uid: uid_t
    let name: String
    let path: String?
    /// The command line, empty for processes of other users.
    let arguments: [String]
    let started: Date
    /// Percent of one core over the last interval; nil for processes we may
    /// not inspect, such as root's.
    var cpu: Double?
    /// Memory footprint in bytes, as Activity Monitor's Memory column.
    var memory: UInt64?
    var threads: Int?

    var id: pid_t { pid }

    var commandLine: String {
        arguments.isEmpty ? (path ?? name) : arguments.joined(separator: " ")
    }
}

/// Whole-machine memory figures.
struct SystemMemory: Equatable {
    var total: UInt64 = 0
    var used: UInt64 = 0
    var swapTotal: UInt64 = 0
    var swapUsed: UInt64 = 0
}

/// Reads every process with libproc. CPU use is the change in CPU time since
/// the previous sample, so the first sample has no CPU figures. Not thread
/// safe: use one sampler from one queue.
final class ProcessSampler {
    private struct Previous {
        let start: UInt64
        let cpuTime: UInt64
    }

    private struct Static {
        let start: UInt64
        let path: String?
        let arguments: [String]
    }

    private var previous: [pid_t: Previous] = [:]
    private var previousTime: UInt64 = 0
    /// Paths and arguments don't change after exec, so they're read once.
    private var cache: [pid_t: Static] = [:]

    func sample() -> [ProcessSample] {
        let now = mach_absolute_time()
        let elapsed = previousTime == 0 ? 0 : now - previousTime
        var next: [pid_t: Previous] = [:]
        var nextCache: [pid_t: Static] = [:]
        var samples: [ProcessSample] = []

        for pid in Self.allPIDs() where pid > 0 {
            guard let bsd = Self.basicInfo(pid) else { continue }
            let start = bsd.start

            let fixed: Static
            if let cached = cache[pid], cached.start == start {
                fixed = cached
            } else {
                fixed = Static(start: start, path: Self.path(pid), arguments: Self.arguments(pid))
            }
            nextCache[pid] = fixed

            var sample = ProcessSample(
                pid: pid,
                ppid: bsd.ppid,
                uid: bsd.uid,
                name: Self.name(bsd.name, path: fixed.path, arguments: fixed.arguments),
                path: fixed.path,
                arguments: fixed.arguments,
                started: Date(timeIntervalSince1970: TimeInterval(start / 1_000_000)))

            if let usage = Self.rusage(pid) {
                // Both CPU time and wall time are in mach ticks, so no conversion.
                let cpuTime = usage.ri_user_time + usage.ri_system_time
                next[pid] = Previous(start: start, cpuTime: cpuTime)
                if elapsed > 0, let before = previous[pid], before.start == start {
                    sample.cpu = Double(cpuTime &- before.cpuTime) / Double(elapsed) * 100
                }
                sample.memory = usage.ri_phys_footprint
            }
            sample.threads = Self.threadCount(pid)
            samples.append(sample)
        }

        previous = next
        previousTime = now
        cache = nextCache
        return samples
    }

    // MARK: Trees

    /// Child processes by parent.
    static func children(of samples: [ProcessSample]) -> [pid_t: [pid_t]] {
        var children: [pid_t: [pid_t]] = [:]
        for sample in samples { children[sample.ppid, default: []].append(sample.pid) }
        return children
    }

    /// A process and everything below it.
    static func subtree(_ root: pid_t, children: [pid_t: [pid_t]]) -> [pid_t] {
        var result: [pid_t] = []
        var stack = [root]
        var seen: Set<pid_t> = []
        while let pid = stack.popLast() {
            guard seen.insert(pid).inserted else { continue }
            result.append(pid)
            stack += children[pid] ?? []
        }
        return result
    }

    /// The parent of each running process, read quickly without usage figures.
    static func parents() -> [pid_t: pid_t] {
        var parents: [pid_t: pid_t] = [:]
        for pid in allPIDs() where pid > 0 {
            if let bsd = basicInfo(pid) { parents[pid] = bsd.ppid }
        }
        return parents
    }

    static func descendants(of root: pid_t, parents: [pid_t: pid_t]) -> [pid_t] {
        var children: [pid_t: [pid_t]] = [:]
        for (pid, parent) in parents { children[parent, default: []].append(pid) }
        return subtree(root, children: children)
    }

    // MARK: Machine

    static func systemMemory() -> SystemMemory {
        var memory = SystemMemory()
        memory.total = ProcessInfo.processInfo.physicalMemory

        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        if result == KERN_SUCCESS {
            let page = UInt64(vm_kernel_page_size)
            // Activity Monitor's "Memory Used": app memory, wired and compressed.
            let app = UInt64(stats.internal_page_count) - UInt64(stats.purgeable_count)
            memory.used = (app + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * page
        }

        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 {
            memory.swapTotal = swap.xsu_total
            memory.swapUsed = swap.xsu_used
        }
        return memory
    }

    // MARK: Ending processes

    /// Sends a signal; false when the process is gone or not ours.
    @discardableResult
    static func signal(_ pid: pid_t, _ signal: Int32) -> Bool {
        guard pid > 1, pid != getpid() else { return false }
        return kill(pid, signal) == 0
    }

    // MARK: libproc

    private static func allPIDs() -> [pid_t] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        // Room for processes started between the two calls.
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 64)
        let count = pids.withUnsafeMutableBytes { buffer in
            proc_listallpids(buffer.baseAddress, Int32(buffer.count))
        }
        guard count > 0 else { return [] }
        return Array(pids.prefix(Int(count)))
    }

    private struct BasicInfo {
        let ppid: pid_t
        let uid: uid_t
        /// Microseconds since 1970.
        let start: UInt64
        let name: String
    }

    /// Parent, owner, start and name. libproc refuses other users' processes,
    /// so those are read with sysctl, as ps does.
    private static func basicInfo(_ pid: pid_t) -> BasicInfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        if proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size {
            let name = withUnsafeBytes(of: &info.pbi_name) { cString($0) }
            return BasicInfo(
                ppid: pid_t(info.pbi_ppid),
                uid: info.pbi_uid,
                start: UInt64(info.pbi_start_tvsec) * 1_000_000 + UInt64(info.pbi_start_tvusec),
                name: name.isEmpty ? withUnsafeBytes(of: &info.pbi_comm) { cString($0) } : name)
        }

        var process = kinfo_proc()
        var length = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &process, &length, nil, 0) == 0, length > 0 else { return nil }
        let started = process.kp_proc.p_un.__p_starttime
        return BasicInfo(
            ppid: process.kp_eproc.e_ppid,
            uid: process.kp_eproc.e_ucred.cr_uid,
            start: UInt64(started.tv_sec) * 1_000_000 + UInt64(started.tv_usec),
            name: withUnsafeBytes(of: &process.kp_proc.p_comm) { cString($0) })
    }

    private static func cString(_ bytes: UnsafeRawBufferPointer) -> String {
        let end = bytes.firstIndex(of: 0) ?? bytes.count
        return String(decoding: bytes[..<end], as: UTF8.self)
    }

    private static func rusage(_ pid: pid_t) -> rusage_info_v4? {
        var usage = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        return result == 0 ? usage : nil
    }

    private static func threadCount(_ pid: pid_t) -> Int? {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size else { return nil }
        return Int(info.pti_threadnum)
    }

    private static func path(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    /// The name the process was started as, so `claude` shows as claude and
    /// not as the versioned file it runs; else the executable's name.
    private static func name(_ kernelName: String, path: String?, arguments: [String]) -> String {
        if let first = arguments.first, !first.isEmpty { return (first as NSString).lastPathComponent }
        if let path, !path.isEmpty { return (path as NSString).lastPathComponent }
        return kernelName
    }

    /// The command line from KERN_PROCARGS2: argc, the executable path, then
    /// argv, each ending in NUL.
    private static func arguments(_ pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return [] }

        let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        var index = MemoryLayout<Int32>.size
        // Skip the executable path and the NULs that pad it.
        while index < size, buffer[index] != 0 { index += 1 }
        while index < size, buffer[index] == 0 { index += 1 }

        var arguments: [String] = []
        while arguments.count < argc, index < size {
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            arguments.append(String(decoding: buffer[start..<index], as: UTF8.self))
            index += 1
        }
        return arguments
    }
}
