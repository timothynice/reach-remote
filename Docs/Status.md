# Developer preview status

Reach is functional software with a native Mac host and universal iPhone/iPad client. The maintainer has used a physical iPhone for desktop viewing, pointer/keyboard control, caret visibility, scrolling, monitor switching, foreground reconnection and cellular relay access. Automatic saved-Mac routing has owner-reported acceptance. That does not validate every device, application or network.

## Automated evidence

The verification gate exercises authenticated real TCP/WSS transport; pairing, trust, revocation and pinned destinations; adversarial framing/payload cases; actual H.264 encoding/decoding; viewport/focus/display/scroll geometry; retry cancellation/coalescing; and relay forwarding/resource limits. Both native Release targets compile with full concurrency checks and Swift warnings as errors. CI does not carry signing or relay credentials.

## Open validation

- Fresh clone/build using another developer's team and a second Mac; permission and update behavior with stable signing.
- Physical iPad control, hardware keyboard, live multitasking/resizing and broader phone sizes.
- VoiceOver and Dynamic Type device acceptance. Labeled controls do not make remote macOS content semantically accessible through iOS VoiceOver.
- Sustained sessions, measured input-to-visible latency, energy/thermal/battery use, adverse networks, sleep/wake and network switching.
- Broad third-party Mac Accessibility compatibility for caret geometry and scrollability hints.
- Independent protocol/security review, fuzzing, sustained relay load and operational abuse testing.

## Deliberate boundaries

No account, public hosted relay, public TestFlight enrollment, App Store distribution, automatic Mac updater, remote wake, pre-login/FileVault access or private virtual-display creation is included. Remote transport is outbound WSS relay rather than ICE/STUN direct traversal. Video uses H.264; HEVC is not implemented. Clipboard transfer is explicit/opt-in. The scroll rail controls speed and direction, not absolute document position.

Local use needs no relay. Self-hosted remote use requires a public TLS endpoint and ongoing server/dependency maintenance. Keep resource limits conservative and monitor bandwidth before adding users. This is a developer preview, not a managed service or a promise of production availability.
