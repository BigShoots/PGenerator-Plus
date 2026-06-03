#!/usr/bin/env node
'use strict';

/*
 * WebOS SSAP relay for calibration/debugging.
 *
 * Usage:
 *   node tools/webos-ssap-relay.js --listen-host 0.0.0.0 --listen-port 3000 --target ws://192.168.1.177:3000
 *   node tools/webos-ssap-relay.js --target-ip 192.168.1.177 --log tmp/webos-relay-test.jsonl
 *
 * Calman should connect to this process as though it were the LG webOS TV.
 * The relay opens a WebSocket connection to the real TV, forwards SSAP frames
 * bidirectionally, and writes JSONL logs for JSON/text frames.
 */

const crypto = require('crypto');
const fs = require('fs');
const http = require('http');
const https = require('https');
const net = require('net');
const path = require('path');
const tls = require('tls');

const WS_GUID = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';

function usage(exitCode = 0) {
  const out = exitCode ? process.stderr : process.stdout;
  out.write(`Usage: node tools/webos-ssap-relay.js [options]

Options:
  --listen-host <host>  Host/IP to bind for Calman clients (default 0.0.0.0)
  --listen-port <port>  Port to bind for Calman clients (default 3000)
  --listen-tls          Accept secure WebSocket clients (webOS port 3001)
  --listen-auto-tls     Accept either plain or secure WebSocket clients on one port
  --tls-cert <path>     Certificate for --listen-tls or --listen-auto-tls
  --tls-key <path>      Private key for --listen-tls or --listen-auto-tls
  --target <uri>        Target webOS WebSocket URI (default ws://192.168.1.177:3000)
  --target-ip <ip>      Shortcut for --target ws://<ip>:3000
  --log <path>          JSONL log path (default tmp/webos-relay-<timestamp>.jsonl)
  --help               Show this help

The relay logs JSON/text messages as c2t (Calman to TV) and t2c (TV to Calman).
Binary frames are forwarded and logged by length only.
`);
  process.exit(exitCode);
}

function parseArgs(argv) {
  const args = {
    listenHost: '0.0.0.0',
    listenPort: 3000,
    listenTls: false,
    listenAutoTls: false,
    tlsCert: null,
    tlsKey: null,
    target: 'ws://192.168.1.177:3000',
    logPath: defaultLogPath()
  };
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    const next = () => {
      if (i + 1 >= argv.length) usage(2);
      return argv[++i];
    };
    if (arg === '--help' || arg === '-h') usage(0);
    else if (arg === '--listen-host') args.listenHost = next();
    else if (arg === '--listen-port') args.listenPort = Number(next());
    else if (arg === '--listen-tls') args.listenTls = true;
    else if (arg === '--listen-auto-tls') args.listenAutoTls = true;
    else if (arg === '--tls-cert') args.tlsCert = next();
    else if (arg === '--tls-key') args.tlsKey = next();
    else if (arg === '--target') args.target = next();
    else if (arg === '--target-ip') args.target = `ws://${next()}:3000`;
    else if (arg === '--log') args.logPath = next();
    else {
      process.stderr.write(`Unknown argument: ${arg}\n`);
      usage(2);
    }
  }
  if (!Number.isInteger(args.listenPort) || args.listenPort < 1 || args.listenPort > 65535) {
    throw new Error(`Invalid --listen-port: ${args.listenPort}`);
  }
  if (args.listenTls && args.listenAutoTls) {
    throw new Error('--listen-tls and --listen-auto-tls are mutually exclusive');
  }
  if ((args.listenTls || args.listenAutoTls) && (!args.tlsCert || !args.tlsKey)) {
    throw new Error('--listen-tls/--listen-auto-tls require --tls-cert and --tls-key');
  }
  return args;
}

function defaultLogPath() {
  const stamp = new Date().toISOString().replace(/[:.]/g, '').replace(/-/g, '').replace('T', 'T').replace('Z', 'Z');
  return path.join('tmp', `webos-relay-${stamp}.jsonl`);
}

function wsAccept(key) {
  return crypto.createHash('sha1').update(key + WS_GUID).digest('base64');
}

function makeKey() {
  return crypto.randomBytes(16).toString('base64');
}

function writeFrame(socket, opcode, payload, options = {}) {
  if (!Buffer.isBuffer(payload)) payload = Buffer.from(payload || '');
  const mask = !!options.mask;
  const len = payload.length;
  let headerLen = 2;
  if (len >= 126 && len <= 0xffff) headerLen += 2;
  else if (len > 0xffff) headerLen += 8;
  if (mask) headerLen += 4;
  const frame = Buffer.alloc(headerLen + len);
  let offset = 0;
  frame[offset++] = 0x80 | (opcode & 0x0f);
  if (len < 126) {
    frame[offset++] = (mask ? 0x80 : 0) | len;
  } else if (len <= 0xffff) {
    frame[offset++] = (mask ? 0x80 : 0) | 126;
    frame.writeUInt16BE(len, offset);
    offset += 2;
  } else {
    frame[offset++] = (mask ? 0x80 : 0) | 127;
    frame.writeBigUInt64BE(BigInt(len), offset);
    offset += 8;
  }
  if (mask) {
    const key = crypto.randomBytes(4);
    key.copy(frame, offset);
    offset += 4;
    for (let i = 0; i < len; i++) frame[offset + i] = payload[i] ^ key[i % 4];
  } else {
    payload.copy(frame, offset);
  }
  socket.write(frame);
}

class WebSocketFrameReader {
  constructor(onFrame) {
    this.buffer = Buffer.alloc(0);
    this.onFrame = onFrame;
  }

  push(chunk) {
    this.buffer = Buffer.concat([this.buffer, chunk]);
    while (this.buffer.length >= 2) {
      const first = this.buffer[0];
      const second = this.buffer[1];
      const opcode = first & 0x0f;
      const masked = !!(second & 0x80);
      let len = second & 0x7f;
      let offset = 2;
      if (len === 126) {
        if (this.buffer.length < offset + 2) return;
        len = this.buffer.readUInt16BE(offset);
        offset += 2;
      } else if (len === 127) {
        if (this.buffer.length < offset + 8) return;
        const bigLen = this.buffer.readBigUInt64BE(offset);
        if (bigLen > BigInt(Number.MAX_SAFE_INTEGER)) throw new Error('WebSocket frame too large');
        len = Number(bigLen);
        offset += 8;
      }
      let maskKey = null;
      if (masked) {
        if (this.buffer.length < offset + 4) return;
        maskKey = this.buffer.subarray(offset, offset + 4);
        offset += 4;
      }
      if (this.buffer.length < offset + len) return;
      let payload = this.buffer.subarray(offset, offset + len);
      if (masked) {
        const unmasked = Buffer.alloc(payload.length);
        for (let i = 0; i < payload.length; i++) unmasked[i] = payload[i] ^ maskKey[i % 4];
        payload = unmasked;
      } else {
        payload = Buffer.from(payload);
      }
      this.buffer = this.buffer.subarray(offset + len);
      this.onFrame({ opcode, payload, fin: !!(first & 0x80) });
    }
  }
}

class JsonlLogger {
  constructor(logPath) {
    this.logPath = logPath;
    fs.mkdirSync(path.dirname(logPath), { recursive: true });
    this.stream = fs.createWriteStream(logPath, { flags: 'a' });
  }

  log(entry) {
    this.stream.write(JSON.stringify({ ts: new Date().toISOString(), ...entry }) + '\n');
  }

  close() {
    return new Promise(resolve => this.stream.end(resolve));
  }
}

function logPayload(logger, direction, payload, opcode) {
  if (opcode === 1) {
    const text = payload.toString('utf8');
    try {
      logger.log({ direction, type: 'json', json: JSON.parse(text) });
    } catch (err) {
      logger.log({ direction, type: 'text', text });
    }
  } else if (opcode === 2) {
    logger.log({ direction, type: 'binary', bytes: payload.length });
  }
}

function connectTarget(targetUri) {
  return new Promise((resolve, reject) => {
    const url = new URL(targetUri);
    if (url.protocol !== 'ws:' && url.protocol !== 'wss:') {
      reject(new Error(`Target must be ws:// or wss://, got ${targetUri}`));
      return;
    }
    const secure = url.protocol === 'wss:';
    const port = Number(url.port || (secure ? 443 : 80));
    const host = url.hostname;
    const socket = secure
      ? tls.connect({ host, port, servername: host, rejectUnauthorized: false })
      : net.connect({ host, port });
    const key = makeKey();
    const pathAndQuery = `${url.pathname || '/'}${url.search || ''}`;
    let handshake = Buffer.alloc(0);
    let settled = false;

    function fail(err) {
      if (settled) return;
      settled = true;
      socket.destroy();
      reject(err);
    }

    socket.once('error', fail);
    socket.once(secure ? 'secureConnect' : 'connect', () => {
      socket.write([
        `GET ${pathAndQuery} HTTP/1.1`,
        `Host: ${url.host}`,
        'Upgrade: websocket',
        'Connection: Upgrade',
        'Sec-WebSocket-Version: 13',
        `Sec-WebSocket-Key: ${key}`,
        '\r\n'
      ].join('\r\n'));
    });
    socket.on('data', function onData(chunk) {
      if (settled) return;
      handshake = Buffer.concat([handshake, chunk]);
      const end = handshake.indexOf('\r\n\r\n');
      if (end < 0) return;
      const head = handshake.subarray(0, end).toString('utf8');
      if (!/^HTTP\/1\.[01] 101\b/i.test(head)) {
        fail(new Error(`Target WebSocket upgrade failed: ${head.split('\r\n')[0] || 'no status'}`));
        return;
      }
      const leftover = handshake.subarray(end + 4);
      settled = true;
      socket.removeListener('data', onData);
      socket.removeListener('error', fail);
      resolve({ socket, leftover });
    });
  });
}

function closeSocket(socket, options = {}) {
  if (!socket || socket.destroyed) return;
  try {
    writeFrame(socket, 0x8, Buffer.alloc(0), { mask: !!options.mask });
  } catch (err) {
    // The socket may already be half-closed.
  }
  socket.end();
  setTimeout(() => socket.destroy(), 500).unref();
}

async function bridgeClient(clientSocket, req, upgradeHead, targetUri, logger) {
  const clientAddress = `${req.socket.remoteAddress || 'unknown'}:${req.socket.remotePort || ''}`;
  logger.log({ event: 'client_connected', client: clientAddress, target: targetUri });
  let targetSocket = null;
  let targetReady = false;
  const pending = [];

  const sendToTarget = frame => {
    if (!targetReady) {
      pending.push(frame);
      return;
    }
    writeFrame(targetSocket, frame.opcode, frame.payload, { mask: true });
  };
  const clientReader = new WebSocketFrameReader(frame => {
    if (frame.opcode === 0x8) {
      closeSocket(targetSocket, { mask: true });
      closeSocket(clientSocket);
      return;
    }
    if (frame.opcode === 0x9) {
      writeFrame(clientSocket, 0xA, frame.payload, { mask: false });
      return;
    }
    logPayload(logger, 'c2t', frame.payload, frame.opcode);
    sendToTarget(frame);
  });

  clientSocket.on('data', chunk => {
    try {
      clientReader.push(chunk);
    } catch (err) {
      logger.log({ event: 'client_frame_error', error: err.message });
      closeSocket(clientSocket);
      closeSocket(targetSocket, { mask: true });
    }
  });
  clientSocket.once('close', () => {
    logger.log({ event: 'client_closed', client: clientAddress });
    closeSocket(targetSocket, { mask: true });
  });
  clientSocket.once('error', err => {
    logger.log({ event: 'client_error', client: clientAddress, error: err.message });
    closeSocket(targetSocket, { mask: true });
  });

  try {
    const target = await connectTarget(targetUri);
    targetSocket = target.socket;
    targetReady = true;
    logger.log({ event: 'target_connected', target: targetUri });
    const targetReader = new WebSocketFrameReader(frame => {
      if (frame.opcode === 0x8) {
        closeSocket(clientSocket);
        closeSocket(targetSocket, { mask: true });
        return;
      }
      if (frame.opcode === 0x9) {
        writeFrame(targetSocket, 0xA, frame.payload, { mask: true });
        return;
      }
      logPayload(logger, 't2c', frame.payload, frame.opcode);
      writeFrame(clientSocket, frame.opcode, frame.payload, { mask: false });
    });
    targetSocket.on('data', chunk => {
      try {
        targetReader.push(chunk);
      } catch (err) {
        logger.log({ event: 'target_frame_error', error: err.message });
        closeSocket(clientSocket);
        closeSocket(targetSocket, { mask: true });
      }
    });
    targetSocket.once('close', () => {
      logger.log({ event: 'target_closed', target: targetUri });
      closeSocket(clientSocket);
    });
    targetSocket.once('error', err => {
      logger.log({ event: 'target_error', target: targetUri, error: err.message });
      closeSocket(clientSocket);
    });
    if (target.leftover && target.leftover.length) targetReader.push(target.leftover);
    if (upgradeHead && upgradeHead.length) clientReader.push(upgradeHead);
    while (pending.length) {
      const frame = pending.shift();
      writeFrame(targetSocket, frame.opcode, frame.payload, { mask: true });
    }
  } catch (err) {
    logger.log({ event: 'target_connect_failed', target: targetUri, error: err.message });
    closeSocket(clientSocket);
  }
}

function looksLikeTlsClientHello(chunk) {
  return chunk && chunk.length >= 3 && chunk[0] === 0x16 && chunk[1] === 0x03;
}

function attachClientServerHandlers(server, args, logger, protocol) {
  server.on('clientError', (err, socket) => {
    logger.log({
      event: 'client_http_error',
      protocol,
      error: err.message,
      code: err.code || null,
      bytes: err.rawPacket ? err.rawPacket.subarray(0, 16).toString('hex') : null
    });
    if (socket && !socket.destroyed) socket.destroy();
  });
  server.on('upgrade', (req, socket, head) => {
    logger.log({
      event: 'client_upgrade',
      protocol,
      remote: req.socket.remoteAddress,
      url: req.url,
      headers: req.headers
    });
    const key = req.headers['sec-websocket-key'];
    if (!key) {
      socket.end('HTTP/1.1 400 Bad Request\r\n\r\nMissing Sec-WebSocket-Key');
      return;
    }
    socket.write([
      'HTTP/1.1 101 Switching Protocols',
      'Upgrade: websocket',
      'Connection: Upgrade',
      `Sec-WebSocket-Accept: ${wsAccept(key)}`,
      '\r\n'
    ].join('\r\n'));
    bridgeClient(socket, req, head, args.target, logger).catch(err => {
      logger.log({ event: 'bridge_failed', protocol, error: err.message });
      closeSocket(socket);
    });
  });
}

function createAutoTlsServer(httpServer, tlsHttpServer, secureContext, logger, sockets) {
  return net.createServer(socket => {
    sockets.add(socket);
    socket.once('close', () => sockets.delete(socket));

    const remote = `${socket.remoteAddress || 'unknown'}:${socket.remotePort || ''}`;
    const onError = err => {
      logger.log({ event: 'client_protocol_detect_error', remote, error: err.message });
    };
    socket.once('error', onError);
    socket.once('data', chunk => {
      socket.removeListener('error', onError);
      socket.pause();
      socket.unshift(chunk);

      const protocol = looksLikeTlsClientHello(chunk) ? 'tls' : 'plain';
      logger.log({
        event: 'client_protocol_detected',
        remote,
        protocol,
        bytes: chunk.subarray(0, 16).toString('hex')
      });
      if (protocol === 'tls') {
        const tlsSocket = new tls.TLSSocket(socket, { isServer: true, secureContext });
        tlsSocket.once('error', err => {
          logger.log({ event: 'client_tls_error', remote, error: err.message, code: err.code || null });
        });
        tlsHttpServer.emit('connection', tlsSocket);
        tlsSocket.resume();
      } else {
        httpServer.emit('connection', socket);
        socket.resume();
      }
    });
  });
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const logger = new JsonlLogger(args.logPath);
  const requestHandler = (req, res) => {
    logger.log({ event: 'http_request', method: req.method, url: req.url, remote: req.socket.remoteAddress });
    res.writeHead(426, { 'Content-Type': 'text/plain' });
    res.end('WebSocket upgrade required\n');
  };
  const sockets = new Set();
  const tlsOptions = (args.listenTls || args.listenAutoTls)
    ? {
        cert: fs.readFileSync(args.tlsCert),
        key: fs.readFileSync(args.tlsKey)
      }
    : null;
  const server = (() => {
    if (args.listenAutoTls) {
      const plainServer = http.createServer(requestHandler);
      const tlsHttpServer = http.createServer(requestHandler);
      const secureContext = tls.createSecureContext(tlsOptions);
      attachClientServerHandlers(plainServer, args, logger, 'plain');
      attachClientServerHandlers(tlsHttpServer, args, logger, 'tls');
      return createAutoTlsServer(plainServer, tlsHttpServer, secureContext, logger, sockets);
    }
    const clientServer = args.listenTls
      ? https.createServer(tlsOptions, requestHandler)
      : http.createServer(requestHandler);
    clientServer.on('connection', socket => {
      sockets.add(socket);
      socket.once('close', () => sockets.delete(socket));
    });
    attachClientServerHandlers(clientServer, args, logger, args.listenTls ? 'tls' : 'plain');
    return clientServer;
  })();

  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(args.listenPort, args.listenHost, resolve);
  });
  const listenMode = args.listenAutoTls ? 'auto-tls' : (args.listenTls ? 'tls' : 'plain');
  logger.log({ event: 'relay_started', listen_host: args.listenHost, listen_port: args.listenPort, listen_mode: listenMode, target: args.target, log_path: args.logPath });
  process.stdout.write(`WebOS SSAP relay listening on ${args.listenHost}:${args.listenPort}\n`);
  process.stdout.write(`Client listen mode: ${listenMode}\n`);
  process.stdout.write(`Forwarding to ${args.target}\n`);
  process.stdout.write(`Logging JSONL to ${args.logPath}\n`);

  async function shutdown(signal) {
    logger.log({ event: 'relay_stopping', signal });
    for (const socket of sockets) closeSocket(socket);
    await new Promise(resolve => server.close(resolve));
    await logger.close();
    process.exit(0);
  }

  process.on('SIGINT', () => shutdown('SIGINT'));
  process.on('SIGTERM', () => shutdown('SIGTERM'));
}

main().catch(err => {
  process.stderr.write(`${err.stack || err.message}\n`);
  process.exit(1);
});
