# Build patches for the entry shim

Files passed to WasmCodegen as `Config(extra_patches)` when compiling `PkgEntry` (bound as `PkgEntry`):

- `entry-runtime.jl`: `PkgEntry.init_runtime()` in Wasm — Base's runtime globals (`ARGS`, `ENV`, the working
  directory, `DEPOT_PATH`, `LOAD_PATH`, the active project) read from WASI, as Julia's startup sets them natively;
  and `Base.load_path_expand` without `@script` paths.
- `entry-trim.jl`: Base's printing without an IO argument (`print(x)`, `println(x)`, `show(x)`, `printstyled(msg...)`,
  `display(x)`) to `Core.stdout`/`Core.stderr`; `show(::Tar.Header)` without Base's expression printer.

They also need the image-time reset of Base's globals (`Base.stdout`/`stderr` = Core's streams, `stdin` = `devnull`,
the load and depot paths emptied), which `WasmCompatPkgExt`'s stream overlays rely on.
