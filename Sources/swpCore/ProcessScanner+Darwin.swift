#if canImport(Darwin)
import Darwin
import Foundation

/// macOS process and socket enumeration, straight from `libproc` and `sysctl`.
///
/// Nothing here shells out. `lsof`/`ps` would each cost a fork, a pipe and a
/// parser for output that is not a stable interface, and `lsof` in particular
/// takes longer to start than this whole scan takes to run.
enum DarwinScanner {

    // MARK: - Processes

    /// Every process on the machine, without their sockets.
    ///
    /// Enumerated through `sysctl(KERN_PROC_ALL)` — the same table `ps` reads —
    /// rather than `proc_listpids` + `proc_pidinfo`. The libproc route looks
    /// tidier and quietly loses a third of the machine: `PROC_PIDTBSDINFO`
    /// returns `EPERM` for a process we do not own, so every root and system
    /// service was dropped from the list without a word. The sysctl table has
    /// no such restriction; it carries the pid, parent, uid, name and start
    /// time for everything, and libproc is then asked only for the extras
    /// (path, memory, arguments) that it is willing to give.
    static func processes() -> [ProcessRecord] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [] }

        let stride = MemoryLayout<kinfo_proc>.stride
        // Headroom for processes started between the sizing call and the read;
        // the kernel reports how much it actually wrote, so the slack costs
        // nothing but a little memory.
        var table = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 64)
        size = table.count * stride
        guard sysctl(&mib, 4, &table, &size, nil, 0) == 0 else { return [] }
        let count = size / stride

        // One reader for the whole scan. `KERN_PROCARGS2` wants a buffer the
        // size of `KERN_ARGMAX` — a megabyte on macOS — and allocating (and
        // zeroing) one per process turned a 12 ms scan into a 600 ms one.
        let reader = ArgumentReader()
        var records: [ProcessRecord] = []
        records.reserveCapacity(count)
        for entry in table[0..<count] where entry.kp_proc.p_pid > 0 {
            records.append(record(from: entry, reader: reader))
        }
        return records
    }

    private static func record(from entry: kinfo_proc, reader: ArgumentReader) -> ProcessRecord {
        var entry = entry
        let pid = entry.kp_proc.p_pid
        let path = executablePath(pid)

        // `p_comm` is capped at 16 characters, so "Google Chrome Helper" arrives
        // cut. `proc_pidinfo`'s `pbi_name` holds twice that and is tried first;
        // for another user's process it is refused, and the truncated name is
        // then the best the kernel will say — better a short true name than a
        // blank column.
        var name = ""
        var info = proc_bsdinfo()
        if proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info,
                        Int32(MemoryLayout<proc_bsdinfo>.size)) == Int32(MemoryLayout<proc_bsdinfo>.size) {
            name = string(from: info.pbi_name)
        }
        if name.isEmpty { name = string(from: entry.kp_proc.p_comm) }
        if name.isEmpty { name = (path as NSString).lastPathComponent }

        // One call, two answers: the same `proc_taskinfo` that carries resident
        // size carries the cumulative CPU counters, so CPU costs no syscall at
        // all. Both are refused together for a process we do not own, which is
        // why the MEM and CPU columns go blank on the same rows.
        var memory: UInt64?
        var cpuSeconds: TimeInterval?
        var task = proc_taskinfo()
        if proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task,
                        Int32(MemoryLayout<proc_taskinfo>.size)) == Int32(MemoryLayout<proc_taskinfo>.size) {
            memory = task.pti_resident_size
            // The counters are nanoseconds on Darwin, already summed across the
            // process's threads.
            cpuSeconds = TimeInterval(task.pti_total_user + task.pti_total_system) / 1_000_000_000
        }

        let started = entry.kp_proc.p_starttime
        let uid = entry.kp_eproc.e_ucred.cr_uid

        return ProcessRecord(
            pid: pid,
            ppid: entry.kp_eproc.e_ppid,
            name: name,
            path: path,
            arguments: reader.arguments(pid),
            uid: uid,
            user: UserNames.name(for: uid),
            startTime: started.tv_sec > 0
                ? Date(timeIntervalSince1970: TimeInterval(started.tv_sec))
                : nil,
            memoryBytes: memory,
            cpuSeconds: cpuSeconds
        )
    }

    private static func executablePath(_ pid: pid_t) -> String {
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        // Refused for another user's process without root; an empty path is the
        // honest answer there, and the name still comes from the sysctl table.
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return "" }
        return String(cString: buf)
    }

    /// Reads argument vectors, reusing one big buffer across a whole scan.
    ///
    /// A class rather than free functions purely so the buffer has an owner
    /// with a `deinit`: `KERN_ARGMAX` is a megabyte, and the alternative —
    /// allocating it per process — is the single most expensive thing this
    /// scanner could do.
    final class ArgumentReader {

        private let capacity: Int
        private let buffer: UnsafeMutablePointer<CChar>

        init() {
            var argMax: Int32 = 0
            var size = MemoryLayout<Int32>.size
            var mib: [Int32] = [CTL_KERN, KERN_ARGMAX]
            // The sysctl has not failed in living memory, but a fallback keeps
            // the reader usable rather than making every caller handle nil.
            if sysctl(&mib, 2, &argMax, &size, nil, 0) != 0 || argMax <= 0 { argMax = 262_144 }
            capacity = Int(argMax)
            // Deliberately not zeroed: the kernel reports how much it wrote and
            // nothing past that is ever read.
            buffer = UnsafeMutablePointer<CChar>.allocate(capacity: capacity)
        }

        deinit { buffer.deallocate() }

        /// The full argument vector for `pid`, or empty when the kernel refuses.
        ///
        /// The buffer's layout is: a 4-byte argc, the executable path, NUL
        /// padding, then argc NUL-terminated arguments, then the environment —
        /// which is deliberately never read past. Environments hold tokens and
        /// passwords, and this tool prints what it reads.
        func arguments(_ pid: pid_t) -> [String] {
            var length = capacity
            var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
            // EPERM for another user's process without root, EINVAL for one that
            // just exited. Both mean "no arguments", which callers already handle.
            guard sysctl(&mib, 3, buffer, &length, nil, 0) == 0,
                  length > MemoryLayout<Int32>.size else { return [] }

            let raw = UnsafeRawBufferPointer(start: buffer, count: length)
            let argc = Int(raw.loadUnaligned(as: Int32.self))
            guard argc > 0 else { return [] }

            var index = MemoryLayout<Int32>.size
            // Step over the executable path and the NUL padding the kernel
            // aligns the first argument with.
            while index < length, raw[index] != 0 { index += 1 }
            while index < length, raw[index] == 0 { index += 1 }

            var result: [String] = []
            result.reserveCapacity(argc)
            var start = index
            while index < length, result.count < argc {
                if raw[index] == 0 {
                    // Lossy on purpose, and so exempt from the rule that would
                    // have this use `String(bytes:encoding:)`: that returns nil
                    // for an argument that is not valid UTF-8, which would drop
                    // the argument — and shift every later one into its place.
                    // Replacement characters are the honest rendering.
                    // swiftlint:disable:next optional_data_string_conversion
                    result.append(String(decoding: raw[start..<index], as: UTF8.self))
                    start = index + 1
                }
                index += 1
            }
            return result
        }
    }

    /// Read a fixed-size C char tuple (`pbi_name`, `pbi_comm`) as a String.
    private static func string<T>(from tuple: T) -> String {
        withUnsafeBytes(of: tuple) { raw in
            guard let base = raw.baseAddress else { return "" }
            return String(cString: base.assumingMemoryBound(to: CChar.self))
        }
    }

    // MARK: - Sockets

    /// Bound local endpoints per pid.
    ///
    /// Without root the kernel only opens the file descriptors of processes we
    /// own, so another user's server shows up in the list with no ports against
    /// it. That is a real limit rather than a bug, and `swp` says so in the
    /// footer instead of pretending the port is unheld — see `ScanNotes`.
    static func listeners(for pids: [pid_t]) -> (map: [pid_t: [Listener]], denied: Bool) {
        var map: [pid_t: [Listener]] = [:]
        var denied = false
        for pid in pids {
            let (found, wasDenied) = listeners(pid)
            if wasDenied { denied = true }
            if !found.isEmpty { map[pid] = found.merged() }
        }
        return (map, denied)
    }

    private static func listeners(_ pid: pid_t) -> (listeners: [Listener], denied: Bool) {
        let sizeGuess = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard sizeGuess > 0 else { return ([], errno == EPERM) }
        var fds = [proc_fdinfo](repeating: proc_fdinfo(),
                                count: Int(sizeGuess) / MemoryLayout<proc_fdinfo>.size)
        let written = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, sizeGuess)
        guard written > 0 else { return ([], errno == EPERM) }

        var found: [Listener] = []
        for fd in fds[0..<(Int(written) / MemoryLayout<proc_fdinfo>.size)]
        where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var info = socket_fdinfo()
            let n = proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info,
                                   Int32(MemoryLayout<socket_fdinfo>.size))
            guard n == Int32(MemoryLayout<socket_fdinfo>.size) else { continue }
            if let listener = listener(from: info) { found.append(listener) }
        }
        return (found, false)
    }

    private static func listener(from info: socket_fdinfo) -> Listener? {
        switch info.psi.soi_kind {
        case Int32(SOCKINFO_TCP):
            let tcp = info.psi.soi_proto.pri_tcp
            // Only sockets in LISTEN. An established connection is a client of
            // whoever is listening, and listing every one of a browser's
            // sockets would bury the single row worth acting on.
            guard tcp.tcpsi_state == Int32(TSI_S_LISTEN) else { return nil }
            return endpoint(tcp.tcpsi_ini, netProtocol: .tcp)
        case Int32(SOCKINFO_IN):
            // UDP has no listen state; a bound local port is the whole signal.
            let ins = info.psi.soi_proto.pri_in
            guard ins.insi_lport != 0 else { return nil }
            return endpoint(ins, netProtocol: .udp)
        default:
            return nil
        }
    }

    /// Turn an `in_sockinfo` into a `Listener`, or nil when it carries no port.
    ///
    /// The port arrives in network byte order inside an `Int32` field, so it is
    /// narrowed before the swap — taking `bigEndian` of the widened value would
    /// shift the port into the high half and read every server as port 0.
    private static func endpoint(_ ins: in_sockinfo, netProtocol: Listener.NetProtocol) -> Listener? {
        let port = UInt16(bigEndian: UInt16(truncatingIfNeeded: ins.insi_lport))
        guard port != 0 else { return nil }
        if ins.insi_vflag & UInt8(INI_IPV6) != 0, ins.insi_vflag & UInt8(INI_IPV4) == 0 {
            let addr = ins.insi_laddr.ina_6
            return Listener(port: port, netProtocol: netProtocol, family: .v6,
                            address: format(v6: addr))
        }
        let raw = ins.insi_laddr.ina_46.i46a_addr4.s_addr
        return Listener(port: port, netProtocol: netProtocol, family: .v4,
                        address: format(v4: raw))
    }

    private static func format(v4 raw: in_addr_t) -> String {
        guard raw != 0 else { return "*" }
        var addr = in_addr(s_addr: raw)
        var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &addr, &buf, socklen_t(INET_ADDRSTRLEN)) != nil else { return "*" }
        return String(cString: buf)
    }

    private static func format(v6 addr: in6_addr) -> String {
        var value = addr
        let isUnspecified = withUnsafeBytes(of: &value) { $0.allSatisfy { $0 == 0 } }
        guard !isUnspecified else { return "*" }
        var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard inet_ntop(AF_INET6, &value, &buf, socklen_t(INET6_ADDRSTRLEN)) != nil else { return "*" }
        return String(cString: buf)
    }
}
#endif
