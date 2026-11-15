# Architecture

Reach has two native targets: ReachMac (macOS 14+) and ReachPhone (iOS/iPadOS 17+). Shared Swift code handles device identity, authentication, bounded framing, messages, discovery and transport.

The Mac captures a selected display with ScreenCaptureKit and encodes H.264 with VideoToolbox. Encoded frames cross the authenticated transport, are decoded with VideoToolbox on iOS, and presented inside a zoomable portrait-first viewport. Generation/encoder identifiers prevent stale callbacks from replacing a newer session. Quality changes are bounded and serialized.

Mouse/keyboard events use supported macOS input and Accessibility APIs after user permission. Accessibility probes request focused geometry and scrolling capability, not document text. Keyboard-aware focus keeps the caret visible; missing AX data falls back to the last interaction point. Protected content and secure input are respected.

Bonjour publishes a public identity fingerprint as an untrusted routing hint. Saved Macs are keyed by authenticated signing identity, not name. Selecting a Mac tries a matching nearby TCP endpoint first, then its saved relay if local access fails or identity verification takes longer than the grace period. Verification pins the saved identity before trusting the session; human pairing is not interrupted by the fallback timer.

The optional Node relay carries opaque binary records over outbound WSS. Both endpoints still perform the same authentication and encryption. After pairing, an authenticated host can share its configured connection profile with a capable client. There is no server account or automatic public room enrollment. See SelfHosting.md and SECURITY.md.

Each installation stores identity, trust and saved profiles in Keychain. Sessions use fresh signed ephemeral exchanges, transcript-derived directional keys, code comparison, bilateral approval and replay-protected AES-GCM records. This custom protocol is not independently audited.

Two fingers always pan/zoom. One finger moves the relative pointer by default, with optional direct touch. A monitor browser stores each display's zoom/position. Its spatial ordering comes from Mac display bounds; fixed controls do not page with previews. A conservative AX hint decides whether to show the overlay scroll rail; unknown apps retain a fallback and an always-show option.

No private virtual-display API is used and the Mac's display configuration is not changed. Existing monitors, portrait viewport framing and smooth pan/zoom provide the fallback. No ICE/STUN or HEVC implementation is claimed.
