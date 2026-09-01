#if !canImport(Darwin) && canImport(Glibc)
import Foundation
import Glibc

/// Linux process and socket enumeration, read straight out of `/proc`.
///
/// The shape mirrors the Darwin scanner so `ProcessScanner` can hold one seam,
/// but the mechanics are inverted: macOS asks the kernel per process and gets
/// its sockets back, while Linux publishes the socket table globally and makes
/// you join it to processes yourself, through the inode behind each socket fd.
enum LinuxScanner {

    private static let procRoot = "/proc"

    // MARK: - Processes

    static func processes() -> [ProcessRecord] {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: procRoot) else { return [] }
        let boot = bootTime()
        let ticks = Double(sysconf(Int32(_SC_CLK_TCK)))
        let pageSize = UInt64(sysconf(Int32(_SC_PAGESIZE)))

        var records: [ProcessRecord] = []
        records.reserveCapacity(256)
        for entry in entries {
            guard let pid = Int32(entry) else { continue }
            if let record = record(pid: pid, boot: boot, ticks: ticks, pageSize: pageSize) {
                records.append(record)
            }
        }
        return records
    }

    private static func record(pid: Int32, boot: Date?, ticks: Double, pageSize: UInt64) -> ProcessRecord? {
        let base = "\(procRoot)/\(pid)"
        // A process that exits mid-scan takes its whole directory with it, so
        // every read here is allowed to fail and the record is simply dropped.
        guard let stat = try? String(contentsOfFile: "\(base)/stat", encoding: .utf8) else { return nil }

        // `comm` is parenthesised and may itself contain spaces and parens
        // ("(sd-pam)", "(Web Content)"), so the fields are split around the
        // *last* ')' rather than by whitespace across the whole line — the
        // classic /proc/stat parsing bug, and the reason field 22 is never where
        // a naive split puts it.
        guard let open = stat.firstIndex(of: "("), let close = stat.lastIndex(of: ")") else { return nil }
        let comm = String(stat[stat.index(after: open)..<close])
        let rest = stat[stat.index(after: close)...].split(separator: " ").map(String.init)
        // rest[0] is state; ppid is the next one, and the stat(5) field numbers
        // are 3-based from here, so field N sits at rest[N - 3].
        let ppid = rest.count > 1 ? Int32(rest[1]) ?? 0 : 0
        // stat(5) numbers its fields from 1 and `rest` begins at field 3, so
        // field N is rest[N - 3] throughout.
        let utime = rest.count > 11 ? Double(rest[11]) ?? 0 : 0          // field 14
        let stime = rest.count > 12 ? Double(rest[12]) ?? 0 : 0          // field 15
        let startTicks = rest.count > 19 ? Double(rest[19]) ?? 0 : 0     // field 22
        let rssPages = rest.count > 21 ? UInt64(rest[21]) ?? 0 : 0       // field 24

        let uid = realUID(base: base)
        let arguments = commandLine(base: base)
        let path = (try? FileManager.default.destinationOfSymbolicLink(atPath: "\(base)/exe")) ?? ""

        var name = comm
        if name.isEmpty { name = (path as NSString).lastPathComponent }

        var start: Date?
        if let boot, ticks > 0, startTicks > 0 {
            start = boot.addingTimeInterval(startTicks / ticks)
        }

        return ProcessRecord(
            pid: pid,
            ppid: ppid,
            name: name,
            path: path,
            arguments: arguments,
            uid: uid,
            user: UserNames.name(for: uid),
            startTime: start,
            memoryBytes: rssPages * pageSize,
            // Clock ticks, not nanoseconds, and the tick rate is a runtime
            // value — 100 Hz nearly everywhere, but sysconf is the only thing
            // entitled to say so.
            cpuSeconds: ticks > 0 ? (utime + stime) / ticks : nil
        )
    }

    /// The real uid from `/proc/<pid>/status` — its `Uid:` line lists real,
    /// effective, saved and filesystem uids, and the real one is what `ps`
    /// shows and what `--user` should therefore match.
    private static func realUID(base: String) -> uid_t {
        guard let status = try? String(contentsOfFile: "\(base)/status", encoding: .utf8) else { return 0 }
        for line in status.split(separator: "\n") where line.hasPrefix("Uid:") {
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if fields.count > 1, let uid = UInt32(fields[1]) { return uid_t(uid) }
        }
        return 0
    }

    /// The argument vector, NUL-separated in `/proc/<pid>/cmdline`. Empty for
    /// kernel threads, which have no user-space arguments at all.
    private static func commandLine(base: String) -> [String] {
        guard let data = FileManager.default.contents(atPath: "\(base)/cmdline"), !data.isEmpty else {
            return []
        }
        return data.split(separator: 0)
            .compactMap { String(data: Data($0), encoding: .utf8) }
            .filter { !$0.isEmpty }
    }

    /// Boot time from `/proc/stat`'s `btime`, so process start ticks can be
    /// turned into wall-clock dates.
    private static func bootTime() -> Date? {
        guard let stat = try? String(contentsOfFile: "\(procRoot)/stat", encoding: .utf8) else { return nil }
        for line in stat.split(separator: "\n") where line.hasPrefix("btime ") {
            if let seconds = TimeInterval(line.dropFirst("btime ".count).trimmingCharacters(in: .whitespaces)) {
                return Date(timeIntervalSince1970: seconds)
            }
        }
        return nil
    }

    // MARK: - Sockets

    /// Bound endpoints per pid, joined through socket inodes.
    ///
    /// The `/proc/net/*` tables are read once for the whole machine and the
    /// per-process work is a directory listing, so the cost is one pass over
    /// the socket table plus one over the fds — not a table read per process.
    static func listeners(for pids: [Int32]) -> (map: [Int32: [Listener]], denied: Bool) {
        let byInode = socketTable()
        guard !byInode.isEmpty else { return ([:], false) }

        var map: [Int32: [Listener]] = [:]
        var denied = false
        for pid in pids {
            let fdDir = "\(procRoot)/\(pid)/fd"
            guard let fds = try? FileManager.default.contentsOfDirectory(atPath: fdDir) else {
                // EACCES on another user's process; ENOENT on one that just
                // exited. Only the first means the answer is incomplete, and
                // distinguishing them costs a stat we can afford to skip: the
                // caller already knows it skipped processes it does not own.
                continue
            }
            var found: [Listener] = []
            for fd in fds {
                guard let link = try? FileManager.default.destinationOfSymbolicLink(atPath: "\(fdDir)/\(fd)"),
                      link.hasPrefix("socket:["), link.hasSuffix("]") else { continue }
                let inode = String(link.dropFirst("socket:[".count).dropLast())
                if let entries = byInode[inode] { found.append(contentsOf: entries) }
            }
            if !found.isEmpty { map[pid] = found.merged() }
        }
        return (map, denied)
    }

    /// inode → the endpoints it stands for, across TCP/UDP and both families.
    private static func socketTable() -> [String: [Listener]] {
        var table: [String: [Listener]] = [:]
        let sources: [(String, Listener.NetProtocol, Listener.Family)] = [
            ("\(procRoot)/net/tcp", .tcp, .v4),
            ("\(procRoot)/net/tcp6", .tcp, .v6),
            ("\(procRoot)/net/udp", .udp, .v4),
            ("\(procRoot)/net/udp6", .udp, .v6),
        ]
        for (path, netProtocol, family) in sources {
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n").dropFirst() {
                let f = line.split(separator: " ", omittingEmptySubsequences: true)
                guard f.count > 9 else { continue }
                // `st` is the connection state in hex; 0A is TCP_LISTEN. UDP has
                // no listen state, so a bound local port is the whole test there.
                if netProtocol == .tcp, f[3] != "0A" { continue }
                guard let (address, port) = endpoint(String(f[1]), family: family), port != 0 else { continue }
                let inode = String(f[9])
                table[inode, default: []].append(
                    Listener(port: port, netProtocol: netProtocol, family: family, address: address)
                )
            }
        }
        return table
    }

    /// Split a `/proc/net` `local_address` field (`0100007F:1F90`) into a
    /// printable address and a port.
    ///
    /// The address half is the raw in-memory word printed as hex, so on a
    /// little-endian machine its octets arrive reversed — `0100007F` is
    /// 127.0.0.1, not 1.0.0.127. v6 is the same trick four words over.
    private static func endpoint(_ field: String, family: Listener.Family) -> (String, UInt16)? {
        let halves = field.split(separator: ":")
        guard halves.count == 2, let port = UInt16(halves[1], radix: 16) else { return nil }
        let hex = String(halves[0])

        if family == .v4 {
            guard hex.count == 8, let raw = UInt32(hex, radix: 16) else { return nil }
            guard raw != 0 else { return ("*", port) }
            let octets = [raw & 0xFF, (raw >> 8) & 0xFF, (raw >> 16) & 0xFF, (raw >> 24) & 0xFF]
            return (octets.map(String.init).joined(separator: "."), port)
        }

        guard hex.count == 32 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(16)
        for wordIndex in 0..<4 {
            let start = hex.index(hex.startIndex, offsetBy: wordIndex * 8)
            let end = hex.index(start, offsetBy: 8)
            guard let word = UInt32(hex[start..<end], radix: 16) else { return nil }
            bytes.append(contentsOf: [UInt8(word & 0xFF), UInt8((word >> 8) & 0xFF),
                                      UInt8((word >> 16) & 0xFF), UInt8((word >> 24) & 0xFF)])
        }
        guard bytes.contains(where: { $0 != 0 }) else { return ("*", port) }
        var addr = in6_addr()
        withUnsafeMutableBytes(of: &addr) { $0.copyBytes(from: bytes) }
        var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard inet_ntop(AF_INET6, &addr, &buf, socklen_t(INET6_ADDRSTRLEN)) != nil else { return nil }
        return (String(cString: buf), port)
    }
}
#endif
