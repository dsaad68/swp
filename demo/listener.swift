// A listener that does nothing but hold a port, for the demo to find and kill.
//
// Compiled rather than scripted because macOS takes a process's NAME from its
// executable, not from argv[0] — `exec -a vite python3 …` still shows up as
// "Python". Copying this binary to `dev-server`, `vite` and `api-gateway` is
// what makes the demo's NAME column say something recognisable.
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

// Takes `--port N` rather than a bare number so the demo can pass a realistic
// argument vector — the COMMAND column shows the arguments after argv[0], and
// "5173" on its own reads as a bug rather than as a server.
let arguments = CommandLine.arguments
let port: UInt16 = {
    guard let i = arguments.firstIndex(of: "--port"), i + 1 < arguments.count else { return 0 }
    return UInt16(arguments[i + 1]) ?? 0
}()
let fd = socket(AF_INET, 1 /* SOCK_STREAM */, 0)
var yes: Int32 = 1
setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
var addr = sockaddr_in()
addr.sin_family = sa_family_t(AF_INET)
addr.sin_port = port.bigEndian
addr.sin_addr.s_addr = INADDR_ANY
let bound = withUnsafePointer(to: &addr) { p in
    p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
    }
}
guard bound == 0, listen(fd, 8) == 0 else { exit(1) }
// Idle forever; the demo is what ends it.
while true { sleep(3600) }
