import { test } from 'node:test';
import assert from 'node:assert/strict';
import { once } from 'node:events';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createHash, randomBytes } from 'node:crypto';
import { WebSocket } from 'ws';
import { createRelay } from './server.mjs';

test('relay forwards opaque binary frames and closes its peer', async () => {
  const server = createRelay();
  server.listen(0, '127.0.0.1'); await once(server, 'listening');
  const endpoint = `ws://127.0.0.1:${server.address().port}/tunnel?room=${randomBytes(32).toString('hex')}`;
  const host = new WebSocket(`${endpoint}&role=host`);
  await once(host, 'open');
  const hostReady = once(host, 'message');
  const client = new WebSocket(`${endpoint}&role=client`);
  const clientReady = once(client, 'message');
  await once(client, 'open');
  assert.equal(JSON.parse((await hostReady)[0]).type, 'ready');
  assert.equal(JSON.parse((await clientReady)[0]).type, 'ready');
  const packet = randomBytes(128 * 1024);
  const received = once(client, 'message');
  host.send(packet); const [data, binary] = await received;
  assert.equal(binary, true); assert.deepEqual(data, packet);
  const reply = once(host, 'message'); client.send(Buffer.from('opaque'));
  assert.equal((await reply)[0].toString(), 'opaque');
  const closed = once(client, 'close'); host.close(); await closed;
  await new Promise(resolve => server.close(resolve));
});

test('relay rejects weak rendezvous secrets', async () => {
  const server = createRelay(); server.listen(0, '127.0.0.1'); await once(server, 'listening');
  const socket = new WebSocket(`ws://127.0.0.1:${server.address().port}/tunnel?room=123456&role=host`);
  socket.on('error', () => {});
  const [, response] = await once(socket, 'unexpected-response');
  assert.equal(response.statusCode, 400); socket.terminate();
  await new Promise(resolve => server.close(resolve));
});

async function localRelay(options = {}) {
  const server = createRelay(options);
  server.listen(0, '127.0.0.1'); await once(server, 'listening');
  return { server, url: `ws://127.0.0.1:${server.address().port}/tunnel`, close: () => new Promise(resolve => server.close(resolve)) };
}
async function rejection(url) {
  const socket = new WebSocket(url); socket.on('error', () => {});
  const [, response] = await once(socket, 'unexpected-response');
  socket.terminate(); return response.statusCode;
}
async function paired(relay) {
  const url = `${relay.url}?room=${randomBytes(32).toString('hex')}`;
  const host = new WebSocket(`${url}&role=host`); await once(host, 'open');
  const ready = once(host, 'message');
  const client = new WebSocket(`${url}&role=client`); await once(client, 'open'); await ready;
  return { host, client, url };
}

test('relay rejects duplicate roles, excess rooms, invalid paths and roles', async () => {
  const relay = await localRelay({maxRooms: 1});
  const room = randomBytes(32).toString('hex');
  const host = new WebSocket(`${relay.url}?room=${room}&role=host`); await once(host, 'open');
  assert.equal(await rejection(`${relay.url}?room=${room}&role=host`), 409);
  assert.equal(await rejection(`${relay.url}?room=${randomBytes(32).toString('hex')}&role=host`), 409);
  assert.equal(await rejection(`${relay.url}?room=${room}&role=admin`), 400);
  assert.equal(await rejection(`${relay.url.replace('/tunnel', '/other')}?room=${room}&role=client`), 400);
  host.terminate(); await relay.close();
});

test('relay closes unpaired idle sockets', async () => {
  const relay = await localRelay({idleMs: 30});
  const host = new WebSocket(`${relay.url}?room=${randomBytes(32).toString('hex')}&role=host`);
  await once(host, 'open');
  assert.equal((await once(host, 'close'))[0], 1008);
  await relay.close();
});

test('relay bounds per-address connections', async () => {
  const relay = await localRelay({maxConnectionsPerIP: 1});
  const host = new WebSocket(`${relay.url}?room=${randomBytes(32).toString('hex')}&role=host`); await once(host, 'open');
  assert.equal(await rejection(`${relay.url}?room=${randomBytes(32).toString('hex')}&role=host`), 429);
  host.terminate(); await relay.close();
});

test('relay rejects text messages and disconnects their peer', async () => {
  const relay = await localRelay(); const {host, client} = await paired(relay);
  const hostClosed = once(host, 'close'), clientClosed = once(client, 'close');
  host.send('not binary');
  assert.equal((await hostClosed)[0], 1003); await clientClosed; await relay.close();
});

test('relay bounds message floods', async () => {
  const relay = await localRelay({messagesPerSecond: 1}); const {host, client} = await paired(relay);
  const closed = once(host, 'close'), otherClosed = once(client, 'close');
  for (let i = 0; i < 5; i++) host.send(Buffer.from('opaque'));
  assert.equal((await closed)[0], 1008); await otherClosed; await relay.close();
});

test('relay bounds byte floods and oversized messages', async () => {
  const relay = await localRelay({bytesPerSecond: 32}); const {host, client} = await paired(relay);
  const closed = once(host, 'close'), otherClosed = once(client, 'close'); host.send(Buffer.alloc(128));
  assert.equal((await closed)[0], 1008); await otherClosed; await relay.close();
  const small = await localRelay({maxPayload: 128}); const pair = await paired(small);
  const tooLarge = once(pair.host, 'close'), peerClosed = once(pair.client, 'close'); pair.host.send(Buffer.alloc(129));
  assert.equal((await tooLarge)[0], 1009); await peerClosed; await small.close();
});


test('private deployment admits registered rooms and rejects arbitrary rooms', async () => {
  const room = randomBytes(32).toString('hex');
  const relay = await localRelay({allowedRoomHashes: new Set([createHash('sha256').update(room).digest('hex')])});
  assert.equal(await rejection(`${relay.url}?room=${randomBytes(32).toString('hex')}&role=host`), 403);
  const host = new WebSocket(`${relay.url}?room=${room}&role=host`); await once(host, 'open');
  const ready = once(host, 'message');
  const client = new WebSocket(`${relay.url}?room=${room}&role=client`);
  // Consume both ready frames before asserting on application traffic.
  const clientReady = once(client, 'message');
  await once(client, 'open'); await Promise.all([ready, clientReady]);
  const received = once(client, 'message'); host.send(Buffer.from('private'));
  assert.equal((await received)[0].toString(), 'private');
  host.terminate(); client.terminate(); await relay.close();
});


test('required private registry fails startup when absent, unreadable or malformed', () => {
  const dir = mkdtempSync(join(tmpdir(), 'reach-registry-'));
  const registry = join(dir, 'registry');
  try {
    for (const entry of [undefined, registry]) {
      const env = {...process.env, REQUIRE_ROOM_ALLOWLIST: '1'};
      delete env.ROOM_ALLOWLIST_FILE;
      if (entry) env.ROOM_ALLOWLIST_FILE = entry;
      const result = spawnSync(process.execPath, ['server.mjs'], {cwd: import.meta.dirname, env, timeout: 2000});
      assert.equal(result.status, 1);
    }
    for (const content of ['', 'not-a-room-hash']) {
      writeFileSync(registry, content);
      const result = spawnSync(process.execPath, ['server.mjs'], {cwd: import.meta.dirname,
        env: {...process.env, REQUIRE_ROOM_ALLOWLIST: '1', ROOM_ALLOWLIST_FILE: registry}, timeout: 2000});
      assert.equal(result.status, 1);
    }
  } finally { rmSync(dir, {recursive: true, force: true}); }
});
