# AGENTS.md

## What this is

Remo streams a Mac's screen (video + system audio) to an iOS app over UDP, with the iOS app acting as a trackpad for the Mac's pointer. The iOS client can optionally tunnel through an in-process WireGuard client. The design target is low latency over constrained links (tuned around 5 Mbps, 60 fps VFR).

## Commands

The three Swift packages in `Packages/` build and test independently with SwiftPM (Swift Testing, not XCTest):

```sh
cd Packages/RemoTransport && swift test          # also RemoCodec, RemoEngine
swift test --filter policedLinkWithLittleBufferSettlesNearItsRate   # single test by function name
swift test list                                   # list test IDs
```

`remo-engine` CLI (in `Packages/RemoEngine`) runs a server and client without Xcode:

```sh
swift run remo-engine server [port]                    # test pattern, UDP 7711 by default
swift run remo-engine client 127.0.0.1                 # verifies every test-pattern frame
swift run remo-engine server --screen --audio --mouse-control
swift run remo-engine client <host> --screen           # opens a video window (macOS)
```

`--wire-stats` and `--trace-heartbeats` print transport-level diagnostics; `REMO_AUDIO_TRACE_DIR` dumps audio PCM/timing. Run `remo-engine` with no args for full usage.

Apps: `Remo.xcodeproj`, schemes `Remo` (iOS/iPadOS client, also built for Mac Catalyst) and `RemoServer` (macOS server), e.g. `xcodebuild -project Remo.xcodeproj -scheme RemoServer build` or `-scheme Remo -destination 'platform=macOS,variant=Mac Catalyst'`. The client target's "Build WireGuard" phase runs `WireGuard/build.sh`, which needs `rustup` plus the Rust target for each destination: `aarch64-apple-ios`, `aarch64-apple-ios-sim`, and `aarch64-apple-ios-macabi`/`x86_64-apple-ios-macabi` for Catalyst. Saved servers live in the Keychain, and Catalyst offers only the data protection keychain, so the Catalyst build needs `Remo/Remo-Catalyst.entitlements` (`keychain-access-groups`) and a provisioning profile: it can't be signed ad-hoc. Running it on a Mac that isn't registered to the team needs Developer ID signing. On the Mac, the app's files go under `URL.storageDirectory` (its own folder in Application Support), not the shared one. Rust tests: `cd WireGuard && cargo test`.

Signing: both targets read `DEVELOPMENT_TEAM` and `PRODUCT_BUNDLE_IDENTIFIER` from `Config/Signing.xcconfig` (`REMO_DEVELOPMENT_TEAM`, `REMO_BUNDLE_ID_PREFIX`; the project's own team and `me.cyandev` prefix by default). To override them locally, set them in the git-ignored `Config/Signing.local.xcconfig`, which the committed file includes when present. Don't put team or bundle IDs back into `project.xcproj`. In this JSON project format a target's base xcconfig is set per configuration under `specialized-configurations` (`"file"` names a navigator path such as `Config/Signing.xcconfig`, i.e. the group path, not the file-system path), and the target's own `build-settings` override it.

Formatting: each package has a `.swift-format` (4-space indent); run with `xcrun swift-format`.

## Architecture

Dependency order: `RemoTransport` and `RemoCodec` (independent) ← `RemoEngine` ← apps (`Remo/` iOS, `RemoServer/` macOS). App targets are thin SwiftUI shells; session logic belongs in `RemoEngine`.

**RemoTransport** — message transport over an already authenticated datagram path.
- `MessageTransport` is a pure, clock-driven state machine (no I/O): callers feed it events and it emits `IORequest`s. This is why rate-control tests can run a simulated bottleneck on a virtual clock (`RateControlTests`, `DeliveryRateTests`).
- There is one kind of message, not reliable/unreliable channels. Each message's `Delivery` sets a retry budget (`0` = send once, `.infinity` = until delivered), an optional first-send deadline, priority, a `replacing` key (newest value wins), and FEC `redundancy` (`Repair.swift`).
- Rate control is delay- and delivery-based (queueing delay, delivered share, loss trials, policed-link caps). Behavior changes here are usually justified by measurements in the commit message; keep the corresponding tests passing.
- `NetworkMessageSession` wraps a `MessageTransport` around a `DatagramConnection` (plain `NWConnection`, or the app's WireGuard connection) and runs all packet I/O, pacing, ACKs and FEC on a dedicated high-priority serial queue, off the owning actor.

**RemoEngine** — client/server sessions, organized by feature (`Protocol/`, `Video/`, `Audio/`, `Pointer/`, `Source/`, `Diagnostics/`, `Client/`, `Server/`).
- `RemoteScreenServer` listens (`RemoProtocol.defaultPort` = 7711) and creates a `ServerConnection` per client; `RemoteScreenClient.run(_ link:)` takes `.udp(endpoint)` or `.datagrams(DatagramConnection)`.
- Every application message starts with a `MessageKind` byte (`Protocol/MessageKind.swift`). Kinds `0x40…0x7f` route to `VideoSession`. Retired values are marked "not to be reused" — never reassign them.
- Video loss recovery avoids key frames where possible: waiting for repair/retransmission, server-side refresh, long-term references (`RemoCodec/LongTermReferenceToken`), and evidence-based key-frame requests (`VideoRecoveryRequest`).
- Resolution is fixed for a session's lifetime.

**RemoCodec** — VideoToolbox encode/decode, Opus, and `FrameChangeDetector` (drives VFR: unchanged screens send no frames).

**WireGuard/** — Rust `staticlib` over BoringTun exposing the C API in `include/RemoWireGuard.h` (bridged into the iOS target). All calls on a handle must be serialized; returned byte pointers are borrowed only until the next mutating call. `Remo/WireGuardDatagramConnection.swift` adapts it to `DatagramConnection`.

## The `lab` branch

The `lab` branch holds Remo Lab, the experiment harness used to develop and measure transport, rate control and video changes. It never merges into `main`. Changes proven there are brought to `main` without the lab's tracing (e.g. `Trace.swift`, packet taps), and `lab` takes `main` in with `git merge main`. Before changing rate control or loss handling, read the lab's evidence for the current behavior: `git show <remote>/lab:Lab/reports/<file>.md` (`git ls-tree --name-only <remote>/lab Lab/reports/`).

On a checkout of `lab`:
- `Lab/README.md` covers the real-hardware harness. `Lab/remo-lab` drives `RemoServer.app` (HTTP on 127.0.0.1:7480) and the iPhone app in lab mode (control over TCP 7481), with link impairment emulated on the phone. It records `Lab/runs/<run>/` and compares runs per phase.
- `Lab/Sim/README.md` covers `Lab/remo-sim`, which runs the real `MessageTransport` on a virtual clock over modelled paths (`Lab/Sim/paths/`, with `wg-probed` fitted to real probes). Rate-control variants are compared in seconds with `build --variant before|after`, `suite`, then `compare`. Simulate first and confirm on hardware afterwards.
- `.claude/skills/remo-lab/SKILL.md` describes the tuning loop: baseline, one change per hypothesis, the same seed, `--repeat` to measure noise, and checks for regressions. Lab-only app hooks belong in `Remo/Lab/`, `RemoServer/Lab/` and `Lab/App/`. Keep edits to shared files minimal so `main` merges stay clean.

## Conventions

- Concurrency: the iOS target uses Swift 5 mode with default `MainActor` isolation; `RemoServer` uses Swift 6; `RemoTransport` enables `ApproachableConcurrency`. Hot-path transport work must stay off the main actor.
- Commit messages: imperative, sentence-case subject with no type prefix, describing the behavior change; the body explains the reasoning and, for transport/codec tuning, the measured effect.
