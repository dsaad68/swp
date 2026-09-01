import Foundation

/// A network endpoint a process holds open.
///
/// Only *bound local* endpoints are collected: a TCP socket in `LISTEN`, or a
/// UDP socket with a local port. Established connections are deliberately left
/// out — "who has 3000?" means the server, not the dozen browser sockets talking
/// to it, and including them buried the one row worth killing.
public struct Listener: Equatable, Hashable, Sendable {

    public enum NetProtocol: String, Equatable, Hashable, Sendable {
        case tcp
        case udp
    }

    /// Which address family the socket was opened on. A server bound to `::`
    /// usually accepts v4 traffic too, so the two are shown as one row when the
    /// port and protocol agree — see `Listener.merge(_:)`.
    public enum Family: String, Equatable, Hashable, Sendable {
        case v4
        case v6
    }

    public var port: UInt16
    public var netProtocol: NetProtocol
    public var family: Family
    /// The bound address, already rendered: `*` for the wildcard, otherwise the
    /// numeric address (`127.0.0.1`, `::1`). Kept as text because that is the
    /// only thing it is ever used for, and because the two families would
    /// otherwise need two fields nothing reads apart.
    public var address: String

    public init(port: UInt16, netProtocol: NetProtocol, family: Family, address: String) {
        self.port = port
        self.netProtocol = netProtocol
        self.family = family
        self.address = address
    }

    /// True when the socket is reachable from another machine — i.e. it is not
    /// bound to loopback. The picker marks these, since killing (or leaving up)
    /// a world-facing listener is the more consequential choice.
    public var isWildcard: Bool { address == "*" }

    /// `*:3000` / `127.0.0.1:5432`, the way `lsof` and every server's own log
    /// line spell it, so the row matches what the user already saw.
    public var display: String { "\(address):\(port)" }
}

public extension Array where Element == Listener {

    /// Collapse the duplicates a dual-stack server produces.
    ///
    /// A process that binds `::` on macOS reports one v6 socket, and one that
    /// binds `0.0.0.0` reports one v4 — but plenty bind both, and Node in
    /// particular reports the same port twice. Two rows saying `*:3000` next to
    /// each other are noise, so entries agreeing on port + protocol + address
    /// are folded into one, preferring the v4 spelling because that is what the
    /// user typed into their browser.
    ///
    /// Sorted by port so the column reads in a stable order across refreshes —
    /// a list that reshuffles under the cursor is a list you cannot kill from.
    func merged() -> [Listener] {
        var seen: [String: Listener] = [:]
        for entry in self {
            let key = "\(entry.netProtocol.rawValue)/\(entry.address)/\(entry.port)"
            if let existing = seen[key] {
                // v4 wins the tie; otherwise keep the first, which is arbitrary
                // but stable for a given scan.
                if existing.family == .v6, entry.family == .v4 { seen[key] = entry }
            } else {
                seen[key] = entry
            }
        }
        return seen.values.sorted {
            ($0.port, $0.netProtocol.rawValue, $0.address) < ($1.port, $1.netProtocol.rawValue, $1.address)
        }
    }

    /// The ports as a single cell: `3000`, or `3000,3001+18` when there are
    /// more than the column can show. Ports repeat
    /// across addresses (a server on both loopback and the wildcard), and the
    /// number is the answer the column exists to give, so they are deduplicated
    /// here even though `merged()` keeps the addresses apart.
    func portSummary(limit: Int = 2) -> String {
        var ports: [UInt16] = []
        for entry in self where !ports.contains(entry.port) { ports.append(entry.port) }
        guard ports.count > limit else { return ports.map(String.init).joined(separator: ",") }
        let head = ports.prefix(limit).map(String.init).joined(separator: ",")
        return "\(head)+\(ports.count - limit)"
    }
}
