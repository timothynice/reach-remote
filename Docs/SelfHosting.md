# Self-hosting remote connections

Local connections need no server. To connect across networks, run the included relay on a server you control, behind HTTPS/WSS with a valid public certificate. Both Mac and phone make outbound connections; no router port forwarding is needed on either device's network.

The relay is not a remote desktop login service. It pairs one host and one client in a registered random room, forwards encrypted records, and leaves device authentication/approval to Reach. No maintainer relay access is included.

## 1. Prepare the server

Use a small Linux server with Node.js 22, a hostname pointing to it, a TLS reverse proxy such as Caddy, and ports 80/443 available for your chosen TLS workflow. Capacity and bandwidth depend on resolution, motion and session length; the included resource limits are starting points, not a supported user count.

Copy `Relay/` to `/opt/reach-relay`, create a dedicated non-login `reach-relay` user, and install locked dependencies:

```sh
cd /opt/reach-relay
npm ci --omit=dev
sudo install -d -o root -g reach-relay -m 0750 /etc/reach-relay
```

Keep the installed source owned by an administrator and readable by the service. The service user should not be able to replace its executable or registry. Exact account creation/package commands vary by distribution. Node must be available at the service's `ExecStart` path; adjust the sample if yours differs.

## 2. Create a room privately

On your Mac, from the repository root:

```sh
python3 scripts/create-relay-room.py \
  --url wss://relay.example.com/tunnel \
  --output "$HOME/.config/reach/my-mac"
```

This writes a fresh random room, a private configuration JSON, and its SHA-256 registry entry with restrictive permissions. It does not print the credential. Keep the generated directory outside the repo. Each Mac needs a separate room. Do not use a copied example string as a credential.

Transfer **only** `allowed-rooms` to `/etc/reach-relay/allowed-rooms` on the server using your normal secure administrative channel, then set ownership `root:reach-relay` and mode `0640`. For multiple Macs, combine the hash entries, one per line. Do not upload `configuration.json` or the raw room to the server.

## 3. Start the constrained service

Review `Relay/deploy/reach-relay.service`, then install it in `/etc/systemd/system/` and run:

```sh
sudo systemctl daemon-reload
sudo systemctl enable --now reach-relay
sudo systemctl status reach-relay --no-pager
```

The sample binds only `127.0.0.1:8787`, requires an allowlist, and constrains memory, CPU and privileges. Missing/malformed registries fail startup. The default development `npm start` profile does **not** require registered rooms; never expose that profile publicly.

## 4. Enable TLS

Adapt `Relay/deploy/Caddyfile.fragment` to your hostname. It deliberately omits access logging and handles proxy errors without logging credential-bearing tunnel URLs. Keep debug logging disabled. Do not enable query logging in any upstream proxy, CDN or tracing service. Add edge connection/rate limits appropriate to your network; the relay never trusts forwarded-IP headers, so its per-address limits see the reverse proxy's address.

Validate the configuration before reloading your proxy. Do not overwrite unrelated virtual hosts or firewall rules. Let your TLS proxy handle certificate renewal. `/health` is a readiness endpoint; an HTTP 200 does not verify a complete encrypted desktop session.

## 5. Configure Reach once

Open the private `configuration.json` locally. In the Mac host's **Advanced connection setup**, enter its `url` and `room`, then save. Do not share screenshots of these fields.

Connect from your phone/tablet on the local network and compare/approve pairing codes on both devices. The Mac shares its connection profile inside the authenticated encrypted session. Thereafter choose the same saved Mac: Reach tries local access first and falls back to your relay. Alternatively use **Copy invitation** on the Mac and **Add a Mac** on the client for first pairing away from home.

Test outside your network, for example with phone Wi-Fi fully off and cellular enabled. Verify desktop viewing, a harmless click and typing. Do not assume remote access works because local access works. The Mac must remain awake, logged in and online.

## Maintain, revoke and recover

Monitor readiness, service restarts, memory and bandwidth. Keep OS, Node, TLS proxy and locked dependencies patched. Back up your configuration securely. Changes to an allowlist require a service restart; restart disconnects active sessions.

If an invitation leaks, generate a replacement room, replace the corresponding server registry entry, restart the relay, and save the new configuration on the Mac. Reconnect locally to refresh the paired client's profile. Revoke lost devices in Reach as well; changing a room does not remove device trust.

The relay can see rendezvous credentials, public handshake identities/names and connection metadata, but not decrypted desktop/input. It does not offer availability guarantees. See SECURITY.md.
