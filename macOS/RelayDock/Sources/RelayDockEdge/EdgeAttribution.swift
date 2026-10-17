import Darwin
import Foundation

struct EdgePeerInfo: Equatable, Sendable {
    var pid: Int32
    var name: String
}

/// Best-effort same-user peer attribution through a libproc fd scan — the
/// mechanism `lsof` uses, verified working unprivileged on macOS. It answers
/// "which local process owns this tunnel" from the client socket's local
/// port. It never gates or slows routing: it runs on demand for status,
/// caches briefly, and returning nil is an acceptable outcome.
final class EdgeAttribution: @unchecked Sendable {
    private struct CacheEntry {
        var at: Date
        var info: EdgePeerInfo?
    }

    private let lock = NSLock()
    private var cache: [UInt16: CacheEntry] = [:]
    private let cacheLifetime: TimeInterval = 3

    func peer(forClientPort port: UInt16, edgePort: UInt16) -> EdgePeerInfo? {
        lock.lock()
        if let entry = cache[port], Date().timeIntervalSince(entry.at) < cacheLifetime {
            lock.unlock()
            return entry.info
        }
        lock.unlock()

        let info = Self.scan(clientPort: port, edgePort: edgePort)
        lock.lock()
        cache[port] = CacheEntry(at: Date(), info: info)
        if cache.count > 128 {
            cache = cache.filter { Date().timeIntervalSince($0.value.at) < 60 }
        }
        lock.unlock()
        return info
    }

    private static func scan(clientPort: UInt16, edgePort: UInt16) -> EdgePeerInfo? {
        var capacity = proc_listallpids(nil, 0)
        guard capacity > 0 else { return nil }
        capacity += 16
        var pids = [pid_t](repeating: 0, count: Int(capacity))
        let filled = proc_listallpids(&pids, Int32(MemoryLayout<pid_t>.size * pids.count))
        guard filled > 0 else { return nil }
        let pidCount = Int(filled) / MemoryLayout<pid_t>.size
        let ownPID = getpid()
        let loopback = inet_addr("127.0.0.1")

        for pid in pids.prefix(pidCount) where pid > 0 && pid != ownPID {
            let fdBytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
            guard fdBytes > 0 else { continue }
            let fdCount = Int(fdBytes) / MemoryLayout<proc_fdinfo>.stride + 4
            guard fdCount > 0, fdCount < 8192 else { continue }
            var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: fdCount)
            let got = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(MemoryLayout<proc_fdinfo>.stride * fds.count))
            guard got > 0 else { continue }

            let scannedCount = Int(got) / MemoryLayout<proc_fdinfo>.stride
            for fd in fds.prefix(scannedCount) where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
                var info = socket_fdinfo()
                let result = proc_pidfdinfo(
                    pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info,
                    Int32(MemoryLayout<socket_fdinfo>.stride)
                )
                guard result == MemoryLayout<socket_fdinfo>.stride else { continue }
                guard info.psi.soi_kind == SOCKINFO_TCP, info.psi.soi_family == UInt8(AF_INET) else { continue }
                let tcp = info.psi.soi_proto.pri_tcp
                guard tcp.tcpsi_state == TCPS_ESTABLISHED else { continue }
                // libproc reports ports in network byte order (verified against
                // `lsof -nP -iTCP`); addresses use the same order as `inet_addr`.
                let localPort = UInt16(bigEndian: UInt16(truncatingIfNeeded: tcp.tcpsi_ini.insi_lport))
                let remotePort = UInt16(bigEndian: UInt16(truncatingIfNeeded: tcp.tcpsi_ini.insi_fport))
                guard localPort == clientPort, remotePort == edgePort else { continue }
                // Both endpoints must be loopback: the client socket talks to Edge.
                guard tcp.tcpsi_ini.insi_laddr.ina_46.i46a_addr4.s_addr == loopback,
                      tcp.tcpsi_ini.insi_faddr.ina_46.i46a_addr4.s_addr == loopback else { continue }
                var name = [CChar](repeating: 0, count: 256)
                let nameLength = proc_name(pid, &name, UInt32(name.count))
                let nameBytes = name.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }
                let processName = nameLength > 0 && !nameBytes.isEmpty
                    ? String(decoding: nameBytes, as: UTF8.self)
                    : "pid \(pid)"
                return EdgePeerInfo(pid: pid, name: processName)
            }
        }
        return nil
    }
}
