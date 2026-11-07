#!/usr/bin/env node
// Frozen Pkg server. Serves the Pkg-server protocol on 127.0.0.1
// so that native Pkg and the Wasm module see identical, immutable inputs:
//   GET /registries                     -> the frozen registry line(s) from fixtures/frozen.toml
//   GET /registry/<uuid>/<hash>         -> content-addressed tarball (cached)
//   GET /package/<uuid>/<hash>          -> content-addressed tarball (cached)
//   GET /artifact/<hash>                -> content-addressed tarball (cached)
// Anything else is a 404. Content comes from fixtures/cache, filled from the upstream
// server on first use unless --offline. Encoding variant (zst/gz) follows the request's
// Accept-Encoding the way the real server does (zstd if offered, else gzip).
//
// usage: node pkgserver.mjs [--port N] [--offline] [--log FILE] [--frozen FILE] [--cache DIR]
// Prints "LISTENING http://127.0.0.1:<port>" on stdout once ready.
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, '..');
const opts = { port: 0, offline: false, log: null,
  frozen: path.join(root, 'fixtures/frozen.toml'), cache: path.join(root, 'fixtures/cache') };
for (let i = 2; i < process.argv.length; i++) {
  const a = process.argv[i];
  if (a === '--port') opts.port = Number(process.argv[++i]);
  else if (a === '--offline') opts.offline = true;
  else if (a === '--log') opts.log = process.argv[++i];
  else if (a === '--frozen') opts.frozen = process.argv[++i];
  else if (a === '--cache') opts.cache = process.argv[++i];
  else { console.error(`pkgserver: unknown argument ${a}`); process.exit(2); }
}

// Minimal reader for the keys we need from frozen.toml (flat `key = "value"` lines).
function readFrozen(file) {
  const txt = fs.readFileSync(file, 'utf8');
  const get = (k) => {
    const m = txt.match(new RegExp(`^${k}\\s*=\\s*"([^"]*)"`, 'm'));
    if (!m) throw new Error(`pkgserver: ${file} lacks ${k}`);
    return m[1];
  };
  return { upstream: get('server'), uuid: get('registry_uuid'), hash: get('registry_tree_hash') };
}
const frozen = readFrozen(opts.frozen);
const registriesBody = `/registry/${frozen.uuid}/${frozen.hash}\n`;

// Synchronous append: the log is complete the moment a response starts, so the
// orchestrator can split it at command boundaries.
const logLine = (line) => { if (opts.log) fs.appendFileSync(opts.log, `${new Date().toISOString()} ${line}\n`); };
const log = logLine;
if (opts.log) fs.appendFileSync(opts.log, '');   // exists even if no request arrives

const IMMUTABLE = /^\/(registry\/[0-9a-f-]{36}\/[0-9a-f]{40}|package\/[0-9a-f-]{36}\/[0-9a-f]{40}|artifact\/[0-9a-f]{40})$/;

// Upstream fills are bounded (FETCH_TIMEOUT_MS for the whole transfer) and aborted on shutdown.
const FETCH_TIMEOUT_MS = 300_000;
const shutdownCtl = new AbortController();
const inflight = new Map();
async function fetchToCache(urlPath, variant, file) {
  const key = file;
  if (inflight.has(key)) return inflight.get(key);
  const p = (async () => {
    const signal = AbortSignal.any([shutdownCtl.signal, AbortSignal.timeout(FETCH_TIMEOUT_MS)]);
    const res = await fetch(frozen.upstream + urlPath, {
      headers: { 'Accept-Encoding': variant === 'zst' ? 'zstd, gzip' : 'gzip' }, redirect: 'follow', signal });
    if (res.status !== 200) { await res.arrayBuffer().catch(() => {}); return res.status; }
    const buf = Buffer.from(await res.arrayBuffer());
    const magicZst = buf.length >= 4 && buf.readUInt32BE(0) === 0x28b52ffd;
    const magicGz = buf.length >= 2 && buf[0] === 0x1f && buf[1] === 0x8b;
    // The upstream may legitimately answer a zstd request with gzip; store under the true variant.
    const real = magicZst ? 'zst' : magicGz ? 'gz' : null;
    if (!real) throw new Error(`upstream ${urlPath}: unrecognised archive magic`);
    const realFile = file.replace(/\.(zst|gz)$/, '.' + real);
    fs.mkdirSync(path.dirname(realFile), { recursive: true });
    fs.writeFileSync(realFile + '.partial', buf);
    fs.renameSync(realFile + '.partial', realFile);
    return 200;
  })().finally(() => inflight.delete(key));
  inflight.set(key, p);
  return p;
}

function cachedFile(urlPath, wantZst) {
  const base = path.join(opts.cache, urlPath);
  const order = wantZst ? ['zst', 'gz'] : ['gz'];
  for (const v of order) if (fs.existsSync(`${base}.${v}`)) return `${base}.${v}`;
  return null;
}

// Every request line ends with sys=<Julia-System header> (or sys=- when absent): the
// client's platform as the server sees it.
const server = http.createServer(async (req, res) => {
  let urlPath = String(req.url);
  const sysHdr = req.headers['julia-system'];
  const sys = `sys=${sysHdr === undefined ? '-' : encodeURIComponent(String(sysHdr))}`;
  const log = (line) => logLine(`${line} ${sys}`);
  try {
    try {
      urlPath = new URL(req.url, 'http://x').pathname;
    } catch {
      log(`${req.method} ${JSON.stringify(urlPath)} 400`); res.writeHead(400).end(); return;
    }
    const ae = String(req.headers['accept-encoding'] || '');
    const wantZst = /\bzstd\b/.test(ae);
    if (req.method !== 'GET' && req.method !== 'HEAD') {
      log(`${req.method} ${urlPath} 405`); res.writeHead(405).end(); return;
    }
    if (urlPath === '/registries') {
      log(`${req.method} ${urlPath} 200`);
      res.writeHead(200, { 'Content-Type': 'text/plain', 'Content-Length': Buffer.byteLength(registriesBody) });
      res.end(req.method === 'HEAD' ? undefined : registriesBody);
      return;
    }
    if (!IMMUTABLE.test(urlPath)) { log(`${req.method} ${urlPath} 404`); res.writeHead(404).end(); return; }
    let file = cachedFile(urlPath, wantZst);
    if (!file && !opts.offline) {
      const st = await fetchToCache(urlPath, wantZst ? 'zst' : 'gz', path.join(opts.cache, urlPath) + (wantZst ? '.zst' : '.gz'));
      if (st !== 200) { log(`${req.method} ${urlPath} upstream-${st}`); res.writeHead(st === 404 ? 404 : 502).end(); return; }
      file = cachedFile(urlPath, wantZst);
    }
    if (!file) { log(`${req.method} ${urlPath} 404-offline`); res.writeHead(404).end(); return; }
    const size = fs.statSync(file).size;
    log(`${req.method} ${urlPath} 200 ${path.basename(file)} ${size}`);
    res.writeHead(200, { 'Content-Type': 'application/octet-stream', 'Content-Length': size });
    if (req.method === 'HEAD') { res.end(); return; }
    const rs = fs.createReadStream(file);
    rs.on('error', (e) => { log(`${req.method} ${urlPath} read-error ${e.message}`); res.destroy(e); });
    res.on('error', () => rs.destroy());
    rs.pipe(res);
  } catch (e) {
    log(`${req.method} ${urlPath} 500 ${e && e.message}`);
    if (!res.headersSent) res.writeHead(500);
    res.end();
  }
});
server.listen(opts.port, '127.0.0.1', () => {
  console.log(`LISTENING http://127.0.0.1:${server.address().port}`);
});
server.on('clientError', (err, sock) => { log(`clientError ${err.code || err.message}`); sock.destroy(); });
// Bounded shutdown: abort upstream fills, drop client connections, exit within 2 s.
function shutdown() {
  shutdownCtl.abort();
  server.close(() => process.exit(0));
  server.closeAllConnections();
  setTimeout(() => process.exit(0), 2000).unref();
}
for (const sig of ['SIGINT', 'SIGTERM']) process.on(sig, shutdown);
process.on('unhandledRejection', (e) => { log(`unhandledRejection ${e && e.message}`); });
