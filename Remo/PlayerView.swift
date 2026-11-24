//
//  Created by Cyandev on 11/21/26.
//

import RemoEngine
import SwiftUI
import UIKit

/// The remote screen with system chrome hidden and a compact control pill that fades while streaming.
struct PlayerView: View {
    let player: StreamPlayer
    let surface: VideoSurface
    let title: String

    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @Environment(\.scenePhase) private var scenePhase
    @State private var keyboardVisible = false
    @State private var keyboardFrame = CGRect.zero
    @State private var resizeReconnectTask: Task<Void, Never>?
    @State private var measuredSceneSize = CGSize.zero

    var body: some View {
        // The backdrop and video fill the full screen. On iOS 27.1+, floating controls and the
        // scroll wheel position themselves against exact hardware occlusions and corner insets
        // instead of the full-edge rectangular safe area.
        ZStack {
            // Hosts the video as the view it zooms, so it stays up from the moment the session
            // starts: the surface only draws frames while it is in a window. The trackpad canvas
            // fills the entire screen (ignoring all safe areas) and aspect-fits the picture inside
            // it.
            TrackpadView(
                onInput: player.handleTrackpad,
                excludedRects: keyboardVisible ? [keyboardFrame] : [],
                showsWheel: player.phase == .streaming && player.remoteControlAvailable,
                controlsPointer: player.phase == .streaming && player.remoteControlAvailable,
                surface: surface, videoSize: player.videoSize,
                bottomInset: keyboardVisible ? keyboardFrame.height : 0)

            if let status {
                ProgressView(status)
                    .tint(.white)
                    .foregroundStyle(.white)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            Color.black
                .onGeometryChange(for: CGSize.self) {
                    $0.size
                } action: { newSize in
                    measuredSceneSize = newSize
                    handleSceneResize(newSize)
                }
                .ignoresSafeArea()
        }
        .overlay {
            if keyboardVisible {
                ZStack(alignment: .bottom) {
                    Color.clear.allowsHitTesting(false)
                    RemoteKeyboardView(
                        modifierStates: player.modifierStates,
                        capsLockActive: player.capsLockActive,
                        onToggleModifier: { player.toggleModifier($0) },
                        onKeystroke: { player.sendKeystroke($0) },
                        onKeyDown: { player.sendKeyDown($0) },
                        onKeyUp: { player.sendKeyUp($0) },
                        onScrubStep: { player.sendCursorScrubStep($0) },
                        onScrubEnd: { player.finishCursorScrub() },
                        onDismiss: { setKeyboardVisible(false) }
                    )
                    .onGeometryChange(for: CGRect.self) {
                        $0.frame(in: .global)
                    } action: {
                        keyboardFrame = $0
                    }
                }
                .ignoresSafeArea(edges: [.bottom, .horizontal])
                .transition(.move(edge: .bottom))
            }
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        // Watching or driving the remote screen doesn’t touch the phone’s own screen often enough
        // to keep it awake, so auto-lock is off for as long as the player is up.
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear {
            resizeReconnectTask?.cancel()
            resizeReconnectTask = nil
            player.releaseKeyboard(includingModifiers: true)
            UIApplication.shared.isIdleTimerDisabled = false
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase != .active {
                resizeReconnectTask?.cancel()
                resizeReconnectTask = nil
                player.releaseKeyboard(includingModifiers: true)
            } else if measuredSceneSize.width > 0, measuredSceneSize.height > 0 {
                handleSceneResize(measuredSceneSize)
            }
        }
        .onChange(of: player.remoteControlAvailable) { _, available in
            if !available && keyboardVisible {
                setKeyboardVisible(false)
            }
        }
    }

    private var status: String? {
        switch player.phase {
        case .connecting: String(localized: "Connecting…")
        case .waitingForVideo: String(localized: "Waiting for video…")
        default: nil
        }
    }

    private func setKeyboardVisible(_ visible: Bool) {
        if !visible {
            // Release any key mid-hold without clearing active modifiers, so modified trackpad
            // actions (e.g. ⌘+Click) continue to work after dismissing the keyboard.
            player.releaseKeyboard(includingModifiers: false)
        }
        withAnimation(.spring) {
            keyboardVisible = visible
        }
    }

    private func handleSceneResize(_ size: CGSize) {
        guard scenePhase == .active, size.width > 0, size.height > 0,
            let current = player.targetStream,
            let currentVirtualDisplay = current.virtualDisplay
        else { return }
        let target = RemoteServer.StreamSettings.virtualDisplay(for: size)
        if target == currentVirtualDisplay {
            resizeReconnectTask?.cancel()
            resizeReconnectTask = nil
            return
        }
        resizeReconnectTask?.cancel()
        resizeReconnectTask = Task {
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled, scenePhase == .active,
                let latest = player.targetStream, latest.virtualDisplay != nil
            else { return }
            let settledTarget = RemoteServer.StreamSettings.virtualDisplay(for: measuredSceneSize)
            guard settledTarget != latest.virtualDisplay else { return }
            var updated = latest
            updated.virtualDisplay = settledTarget
            player.reconnect(stream: updated)
        }
    }
}
