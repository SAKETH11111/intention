import {test, before, after} from 'node:test';
import assert from 'node:assert/strict';
import net from 'node:net';
import http from 'node:http';
import {gzipSync} from 'node:zlib';
import {once} from 'node:events';
import {WebSocket, WebSocketServer} from 'ws';
import {createProxy, createBoundedForwarder, requestUpstream, MAX_QUEUED_BYTES, MAX_QUEUED_MESSAGES} from '../src/server.mjs';
import {settings} from '../src/config.mjs';

const env = {UPSTREAM_API: 'https://api.example/base', UPSTREAM_SPEECH: 'wss://speech.example/stream', ALLOWED_ORIGINS: 'https://client.example'};
let proxy, fixture, port, forwarded, responseFactory, speechHeaders, speechMode = 'echo';
const upstreams = [], fixtureConnections = [];
async function freePort() {
  const socket = net.createServer(); socket.listen(0, '127.0.0.1'); await once(socket, 'listening');
  const value = socket.address().port; await new Promise(resolve => socket.close(resolve)); return value;
}
before(async () => {
  fixture = new WebSocketServer({port: 0, host: '127.0.0.1', verifyClient: (_info, done) => speechMode === 'refused' ? done(false, 401) : done(true)});
  await once(fixture, 'listening');
  fixture.on('connection', (ws, req) => {
    fixtureConnections.push(ws);
    speechHeaders = req.headers;
    ws.on('message', (data, binary) => ws.send(data, {binary}));
  });
  port = await freePort();
  proxy = createProxy({...env, PROXY_PORT: String(port)}, {
    requestImpl: async (url, options) => {
      forwarded = {url: String(url), ...options};
      return responseFactory ? responseFactory() : new Response('ok', {headers: {'Content-Type': 'text/plain'}});
    },
    webSocketFactory: (url, options) => {
      assert.equal(url, env.UPSTREAM_SPEECH);
      const ws = new WebSocket(`ws://127.0.0.1:${fixture.address().port}`, options.protocols, options);
      upstreams.push(ws); return ws;
    }
  });
  proxy.server.listen(port, '127.0.0.1'); await once(proxy.server, 'listening');
});
after(async () => {
  for (const ws of fixture.clients) ws.terminate();
  for (const ws of proxy.wss.clients) ws.terminate();
  for (const ws of upstreams) ws.terminate();
  await new Promise(resolve => fixture.close(resolve));
  await new Promise(resolve => proxy.server.close(resolve));
});
function request(path, options = {}) { return fetch(proxy.origin + path, {...options, redirect: 'manual'}); }
async function connect(authorization = 'Bearer synthetic-grant') {
  const headers = authorization === null ? {} : {Authorization: authorization};
  const ws = new WebSocket(proxy.origin.replace('http:', 'ws:') + '/speech', {headers});
  await once(ws, 'open'); return ws;
}
async function close(ws) { const ended = once(ws, 'close'); ws.close(); await ended; }

test('configuration requires secure upstreams and explicit browser origins', () => {
  assert.equal(settings(env).api.href, 'https://api.example/base');
  for (const invalid of [{UPSTREAM_API: 'http://api.example'}, {UPSTREAM_SPEECH: 'ws://speech.example'},
    {UPSTREAM_API: 'https://user:password@api.example'}, {UPSTREAM_SPEECH: 'wss://speech.example?key=synthetic'},
    {ALLOWED_ORIGINS: 'https://client.example/path'}]) assert.throws(() => settings({...env, ...invalid}));
  assert.throws(() => createProxy({...env, PROXY_PORT: '70000'}));
});

test('HTTP forwards body bytes, path, query and authorization without edits', async () => {
  responseFactory = undefined;
  const body = Buffer.from(' { "message": "Synthetic text", "compose": {"add_signature": true} }\n');
  const response = await request('/v1/writing/drafts?format=plain', {method: 'POST', body,
    headers: {Authorization: 'Bearer synthetic-device', 'Content-Type': 'application/json', Cookie: 'synthetic-cookie', 'X-Provider': 'synthetic'}});
  assert.equal(response.status, 200); assert.equal(await response.text(), 'ok');
  assert.equal(forwarded.url, 'https://api.example/base/v1/writing/drafts?format=plain');
  assert.deepEqual(forwarded.body, body);
  assert.equal(forwarded.headers.authorization, 'Bearer synthetic-device');
  assert.equal(forwarded.headers['content-type'], 'application/json');
  assert.ok(!('cookie' in forwarded.headers)); assert.ok(!('x-provider' in forwarded.headers));
});

test('HTTP returns signed documents and grant bytes unchanged', async () => {
  const body = ' {"grant":"v1.synthetic.signature","expires_in":300,"signed_payload":"synthetic-payload","signature":"synthetic-signature"}\n';
  responseFactory = () => new Response(body, {status: 201, headers: {'Content-Type': 'application/json'}});
  const response = await request('/v1/speech/grants', {method: 'POST'});
  assert.equal(response.status, 201); assert.equal(await response.text(), body);
});

test('HTTP preserves binary responses and upstream errors', async () => {
  const binary = Buffer.from([0, 255, 1, 128]);
  responseFactory = () => new Response(binary, {headers: {'Content-Type': 'application/octet-stream'}});
  let response = await request('/download'); assert.deepEqual(Buffer.from(await response.arrayBuffer()), binary);
  const body = '{"detail":"A synthetic service error","retry":true}';
  responseFactory = () => new Response(body, {status: 503, headers: {'Content-Type': 'application/json', 'Retry-After': '4'}});
  response = await request('/status'); assert.equal(response.status, 503); assert.equal(await response.text(), body);
  assert.equal(response.headers.get('retry-after'), '4');
});

test('redirects are returned unchanged and never followed by the proxy', async () => {
  responseFactory = () => new Response(null, {status: 303, headers: {Location: 'https://api.example/next'}});
  const response = await request('/next'); assert.equal(response.status, 303);
  assert.equal(response.headers.get('location'), 'https://api.example/next');
});

test('response framing and cookies do not contaminate the local connection', async () => {
  responseFactory = () => new Response('unchanged', {headers: {'Content-Type': 'text/plain', 'Content-Length': '100', 'Set-Cookie': 's=synthetic', Server: 'synthetic'}});
  const response = await request('/framing'); assert.equal(await response.text(), 'unchanged');
  assert.notEqual(response.headers.get('content-length'), '100');
  assert.equal(response.headers.get('set-cookie'), null); assert.equal(response.headers.get('server'), null);
});

test('empty admission and HEAD responses remain empty', async () => {
  responseFactory = () => new Response(null, {status: 204});
  let response = await request('/admission', {method: 'POST'}); assert.equal(response.status, 204); assert.equal(await response.text(), '');
  responseFactory = () => new Response('not returned', {headers: {'Content-Type': 'text/plain'}});
  response = await request('/head', {method: 'HEAD'}); assert.equal(await response.text(), '');
});

test('unconfigured startup reports health and never calls an upstream', async () => {
  const temporaryPort = await freePort(); let calls = 0;
  const empty = createProxy({PROXY_PORT: String(temporaryPort)}, {requestImpl: () => { calls++; throw Error('unreachable'); }});
  empty.server.listen(temporaryPort, '127.0.0.1'); await once(empty.server, 'listening');
  try {
    assert.deepEqual(await (await fetch(empty.origin + '/health')).json(), {status: 'ok', configured: false});
    assert.equal((await fetch(empty.origin + '/v1/me')).status, 503); assert.equal(calls, 0);
  } finally { await new Promise(resolve => empty.server.close(resolve)); }
});

test('browser origin checks and preflight are enforced before forwarding', async () => {
  forwarded = undefined;
  let response = await request('/status', {headers: {Origin: 'https://other.example'}});
  assert.equal(response.status, 403); assert.equal(forwarded, undefined);
  response = await request('/status', {method: 'OPTIONS', headers: {Origin: 'https://client.example', 'Access-Control-Request-Method': 'POST'}});
  assert.equal(response.status, 204); assert.equal(response.headers.get('access-control-allow-origin'), 'https://client.example');
  assert.equal(forwarded, undefined);
  responseFactory = () => new Response('ok');
  response = await request('/status', {headers: {Origin: 'https://client.example'}});
  assert.equal(response.status, 200); assert.equal(response.headers.get('access-control-allow-origin'), 'https://client.example');
});

async function rawRequest(line, headers = '', host = `127.0.0.1:${port}`) {
  const socket = net.connect(port, '127.0.0.1'); await once(socket, 'connect');
  let response = ''; socket.on('data', data => { response += data; });
  const ended = once(socket, 'close');
  socket.write(`${line}\r\nHost: ${host}\r\nConnection: close\r\n${headers}\r\n`);
  await ended; return response;
}

test('absolute-form targets and non-local Host headers are refused', async () => {
  forwarded = undefined;
  assert.match(await rawRequest('GET https://other.example/ HTTP/1.1'), /HTTP\/1.1 400/);
  assert.match(await rawRequest('GET //other.example/ HTTP/1.1'), /HTTP\/1.1 400/);
  assert.match(await rawRequest('GET /status HTTP/1.1', '', 'other.example'), /HTTP\/1\.1 403/);
  assert.equal(forwarded, undefined);
});

test('transport failures expose only a fixed local error', async () => {
  responseFactory = () => { throw Error('synthetic credential-bearing transport error'); };
  const response = await request('/failure'); assert.equal(response.status, 502);
  assert.deepEqual(await response.json(), {detail: 'upstream_unavailable'});
});

test('oversized upstream responses are refused before returning a body', async () => {
  responseFactory = () => new Response(Buffer.alloc(8 * 1024 * 1024 + 1));
  const response = await request('/large'); assert.equal(response.status, 502);
  assert.deepEqual(await response.json(), {detail: 'upstream_unavailable'});
});

test('WebSocket messages and authorization cross the bridge unchanged', async () => {
  const ws = await connect('Bearer v1.synthetic.signature');
  assert.equal(speechHeaders.authorization, 'Bearer v1.synthetic.signature');
  const text = ' {"type":"start", "retention":true, "unknown":"Synthetic text"}\n';
  let received = once(ws, 'message'); ws.send(text);
  let [data, binary] = await received; assert.equal(data.toString(), text); assert.equal(binary, false);
  const bytes = Buffer.from([0, 255, 4, 128, 64]); received = once(ws, 'message'); ws.send(bytes, {binary: true});
  [data, binary] = await received; assert.deepEqual(data, bytes); assert.equal(binary, true);
  received = once(ws, 'message'); ws.send('a non-JSON message');
  [data] = await received; assert.equal(data.toString(), 'a non-JSON message'); await close(ws);
});

test('a malformed downstream handshake does not open an upstream', async () => {
  const count = upstreams.length;
  const socket = net.connect(port, '127.0.0.1'); await once(socket, 'connect');
  let response = ''; socket.on('data', data => { response += data; }); const ended = once(socket, 'close');
  socket.write(`GET /speech HTTP/1.1\r\nHost: 127.0.0.1:${port}\r\nConnection: Upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Version: 13\r\nAuthorization: Bearer synthetic-grant\r\n\r\n`);
  await ended; assert.match(response, /HTTP\/1.1 400/); assert.equal(upstreams.length, count);
});

test('an upstream handshake refusal is returned without leaving a connection', async () => {
  speechMode = 'refused';
  const ws = new WebSocket(proxy.origin.replace('http:', 'ws:') + '/speech', {headers: {Authorization: 'Bearer synthetic-grant'}});
  const status = new Promise(resolve => ws.once('unexpected-response', (_request, response) => { response.resume(); resolve(response.statusCode); }));
  ws.on('error', () => {});
  assert.equal(await status, 401); ws.terminate(); speechMode = 'echo';
});

test('queued sends are capped even before bufferedAmount reports them', () => {
  let calls = 0, aborted;
  const target = {bufferedAmount: 0, send() { calls++; }};
  const relay = createBoundedForwarder(target, code => { aborted = code; });
  for (let i = 0; i < 65; i++) relay.send(Buffer.alloc(16384), true);
  assert.equal(calls, 64); assert.equal(aborted, 1009); assert.equal(MAX_QUEUED_BYTES, 1024 * 1024); relay.dispose();
});

test('new messages cannot postpone a stalled send deadline', async () => {
  let aborted; const target = {bufferedAmount: 0, send() {}};
  const relay = createBoundedForwarder(target, code => { aborted = code; }, 60);
  relay.send(Buffer.alloc(16), true); const trickle = setInterval(() => relay.send(Buffer.alloc(16), true), 10);
  await new Promise(resolve => setTimeout(resolve, 110)); clearInterval(trickle); relay.dispose(); assert.equal(aborted, 1011);
});

async function rawBodyRequest(origin, method, body, headers = {}) {
  return new Promise((resolve, reject) => {
    const request = http.request(new URL('/bytes', origin), {method, headers: {...headers, 'Content-Length': body.length}}, response => {
      const chunks = []; response.on('data', chunk => chunks.push(chunk));
      response.on('error', reject);
      response.on('end', () => resolve({status: response.statusCode, headers: response.headers, body: Buffer.concat(chunks)}));
    });
    request.on('error', reject); request.end(body);
  });
}

test('GET and HEAD bodies reach the configured service unchanged', async () => {
  const body = Buffer.from('synthetic request body'); responseFactory = () => new Response('ok');
  for (const method of ['GET', 'HEAD']) {
    const response = await rawBodyRequest(proxy.origin, method, body);
    assert.equal(response.status, 200); assert.equal(forwarded.method, method); assert.deepEqual(forwarded.body, body);
  }
});

test('compressed request and response bytes survive the native HTTP transport', async () => {
  const encoded = gzipSync(Buffer.from('{"message":"Synthetic compression fixture"}'));
  let arrived, arrivedHeaders;
  const service = http.createServer(async (req, res) => {
    const chunks = []; for await (const chunk of req) chunks.push(chunk);
    arrived = Buffer.concat(chunks); arrivedHeaders = req.headers;
    res.writeHead(200, {'Content-Type': 'application/json', 'Content-Encoding': 'gzip'}); res.end(encoded);
  });
  service.listen(0, '127.0.0.1'); await once(service, 'listening');
  const temporaryPort = await freePort();
  const local = createProxy({...env, PROXY_PORT: String(temporaryPort)}, {
    requestImpl: (_url, options) => requestUpstream(new URL(`http://127.0.0.1:${service.address().port}/bytes`), options, http.request)
  });
  local.server.listen(temporaryPort, '127.0.0.1'); await once(local.server, 'listening');
  try {
    const response = await rawBodyRequest(local.origin, 'POST', encoded, {'Content-Type': 'application/json', 'Content-Encoding': 'gzip'});
    assert.deepEqual(arrived, encoded); assert.equal(arrivedHeaders['content-encoding'], 'gzip');
    assert.deepEqual(response.body, encoded); assert.equal(response.headers['content-encoding'], 'gzip');
    await rawBodyRequest(local.origin, 'GET', encoded); assert.deepEqual(arrived, encoded);
    await rawBodyRequest(local.origin, 'HEAD', encoded); assert.deepEqual(arrived, encoded);
  } finally {
    await new Promise(resolve => local.server.close(resolve)); await new Promise(resolve => service.close(resolve));
  }
});

test('an empty stalled send still has a progress deadline', async () => {
  let aborted; const target = {bufferedAmount: 0, send() {}};
  const relay = createBoundedForwarder(target, code => { aborted = code; }, 40);
  relay.send(Buffer.alloc(0), false); await new Promise(resolve => setTimeout(resolve, 80));
  relay.dispose(); assert.equal(aborted, 1011);
});

test('empty messages have a finite queue bound', () => {
  let calls = 0, aborted; const target = {bufferedAmount: 0, send() { calls++; }};
  const relay = createBoundedForwarder(target, code => { aborted = code; });
  for (let i = 0; i <= 1024; i++) relay.send(Buffer.alloc(0), false);
  relay.dispose(); assert.equal(calls, 1024); assert.equal(MAX_QUEUED_MESSAGES, 1024); assert.equal(aborted, 1009);
});

test('invalid subprotocol offers are refused before opening the upstream', async () => {
  const count = upstreams.length;
  for (const protocols of ['duplicate, duplicate', 'one,,two', 'one two', 'one' + String.fromCharCode(160)]) {
    const socket = net.connect(port, '127.0.0.1'); await once(socket, 'connect');
    let response = ''; socket.on('data', data => { response += data; }); const ended = once(socket, 'close');
    socket.write(`GET /speech HTTP/1.1\r\nHost: 127.0.0.1:${port}\r\nConnection: Upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: MDEyMzQ1Njc4OWFiY2RlZg==\r\nSec-WebSocket-Protocol: ${protocols}\r\nAuthorization: Bearer synthetic-grant\r\n\r\n`, 'latin1');
    await ended; assert.match(response, /HTTP\/1\.1 400/);
  }
  assert.equal(upstreams.length, count);
});

test('the same selected subprotocol is used on both WebSocket connections', async () => {
  const ws = new WebSocket(proxy.origin.replace('http:', 'ws:') + '/speech', ['speech-v1', 'speech-v2'], {headers: {Authorization: 'Bearer synthetic-grant'}});
  await once(ws, 'open'); assert.equal(ws.protocol, 'speech-v1');
  assert.equal(upstreams.at(-1).protocol, 'speech-v1'); await close(ws);
});


test('ordinary OPTIONS requests keep their body and reach upstream', async () => {
  responseFactory = () => new Response('ordinary OPTIONS');
  const body = Buffer.from('synthetic OPTIONS body');
  const response = await rawBodyRequest(proxy.origin, 'OPTIONS', body, {Origin: 'https://client.example'});
  assert.equal(response.status, 200); assert.equal(forwarded.method, 'OPTIONS'); assert.deepEqual(forwarded.body, body);
});

test('native HEAD, 204 and 304 response streams finish and release their connections', async () => {
  const service = http.createServer((req, res) => {
    const status = req.url.endsWith('/204') ? 204 : req.url.endsWith('/304') ? 304 : 200;
    res.writeHead(status); res.end('synthetic representation');
  });
  service.listen(0, '127.0.0.1'); await once(service, 'listening');
  const agent = new http.Agent({keepAlive: true, maxSockets: 1});
  const observed = [], temporaryPort = await freePort();
  const local = createProxy({...env, PROXY_PORT: String(temporaryPort)}, {
    requestImpl: async (url, options) => {
      const target = new URL(`http://127.0.0.1:${service.address().port}${url.pathname}`);
      const response = await requestUpstream(target, options, (address, opts, done) => http.request(address, {...opts, agent}, done));
      observed.push(response.body); return response;
    }
  });
  local.server.listen(temporaryPort, '127.0.0.1'); await once(local.server, 'listening');
  try {
    for (const [method, path] of [['HEAD', '/head'], ['GET', '/204'], ['GET', '/304']]) {
      await new Promise((resolve, reject) => {
        const req = http.request(new URL(path, local.origin), {method}, res => { res.resume(); res.on('end', resolve); res.on('error', reject); });
        req.on('error', reject); req.end();
      });
      assert.equal(observed.at(-1).readableEnded, true);
      await new Promise(resolve => setImmediate(resolve));
      assert.equal(Object.values(agent.sockets).flat().length, 0);
    }
  } finally {
    agent.destroy(); await new Promise(resolve => local.server.close(resolve)); await new Promise(resolve => service.close(resolve));
  }
});

test('downstream graceful close code and reason reach the upstream', async () => {
  const ws = await connect(); const ended = once(fixtureConnections.at(-1), 'close');
  ws.close(1000, 'done');
  const [code, reason] = await ended; assert.equal(code, 1000); assert.equal(reason.toString(), 'done');
});

test('upstream argument-free close reaches downstream without an abnormal code', async () => {
  const ws = await connect(); const ended = once(ws, 'close'); fixtureConnections.at(-1).close();
  const [code, reason] = await ended; assert.equal(code, 1005); assert.equal(reason.length, 0);
});

test('upstream graceful close code and reason reach downstream', async () => {
  const ws = await connect(); const ended = once(ws, 'close'); fixtureConnections.at(-1).close(1013, 'retry later');
  const [code, reason] = await ended; assert.equal(code, 1013); assert.equal(reason.toString(), 'retry later');
});

test('a peer that never acknowledges a graceful close is terminated', async () => {
  const ws = await connect(); const upstream = upstreams.at(-1), peer = fixtureConnections.at(-1);
  peer.pause(); await close(ws); await new Promise(resolve => setTimeout(resolve, 350));
  assert.equal(upstream.readyState, WebSocket.CLOSED); peer.resume(); peer.terminate();
});


test('WebSocket authorization scheme and length belong to the configured service', async () => {
  for (const value of ['bearer synthetic-grant', 'Basic ' + Buffer.from('synthetic:fixture').toString('base64'), 'Bearer ' + 'x'.repeat(3000), null]) {
    const ws = await connect(value);
    assert.equal(speechHeaders.authorization, value ?? undefined);
    await close(ws);
  }
});

test('a rejected half-open client cannot retain the server socket', async () => {
  const accepted = once(proxy.server, 'connection');
  const socket = net.connect({port, host: '127.0.0.1', allowHalfOpen: true});
  await once(socket, 'connect'); const [serverSocket] = await accepted;
  let response = ''; socket.on('data', data => { response += data; });
  const ended = once(socket, 'end');
  try {
    socket.write(`GET /speech HTTP/1.1\r\nHost: 127.0.0.1:${port}\r\nConnection: Upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Version: 13\r\n\r\n`);
    await ended; assert.match(response, /HTTP\/1\.1 400/);
    await new Promise(resolve => setTimeout(resolve, 350)); assert.equal(serverSocket.destroyed, true);
  } finally { socket.destroy(); }
});
