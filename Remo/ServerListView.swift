//
//  Created by Cyandev on 11/21/26.
//

import SwiftUI
import UIKit

struct ServerListView: View {
    let store: ServerStore
    @Binding var selection: UUID?
    let onAdd: () -> Void
    let onEdit: (RemoteServer) -> Void
    let onDelete: (RemoteServer) -> Void

    var body: some View {
        List(selection: $selection) {
            ForEach(store.servers) { server in
                NavigationLink(value: server.id) {
                    ServerRow(server: server, thumbnail: store.thumbnails[server.id])
                }
                .contextMenu {
                    Button("Edit", systemImage: "pencil") { onEdit(server) }
                    Button("Delete", systemImage: "trash", role: .destructive) { onDelete(server) }
                }
            }
        }
        .overlay {
            if store.loadFailed {
                ContentUnavailableView(
                    "Couldn’t Load Servers", systemImage: "exclamationmark.triangle",
                    description: Text("Remo couldn’t read the saved servers from Keychain."))
            } else if store.servers.isEmpty {
                ContentUnavailableView {
                    Label("No Servers", systemImage: "display")
                } description: {
                    Text("Add a Mac running the Remo server to see and control it from here.")
                } actions: {
                    Button("Add Server", action: onAdd)
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .navigationTitle("Remo")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Add Server", systemImage: "plus", action: onAdd)
                    .labelStyle(.iconOnly)
            }
        }
    }
}

private struct ServerRow: View {
    @Environment(\.appearsActive) private var appearsActive
    let server: RemoteServer
    let thumbnail: UIImage?

    var body: some View {
        HStack(spacing: 14) {
            ServerThumbnail(image: thumbnail, cornerRadius: 10)
                .frame(width: 104)
            VStack(alignment: .leading, spacing: 3) {
                Text(server.displayName)
                    .font(.headline)
                    .foregroundStyle(
                        appearsActive ? AnyShapeStyle(.primary) : AnyShapeStyle(Color(.label))
                    )
                    .lineLimit(1)
                HStack(spacing: 4) {
                    if server.useWireGuard {
                        Image(systemName: "lock.fill")
                            .imageScale(.small)
                            .accessibilityLabel("WireGuard")
                    }
                    Text(server.address.host)
                        .monospaced()
                        .lineLimit(1)
                }
                .font(.subheadline)
                .foregroundStyle(
                    appearsActive
                        ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color(.secondaryLabel)))
                LastSessionText(date: server.lastSessionAt, compact: true)
                    .font(.caption)
                    .foregroundStyle(
                        appearsActive
                            ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color(.secondaryLabel)))
            }
        }
        .padding(.vertical, 4)
    }
}

struct LastSessionText: View {
    let date: Date?
    /// Drops the “Last session” prefix where rows are narrow.
    var compact = false

    var body: some View {
        if let date {
            if compact {
                Text(date, format: .relative(presentation: .named))
            } else {
                Text("Last session \(date, format: .relative(presentation: .named))")
            }
        } else {
            Text("Never connected")
        }
    }
}

/// The last frame of a server’s previous session, or a placeholder before its first one.
struct ServerThumbnail: View {
    let image: UIImage?
    let cornerRadius: CGFloat

    var body: some View {
        Color(.systemGray5)
            .aspectRatio(16 / 10, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "display")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
            }
            .clipShape(.rect(cornerRadius: cornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(.primary.opacity(0.08), lineWidth: 0.5)
            }
            .accessibilityHidden(true)
    }
}
