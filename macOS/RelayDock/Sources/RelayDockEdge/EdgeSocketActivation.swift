import Darwin
import Foundation
import RelayDockCore

/// launchd socket activation (P3): the installer's agent plist declares
/// `Sockets`, launchd owns the listening sockets, and Edge is started on the
/// first connection. Edge retrieves the descriptors with
/// `launch_activate_socket`; when it was not started that way (spawn-on-demand
/// or a direct `run`), the lookup finds nothing and the server binds its own
/// listener exactly as before.
enum EdgeSocketActivation {
    /// launchd `Sockets` key for the primary loopback listener.
    static let primaryName = "Listeners"

    /// launchd `Sockets` key for the configured listener at `index` in
    /// `edge.json` (1-based: the primary is `Listeners`, so the first extra
    /// listener is `Listeners-2`).
    static func listenerName(index: Int) -> String { "Listeners-\(index + 2)" }

    /// The inherited descriptors for `name`, or an empty array when Edge is
    /// not running under launchd socket activation.
    ///
    /// Test/sandbox override: `RELAYDOCK_EDGE_ACTIVATE_FD` preloads the
    /// primary listener's descriptor (the sandbox binds a loopback socket and
    /// passes it through exec, exercising the whole activated serve path
    /// without a real launchd).
    static func listeningDescriptors(named name: String) -> [Int32] {
        let environment = ProcessInfo.processInfo.environment
        if name == primaryName,
           let raw = environment["RELAYDOCK_EDGE_ACTIVATE_FD"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty,
           let fd = Int32(raw), fd >= 0 {
            return [fd]
        }
        var descriptors: UnsafeMutablePointer<Int32>?
        var count = 0
        let result = relaydock_launch_activate_socket(name, &descriptors, &count)
        guard result == 0, let descriptors else { return [] }
        defer { free(descriptors) }
        return (0..<count).map { descriptors[$0] }
    }
}

/// `launch_activate_socket` from `<launch.h>`, declared here so the package
/// needs no C shim. Returns 0 on success and hands back a malloc'd array the
/// caller frees; the descriptors themselves stay open.
@_silgen_name("launch_activate_socket")
private func relaydock_launch_activate_socket(
    _ name: UnsafePointer<CChar>,
    _ descriptors: UnsafeMutablePointer<UnsafeMutablePointer<Int32>?>?,
    _ count: UnsafeMutablePointer<Int>?
) -> Int32

/// What each listener reported at start: port, pinned entry (nil for the
/// primary), and whether it came from launchd socket activation. The daemon
/// flattens this into the status payload.
final class EdgeListenerReport: @unchecked Sendable {
    struct Entry: Sendable, Equatable {
        var port: Int
        var entryID: String?
        var activated: Bool
    }

    private let lock = NSLock()
    private var entries: [Entry] = []

    func note(port: Int, entryID: String?, activated: Bool) {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll { $0.port == port }
        entries.append(Entry(port: port, entryID: entryID, activated: activated))
    }

    func snapshot() -> [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return entries.sorted { $0.port < $1.port }
    }
}
