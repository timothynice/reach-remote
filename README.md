# Reach

Your Mac. Within reach.

A native, portrait-first remote desktop for iPhone and iPad, with a lightweight Mac menu bar host. View and control your desktop, pan and zoom comfortably, type with macOS modifiers, and move between monitors without giving up your place.

**Developer preview · MIT licensed · Bring your own Apple signing and optional relay.**

Reach runs locally without an account or server. For access across networks, deploy your own small relay once, pair your devices, then select the same saved Mac wherever you are. Reach chooses nearby or relay automatically. No public hosted relay or public TestFlight access is included.

## What works

- Native SwiftUI apps; ScreenCaptureKit capture and VideoToolbox H.264 hardware encoding/decoding.
- Portrait viewport with pinch zoom, two-finger pan, anchored double-tap zoom, fit width/height and readable focus.
- Precision pointer mode by default, direct touch, drag, right-click and a continuous variable-speed edge scroll rail.
- Keyboard modifier/shortcut row and caret-aware viewport positioning.
- Multiple monitors with per-display zoom/position; monitor pill or three-finger tap opens the swipe browser.
- Bonjour discovery, persistent device trust, explicit clipboard controls and automatic local/relay selection.
- Authenticated end-to-end encrypted desktop/input transport. The custom protocol has **not** had an independent security audit.

## Build and connect

Requires a Mac with macOS 14+, full Xcode 16+ selected as the active developer directory, XcodeGen, and an iPhone/iPad with iOS/iPadOS 17+. Node.js 22 is needed for relay tests and self-hosting. Xcode must include a simulator runtime for simulator builds. This is a source distribution; an Apple account and signing are needed for installation on a physical iPhone/iPad.

```sh
git clone https://github.com/timothynice/reach-remote.git
cd reach-remote
brew install xcodegen
xcodegen generate
open Reach.xcodeproj
```

1. Select **ReachMac**, choose your development team under Signing & Capabilities, and run it on your Mac. Grant Screen Recording and Accessibility when prompted; reopen if macOS requests it.
2. Select **ReachPhone**, choose your team and a unique bundle identifier, and run on your iPhone or iPad. Use a unique Mac bundle identifier too if your team cannot register the default. Keep your own identifiers/signing stable across updates to preserve permissions. `project.yml` is the source of project settings: save your team/identifier changes there before regenerating.
3. Allow Local Network access. Start on the same reachable local network, select your Mac, compare the six-digit code on both devices and approve both. Never approve mismatched codes.
4. Your desktop opens. Two fingers pan/zoom. The keyboard and controls reveal on tap; use the monitor pill to browse displays. In-app Help covers the gestures.

The generated project has no maintainer signing team. Personal Team signing may require periodically reinstalling the iOS app; it is not a permanent App Store installation. A paid Apple Developer membership is needed for some distribution workflows.

For unsigned compilation only: `scripts/build.sh` uses your configured signing for the Mac; `scripts/verify.sh --all` below builds both targets without signing. Simulators are useful for UI checks; physical devices are required to validate actual touch/network/keyboard behavior.

## Connect from outside your network

Follow [self-hosting](Docs/SelfHosting.md). Configure your relay endpoint and a unique registered room in the Mac's **Advanced connection setup**, then connect locally once to save the connection profile on your phone/tablet. After that, simply select your saved Mac. An invitation is available for initial pairing away from home; treat it as a secret.

The Mac must be awake, logged in and online. Reach does not wake a sleeping Mac, bypass secure input, unlock FileVault before login, stream protected content or create a portrait virtual display using private APIs. Remote sessions use an outbound WSS relay; ICE/STUN peer-to-peer traversal is not implemented.

## Verify

```sh
npm --prefix Relay ci
scripts/verify.sh --all
```

The gate covers protocol/security regression tests, real encrypted TCP/WSS integration, H.264 encode/decode, viewport/focus/display/scroll geometry, cancellation/retry behavior, relay abuse limits, and unsigned Mac/iOS Release builds. Logs are written to ignored `build/verification/`. It does not install apps or control the user's desktop.

See [architecture](Docs/Architecture.md), [security](SECURITY.md), [known limitations and test coverage](Docs/Status.md), and [contributing](CONTRIBUTING.md). Automated checks do not establish battery life, internet reliability or independent security assurance.

## Project layout

| Directory | Responsibility |
|---|---|
| `Mac/` | Menu bar host, permissions, desktop capture and input |
| `iOS/` | Universal client, viewport, decoder, controls and pairing |
| `Shared/` | Protocol, authentication, transport, discovery and geometry |
| `Relay/` | Small self-hosted Node WebSocket relay and deployment examples |
| `Tests/` | Native and relay integration/regression coverage |

Created by **Timothy Nice**. Contributions are welcome, especially physical iPad testing, Accessibility interoperability, weak-network behavior and security review. MIT applies to original project code and artwork; bundled third-party software retains its own license (see [notices](THIRD_PARTY_NOTICES.md)).
