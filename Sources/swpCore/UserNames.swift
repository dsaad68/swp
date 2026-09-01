import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// uid → login name, cached.
///
/// A scan resolves the same handful of uids a thousand times over, and each
/// miss is a directory-service call — on a machine bound to a network directory
/// that is a round trip, so an uncached scan could take longer than the rest of
/// the program put together. The cache lives for the process, which is right
/// even for the refreshing picker: uids do not get renamed while it is open.
public enum UserNames {

    private static var cache: [uid_t: String] = [:]

    /// The login name for `uid`, or the number as text when there is none —
    /// containers and deleted accounts leave uids with no passwd entry, and a
    /// blank column there would read as a bug.
    public static func name(for uid: uid_t) -> String {
        if let hit = cache[uid] { return hit }
        var resolved = String(uid)
        if let pw = getpwuid(uid), let name = pw.pointee.pw_name {
            resolved = String(cString: name)
        }
        cache[uid] = resolved
        return resolved
    }

    /// The uid behind a name, for `--user`. Accepts a number too, so
    /// `--user 0` and `--user root` agree.
    public static func uid(forName name: String) -> uid_t? {
        if let numeric = UInt32(name) { return uid_t(numeric) }
        guard let pw = getpwnam(name) else { return nil }
        return pw.pointee.pw_uid
    }

    /// Reset the cache. Tests only — nothing in a run wants a cold cache.
    static func resetCacheForTesting() { cache.removeAll() }
}
