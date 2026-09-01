import Foundation

/// What the user asked for, as a value that can be matched against a process.
///
/// Deliberately not fuzzy. The interactive filter is fuzzy because a wrong
/// match there costs a keystroke, but a query on the command line can end in
/// `--kill`, and a scoring function that decides `node` also means `nodemon` is
/// not something to hand a signal. So terms here are exact for numbers and
/// case-insensitive substrings for text — the rule fits in one sentence of
/// `--help`, which is the real test.
public struct Query: Equatable, Sendable {

    /// The highest number that can be a port. A bare number above it cannot be
    /// one, so it is read as a pid instead of matching nothing.
    public static let maxPort = 65535

    public var ports: [UInt16] = []
    public var pids: [Int32] = []
    /// Free text, matched against the name first and the whole command line
    /// second.
    public var terms: [String] = []

    public init(ports: [UInt16] = [], pids: [Int32] = [], terms: [String] = []) {
        self.ports = ports
        self.pids = pids
        self.terms = terms
    }

    /// True when nothing was asked for, i.e. every process matches.
    public var isEmpty: Bool { ports.isEmpty && pids.isEmpty && terms.isEmpty }

    /// Classify one bare word from the command line.
    ///
    /// A number is a port, because that is what people type: `swp 3000`. Above
    /// `maxPort` it cannot be a port, so it is a pid — which also makes
    /// `swp 41235` do the obvious thing without a flag.
    public static func classify(_ word: String) -> Query {
        guard let number = Int(word), number >= 0 else { return Query(terms: [word]) }
        if number <= maxPort { return Query(ports: [UInt16(number)]) }
        guard let pid = Int32(exactly: number) else { return Query(terms: [word]) }
        return Query(pids: [pid])
    }

    /// Merge another query into this one. Terms accumulate across all three
    /// kinds, and matching is an AND across kinds — `swp node 3000` means the
    /// node process on 3000, not everything called node plus everything on 3000.
    public mutating func merge(_ other: Query) {
        ports.append(contentsOf: other.ports)
        pids.append(contentsOf: other.pids)
        terms.append(contentsOf: other.terms)
    }

    /// Whether `record` satisfies the query.
    ///
    /// Within a kind the terms are an OR (`--port 3000 --port 8080` means
    /// either), across kinds an AND. That is the reading that makes each extra
    /// word narrow the result, which is what typing another word is for.
    public func matches(_ record: ProcessRecord) -> Bool {
        if !ports.isEmpty {
            guard record.listeners.contains(where: { ports.contains($0.port) }) else { return false }
        }
        if !pids.isEmpty {
            guard pids.contains(record.pid) else { return false }
        }
        for term in terms {
            guard Query.matches(term: term, in: record) else { return false }
        }
        return true
    }

    /// One text term against one process: the executable name first, then the
    /// full command line, then the user.
    ///
    /// The name is checked on its own rather than as part of the command line
    /// so that `swp node` cannot be satisfied by an unrelated process that
    /// merely mentions node in an argument — it still matches that process, but
    /// only after everything actually called node, which is what the ordering
    /// in `filter` preserves.
    static func matches(term: String, in record: ProcessRecord) -> Bool {
        let needle = term.lowercased()
        if record.name.lowercased().contains(needle) { return true }
        if record.commandLine.lowercased().contains(needle) { return true }
        if record.user.lowercased() == needle { return true }
        return false
    }

    /// Apply the query.
    ///
    /// When any process matches a term *by name*, the ones that matched only
    /// because their command line mentions it are dropped rather than merely
    /// ranked lower. `swp node` on a machine running VS Code otherwise returns
    /// the one node server plus six helpers whose arguments contain
    /// `node.mojom` — and this is a query that can end in `--kill`, so a
    /// near-miss is worse than no match. The looser reading is still there when
    /// nothing matches by name, which is what makes `swp mojom` find them.
    public func filter(_ records: [ProcessRecord]) -> [ProcessRecord] {
        let matched = records.filter(matches)
        guard !terms.isEmpty else { return matched }
        let byName = matched.filter { record in
            terms.allSatisfy { record.name.lowercased().contains($0.lowercased()) }
        }
        return byName.isEmpty ? matched : byName
    }
}
