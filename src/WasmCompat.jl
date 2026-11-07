"""
    WasmCompat

Compatibility of Julia's standard library with WasmCodegen's closed world. The package has no code
of its own that a program calls: each standard library it covers has a package extension, loaded
when the program loads that library and WasmCodegen together, which adds methods to WasmCodegen's
overlay method table (`WasmCodegen.Runtime.WASM_METHODS`). Those methods replace the library's
own only when WasmCodegen compiles a program; native code is unchanged.

| Extension | Loaded with | What it replaces in Wasm |
|---|---|---|
| `WasmCompatTOMLExt` | TOML | `TOML.print` with static dispatch; long integer literals without GMP |
| `WasmCompatLoggingExt` | Logging | `@info`/`@warn`/`@error` printed as `ConsoleLogger` prints them, to stderr |
| `WasmCompatTarExt` | Tar | callbacks specialized on; version field check without a regex |
| `WasmCompatArgToolsExt` | ArgTools | callbacks specialized on; `open` without a keyword splat |
| `WasmCompatArtifactsExt` | Artifacts | `Overrides.toml` tables parsed without an abstract `Pair` generator |
| `WasmCompatPCRE2Ext` | PCRE2_wasm_jll | Base's `Regex` on PCRE2 compiled to Wasm ([`pcre2_config`](@ref)) |
| `WasmCompatLibGit2Ext` | LibGit2_wasm_jll, LibGit2 | `LibGit2` on libgit2 compiled to Wasm ([`libgit2_config`](@ref)) |
| `WasmCompatSIMDExt` | SIMD | SIMD.jl's LLVM intrinsics as the same operation on each lane |
| `WasmCompatBaseExt` | (WasmCodegen alone) | `Base.generating_output()` is `false` |

Functions here that are part of the extensions' interface with programs and builds:
[`showerror_hook`](@ref), [`pcre2_config`](@ref), [`pcre2_module`](@ref), [`libgit2_config`](@ref) and
[`libgit2_module`](@ref).

An overlay replaces the native method only where inference does not evaluate the call at compile
time: WasmCodegen's inference still evaluates calls with constant arguments using the native
methods (see `WasmCodegen.Runtime.@wasm_method`), so each overlay here reads state or performs
I/O rather than computing a constant.
"""
module WasmCompat

"""
    WasmCompat.showerror_hook(io::IO, e) -> Bool

Called in Wasm by the extensions that show exceptions of types not known at compile time (a
logged `exception = err` of a `catch`), before WasmCodegen's own `Runtime.showerror_any`, which
shows Base's exceptions. The default shows nothing and returns `false`. A program with exception
types of its own overlays it, typically with an `isa` test per type:

```julia
Base.Experimental.@overlay WasmCodegen.Runtime.WASM_METHODS function WasmCompat.showerror_hook(io::IO, @nospecialize(e))
    e isa MyError && (showerror(io, e::MyError); return true)
    return false
end
```
"""
showerror_hook(io::IO, @nospecialize(e)) = false

"""
    WasmCompat.pcre2_config(config::WasmCodegen.Config; check_version = true) -> Config

`config` with Base's `Regex` on PCRE2 compiled to WebAssembly (the extension
`WasmCompatPCRE2Ext`, loaded with WasmCodegen and PCRE2_wasm_jll): Base's PCRE2 calls are
functions of the extension (`Config(foreign_functions)`) over PCRE2_wasm_jll's standalone module,
which the host instantiates and gives the program as the import module `"pcre2"`
(`Config(import_libraries)`; `js/pcre2.mjs`, with the file [`pcre2_module`](@ref)). For
`Config(host = :wasi)`. PCRE2_wasm_jll's version must be the compiling Julia's PCRE2
(`check_version`), whose error messages and offsets differ between minor versions.
"""
function pcre2_config end

"""
    WasmCompat.pcre2_module() -> String

The path of the PCRE2 module a program compiled with [`pcre2_config`](@ref) imports as `"pcre2"`.
"""
function pcre2_module end

"""
    WasmCompat.libgit2_config(config::WasmCodegen.Config; check_version = true) -> Config

`config` with Julia's `LibGit2` on libgit2 compiled to WebAssembly (the extension
`WasmCompatLibGit2Ext`, loaded with WasmCodegen, LibGit2_wasm_jll and LibGit2): `LibGit2`'s calls
of libgit2 are functions of the extension (`Config(foreign_functions)`) over LibGit2_wasm_jll's
standalone module, which the host instantiates, with a WASI instance of its own over the program's
preopens, and gives the program as the import module `"libgit2"` (`Config(import_libraries)`;
`js/libgit2.mjs`, with the file [`libgit2_module`](@ref)). For `Config(host = :wasi)`.
LibGit2_wasm_jll's version must be the compiling Julia's libgit2 (`check_version`).
"""
function libgit2_config end

"""
    WasmCompat.libgit2_module() -> String

The path of the libgit2 module a program compiled with [`libgit2_config`](@ref) imports as `"libgit2"`.
"""
function libgit2_module end

end # module
