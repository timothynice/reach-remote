import http from 'node:http';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { WebSocketServer, WebSocket } from 'ws';
import { pathToFileURL } from 'node:url';

// TLS terminates at the reverse proxy. The relay never receives Reach session keys.
export function createRelay({ maxRooms = 1000, idleMs = 60_000, maxConnectionsPerIP = 16,
  messagesPerSecond = 1024, bytesPerSecond = 16 * 1024 * 1024, maxPayload = 8 * 1024 * 1024,
  allowedRoomHashes = null, serverFactory = handler => http.createServer(handler) } = {}) {
  const rooms = new Map();
  const addresses = new Map();
  const attempts = new Map();
  const reject = (socket, status) => socket.end(`HTTP/1.1 ${status}\r\nConnection: close\r\n\r\n`);

  const server = serverFactory((req, res) => {
    res.writeHead(req.url === '/health' ? 200 : 404, {'Content-Type': 'text/plain'});
    res.end(req.url === '/health' ? 'Reach relay ready\n' : 'Not found\n');
  });
  server.headersTimeout = 5000;
  server.requestTimeout = 15000;
  const wss = new WebSocketServer({ noServer: true, maxPayload, perMessageDeflate: false });
  server.on('upgrade', (req, socket, head) => {
    // Do not trust X-Forwarded-For: a deployment's edge must apply its own trusted-client limits.
    const address = req.socket.remoteAddress ?? 'unknown';
    const now = performance.now();
    for (const [ip, entry] of attempts) if (now - entry.start >= 60_000) attempts.delete(ip);
    if (!attempts.has(address) && attempts.size >= 10_000) { reject(socket, '503 Service Unavailable'); return; }
    const attempt = attempts.get(address) ?? { start: now, count: 0 };
    attempt.count += 1; attempts.set(address, attempt);
    if (attempt.count > 120 || (addresses.get(address) ?? 0) >= maxConnectionsPerIP) {
      reject(socket, '429 Too Many Requests'); return;
    }
    if ((req.url?.length ?? 0) > 2048) { reject(socket, '400 Bad Request'); return; }
    let url;
    try { url = new URL(req.url, 'http://localhost'); } catch { socket.destroy(); return; }
    const room = url.searchParams.get('room'), role = url.searchParams.get('role');
    if (url.pathname !== '/tunnel' || !/^[a-f0-9]{64}$/.test(room ?? '') || !['host', 'client'].includes(role)) {
      socket.end('HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n'); return;
    }
    if (allowedRoomHashes && !allowedRoomHashes.has(createHash('sha256').update(room).digest('hex'))) {
      reject(socket, '403 Forbidden'); return;
    }
    const members = rooms.get(room);
    if (members?.[role] || (!members && rooms.size >= maxRooms)) {
      socket.end('HTTP/1.1 409 Conflict\r\nConnection: close\r\n\r\n'); return;
    }
    wss.handleUpgrade(req, socket, head, ws => {
      const pair = rooms.get(room) ?? {};
      rooms.set(room, pair);
      pair[role] = ws;
      addresses.set(address, (addresses.get(address) ?? 0) + 1);
      let tokens = messagesPerSecond * 2, byteTokens = bytesPerSecond * 2, lastRefill = performance.now();
      ws.alive = true;
      ws.on('pong', () => { ws.alive = true; });
      const timer = setTimeout(() => { if (!pair.host || !pair.client) ws.close(1008, 'Pairing timeout'); }, idleMs);
      timer.unref();
      ws.on('message', (data, binary) => {
        const tick = performance.now(), elapsed = Math.max(0, (tick - lastRefill) / 1000);
        lastRefill = tick;
        tokens = Math.min(messagesPerSecond * 2, tokens + elapsed * messagesPerSecond) - 1;
        byteTokens = Math.min(bytesPerSecond * 2, byteTokens + elapsed * bytesPerSecond) - data.length;
        if (tokens < 0 || byteTokens < 0) { ws.close(1008, 'Rate limit exceeded'); return; }
        if (!binary) { ws.close(1003, 'Binary messages required'); return; }
        const other = pair[role === 'host' ? 'client' : 'host'];
        if (!other || other.readyState !== WebSocket.OPEN) { ws.close(1008, 'Peer unavailable'); return; }
        if (other.bufferedAmount > 8 * 1024 * 1024) { other.close(1013, 'Receiver too slow'); ws.close(1013, 'Receiver too slow'); return; }
        other.send(data, {binary: true});
      });
      ws.on('error', () => ws.terminate());
      ws.on('close', () => {
        clearTimeout(timer);
        const remaining = (addresses.get(address) ?? 1) - 1;
        if (remaining > 0) addresses.set(address, remaining); else addresses.delete(address);
        if (pair[role] !== ws) return;
        delete pair[role];
        const other = pair[role === 'host' ? 'client' : 'host'];
        if (other) other.close(1001, 'Peer disconnected');
        if (rooms.get(room) === pair) rooms.delete(room);
      });
      if (pair.host && pair.client) {
        const ready = JSON.stringify({type: 'ready'});
        pair.host.send(ready); pair.client.send(ready);
      }
    });
  });
  const heartbeat = setInterval(() => {
    for (const ws of wss.clients) {
      if (!ws.alive) { ws.terminate(); continue; }
      ws.alive = false; ws.ping();
    }
  }, 30_000);
  heartbeat.unref();
  server.on('close', () => { clearInterval(heartbeat); for (const ws of wss.clients) ws.terminate(); wss.close(); });
  return server;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  // Public deployments fail closed if the private room registry is missing or malformed.
  let options = {};
  if (process.env.ROOM_ALLOWLIST_FILE) {
    const hashes = readFileSync(process.env.ROOM_ALLOWLIST_FILE, 'utf8').trim().split(/\s+/);
    if (!hashes.length || hashes.some(hash => !/^[a-f0-9]{64}$/.test(hash))) throw new Error('Invalid room registry');
    options = { allowedRoomHashes: new Set(hashes), maxRooms: 2, maxConnectionsPerIP: 4,
      bytesPerSecond: 4 * 1024 * 1024 };
  }
  if (process.env.REQUIRE_ROOM_ALLOWLIST === '1' && !options.allowedRoomHashes) throw new Error('Private room registry required');
  const server = createRelay(options);
  server.listen(Number(process.env.PORT ?? 8787), process.env.BIND ?? '127.0.0.1', () => {
    console.log('Reach relay listening; configure a TLS reverse proxy for public access.');
  });
}
