# Stock Pkg compiled to Wasm, against the native Pkg

The package manager of Julia 1.13 (JuliaLang/Pkg.jl `release-1.13`, with the patches listed in
[`patches.toml`](patches.toml)) compiled to WebAssembly with WasmCodegen, WasmCompat and WasmHost
behind a thin entry shim (`shim/`), and the same patched Pkg run natively: each scenario of
[`fixtures/scenarios.toml`](fixtures/scenarios.toml) runs both ways from the same initial state,
against a local Pkg server that serves a frozen General registry, and the results are compared
(`compare.jl`: environments, installed packages and artifacts by tree hash, registries, exit
codes, output, the requests made to the server).

Why `release-1.13`: WasmCodegen supports Julia 1.12 and 1.13, and Pkg's master needs Julia 1.15.
A master PR is applied as its `src/` diff, or as its backport to `release-1.13` where that diff
doesn't apply. `apply_patches.jl --check-heads` reports which pinned PRs have moved since; `--refresh`
re-pins them.

## Files

| File | |
|---|---|
| `patches.toml`, `apply_patches.jl` | the sources: each repository at a pinned commit plus patches, applied one by one into `work/` |
| `build.jl`, `base_globals.jl` | the Wasm build (`out/module/pkgentry.wasm`), with the relocation test's sentinels and poisoned Pkg state |
| `js/run.mjs` | the Node runner of the module (WASI, WasmCodegen's `julia_io`/`julia_task`, WasmHost, PCRE2, libgit2) |
| `native_pkg.jl` | the native twin of the module's entry point, on the patched Pkg |
| `scenarios.jl` | initial states, native baselines, Wasm runs, the relocation test, the report |
| `compare.jl`, `imagescan.jl`, `git_fixture.jl` | the equivalence checks, the scan of the module for build-host strings, the git fixtures |
| `js/pkgserver.mjs` | the frozen Pkg server (payloads cached in `fixtures/cache`) |
| `shim/` | the entry shim (its `build_args.txt`: extra arguments of `build.jl`) |

## Running it locally

Julia 1.13 and Node 24 (`NODE=/path/to/node` if it isn't on `PATH`), from the repository root:

    julia test/pkg/apply_patches.jl                      # sources into test/pkg/work
    julia test/pkg/build.jl $(grep -v '^#' test/pkg/shim/build_args.txt 2>/dev/null)   # ~10 min, ~2.5 GB
    julia test/pkg/scenarios.jl prepare                  # initial states (fixtures/initial)
    julia test/pkg/scenarios.jl baseline                 # native runs: test/pkg/out/native
    julia test/pkg/scenarios.jl run --impl wasm          # Wasm runs, compared with the baselines
    julia test/pkg/scenarios.jl relocation               # the module with decoy build-time paths preopened
    julia test/pkg/scenarios.jl report                   # scenario | Wasm | native | EQUIVALENT?

Scenario names select a subset (`scenarios.jl run --impl wasm S-add S-fail`); `run --impl native`
reruns the native side against its baselines. The CI workflow is
[`.github/workflows/stock-pkg.yml`](../../.github/workflows/stock-pkg.yml).
