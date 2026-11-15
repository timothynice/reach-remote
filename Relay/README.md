# Reach relay

Self-hosted Node.js 22 WebSocket carrier for Reach's authenticated encrypted sessions.

```sh
npm ci
npm test
```

See [self-hosting](../Docs/SelfHosting.md) for TLS, room generation, registered-room access, the constrained systemd service, client setup and maintenance. No public relay access is included.

For local development only, `npm start` binds 127.0.0.1:8787. Do not expose the unrestricted development profile publicly. Production requires `REQUIRE_ROOM_ALLOWLIST=1` and `ROOM_ALLOWLIST_FILE` with registered SHA-256 hashes. One host and one client occupy each room. Never log room query parameters.

The server bounds rooms, waiting time, payloads, receiver queues, per-address upgrades/connections and per-socket byte/message rates. These are abuse controls, not a capacity guarantee. A reverse proxy needs its own trusted-client limits: the relay does not trust forwarded-IP headers.

`scripts/test-relay-carrier.sh` from the repository root exercises the real Swift protocol over a temporary local TLS relay, including certificate rejection, pairing, encrypted control/video and reconnect. It does not prove public connectivity or sustained-session performance. See SECURITY.md.
