#!/usr/bin/env node
// The Node runner of the package manager compiled to Wasm (test/pkg/build.jl's module): one
// command per instance.
//
//   node run.mjs --wasm FILE --dir ABS [--dir ABS ...] [--env K=V ...] [--no-network]
//                [--platform-tag k=v ...] [--timing FILE] [--trace-fs FILE] -- <cmd> [words...]
//
// - Preopens: exactly the --dir list, identity-mapped (guest path == host path), absolute.
// - Env: the --env list (only JULIA_DEPOT_PATH, JULIA_PROJECT, JULIA_PKG_SERVER, HOME, PWD,
//   TMPDIR, JULIA_PKG_* and PKGENTRY_TRACE), plus, set by the runner, WASMHOST_PLATFORM (the
//   detected platform tags with the --platform-tag overrides, for WasmHost.Platform) and
//   WASMHOST_SPOOL (downloads and decompression, `$TMPDIR/.wasmhost`, when TMPDIR is in a
//   preopen). Nothing is inherited from process.env.
// - WASI args: ["pkgentry", <cmd>, words...].
// - --no-network: every HTTP request of the module (and of libgit2) fails as a refused
//   connection.
// - Adapters: WasmCodegen's js/julia_io.mjs (paths and events) and js/julia_task.mjs ($WCG_JS),
//   WasmHost's js/node ($WASMHOST_JS), WasmCompat's js/pcre2.mjs and js/libgit2.mjs, with the
//   PCRE2 and libgit2 modules beside the program (libpcre2-8.wasm, libgit2.wasm), each only if
//   the module imports it.
//
// Lifecycle: instantiate → bindMemory → wasi.initialize → ABI version check
// (`pkgentry_abi_version()` = ABI_VERSION) → root call `pkgentry_init()` → (only if it returned
// 0) root call `pkgentry_main()` → exit code = main's return. Traps, foreign exceptions, and
// any runner failure print a diagnostic and exit 70. Usage errors exit 2.

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

export const EXIT_INTERNAL = 70;
export const EXIT_USAGE = 2;
const ABI_VERSION = 1;
const ENV_ALLOWED = new Set(['JULIA_DEPOT_PATH', 'JULIA_PROJECT', 'JULIA_PKG_SERVER', 'HOME', 'PWD', 'TMPDIR', 'PKGENTRY_TRACE']);
const envAllowed = (k) => ENV_ALLOWED.has(k) || k.startsWith('JULIA_PKG_');
const NAMESPACES = new Set(['wasi_snapshot_preview1', 'julia_io', 'julia_task', 'pcre2', 'libgit2']);
const HERE = path.dirname(fileURLToPath(import.meta.url));
const COMPAT_JS = path.resolve(HERE, '..', '..', '..', 'js');   // WasmCompat.jl/js

class UsageError extends Error {}

export function parseArgs(argv) {
  const o = { wasm: null, dirs: [], env: {}, network: true, timing: null, traceFs: null, platformTags: {}, args: [] };
  let i = 0;
  const need = (flag) => {
    if (i + 1 >= argv.length) throw new UsageError(`${flag} needs a value`);
    return argv[++i];
  };
  for (; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--') { o.args = argv.slice(i + 1); break; }
    else if (a === '--wasm') o.wasm = need(a);
    else if (a === '--dir') o.dirs.push(need(a));
    else if (a === '--env') {
      const kv = need(a);
      const eq = kv.indexOf('=');
      if (eq <= 0) throw new UsageError(`--env expects K=V, got ${JSON.stringify(kv)}`);
      const k = kv.slice(0, eq);
      if (!envAllowed(k)) throw new UsageError(`--env ${k} is not in the env policy`);
      if (k in o.env) throw new UsageError(`--env ${k} given twice`);
      o.env[k] = kv.slice(eq + 1);
    }
    else if (a === '--no-network') o.network = false;
    else if (a === '--platform-tag') {
      const kv = need(a);
      const eq = kv.indexOf('=');
      if (eq <= 0 || eq === kv.length - 1) throw new UsageError(`--platform-tag expects k=v, got ${JSON.stringify(kv)}`);
      const k = kv.slice(0, eq), v = kv.slice(eq + 1);
      if (k in o.platformTags) throw new UsageError(`--platform-tag ${k} given twice`);
      if (k.includes(';') || k.includes('=') || v.includes(';')) throw new UsageError(`--platform-tag ${kv}: ';' (or '=' in a name) is not allowed`);
      o.platformTags[k] = v;
    }
    else if (a === '--timing') o.timing = need(a);
    else if (a === '--trace-fs') o.traceFs = need(a);
    else throw new UsageError(`unknown argument ${JSON.stringify(a)}`);
  }
  if (!o.wasm) throw new UsageError('--wasm FILE is required');
  if (o.dirs.length === 0) throw new UsageError('at least one --dir is required');
  if (o.args.length === 0) throw new UsageError('missing command after --');
  for (const d of o.dirs) {
    if (!path.isAbsolute(d)) throw new UsageError(`--dir ${d} is not absolute`);
    const bare = d.length > 1 ? d.replace(/\/+$/, '') : d;
    if (path.normalize(bare) !== bare) throw new UsageError(`--dir ${d} is not normalised`);
    let st;
    try { st = fs.statSync(d); } catch { throw new UsageError(`--dir ${d} does not exist`); }
    if (!st.isDirectory()) throw new UsageError(`--dir ${d} is not a directory`);
  }
  o.dirs = o.dirs.map((d) => (d.length > 1 ? d.replace(/\/+$/, '') : d));
  return o;
}

function adapterDir(envName) {
  const d = process.env[envName];
  if (!d) throw new Error(`$${envName} is not set (the directory of the adapter modules)`);
  return d;
}
const importFrom = (dir, file) => import(pathToFileURL(path.join(dir, file)).href);

// --trace-fs: every path-taking host call, one tab-separated line each:
//   <ns>.<import> \t <dirfd or -> \t <raw path argument> \t <resolved absolute guest path>
// for the "only the scenario dir" check and the relocation test. WASI p1 path calls carry
// (dirfd, path_ptr, path_len). Preopen fds are 3.. in --dir order (node:wasi); directory fds
// opened later by path_open are tracked from its fd out-param and dropped on fd_close. An
// absolute raw WASI path resolves to "!absolute:<raw>", an unknown dirfd to "!fd<N>:<raw>";
// neither can pass as in-scope. julia_io's path imports take absolute paths.
const WASI_PATH_ARGS = {
  path_open: [[0, 2, 3]], path_filestat_get: [[0, 2, 3]], path_filestat_set_times: [[0, 2, 3]],
  path_create_directory: [[0, 1, 2]], path_remove_directory: [[0, 1, 2]], path_unlink_file: [[0, 1, 2]],
  path_readlink: [[0, 1, 2]], path_rename: [[0, 1, 2], [3, 4, 5]], path_symlink: [[2, 3, 4]],
  path_link: [[0, 2, 3], [4, 5, 6]],
};
// path_symlink: only `link` is accessed; `target` is data
const JULIA_IO_PATH_ARGS = { path_mode: [[0, 1]], path_chmod: [[0, 1]], path_symlink: [[2, 3]] };
// Fields are escaped (\\, \t, \n, \r) so that a path cannot forge a field; readers require
// exactly 4 fields.
const escField = (x) => String(x).replace(/[\\\t\n\r]/g, (c) => ({ '\\': '\\\\', '\t': '\\t', '\n': '\\n', '\r': '\\r' })[c]);
const traceLine = (...fields) => fields.map(escField).join('\t');
function makeFsTracer(dirs, memRef) {
  const lines = [];
  const fds = new Map(dirs.map((d, i) => [i + 3, d]));
  const str = (off, len) => Buffer.from(new Uint8Array(memRef.memory.buffer, off >>> 0, len >>> 0)).toString('utf8');
  function resolve(fd, raw) {
    if (raw.startsWith('/')) return `!absolute:${raw}`;
    const base = fds.get(fd);
    return base === undefined ? `!fd${fd}:${raw}` : path.posix.normalize(path.posix.join(base, raw));
  }
  function wrap(ns, imports, table, absolute) {
    const out = { ...imports };
    for (const [name, specs] of Object.entries(table)) {
      const f = imports[name];
      if (typeof f !== 'function') continue;
      out[name] = function (...a) {
        let opened = null;
        try {
          for (const sp of specs) {
            if (absolute) {
              const raw = str(a[sp[0]], a[sp[1]]);
              lines.push(traceLine(`${ns}.${name}`, '-', raw, raw.startsWith('/') ? path.posix.normalize(raw) : `!relative:${raw}`));
            } else {
              const fd = a[sp[0]], raw = str(a[sp[1]], a[sp[2]]);
              const res = resolve(fd, raw);
              lines.push(traceLine(`${ns}.${name}`, String(fd), raw, res));
              if (name === 'path_open') opened = res;
            }
          }
        } catch (e) { lines.push(traceLine(`${ns}.${name}`, '-', '', `!unreadable:${e.message}`)); }
        const r = f.apply(this, a);
        if (opened !== null && r === 0 && !opened.startsWith('!')) {
          // path_open(fd, dirflags, path, len, oflags, rights_base, rights_inh, fdflags, fd_out)
          try { fds.set(new DataView(memRef.memory.buffer).getUint32(a[8] >>> 0, true), opened); } catch {}
        }
        return r;
      };
    }
    if (ns === 'wasi') {
      // directory-fd provenance: a successful close forgets the fd; fd_renumber moves it
      if (typeof imports.fd_close === 'function') {
        out.fd_close = function (fd, ...rest) {
          const r = imports.fd_close.call(this, fd, ...rest);
          if (r === 0) fds.delete(fd);
          return r;
        };
      }
      if (typeof imports.fd_renumber === 'function') {
        out.fd_renumber = function (from, to, ...rest) {
          const r = imports.fd_renumber.call(this, from, to, ...rest);
          if (r === 0) {
            const base = fds.get(from);
            fds.delete(from);
            if (base === undefined) fds.delete(to); else fds.set(to, base);
            lines.push(traceLine('wasi.fd_renumber', `${from}->${to}`, '', base ?? `!fd${from}:`));
          }
          return r;
        };
      }
    }
    return out;
  }
  return {
    wrapWasi: (imp) => wrap('wasi', imp, WASI_PATH_ARGS, false),
    wrapJuliaIO: (imp) => wrap('julia_io', imp, JULIA_IO_PATH_ARGS, true),
    lines,
  };
}

function checkModuleImports(mod) {
  for (const imp of WebAssembly.Module.imports(mod)) {
    if (!NAMESPACES.has(imp.module)) throw new Error(`module imports ${imp.module}.${imp.name}, which this runner doesn't provide`);
  }
}

export async function run(o, { log = (s) => process.stderr.write(s) } = {}) {
  const t = { start: performance.now() };
  const mark = (k) => { t[k] = Math.round(performance.now() - t.start); };
  const { WASI } = await import('node:wasi');   // (dynamic: after the warning filter is installed)
  let tracer = null;
  let events = null;
  let jt = null;
  const flushTrace = () => { if (tracer) fs.writeFileSync(o.traceFs, tracer.lines.map((l) => l + '\n').join('')); };
  try {
    const bytes = fs.readFileSync(o.wasm);
    const mod = await WebAssembly.compile(bytes);
    mark('compile');
    checkModuleImports(mod);
    const libs = new Set(WebAssembly.Module.imports(mod).map((i) => i.module));

    const wasmhostJs = adapterDir('WASMHOST_JS');
    const wcgJs = adapterDir('WCG_JS');
    const { wrapWasi, platformEnv, makeImports } = await importFrom(wasmhostJs, 'index.mjs');
    const preopens = Object.fromEntries(o.dirs.map((d) => [d, d]));
    const env = { ...o.env, ...platformEnv(o.platformTags) };
    const inPreopen = (p) => o.dirs.some((d) => p === d || p.startsWith(d.endsWith('/') ? d : d + '/'));
    const spool = o.env.TMPDIR && inPreopen(o.env.TMPDIR) ? path.posix.join(o.env.TMPDIR, '.wasmhost') : null;
    if (spool) env.WASMHOST_SPOOL = spool;
    const refuse = async () => { throw Object.assign(new Error('network disabled by the runner (--no-network)'), { cause: { code: 'ECONNREFUSED' } }); };
    const fetchOpts = o.network ? {} : { fetchImpl: refuse };

    const wasi = new WASI({ version: 'preview1', args: ['pkgentry', ...o.args], env, preopens, returnOnExit: true });
    const memRef = { memory: null };
    tracer = o.traceFs ? makeFsTracer(o.dirs, memRef) : null;
    let wasiImp = tracer ? tracer.wrapWasi(wasi.wasiImport) : wasi.wasiImport;
    let host = null;
    if (spool) {
      host = wrapWasi(wasiImp, { preopens, spool, mode: 'jspi', ...fetchOpts });
      wasiImp = host.wasiImport;
    }
    const imports = { wasi_snapshot_preview1: wasiImp };
    const bind = [];
    if (libs.has('julia_io')) {
      const { makeJuliaIOPaths, makeJuliaIOEvents } = await importFrom(wcgJs, 'julia_io.mjs');
      const paths = makeJuliaIOPaths({ preopens: o.dirs });
      events = makeJuliaIOEvents();
      const jio = { ...paths.imports, ...events.imports };
      imports.julia_io = tracer ? tracer.wrapJuliaIO(jio) : jio;
      bind.push(paths, events);
    }
    if (libs.has('julia_task')) {
      const { makeJuliaTask } = await importFrom(wcgJs, 'julia_task.mjs');
      jt = makeJuliaTask({ events, keepAlive: false });
      Object.assign(imports, jt.imports);
    }
    if (libs.has('pcre2')) {
      const { pcre2Imports } = await importFrom(COMPAT_JS, 'pcre2.mjs');
      Object.assign(imports, await pcre2Imports(fs.readFileSync(path.join(path.dirname(o.wasm), 'libpcre2-8.wasm'))));
    }
    if (libs.has('libgit2')) {
      // libgit2 with a WASI of its own over the same preopens and environment, and WasmHost's
      // fetch import for https (response bodies in $WASMHOST_SPOOL)
      const { libgit2Imports } = await importFrom(COMPAT_JS, 'libgit2.mjs');
      const genv = { ...env };
      if (o.env.TMPDIR) { genv.WASMHOST_SPOOL = path.posix.join(o.env.TMPDIR, '.wasmhost-libgit2'); fs.mkdirSync(genv.WASMHOST_SPOOL, { recursive: true }); }
      const gwasi = new WASI({ version: 'preview1', args: ['libgit2'], env: genv, preopens, returnOnExit: true });
      const wasmHost = makeImports({ preopens, ...fetchOpts });
      Object.assign(imports, await libgit2Imports(fs.readFileSync(path.join(path.dirname(o.wasm), 'libgit2.wasm')), { wasi: gwasi, wasmHost }));
    }
    const instance = await WebAssembly.instantiate(mod, imports);
    mark('instantiate');

    const ex = instance.exports;
    if (!(ex.memory instanceof WebAssembly.Memory)) throw new Error('module does not export "memory"');
    for (const b of bind) b.bindMemory(ex.memory);
    host?.bindMemory(ex.memory);
    memRef.memory = ex.memory;
    wasi.initialize(instance);
    jt?.bind(instance);
    const root = (f) => (jt ? jt.call(f) : WebAssembly.promising(f)());

    if (typeof ex.pkgentry_abi_version !== 'function') throw new Error('module exports no pkgentry_abi_version');
    const v = ex.pkgentry_abi_version();
    if (v !== ABI_VERSION) throw new Error(`module ABI version ${v} != runner ABI version ${ABI_VERSION}`);
    for (const f of ['pkgentry_init', 'pkgentry_main']) {
      if (typeof ex[f] !== 'function') throw new Error(`module exports no ${f}`);
    }
    // one root call at a time
    const st = await root(ex.pkgentry_init);
    mark('init');
    if (st !== 0) {
      flushTrace();
      return { code: st, timing: t, phase: 'init' };
    }
    const rc = await root(ex.pkgentry_main);
    mark('main');
    flushTrace();
    return { code: rc, timing: t, phase: 'main' };
  } catch (e) {
    try { flushTrace(); } catch {}
    log(`pkgentry runner: ${describe(e)}\n`);
    return { code: EXIT_INTERNAL, timing: t, phase: 'internal', error: e };
  } finally {
    jt?.shutdown();
    events?.stop?.();
  }
}

function describe(e) {
  if (e instanceof WebAssembly.RuntimeError) return `wasm trap: ${e.message}\n${e.stack ?? ''}`;
  if (typeof WebAssembly.Exception === 'function' && e instanceof WebAssembly.Exception) return 'uncaught WebAssembly.Exception escaped the module (no Julia catch)';
  if (e instanceof Error) return `${e.name}: ${e.message}\n${e.stack ?? ''}`;
  return `non-Error thrown: ${String(e)}`;
}

async function main() {
  let o;
  try {
    o = parseArgs(process.argv.slice(2));
  } catch (e) {
    if (e instanceof UsageError) {
      process.stderr.write(`pkgentry runner: ${e.message}\nusage: node run.mjs --wasm FILE --dir ABS... [--env K=V...] [--no-network] [--platform-tag k=v...] [--timing FILE] [--trace-fs FILE] -- <cmd> [words...]\n`);
      process.exitCode = EXIT_USAGE;
      return;
    }
    throw e;
  }
  const r = await run(o);
  if (o.timing) {
    try { fs.writeFileSync(o.timing, JSON.stringify({ code: r.code, phase: r.phase, ms: r.timing }) + '\n'); } catch {}
  }
  process.exitCode = r.code;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  // last-resort boundary: anything escaping run() still exits 70 with a diagnostic
  const die = (what) => (e) => {
    process.stderr.write(`pkgentry runner: ${what}: ${describe(e)}\n`);
    process.exit(EXIT_INTERNAL);
  };
  // node:wasi is "experimental" on Node 24: drop that one warning so that stderr carries only
  // the module's output (compare.jl matches error text against the stderr tail)
  process.removeAllListeners('warning');
  process.on('warning', (w) => {
    if (w.name === 'ExperimentalWarning' && /WASI/.test(w.message)) return;
    process.stderr.write(`${w.name}: ${w.message}\n`);
  });
  process.on('uncaughtException', die('uncaught exception'));
  process.on('unhandledRejection', die('unhandled rejection'));
  main().catch(die('runner failure'));
}
