"""
    WasmCompatPkgExt

Pkg for WasmCodegen's closed world: what stock Pkg needs beyond its own source to compile to Wasm
as a command-line program. Overlays (methods of `WasmCodegen.Runtime.WASM_METHODS`, used only when
compiling to Wasm), each removing traps from the functions that call it (WasmCodegen compiles a
function with an unsupported construct as a function that traps):

- **Pkg's output stream.** Pkg keeps its stream as an `IO`: `Context.io::IO`, `DEFAULT_IO`, and
  `IOContext{IO}` wrappers of `stdout`/`stderr` (`unstableio`, built behind an inference barrier on
  purpose, to compile Pkg's printing once for every stream). Every print to it is a dynamic call.
  In a compiled command-line program the stream is always that wrapper around Base's `stdout` or
  `stderr`, which in a Wasm module are Core's standard streams (WASI's file descriptors 1 and 2,
  without color): the overlays assert those types, so that the calls dispatch statically. A
  `TypeError` at run time means another stream got there (a program that sets `DEFAULT_IO` or
  passes its own `io`: not supported by these overlays). Upstream, a concrete `Context.io` and
  printing leaf functions would replace them.
- **Download cancellation.** `PlatformEngines.with_download_cancellation(f, c)` opens a scope
  (`@with DOWNLOAD_CANCELLATION => c`), which WasmCodegen does not compile (`Core.current_scope`;
  see WasmCompat's Base extension): `f()` runs without it, and downloads are not cancelled together
  on an interrupt (a module has no interrupts).
- **Manifest format.** `Base.is_v1_format_manifest(raw)` reads a `Dict{String}` of a type not known
  at compile time; Pkg's are TOML tables, `Dict{String, Any}`.
- **Standard libraries are installed.** `Operations.is_package_downloaded` checks a standard library's
  source directory, `joinpath(Sys.STDLIB, name)`: a Wasm host has no standard-library directory
  (the image keeps their metadata), so every stdlib would show as not downloaded in `status`
  (`→`) and `instantiate` would not see the environment as instantiated. Natively they always ship
  with Julia: here a package without a tree hash or path that is a standard library is downloaded.
- **Error text.** A logged exception (`exception = err`) of a type not known at compile time is
  shown by `WasmCompat.showerror_hook` (see WasmCompat's Logging extension): Pkg's errors
  (`PkgError`, `ResolverError`) and TOML's `ParserError`, each as its `showerror` shows it.
"""
module WasmCompatPkgExt

import Pkg
import WasmCodegen
import WasmCompat
using Pkg: Types, Resolve, PlatformEngines
using Pkg.Types: Context, PkgError
using Pkg.Resolve: ResolverError

## Pkg's output stream: an `IOContext{IO}` around Core's standard streams
const CoreStd = Union{Core.CoreSTDOUT, Core.CoreSTDERR}

# (`unstableio(io)` for a stream without color, as Core's are; Pkg's `unstableio` asks the stream
# with a dynamic `get(io, :color, false)`)
std_iocontext(io::IO) = IOContext{IO}(io, Base.ImmutableDict{Symbol, Any}())

Base.Experimental.@overlay WasmCodegen.Runtime.WASM_METHODS Pkg.stderr_f() =
    something(Pkg.DEFAULT_IO[], std_iocontext(stderr))::IOContext{IO}
Base.Experimental.@overlay WasmCodegen.Runtime.WASM_METHODS Pkg.stdout_f() =
    something(Pkg.DEFAULT_IO[], std_iocontext(stdout))::IOContext{IO}
Base.Experimental.@overlay WasmCodegen.Runtime.WASM_METHODS Base.@constprop :aggressive Base.getproperty(
        ctx::Context, s::Symbol) = s === :io ? (getfield(ctx, :io)::IOContext{IO}) : getfield(ctx, s)
Base.Experimental.@overlay WasmCodegen.Runtime.WASM_METHODS Base.@constprop :aggressive Base.getproperty(
        io::IOContext{IO}, s::Symbol) = s === :io ? (getfield(io, :io)::CoreStd) : getfield(io, s)

## No scope for the cancellation of downloads
Base.Experimental.@overlay WasmCodegen.Runtime.WASM_METHODS PlatformEngines.with_download_cancellation(
        f, cancellation::PlatformEngines.DownloadCancellation) = f()

## Manifests are TOML tables
Base.Experimental.@overlay WasmCodegen.Runtime.WASM_METHODS function Base.is_v1_format_manifest(raw_manifest::Dict{String})
    if haskey(raw_manifest, "manifest_format")
        mf = raw_manifest["manifest_format"]
        # the off-chance where an old format manifest has a dep called "manifest_format"
        return mf isa Dict{String, Any} && haskey(mf, "uuid")
    else
        return true
    end
end

## Standard libraries ship with Julia (no stdlib directory in Wasm)
Base.Experimental.@overlay WasmCodegen.Runtime.WASM_METHODS function Pkg.Operations.is_package_downloaded(
        manifest_file::String, pkg::Types.PackageSpec; platform = Base.BinaryPlatforms.HostPlatform())
    pkg.tree_hash === nothing && pkg.path === nothing && Types.is_or_was_stdlib(pkg.uuid, VERSION) && return true
    sourcepath = Pkg.Operations.source_path(manifest_file, pkg)
    sourcepath === nothing && return false
    isdir(sourcepath) || return false
    Pkg.Operations.check_artifacts_downloaded(sourcepath; platform) || return false
    return true
end

## Error text of Pkg's errors
Base.Experimental.@overlay WasmCodegen.Runtime.WASM_METHODS function WasmCompat.showerror_hook(io::IO, @nospecialize(e))
    if e isa PkgError
        showerror(io, e::PkgError)
    elseif e isa ResolverError
        show_resolver_error(io, e::ResolverError)
    elseif e isa Base.TOML.ParserError
        showerror(io, e::Base.TOML.ParserError)
    else
        return false
    end
    return true
end

# `showerror(io, ::ResolverError)` (its message is an `AbstractString`, its cause an `Exception`)
function show_resolver_error(io::IO, err::ResolverError)
    msg = err.msg
    msg isa String ? print(io, msg) : msg isa SubString{String} ? print(io, msg) :
        print(io, "(a message of a type this build cannot print)")
    ex = err.ex
    ex === nothing && return
    if ex isa CompositeException
        for cex in ex
            print(io, "\n=> ")
            WasmCompat.showerror_hook(io, cex) || WasmCodegen.Runtime.showerror_any(io, cex)
        end
    else
        print(io, "\n")
        WasmCompat.showerror_hook(io, ex) || WasmCodegen.Runtime.showerror_any(io, ex)
    end
    return
end

end # module
