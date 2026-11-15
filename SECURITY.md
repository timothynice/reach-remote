# Security

Reach is a developer preview. It can view and control an authenticated user's Mac. Its custom session protocol has not been independently audited; assess this before using it on a sensitive machine.

## Reporting a vulnerability

Do not post exploits, room secrets, invitations, screen contents or credentials in a public issue. Use the repository's **Security → Report a vulnerability** private reporting feature when enabled. If unavailable, open a minimal issue asking for a private contact without disclosing the vulnerability. Do not send unsolicited sensitive information through an unrelated channel.

There is no guaranteed response time, bounty or security support SLA. Only the latest source is maintained; no older release security support is promised.

## Trust model

- Each installation stores signing identity and trusted device keys in device-only Keychain storage.
- Fresh signed X25519 ephemeral exchanges and a commitment-before-reveal transcript derive directional AES-GCM keys and a six-digit pairing code. Compare and approve the code on **both** devices. Matching names and Bonjour records are not authentication.
- Application traffic is gated on bilateral authorization. Sequence numbers reject replay. Saved destinations pin the authenticated signing identity on either transport.
- The relay forwards encrypted desktop/input, but observes public handshake identities/names, source IPs, timing, traffic sizes and the rendezvous credential. It can disrupt service. Endpoint compromise is outside this protection.
- A room secret is an additional rendezvous credential, not authorization to control a Mac. Register a fresh random 256-bit room per host. Never reuse example credentials.
- Screen Recording and Accessibility must be explicitly granted on the Mac. Secure input, lock/login and protected-content boundaries still apply.

## Operating safely

Keep invitations/configuration private. Disable URL/query logging on the relay and reverse proxy; redact diagnostics before sharing. Keep Node, dependencies, OS and TLS software patched. Use TLS with normal certificate validation, registered-room allowlisting, constrained service permissions and edge rate/resource limits. Do not expose the relay's development profile publicly.

Forget/revoke a device through Reach if it is lost. Replace its relay room when an invitation is exposed, and remove the old registered room server-side. Keychain errors, signing changes and reinstalls may require new pairing.

## Assurance and open work

Automated coverage includes tampering, replay, role/message bounds, malformed authenticated records, commitment/SAS matching, bilateral approval, identity pins, TCP/WSS pairing/reconnect and relay resource limits. These are regression checks, not an audit. Independent review, fuzzing, sustained load/denial-of-service testing, secure-input boundary testing and broader endpoint/device testing remain open. See Docs/Status.md.
