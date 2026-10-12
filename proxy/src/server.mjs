import http from 'node:http';
import https from 'node:https';
import {fileURLToPath} from 'node:url';
import {resolve} from 'node:path';
import {existsSync} from 'node:fs';
import {WebSocket, WebSocketServer} from 'ws';
import {settings} from './config.mjs';

const requestHeaders = ['authorization', 'content-type', 'content-encoding', 'accept', 'accept-language', 'accept-encoding'];
const responseHeaders = ['content-type', 'content-encoding', 'content-language', 'retry-after', 'location', 'etag', 'content-disposition'];
const methods = new Set(['GET', 'HEAD', 'POST', 'PUT', 'PATCH', 'DELETE', 'OPTIONS']);
const noStore = {'Cache-Control': 'no-store', 'Referrer-Policy': 'no-referrer', 'X-Content-Type-Options': 'nosniff'};

function send(res, status, value) {
  res.writeHead(status, {...noStore, 'Content-Type': 'application/json'});
  res.end(JSON.stringify(value));
}

async function boundedBody(stream, limit) {
  const chunks = [];
  let size = 0;
  for await (const chunk of stream) {
    size += chunk.length;
    if (size > limit) throw Error('too_large');
    chunks.push(chunk);
  }
  return Buffer.concat(chunks);
}

function allowed(req, port, config) {
  const host = req.headers.host;
  return (host === `127.0.0.1:${port}` || host === `localhost:${port}`) &&
    (!req.headers.origin || config?.origins.includes(req.headers.origin));
}

export function requestUpstream(url, options, transport = https.request) {
  return new Promise((resolve, reject) => {
    const body = options.body ?? Buffer.alloc(0);
    const request = transport(url, {method: options.method,
      headers: {...options.headers, 'content-length': String(body.length)}, signal: options.signal}, response => {
      resolve({status: response.statusCode, headers: new Headers(response.headers), body: response});
    });
    request.once('error', reject);
    request.end(body);
  });
}

function offeredProtocols(header) {
  if (header === undefined) return [];
  if (typeof header !== 'string') return null;
  const protocols = header.split(',').map(value => value.replace(/^[ \t]+|[ \t]+$/g, ''));
  return protocols.every(value => /^[!#$%&'*+.^_`|~0-9A-Za-z-]+$/.test(value)) &&
    new Set(protocols).size === protocols.length ? protocols : null;
}

export const MAX_QUEUED_BYTES = 1024 * 1024;
export const MAX_QUEUED_MESSAGES = 1024;

export function createBoundedForwarder(target, abort, stallTimeoutMs = 5000) {
  let pending = 0, pendingMessages = 0, timer, disposed = false;
  const dispose = () => { disposed = true; clearTimeout(timer); };
  const failed = code => { dispose(); abort(code); };
  const watch = () => {
    clearTimeout(timer);
    if (pendingMessages > 0) {
      timer = setTimeout(() => failed(1011), stallTimeoutMs);
      timer.unref?.();
    }
  };
  return {
    dispose,
    send(data, binary) {
      if (disposed) return;
      const bytes = Buffer.byteLength(data);
      if (pendingMessages >= MAX_QUEUED_MESSAGES || pending + bytes > MAX_QUEUED_BYTES ||
          target.bufferedAmount + bytes > MAX_QUEUED_BYTES) {
        return failed(1009);
      }
      const wasEmpty = pendingMessages === 0;
      pending += bytes;
      pendingMessages++;
      // New frames cannot extend the deadline for a send that has made no progress.
      if (wasEmpty) watch();
      try {
        target.send(data, {binary}, error => {
          if (disposed) return;
          pending -= bytes;
          pendingMessages--;
          if (error) return failed(1011);
          watch();
        });
      } catch { failed(1011); }
    }
  };
}

export function createProxy(env, {
  requestImpl = requestUpstream,
  webSocketFactory = (url, options) => new WebSocket(url, options.protocols, options),
  stallTimeoutMs = 5000
} = {}) {
  let config;
  try { config = settings(env); } catch {}
  const port = Number(env.PROXY_PORT || 8787);
  if (!Number.isInteger(port) || port < 1 || port > 65535) throw Error('configuration');
  const origin = `http://127.0.0.1:${port}`;
  const protocolChoices = new WeakMap();
  const wss = new WebSocketServer({noServer: true, maxPayload: MAX_QUEUED_BYTES, perMessageDeflate: false,
    handleProtocols: (_protocols, req) => protocolChoices.get(req) || false});
  const server = http.createServer(async (req, res) => {
    const controller = new AbortController();
    req.once('aborted', () => controller.abort());
    res.once('close', () => { if (!res.writableEnded) controller.abort(); });
    try {
      if (!allowed(req, port, config)) return send(res, 403, {detail: 'forbidden'});
      // A client can select a path, but it cannot select another host or scheme.
      if (!req.url.startsWith('/') || req.url.startsWith('//')) return send(res, 400, {detail: 'invalid_request'});
      const url = new URL(req.url, origin);
      if (req.method === 'GET' && url.pathname === '/health' && !url.search) {
        return send(res, 200, {status: 'ok', configured: !!config});
      }
      if (!config) return send(res, 503, {detail: 'not_configured'});
      if (!methods.has(req.method)) return send(res, 405, {detail: 'method_not_allowed'});
      if (req.method === 'OPTIONS' && req.headers.origin && req.headers['access-control-request-method']) {
        if (!methods.has(req.headers['access-control-request-method'])) return send(res, 405, {detail: 'method_not_allowed'});
        res.writeHead(204, {...noStore, 'Access-Control-Allow-Origin': req.headers.origin,
          'Access-Control-Allow-Headers': 'Authorization, Content-Type, Content-Encoding, Accept, Accept-Language',
          'Access-Control-Allow-Methods': 'GET, HEAD, POST, PUT, PATCH, DELETE, OPTIONS', 'Vary': 'Origin'});
        return res.end();
      }
      const body = await boundedBody(req, MAX_QUEUED_BYTES);
      const target = new URL(config.api);
      target.pathname = config.api.pathname.replace(/\/$/, '') + url.pathname;
      target.search = url.search;
      const headers = {};
      for (const name of requestHeaders) if (req.headers[name]) headers[name] = req.headers[name];
      const response = await requestImpl(target, {method: req.method, headers, body,
        signal: AbortSignal.any([controller.signal, AbortSignal.timeout(120000)])});
      // Even bodyless responses must finish their stream so the upstream connection can be reused.
      const received = response.body ? await boundedBody(response.body, 8 * MAX_QUEUED_BYTES) : Buffer.alloc(0);
      const raw = req.method === 'HEAD' || [204, 205, 304].includes(response.status) ? Buffer.alloc(0) : received;
      const returnedHeaders = {...noStore};
      // The transport retains encoded bytes. Node frames the bounded body with its actual length.
      for (const name of responseHeaders) {
        const value = response.headers.get(name);
        if (value) returnedHeaders[name] = value;
      }
      if (req.headers.origin) {
        returnedHeaders['Access-Control-Allow-Origin'] = req.headers.origin;
        returnedHeaders.Vary = 'Origin';
      }
      res.writeHead(response.status, returnedHeaders);
      res.end(raw);
    } catch {
      if (!res.headersSent) send(res, 502, {detail: 'upstream_unavailable'});
      else res.destroy();
    }
  });

  server.on('upgrade', (req, socket, head) => {
    let rejected = false;
    socket.on('error', () => {});
    const reject = (code = 401) => {
      if (rejected || socket.destroyed) return;
      rejected = true;
      const deadline = setTimeout(() => socket.destroy(), 250);
      deadline.unref?.();
      socket.once('close', () => clearTimeout(deadline));
      socket.end(`HTTP/1.1 ${code} Rejected\r\nContent-Length: 0\r\nConnection: close\r\n\r\n`, () => socket.destroy());
    };
    if (!config || !allowed(req, port, config) || req.url !== '/speech') return reject(403);
    const key = req.headers['sec-websocket-key'];
    if (req.method !== 'GET' || req.headers.upgrade?.toLowerCase() !== 'websocket' ||
        !/^[+/0-9A-Za-z]{22}==$/.test(key || '') || req.headers['sec-websocket-version'] !== '13') {
      return reject(400);
    }
    const protocols = offeredProtocols(req.headers['sec-websocket-protocol']);
    if (!protocols) return reject(400);
    let upstream;
    try {
      const headers = req.headers.authorization === undefined ? {} : {Authorization: req.headers.authorization};
      upstream = webSocketFactory(config.speech.href, {headers, protocols,
        followRedirects: false, handshakeTimeout: 10000, maxPayload: MAX_QUEUED_BYTES, perMessageDeflate: false});
    } catch { return reject(502); }
    let accepted = false, downstream, closeDownstream;
    upstream.once('open', () => {
      try {
        // Both connections use the same upstream-selected subprotocol.
        protocolChoices.set(req, upstream.protocol);
        wss.handleUpgrade(req, socket, head, ws => {
          accepted = true;
          downstream = ws;
          let closing = false, toUpstream, toDownstream, termination;
          const dispose = () => { toUpstream?.dispose(); toDownstream?.dispose(); };
          const beginClose = () => {
            if (closing) return;
            closing = true;
            dispose();
            termination = setTimeout(() => { ws.terminate(); upstream.terminate(); }, 250);
            termination.unref?.();
          };
          const settled = () => {
            if (ws.readyState === WebSocket.CLOSED && upstream.readyState === WebSocket.CLOSED) clearTimeout(termination);
          };
          const relayClose = (target, code, reason) => {
            beginClose();
            if (target.readyState === WebSocket.OPEN) {
              try {
                // 1005 describes a frame with no status code and cannot itself be sent on the wire.
                if (code === 1005) target.close();
                else target.close(code === 1006 ? 1011 : code, reason);
              } catch { target.terminate(); }
            }
            settled();
          };
          closeDownstream = (code = 1011) => {
            if (closing) return;
            beginClose();
            upstream.terminate();
            try { ws.close(code); } catch { ws.terminate(); }
            settled();
          };
          toUpstream = createBoundedForwarder(upstream, closeDownstream, stallTimeoutMs);
          toDownstream = createBoundedForwarder(ws, closeDownstream, stallTimeoutMs);
          ws.on('message', (data, binary) => toUpstream.send(data, binary));
          upstream.on('message', (data, binary) => toDownstream.send(data, binary));
          ws.on('close', (code, reason) => relayClose(upstream, code, reason));
          ws.on('error', () => closeDownstream());
          upstream.on('close', (code, reason) => relayClose(ws, code, reason));
        });
      } catch { upstream.terminate(); reject(400); }
      finally { protocolChoices.delete(req); }
    });
    upstream.on('unexpected-response', (_request, response) => {
      response.resume();
      reject([401, 403, 429].includes(response.statusCode) ? response.statusCode : 502);
      upstream.terminate();
    });
    upstream.on('error', () => { if (!accepted) reject(502); else closeDownstream?.(); });
    // A closed client handshake cannot leave an upstream connection behind.
    socket.on('close', () => { if (!accepted) upstream.terminate(); });
  });
  server.requestTimeout = 125000;
  server.headersTimeout = 15000;
  return {server, wss, origin, configured: !!config};
}

if (process.argv[1] && fileURLToPath(import.meta.url) === resolve(process.argv[1])) {
  const envFile = process.env.PROXY_ENV_FILE || fileURLToPath(new URL('../../.env', import.meta.url));
  if (existsSync(envFile)) process.loadEnvFile(envFile);
  const proxy = createProxy(process.env);
  proxy.server.listen(Number(process.env.PROXY_PORT || 8787), '127.0.0.1', () =>
    console.log(`Local proxy listening at ${proxy.origin}; configured=${proxy.configured}`));
}
