//
//  Created by Cyandev on 11/21/26.
//

import Foundation
import Observation
import Security
import UIKit

/// Saved servers, one Keychain item each, plus the last frame and log of each server’s previous
/// session.
@Observable
final class ServerStore {
    private(set) var servers: [RemoteServer] = []
    private(set) var thumbnails: [UUID: UIImage] = [:]
    /// Servers whose most recent session left a log.
    private(set) var sessionLogs: Set<UUID> = []
    private(set) var loadFailed = false

    @ObservationIgnored private var loaded = false
    private static let service = "me.cyandev.Remo.Server"

    func load(defaults: UserDefaults = .standard) {
        guard !loaded else { return }
        loaded = true
        guard let items = Keychain.items(service: Self.service) else {
            loadFailed = true
            return
        }
        var loadedServers = items.compactMap { account, data -> RemoteServer? in
            guard let server = try? JSONDecoder().decode(RemoteServer.self, from: data),
                server.id.uuidString == account
            else {
                NSLog("Skipping unreadable server item %@", account)
                return nil
            }
            return server
        }
        if loadedServers.isEmpty, let legacy = RemoteServer.legacy(from: defaults), write(legacy) {
            RemoteServer.removeLegacy(from: defaults)
            loadedServers = [legacy]
        }
        servers = loadedServers.sorted(by: RemoteServer.displayOrder)
        for server in servers {
            thumbnails[server.id] = Thumbnails.load(server.id)
            if SessionLogs.exists(server.id) { sessionLogs.insert(server.id) }
        }
    }

    func server(_ id: UUID) -> RemoteServer? {
        servers.first { $0.id == id }
    }

    func save(_ server: RemoteServer) -> Bool {
        guard write(server) else { return false }
        servers.removeAll { $0.id == server.id }
        servers.append(server)
        servers.sort(by: RemoteServer.displayOrder)
        return true
    }

    func delete(_ id: UUID) -> Bool {
        guard Keychain.delete(service: Self.service, account: id.uuidString) else { return false }
        servers.removeAll { $0.id == id }
        thumbnails[id] = nil
        Thumbnails.remove(id)
        sessionLogs.remove(id)
        SessionLogs.remove(id)
        return true
    }

    /// Starts the server’s session log, replacing the previous session’s.
    func beginSessionLog(_ id: UUID) -> SessionLog? {
        do {
            let log = try SessionLog(url: SessionLogs.url(for: id))
            sessionLogs.insert(id)
            return log
        } catch {
            NSLog("Couldn’t start the session log: %@", error.localizedDescription)
            return nil
        }
    }

    /// Records a finished session and keeps its final frame as the server’s preview.
    func recordSession(_ id: UUID, finalFrame: Data) {
        guard var server = server(id) else { return }
        server.lastSessionAt = .now
        if !save(server) { NSLog("Couldn’t record the session for %@", id.uuidString) }
        if Thumbnails.save(finalFrame, for: id), let image = UIImage(data: finalFrame) {
            thumbnails[id] = image
        }
    }

    private func write(_ server: RemoteServer) -> Bool {
        guard let data = try? JSONEncoder().encode(server) else { return false }
        return Keychain.set(data, service: Self.service, account: server.id.uuidString)
    }
}

nonisolated enum Keychain {
    private static func query(service: String, account: String?) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        if let account { query[kSecAttrAccount as String] = account }
        return query
    }

    /// Every item for the service keyed by account, or `nil` when Keychain can’t be read.
    static func items(service: String) -> [(account: String, data: Data)]? {
        var request = query(service: service, account: nil)
        request[kSecMatchLimit as String] = kSecMatchLimitAll
        request[kSecReturnAttributes as String] = true
        request[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let rows = result as? [[String: Any]] else { return nil }
        return rows.compactMap { row in
            guard let account = row[kSecAttrAccount as String] as? String,
                let data = row[kSecValueData as String] as? Data
            else { return nil }
            return (account, data)
        }
    }

    static func data(service: String, account: String? = nil) -> Data? {
        var request = query(service: service, account: account)
        request[kSecReturnData as String] = true
        var item: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    static func set(_ data: Data, service: String, account: String) -> Bool {
        let match = query(service: service, account: account)
        let status = SecItemUpdate(match as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status != errSecItemNotFound { return status == errSecSuccess }
        var item = match
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    static func delete(service: String, account: String? = nil) -> Bool {
        let status = SecItemDelete(query(service: service, account: account) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}

private nonisolated enum Thumbnails {
    private static var directory: URL {
        URL.storageDirectory.appending(path: "Thumbnails", directoryHint: .isDirectory)
    }

    private static func url(for id: UUID) -> URL {
        directory.appending(path: "\(id.uuidString).jpg")
    }

    static func load(_ id: UUID) -> UIImage? {
        UIImage(contentsOfFile: url(for: id).path(percentEncoded: false))
    }

    static func save(_ data: Data, for id: UUID) -> Bool {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url(for: id), options: [.atomic, .completeFileProtection])
            return true
        } catch {
            NSLog("Couldn’t save the preview: %@", error.localizedDescription)
            return false
        }
    }

    static func remove(_ id: UUID) {
        try? FileManager.default.removeItem(at: url(for: id))
    }
}
