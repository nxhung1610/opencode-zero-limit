import Darwin
import Foundation
import RelayDockCore

/// Finds a free loopback port for `relaydock-edge init`. The port is chosen
/// once at install time and never renumbers afterwards: consumers hold it in
/// their environment, so a runtime bind conflict is a loud boot error, not a
/// silent relocation.
enum EdgePortProbe {
    static func isFree(port: Int) -> Bool {
        guard (1...65_535).contains(port) else { return false }
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                bind(descriptor, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { return false }
        return listen(descriptor, 1) == 0
    }

    static func firstFreePort(startingAt: Int, attempts: Int) -> Int? {
        for offset in 0..<max(attempts, 1) {
            let candidate = startingAt + offset
            if isFree(port: candidate) { return candidate }
        }
        return nil
    }
}
