import Foundation

extension URL {
    /// Where the app keeps its files. Outside a sandbox, as on the Mac, Application Support is
    /// shared by every app, so the app's files go in a folder named for it.
    nonisolated static var storageDirectory: URL {
        #if targetEnvironment(macCatalyst)
            applicationSupportDirectory.appending(
                path: Bundle.main.bundleIdentifier ?? "Remo", directoryHint: .isDirectory)
        #else
            applicationSupportDirectory
        #endif
    }
}
