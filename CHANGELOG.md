# Changelog

## 0.1.1 — Mac panel refresh

- Updated Mac, iPhone and iPad app artwork; rounded artwork in the Mac panel.
- Clearer desktop-and-phone menu bar mark and a monitor beside the Mac name.
- Compact panel that sizes to its content and caps overflow at the screen height.
- Separate settings window for permissions, optional remote access, help and collapsed diagnostics.
- Device removal in a Danger Zone with a persistent confirmation sheet; remote removal also confirms.
- Overlay scrollbars and clearer switch alignment.
- Fixed an intermittent ready-message race in the relay registry test.

## 0.1.0 — Developer preview

Initial source release of Reach, a native portrait-first Mac remote desktop client for iPhone and iPad.

- Mac menu bar host with ScreenCaptureKit, VideoToolbox H.264 and supported mouse/keyboard input APIs.
- Portrait pan/zoom, caret-aware keyboard, modifier shortcuts and overlay variable-speed scroll rail.
- Monitor browser with per-display placement, precision cursor and explicit clipboard controls.
- Authenticated pairing, persistent identity-pinned trust, Bonjour discovery and automatic nearby/self-hosted relay connections.
- Optional constrained Node relay with registered-room access and self-hosting instructions.
- Native protocol/transport/codec/geometry tests and unsigned Release CI.

Developer installation requires Xcode and your own signing team. A maintainer-hosted relay is not included. Physical iPad interaction, independent security review, sustained performance and broader network/device testing remain open; see Docs/Status.md.
