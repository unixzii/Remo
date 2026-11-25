//
//  Created by Cyandev on 11/21/26.
//

import RemoEngine
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Shows a server and edits it in place.
struct ServerDetailView: View {
    let server: RemoteServer
    let thumbnail: UIImage?
    /// The most recent session's log, once there has been a session.
    let sessionLog: URL?
    /// Logical size of the window scene hosting this view, used to preview virtual display size.
    let sceneSize: CGSize
    let isNew: Bool
    let failure: String?
    let canConnect: Bool
    @Binding var editRequest: UUID?
    let onSave: (RemoteServer) -> Bool
    let onConnect: (RemoteServer) -> Void
    let onCancelNew: () -> Void
    let onDelete: (RemoteServer) -> Void

    @State private var isEditing: Bool
    @State private var draft: RemoteServer
    @State private var customWidthText: String
    @State private var customHeightText: String
    @State private var customFrameRate: Bool
    @State private var customFrameRateText: String
    @State private var customBitRate: Bool
    @State private var customBitRateText: String
    @State private var saveFailed = false
    #if targetEnvironment(macCatalyst)
    /// Matches macOS System Settings grouped-form cards on Mac Catalyst, where UIKit's
    /// inset-grouped Form defaults to iOS's gray canvas with white cards.
    fileprivate static let catalystCardBackground = Color(
        uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(white: 1, alpha: 0.045)
                : UIColor(white: 0, alpha: 0.027)
        })
    fileprivate static let catalystRowInsets = EdgeInsets(
        top: 8, leading: 12, bottom: 8, trailing: 12)
    fileprivate static let catalystHeaderRowInsets = EdgeInsets(
        top: 12, leading: 12, bottom: 12, trailing: 12)
    fileprivate static let catalystSummaryHeaderInsets = EdgeInsets(
        top: 4, leading: 0, bottom: 4, trailing: 0)
    fileprivate static let catalystSectionHeaderInsets = EdgeInsets(
        top: 4, leading: 12, bottom: 6, trailing: 12)
    fileprivate static let catalystSectionFooterInsets = EdgeInsets(
        top: 6, leading: 12, bottom: 0, trailing: 12)
    #else
    @State private var isWide = false

    /// Detail width from which Connect sits beside the name instead of spanning the page.
    private static let wideLayoutWidth: CGFloat = 520
    #endif

    init(
        server: RemoteServer, thumbnail: UIImage?, sessionLog: URL?, sceneSize: CGSize,
        isNew: Bool, failure: String?,
        canConnect: Bool,
        editRequest: Binding<UUID?>, onSave: @escaping (RemoteServer) -> Bool,
        onConnect: @escaping (RemoteServer) -> Void, onCancelNew: @escaping () -> Void,
        onDelete: @escaping (RemoteServer) -> Void
    ) {
        self.server = server
        self.thumbnail = thumbnail
        self.sessionLog = sessionLog
        self.sceneSize = sceneSize
        self.isNew = isNew
        self.failure = failure
        self.canConnect = canConnect
        _editRequest = editRequest
        self.onSave = onSave
        self.onConnect = onConnect
        self.onCancelNew = onCancelNew
        self.onDelete = onDelete
        _isEditing = State(initialValue: isNew)
        _draft = State(initialValue: server)
        _customWidthText = State(initialValue: String(server.stream.customWidth))
        _customHeightText = State(initialValue: String(server.stream.customHeight))
        _customFrameRate = State(
            initialValue: !RemoteServer.StreamSettings.frameRatePresets.contains(
                server.stream.framesPerSecond))
        _customFrameRateText = State(initialValue: String(server.stream.framesPerSecond))
        _customBitRate = State(
            initialValue: !RemoteServer.StreamSettings.bitRatePresets.contains(
                server.stream.maximumVideoBitRate))
        _customBitRateText = State(
            initialValue: Self.megabitsText(for: server.stream.maximumVideoBitRate))
    }

    var body: some View {
        Group {
            if isEditing {
                Form { editor }
                    .catalystFormChrome()
            } else {
                summary
            }
        }
        .formStyle(.grouped)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(isEditing)
        .toolbar {
            if isEditing {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark", action: cancel)
                        .labelStyle(.iconOnly)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", systemImage: "checkmark", action: save)
                        .labelStyle(.iconOnly)
                        .disabled(!draft.isValid)
                }
            } else {
                ToolbarItem(placement: .primaryAction) {
                    Button("Edit", systemImage: "pencil", action: beginEditing)
                        .labelStyle(.iconOnly)
                }
            }
        }
        .task(id: editRequest) {
            guard editRequest == server.id else { return }
            editRequest = nil
            beginEditing()
        }
    }

    private var summary: some View {
        Form {
            #if targetEnvironment(macCatalyst)
            Section {
                HStack(spacing: 16) {
                    ServerThumbnail(image: thumbnail, cornerRadius: 10)
                        .frame(width: 144)
                    heading
                    Spacer(minLength: 0)
                    connectButton
                }
                .listRowBackground(Color.clear)
                .listRowInsets(Self.catalystSummaryHeaderInsets)
            } footer: {
                if let failure {
                    Text(failure)
                        .foregroundStyle(.red)
                        .listRowInsets(Self.catalystSectionFooterInsets)
                }
            }

            Section {
                connectionRows
                    .catalystCardRow()
            } header: {
                sectionHeader("Server")
            }
            #else
            // Place the hero header in the first section header so insetGrouped row
            // clipping never trims the heading or button corners.
            Section {
                connectionRows
            } header: {
                iosHeader
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 20, trailing: 0))
            }
            #endif

            Section {
                Group {
                    if server.stream.usesVirtualDisplay {
                        let vd = RemoteServer.StreamSettings.virtualDisplay(for: sceneSize)
                        LabeledContent(
                            "Display", value: "Virtual (\(vd.pixelWidth) × \(vd.pixelHeight))")
                    } else {
                        LabeledContent("Resolution", value: server.stream.resolutionSummary)
                    }
                    LabeledContent("Frame Rate", value: "\(server.stream.framesPerSecond) fps")
                    LabeledContent("Max Bit Rate", value: server.stream.bitRateSummary)
                    LabeledContent("Audio", value: server.stream.streamsAudio ? "On" : "Off")
                }
                .catalystCardRow()
            } header: {
                #if targetEnvironment(macCatalyst)
                sectionHeader("Stream")
                #endif
            }

            if let sessionLog {
                Section {
                    let file = SessionLogFile(
                        url: sessionLog, name: "Remo \(server.displayName) \(logDate).log")
                    ShareLink(item: file, preview: SharePreview(file.name)) {
                        Label("Export Last Session Log", systemImage: "doc.text")
                    }
                    .catalystCardButtonRow()
                }
            }
        }
        .catalystFormChrome()
        #if !targetEnvironment(macCatalyst)
        .onGeometryChange(for: Bool.self) {
            $0.size.width >= Self.wideLayoutWidth
        } action: {
            isWide = $0
        }
        #endif
    }

    @ViewBuilder
    private func sectionHeader(_ title: LocalizedStringKey) -> some View {
        #if targetEnvironment(macCatalyst)
        Text(title)
            .font(.body.weight(.semibold))
            .foregroundStyle(Color(.label))
            .textCase(nil)
            .listRowInsets(Self.catalystSectionHeaderInsets)
        #else
        Text(title)
        #endif
    }

    @ViewBuilder private var connectionRows: some View {
        // Use an explicit HStack rather than LabeledContent so long hostnames aren't
        // capped at half the row width while leaving empty space beside the short label.
        HStack(spacing: 16) {
            Text("Address")
            Spacer(minLength: 0)
            Text(server.address.displayString)
                .monospaced()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
        LabeledContent("Connection", value: server.useWireGuard ? "WireGuard" : "Direct")
    }

    #if !targetEnvironment(macCatalyst)
    private var iosHeader: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 16) {
                ServerThumbnail(image: thumbnail, cornerRadius: 20)
                if isWide {
                    HStack(spacing: 16) {
                        heading
                        Spacer(minLength: 0)
                        connectButton
                    }
                } else {
                    heading
                }
            }

            if !isWide {
                connectButton
            }

            if let failure {
                Text(failure)
                    .font(.body)
                    .foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textCase(nil)
    }
    #endif

    /// When the logged session started, in local time, for the exported file's name.
    private var logDate: String {
        let started = sessionLog.flatMap {
            try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate
        }
        let style = Date.VerbatimFormatStyle(
            format:
                "\(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits) \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased))\(minute: .twoDigits)",
            timeZone: .current, calendar: .current)
        return (started ?? .now).formatted(style)
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(server.displayName)
                .font(headingFont)
                .foregroundStyle(.primary)
            LastSessionText(date: server.lastSessionAt)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var headingFont: Font {
        #if targetEnvironment(macCatalyst)
        .title3.weight(.semibold)
        #else
        .title.bold()
        #endif
    }

    private var editorNameFont: Font {
        #if targetEnvironment(macCatalyst)
        .title3.weight(.semibold)
        #else
        .title2.bold()
        #endif
    }

    private var usesInlineConnectButton: Bool {
        #if targetEnvironment(macCatalyst)
        true
        #else
        isWide
        #endif
    }

    private var connectHorizontalPadding: CGFloat {
        #if targetEnvironment(macCatalyst)
        4
        #else
        usesInlineConnectButton ? 8 : 0
        #endif
    }

    /// Spans the page when narrow on iOS; sized to its label beside the name on Catalyst and wide iOS layouts.
    private var connectButton: some View {
        Button {
            onConnect(server)
        } label: {
            Label("Connect", systemImage: "play.fill")
                .labelStyle(.titleAndIcon)
                .font(.headline)
                .padding(.horizontal, connectHorizontalPadding)
                .frame(maxWidth: usesInlineConnectButton ? nil : .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .fixedSize(horizontal: usesInlineConnectButton, vertical: false)
        .disabled(!canConnect || !server.isValid)
    }

    @ViewBuilder private var editor: some View {
        Section {
            HStack(spacing: 16) {
                ServerThumbnail(image: thumbnail, cornerRadius: 10)
                    .frame(width: 120)
                TextField(
                    "Name", text: $draft.name,
                    prompt: Text(draft.address.host.isEmpty ? "Name" : draft.address.host)
                )
                .font(editorNameFont)
                .submitLabel(.done)
            }
            .catalystCardRow(isHeader: true)
        }

        Section {
            Group {
                TextField(
                    draft.useWireGuard ? "Server tunnel IPv4 address" : "Hostname or IP address",
                    text: $draft.address.host
                )
                .textContentType(.URL)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                LabeledContent("UDP port") {
                    TextField(
                        "UDP port", text: $draft.address.port,
                        prompt: Text(verbatim: RemoteServer.Address.defaultPort)
                    )
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                }
            }
            .catalystCardRow()
        } header: {
            sectionHeader("Server")
        }

        Section {
            Toggle("WireGuard", isOn: $draft.useWireGuard)
                .catalystCardRow()
        } header: {
            sectionHeader("Connection")
        }

        if draft.useWireGuard {
            Section {
                Group {
                    TextField("Endpoint (host:port)", text: $draft.wireGuard.endpoint)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Client tunnel IPv4 address", text: $draft.wireGuard.localAddress)
                        .keyboardType(.decimalPad)
                    TextField("Peer public key", text: $draft.wireGuard.peerPublicKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Client private key", text: $draft.wireGuard.privateKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Preshared key (optional)", text: $draft.wireGuard.presharedKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                .catalystCardRow()
            } header: {
                sectionHeader("WireGuard peer")
            }
        }

        Section {
            Group {
                Toggle("Virtual display", isOn: $draft.stream.usesVirtualDisplay)
                if draft.stream.usesVirtualDisplay {
                    let vd = RemoteServer.StreamSettings.virtualDisplay(for: sceneSize)
                    LabeledContent(
                        "Display size",
                        value:
                            "\(vd.pixelWidth) × \(vd.pixelHeight) (\(vd.logicalWidth) × \(vd.logicalHeight) @2x)"
                    )
                } else {
                    Picker("Resolution", selection: $draft.stream.resolution) {
                        ForEach(RemoteServer.StreamSettings.Resolution.allCases) { preset in
                            Text(preset.title).tag(preset)
                        }
                    }
                    if draft.stream.resolution == .custom {
                        LabeledContent("Width") {
                            HStack(spacing: 6) {
                                TextField("Width", text: customWidthBinding, prompt: Text("1920"))
                                    .keyboardType(.numberPad)
                                    .multilineTextAlignment(.trailing)
                                Text("px").foregroundStyle(.secondary)
                            }
                        }
                        LabeledContent("Height") {
                            HStack(spacing: 6) {
                                TextField("Height", text: customHeightBinding, prompt: Text("1080"))
                                    .keyboardType(.numberPad)
                                    .multilineTextAlignment(.trailing)
                                Text("px").foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Picker("Frame rate", selection: frameRateSelection) {
                    ForEach(RemoteServer.StreamSettings.frameRatePresets, id: \.self) { fps in
                        Text("\(fps) fps").tag(Optional(fps))
                    }
                    Text("Custom").tag(Int?.none)
                }
                if customFrameRate {
                    LabeledContent("Custom frame rate") {
                        HStack(spacing: 6) {
                            TextField(
                                "Frame rate", text: customFrameRateBinding, prompt: Text("60")
                            )
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            Text("fps").foregroundStyle(.secondary)
                        }
                    }
                }

                Picker("Max bit rate", selection: bitRateSelection) {
                    ForEach(RemoteServer.StreamSettings.bitRatePresets, id: \.self) { bps in
                        Text(RemoteServer.StreamSettings.formatBitRate(bps)).tag(Optional(bps))
                    }
                    Text("Custom").tag(Int?.none)
                }
                if customBitRate {
                    LabeledContent("Custom bit rate") {
                        HStack(spacing: 6) {
                            TextField("Bit rate", text: customBitRateBinding, prompt: Text("5"))
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                            Text("Mbps").foregroundStyle(.secondary)
                        }
                    }
                }

                Toggle("Stream audio", isOn: $draft.stream.streamsAudio)
            }
            .catalystCardRow()
        } header: {
            sectionHeader("Stream")
        } footer: {
            Group {
                if let problem = draft.stream.validationProblem {
                    Text(problem)
                        .foregroundStyle(.red)
                } else if draft.stream.usesVirtualDisplay {
                    Text(
                        "Creates a 2× HiDPI virtual display on the Mac matching this device’s logical screen size and streams it at full resolution. Capture runs at a variable frame rate up to the limit."
                    )
                } else {
                    Text(
                        "The display is scaled to fit the selected resolution while keeping its aspect ratio. Capture runs at a variable frame rate up to the limit."
                    )
                }
            }
            #if targetEnvironment(macCatalyst)
            .listRowInsets(Self.catalystSectionFooterInsets)
            #endif
        }

        if saveFailed {
            Text("Couldn’t save the server.")
                .foregroundStyle(.red)
                .catalystCardRow()
        }

        if !isNew {
            Section {
                Button("Delete Server", systemImage: "trash", role: .destructive) {
                    onDelete(server)
                }
                .catalystCardButtonRow()
            }
        }
    }

    private var customWidthBinding: Binding<String> {
        Binding {
            customWidthText
        } set: { value in
            customWidthText = value
            draft.stream.customWidth = Int(value.trimmingCharacters(in: .whitespaces)) ?? 0
        }
    }

    private var customHeightBinding: Binding<String> {
        Binding {
            customHeightText
        } set: { value in
            customHeightText = value
            draft.stream.customHeight = Int(value.trimmingCharacters(in: .whitespaces)) ?? 0
        }
    }

    private var frameRateSelection: Binding<Int?> {
        Binding {
            customFrameRate ? nil : draft.stream.framesPerSecond
        } set: { selected in
            if let fps = selected {
                customFrameRate = false
                draft.stream.framesPerSecond = fps
                customFrameRateText = String(fps)
            } else {
                customFrameRate = true
                customFrameRateText =
                    draft.stream.framesPerSecond > 0 ? String(draft.stream.framesPerSecond) : ""
            }
        }
    }

    private var customFrameRateBinding: Binding<String> {
        Binding {
            customFrameRateText
        } set: { value in
            customFrameRateText = value
            draft.stream.framesPerSecond = Int(value.trimmingCharacters(in: .whitespaces)) ?? 0
        }
    }

    private var bitRateSelection: Binding<Int?> {
        Binding {
            customBitRate ? nil : draft.stream.maximumVideoBitRate
        } set: { selected in
            if let bps = selected {
                customBitRate = false
                draft.stream.maximumVideoBitRate = bps
                customBitRateText = Self.megabitsText(for: bps)
            } else {
                customBitRate = true
                customBitRateText =
                    draft.stream.maximumVideoBitRate > 0
                    ? Self.megabitsText(for: draft.stream.maximumVideoBitRate) : ""
            }
        }
    }

    private var customBitRateBinding: Binding<String> {
        Binding {
            customBitRateText
        } set: { value in
            customBitRateText = value
            let trimmed = value.trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: ",", with: ".")
            if let mbps = Double(trimmed), mbps.isFinite, mbps > 0, mbps <= Double(Int32.max) / 1e6
            {
                draft.stream.maximumVideoBitRate = Int((mbps * 1e6).rounded())
            } else {
                draft.stream.maximumVideoBitRate = 0
            }
        }
    }

    private static func megabitsText(for bitsPerSecond: Int) -> String {
        let mbps = Double(bitsPerSecond) / 1e6
        return mbps.formatted(
            .number.grouping(.never).precision(.fractionLength(0...3))
                .locale(Locale(identifier: "en_US_POSIX")))
    }

    private func beginEditing() {
        draft = server
        customWidthText = String(server.stream.customWidth)
        customHeightText = String(server.stream.customHeight)
        customFrameRate = !RemoteServer.StreamSettings.frameRatePresets.contains(
            server.stream.framesPerSecond)
        customFrameRateText = String(server.stream.framesPerSecond)
        customBitRate = !RemoteServer.StreamSettings.bitRatePresets.contains(
            server.stream.maximumVideoBitRate)
        customBitRateText = Self.megabitsText(for: server.stream.maximumVideoBitRate)
        saveFailed = false
        withAnimation { isEditing = true }
    }

    private func cancel() {
        if isNew {
            onCancelNew()
            return
        }
        withAnimation { isEditing = false }
    }

    private func save() {
        guard draft.isValid else { return }
        guard onSave(draft) else {
            saveFailed = true
            return
        }
        withAnimation { isEditing = false }
    }
}

/// A session log shared under a readable name instead of the server's identifier.
private struct SessionLogFile: Transferable {
    let url: URL
    let name: String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .log) { SentTransferredFile($0.url) }
            .suggestedFileName { $0.name }
    }
}

#if targetEnvironment(macCatalyst)
/// UIKit's sliding `UISwitch` ignores `.controlSize` and fixes its frame at iOS's 63×28
/// touch size, so scale the native switch down to macOS grouped-form proportions.
private struct CatalystSwitchToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        LabeledContent {
            Toggle("", isOn: configuration.$isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .scaleEffect(0.7, anchor: .trailing)
                .frame(height: 20)
        } label: {
            configuration.label
        }
    }
}

/// Restores full-row press feedback for action rows when `.listRowBackground` overrides
/// UIKit's default cell highlight on Mac Catalyst.
private struct CatalystFormRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(
                configuration.role == .destructive
                    ? AnyShapeStyle(.red)
                    : AnyShapeStyle(.tint)
            )
            .opacity(configuration.isPressed ? 0.75 : 1)
            .padding(ServerDetailView.catalystRowInsets)
            .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
            .background(
                configuration.isPressed
                    ? Color.primary.opacity(0.08)
                    : Color.clear
            )
            .contentShape(.rect)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
#endif

extension View {
    fileprivate func catalystFormChrome() -> some View {
        #if targetEnvironment(macCatalyst)
        self
            .toggleStyle(CatalystSwitchToggleStyle())
            .scrollContentBackground(.hidden)
            .background(Color(.systemBackground))
            .environment(\.defaultMinListRowHeight, 36)
            .listSectionSpacing(12)
            .contentMargins(.top, 8, for: .scrollContent)
        #else
        self
        #endif
    }

    fileprivate func catalystCardRow(isHeader: Bool = false) -> some View {
        #if targetEnvironment(macCatalyst)
        self
            .listRowBackground(ServerDetailView.catalystCardBackground)
            .listRowSeparatorTint(Color.primary.opacity(0.06))
            .listRowInsets(
                isHeader
                    ? ServerDetailView.catalystHeaderRowInsets
                    : ServerDetailView.catalystRowInsets)
        #else
        self
        #endif
    }

    fileprivate func catalystCardButtonRow() -> some View {
        #if targetEnvironment(macCatalyst)
        self
            .buttonStyle(CatalystFormRowButtonStyle())
            .listRowBackground(ServerDetailView.catalystCardBackground)
            .listRowSeparatorTint(Color.primary.opacity(0.06))
            .listRowInsets(EdgeInsets())
        #else
        self
        #endif
    }
}
