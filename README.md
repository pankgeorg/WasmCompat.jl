# WasmCompat.jl

Julia's standard library for [WasmCodegen.jl](https://github.com/gbaraldi/WasmCodegen.jl)'s closed world.

WasmCodegen compiles a Julia program to WebAssembly (Wasm GC) the way `juliac --trim` compiles it
natively: every call must be resolvable at compile time. Some standard library code is not, either
because it relies on dynamic dispatch that a trimmed program cannot compile, or because it needs
something a Wasm module does not have, such as GMP or a regex engine. WasmCompat replaces that code,
only when WasmCodegen compiles a program, with code that is.

**WasmCompat has no API you call.** Load it in the build script, next to the standard libraries the
program uses, and compile as usual:

```julia
using WasmCodegen, WasmCompat
using TOML, Logging, Tar          # the program's standard libraries
include("program.jl")
WasmCodegen.compile([WasmCodegen.Entry(Program.main, (); name = "main")];
                    config = WasmCodegen.Config(host = :wasi, trim = :safe))
```

Each covered standard library has a package extension, loaded when the program loads that library
together with WasmCodegen. The extension adds methods to WasmCodegen's overlay method table
(`WasmCodegen.Runtime.WASM_METHODS`). WasmCodegen compiles those methods in place of the library's
own. **Native code is unchanged:** the same session can run the program natively, with the
standard library's own methods.

## Extensions

| Extension | Loaded with | In Wasm | Upstream |
|---|---|---|---|
| `WasmCompatTOMLExt` | TOML | `TOML.print` with static dispatch: each value is told apart by `isa`, then printed by Base's own `printvalue` methods, so the output is byte-identical. Integer literals too long for `Int128`/`UInt128` are a parse error rather than a `BigInt` (see *Differences*). | The printer's dynamic dispatch also fails `juliac --trim=safe` natively. |
| `WasmCompatLoggingExt` | Logging | `@info`, `@warn` and `@error` print what Base's default `ConsoleLogger(stderr)` prints for a stream without color. Without this, juliac's trim patches make every log call print nothing. | juliac's `current_logger_for_env` stub drops logs natively too. |
| `WasmCompatTarExt` | Tar | Callbacks (`predicate`, `callback`, `emit`) specialized on, so calling them is static. `check_version_field` without a regex. | JuliaIO/Tar.jl#206 (the same specializations) |
| `WasmCompatArgToolsExt` | ArgTools | Callbacks specialized on. `arg_read`/`arg_write` of a path call `open` without a keyword splat. | JuliaIO/ArgTools.jl#46 |
| `WasmCompatArtifactsExt` | Artifacts | `Overrides.toml` tables parsed in a loop, without a generator whose element type is the abstract `Pair{String}`. | |
| `WasmCompatPCRE2Ext` | PCRE2_wasm_jll | Base's `Regex` on PCRE2 itself, compiled to WebAssembly: see *Regex* below. Opt-in, through `WasmCompat.pcre2_config`. | Needs WasmCodegen's `Config(foreign_functions)` and `Config(import_libraries)` |
| `WasmCompatLibGit2Ext` | LibGit2_wasm_jll, LibGit2 | Julia's `LibGit2` on libgit2 itself, compiled to WebAssembly: see *Git* below. Opt-in, through `WasmCompat.libgit2_config`. | Needs WasmCodegen's `Config(foreign_functions)` and `Config(import_libraries)`; libgit2's WASI changes are proposed upstream |
| `WasmCompatSIMDExt` | SIMD | SIMD.jl's intrinsics (each a `Base.llvmcall` of LLVM IR, which WasmCodegen does not compile) as the same operation on each lane, so code written with `SIMD.Vec` compiles as it is. Lane by lane: scalar speed, no SIMD128 (see *Differences*). | A SIMD128 lowering in WasmCodegen would replace the lanes for 16-byte vectors |
| `WasmCompatBaseExt` | WasmCodegen alone | `Base.generating_output()` is `false`: a compiled program never writes a code cache. Every first call of a `Base.OncePerProcess` value reached it (through `__precompile__(false)`) and trapped. | Or `jl_generating_output` → 0 in WasmCodegen itself |

The Tar and ArgTools overlays are the libraries' own definitions with `::Function` arguments made type
parameters. `gen/specialize_callbacks.jl` generates them from the installed Julia's stdlib sources,
one file per library version (`ext/TarExt/specialized_<version>.jl`). It checks that the printed code
parses back to the same definitions. For a Tar or ArgTools version without a generated file, the
extension warns and adds nothing.

### Interface for programs

`WasmCompat.showerror_hook(io, e) -> Bool` is called in Wasm before WasmCodegen's own
`Runtime.showerror_any`, for a logged exception whose type is not known at compile time
(`exception = err` in a `catch`). By default it does nothing. A program with exception types of its
own overlays it:

```julia
Base.Experimental.@overlay WasmCodegen.Runtime.WASM_METHODS function WasmCompat.showerror_hook(io::IO, @nospecialize(e))
    e isa MyError && (showerror(io, e::MyError); return true)
    return false
end
```

## Regex

Base's `Regex` calls PCRE2, a C library a WebAssembly module does not have. With `WasmCompatPCRE2Ext`, those
calls (`pcre2_compile_8`, `pcre2_match_8`, ...) are Julia functions of the extension, over PCRE2 itself compiled to
WebAssembly as a separate module: [PCRE2_wasm_jll](https://github.com/pankgeorg/PCRE2_wasm_jll.jl)'s
`libpcre2-8.wasm`, which imports nothing. Base's `regex.jl` and `pcre.jl` run unchanged, so patterns, errors and
offsets are PCRE2's own. Unlike the other extensions, this one is opt-in, because the host must provide the module:

```julia
using WasmCodegen, WasmCompat, PCRE2_wasm_jll    # PCRE2_wasm_jll: the PCRE2 of the compiling Julia (10.46 for 1.13.2)
config = WasmCompat.pcre2_config(WasmCodegen.Config(host = :wasi))
WasmCodegen.compile([WasmCodegen.Entry(Program.main, (); name = "main")]; config)
cp(WasmCompat.pcre2_module(), "libpcre2-8.wasm")   # deploy it with the program
```

`pcre2_config` adds the extension's functions (`Config(foreign_functions)`, library `"libpcre2-8"`) and the import
library `"pcre2"` (`Config(import_libraries)`). The host instantiates the PCRE2 module, once per instance of the
program, and gives its exports as the import module `"pcre2"`; `js/pcre2.mjs` does that for JavaScript:

```js
import { pcre2Imports } from './pcre2.mjs';
import { wasiImportObject, wasiInitialize } from './wasi.mjs';   // node:wasi on Node and on Bun
const imports = { ...wasiImportObject(wasi), ...(await pcre2Imports(fs.readFileSync('libpcre2-8.wasm'))) };
```

The program copies patterns and subjects into the PCRE2 module's memory and copies results back. What Base holds
(compiled patterns, match data) are Julia objects, and the ovector and name table it reads are Julia arrays.

- **No JIT.** Base compiles every pattern with `PCRE2_MATCH_INVALID_UTF`, and without a JIT PCRE2 then checks the
  subject's UTF-8 on every match, so `eachmatch` would be quadratic. A subject is checked once when it is copied in,
  and a valid one is matched with a twin of the pattern compiled without that option. `\C` in UTF mode is refused
  at `jit_compile`, as the native JIT does, so Base throws the same error.
- **Compiled patterns are kept** by pattern and options, because finalizers do not run in a module and `Regex`
  frees its pattern only in one. A program that builds the same pattern repeatedly compiles it once.
- **Size:** the PCRE2 module is 399 KB, 110 KB gzipped (PCRE2's whole 8-bit API; about 140 KB of it is Unicode
  tables). The program itself is no larger than with a host regex engine: the same regex workloads compile to
  43 KB (15 KB gzipped), against 44 KB with the host-RegExp engine of gbaraldi/WasmCodegen.jl#35.
- **Speed** (Node 24, best of 5): about 5× native Julia (with its JIT) per match, about 12× on engine-bound
  matching, and about native on compiling patterns.
- **Differs from native Julia:** an error PCRE2 detects only while matching can read differently, because the
  native JIT detects it as JIT stack exhaustion. Example: `(?R)` gives "nested recursion at the same subject
  position" here and "JIT stack limit reached" natively. PCRE2 without a JIT gives the same as here.

## Git

Julia's `LibGit2` calls libgit2, a C library a WebAssembly module does not have. With `WasmCompatLibGit2Ext`,
`LibGit2` runs on libgit2 itself (1.9.7, Julia 1.13.2's), compiled to WebAssembly as a separate module:
[LibGit2_wasm_jll](https://github.com/pankgeorg/LibGit2_wasm_jll.jl)'s `libgit2.wasm`. `LibGit2`'s Julia code
runs, and so does its callers': Pkg's `GitTools`, `Types`, `Operations` and `Registry` unchanged clone, fetch,
open repositories, resolve revisions, read trees and blobs, check out trees, reset, merge (fast-forward) and
rebase with it. Like the PCRE2 extension, this one is opt-in:

```julia
using WasmCodegen, WasmCompat, LibGit2, LibGit2_wasm_jll   # LibGit2_wasm_jll: the libgit2 of the compiling Julia
config = WasmCompat.libgit2_config(WasmCodegen.Config(host = :wasi))
# ... WasmCodegen.compile(entries; config)
cp(WasmCompat.libgit2_module(), "libgit2.wasm")   # deploy it with the program
```

`libgit2_config` adds the extension's functions (`Config(foreign_functions)`, library `LibGit2_jll.libgit2`) and the
import library `"libgit2"`. Unlike PCRE2's, the libgit2 module has imports of its own: WASI preview 1 for its
filesystem (an instance of its own, over the *same* preopens and environment as the program's), and WasmHost's
`wasm_host.http_request` for https (the host's fetch; it suspends, so the program's export runs through JSPI).
`js/libgit2.mjs` instantiates it:

```js
import { libgit2Imports } from './libgit2.mjs';
const wasi = new WASI({ version: 'preview1', preopens, env, returnOnExit: true });   // the program's preopens
const wasmHost = makeImports({ preopens });   // WasmHost.jl's js/node/imports.mjs
const imports = { ...programImports, ...(await libgit2Imports(fs.readFileSync('libgit2.wasm'), { wasi, wasmHost })) };
await WebAssembly.promising(instance.exports.main)();
```

How it works: `LibGit2`'s handle types hold the module's addresses in their `ptr` fields. The `ccall`s that take
and return handles, integers, strings and ids (51) are foreign functions that copy strings and ids in and out. The
methods whose `ccall` passes an option struct, an array of pointers or an out-struct of pointers (`clone`, `fetch`,
`checkout_tree`, `reset!`, `GitRebase`, `add!`, `merge_analysis`, `remotes`, `branch`, configuration strings, the
last error, signatures, rebase operations) are overlays that make the same libgit2 call by the struct's fields:
WasmCodegen loads plain bits through a pointer a foreign function receives, but not pointers inside structs or
arrays. A few overlays are closed-world forms of `LibGit2`'s own code (the object constructors, `commit`, `close`).

- **No callbacks.** libgit2 calls no Julia function: remotes are public https (TLS is the host's) or local paths;
  a remote that asks for credentials is libgit2's `EAUTH` error ("remote authentication required but no callback
  set"); transfer progress is not reported (Pkg's progress bar stays empty).
- **WASI preview 1:** no permission bits, so the module sets `core.filemode = false` for each repository it opens
  (a work tree is not dirty by mode), and the files git records as executable are made executable after a
  checkout through the program's `chmod` (WasmCodegen's `julia_io` host extension; without it they stay
  non-executable). No ssh, no credential helpers.
- **Not in Wasm:** non-fast-forward `merge!`, `merge!` of FETCH_HEAD, `CheckoutOptions(paths)`. Pkg uses none.
- **Node 24:** run Node with `--no-turbo-fast-api-calls`: a node:wasi call that allocates while on a JSPI stack can
  abort the process (`Check failed: isolate_->IsOnCentralStack()`). Bun needs no flag.
- **Size:** the libgit2 module is about 1.1 MB, 380 KB gzipped (920 KB after `wasm-opt -Oz`).

## Differences from native, by design

- **TOML:** an integer literal longer than 33 decimal digits (hex 34, octal 45, binary 130) is
  `ErrOverflowError`, as in a TOML parser limited to 64 bits. Natively it parses as a `BigInt`. A Wasm
  module has no GMP.
- **TOML:** inside an `Any`-typed container, a value must be of one of the types listed in
  `WasmCompatTOMLExt.SCALAR_TYPES`, `TABLE_TYPES` or `ARRAY_TYPES` (the parser's own output and the
  common concrete containers), or one of `UUID`, `SHA1`, `VersionNumber`, `Nothing` or `Symbol`
  passed through the conversion function. Any other value is an error in Wasm.
- **Logging:** the logger is fixed. `with_logger` and `global_logger` are not consulted, the
  minimum level is `Info`, and `JULIA_DEBUG` is ignored. Exceptions are shown without backtraces.
  Values are shown if they are of a common type (strings, symbols, numbers, versions, UUIDs) or an
  exception; any other value, vectors included, is shown as `(a value of type T)`.
- **Logging, a code-generator limit:** a log call whose key-value pairs include a value of a type
  not known at compile time builds a tuple of abstract type in the caller. An example is a caught
  `err` passed as it is: `@warn "..." exception = err`. WasmCodegen doesn't compile such a tuple
  (`trim = :safe` reports "a tuple of abstract type Tuple{Any}"), although native trim does. Assert
  the type at the call (`exception = err::MyError`) or pass a value of a concrete type.

- **SIMD.jl:** a horizontal float reduction (`sum`, `prod` of a `Vec`) adds the lanes left to
  right, where LLVM may associate in any order, so its last bits can differ. `muladd` is computed as
  WebAssembly computes it (core WebAssembly has no fused multiply-add); `fma` is exact as natively.
  Every lane is a scalar operation: a `Vec` loop computes what it computes natively, at scalar speed.

## Requirements and known limits

- **Julia 1.13** (tested with 1.13.2). Julia 1.12 loads the package, but its overlays are untested there.
- **WasmCodegen with `WASM_METHODS`.** `WASM_METHODS` and `@wasm_method` are internal to WasmCodegen
  today. Asking the maintainer to make them a supported interface for packages is part of the
  `Config(import_libraries)` discussion upstream.
- **`verify = :error` does not pass yet.** WasmCodegen's juliac-equivalent verifier infers the
  program with the native method tables, so it reports the standard library's original code as
  unresolved even though the module contains the overlay instead. Build with `verify = :warn`.
  A generic fix in WasmCodegen is under discussion. Code generation is unaffected: `trim = :safe`
  reports 0 diagnostics.
- **Overlays must not be constant.** WasmCodegen's inference still evaluates calls with constant
  arguments using the native methods (see `WasmCodegen.Runtime.@wasm_method`). Each overlay here
  therefore reads state or performs I/O. For example, the Logging extension reads its logger from a
  global rather than constructing it.
- **`Tar.list` reads an undefined value at run time** (a null dereference, with no build diagnostic). `Tar.iterate_headers`,
  which `Tar.list` runs, jumps into its `while` loop with `@goto` (an irreducible loop), and Base's `hasmethod` checks
  of the callback are loops between that label and the use of the header. IRStructurizer, which WasmCodegen
  structures functions with, takes such a nested loop for an entry of the irreducible one and carries the header
  as undefined through it. This is a code-generation issue, not one of this package: with IRStructurizer fixed,
  `tar.jl` is identical to native in Node and in Bun. `Tar.extract`, `read_tarball` and `tree_hash` do not use
  `iterate_headers`.
- **`Tar.extract` sets file modes**, so a program that extracts needs a host with file modes: WasmCodegen's
  `julia_io` host extension (`host_extensions = [:julia_io]`, `js/julia_io.mjs`'s path imports). Without it,
  `chmod` fails with ENOTSUP (WASI preview 1 has no modes) and `Tar.extract` throws an `IOError`.
- **Tar's error messages** use a regex (`read_standard_header`), so programs that hit them need a
  regex engine: the PCRE2 extension (see *Regex*).

## Hosts

The extensions have no host side: they are Julia code compiled into the module, using only WASI
preview 1 through WasmCodegen's runtime. They are host-neutral, except that the PCRE2 and LibGit2 extensions need the
host to instantiate their modules (`js/pcre2.mjs` and `js/libgit2.mjs` for JavaScript; any host that can link two
modules works the same). libgit2's module also needs a WASI instance of its own that shares the program's
filesystem (a browser's WASI shim must give both instances the same directory objects), and a fetch for https
(GitHub sends no CORS headers: a browser needs a proxy).

| Host | Status |
|---|---|
| Node.js 24 (`node:wasi`) | **Tested**: `test/wasm/` compares each program's output with native Julia's |
| Bun 1.4 (`node:wasi`, JavaScriptCore) | **Tested**: the same `test/wasm/` runs (`WASM_RUNTIME=bun`); each output is the same as on Node. Bun's `node:wasi` has no `getImportObject()`/`initialize()`: `js/wasi.mjs` stands in for both |
| Browsers (a JS WASI shim) | Untested |
| Cloudflare workerd | Untested |
| wasmtime | Untested |

## Tests

- `test/runtests.jl` (native): the typed TOML printer against `TOML.print`, byte for byte, on fixed
  and random tables; the Wasm logger's records against `ConsoleLogger`'s; the regex-free version
  check against the regex; that every overlay is present; the PCRE2 configuration, module and version;
  and (`test/simd.jl`) each SIMD.jl lane overlay against SIMD.jl's own LLVM intrinsic, in floats and integers of
  every width, including NaNs, overflow and masks.
- `test/wasm/` (needs Node 24 or Bun 1.4): one small program per extension (`simd.jl`: SIMD.jl `Vec` code and a `OncePerProcess`), compiled with `trim = :safe` (and
  optimized by `wasm-opt -O3`) and run on `node:wasi` in Node or Bun (`WASM_RUNTIME=node|bun`, or both). `check.sh` diffs each program's output with native Julia's. With `PCRE2=1`, `regex.jl` (Base's
  Regex API, compile errors, PCRE-only constructs, Pkg's semver patterns on every `[compat]` range of the General
  registry, Tar's path checks) and `corpus.jl` (69 patterns through `eachmatch`, `keys` and `replace`) run on PCRE2.
  With `LIBGIT2=1 PCRE2=1`, `git.jl` runs the operations Pkg performs through `LibGit2` on repositories it makes
  (init/add!/commit, objects, trees and blobs, HEAD and branches, configuration, remotes, local and file:// clones,
  fetch with Pkg's refspec, checkout into a directory, isdirty, reset!, fast-forward merge!, rebase!, errors);
  with `NET=1 WASM_ENV=NET=1 WASMHOST_JS=<WasmHost.jl>/js/node` also a shallow https clone and an unshallow fetch.

## License

MIT. The overlays in `ext/TarExt` and `ext/ArgToolsExt`, and parts of the TOML and Logging
extensions, are derived from Julia's standard library (MIT, Copyright (c) 2009-2026: Jeff
Bezanson, Stefan Karpinski, Viral B. Shah, and other contributors).
