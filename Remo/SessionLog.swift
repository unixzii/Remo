//
//  Created by Cyandev on 11/22/26.
//

import Foundation

/// The log of one session, in the same lines the `remo-engine` CLI prints, each stamped with
/// the time of day. Lines may come from any thread; they are written in order on a queue.
nonisolated final class SessionLog: @unchecked Sendable {
    /// Stops a runaway session from filling the disk; about a day of statistics lines.
    private static let limit = 32 << 20

    let url: URL
    private let queue = DispatchQueue(label: "Remo.SessionLog", qos: .utility)
    // Accessed only on queue.
    private var handle: FileHandle?
    private var written = 0

    /// Starts a new log at `url`, replacing the previous one.
    init(url: URL) throws {
        self.url = url
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: url, options: .atomic)
        handle = try FileHandle(forWritingTo: url)
    }

    func write(_ line: String) {
        let stamp = Date.now.formatted(.iso8601.time(includingFractionalSeconds: true))
        let data = Data("\(stamp) \(line)\n".utf8)
        queue.async { [self] in
            guard let handle else { return }
            guard written + data.count <= Self.limit else {
                try? handle.write(contentsOf: Data("\(stamp) log size limit reached\n".utf8))
                close(handle)
                return
            }
            do {
                try handle.write(contentsOf: data)
                written += data.count
            } catch {
                NSLog("Couldn’t write the session log: %@", error.localizedDescription)
                close(handle)
            }
        }
    }

    /// Flushes and closes the file. Later lines are dropped.
    func close() {
        queue.async { [self] in
            if let handle { close(handle) }
        }
    }

    private func close(_ handle: FileHandle) {
        try? handle.close()
        self.handle = nil
    }
}

/// Where each server's most recent session log lives.
nonisolated enum SessionLogs {
    private static var directory: URL {
        URL.storageDirectory.appending(path: "Logs", directoryHint: .isDirectory)
    }

    static func url(for id: UUID) -> URL {
        directory.appending(path: "\(id.uuidString).log")
    }

    static func exists(_ id: UUID) -> Bool {
        FileManager.default.fileExists(atPath: url(for: id).path(percentEncoded: false))
    }

    static func remove(_ id: UUID) {
        try? FileManager.default.removeItem(at: url(for: id))
    }
}
