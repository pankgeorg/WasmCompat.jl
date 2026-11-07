"""
    WasmCompatBaseExt

Base for WasmCodegen's closed world: constructs of Base's own code that a program reaches
without asking for them, and that WasmCodegen does not compile. Loaded with WasmCodegen alone.
Overlays (methods of `WasmCodegen.Runtime.WASM_METHODS`, used only when compiling to Wasm), each
removing a trap from every function that calls it (WasmCodegen compiles a function with an
unsupported construct as a function that traps):

- **Scoped values.** `ScopedValues.get` reads `Core.current_scope()`, which WasmCodegen does not
  support. Here the read is the value's default: no scope is active. That is the case of a
  program that does not open a scope (`@with`, `with`) on the paths it runs; one that does must
  overlay its `@with` sites too (the scope they open is not seen here).
- **Styled display.** Base's display of annotated strings (`write`/`print`/`printstyled`/`show`
  of an `AnnotatedString`, an `AnnotatedIOBuffer`) goes through `invoke_in_world(tls_world_age(),
  f, args...)`, a call in another world that WasmCodegen does not compile. A compiled program has
  one world: the overlays call `f` directly, specialized on the arguments.
- **`Experimental.@sync`.** `sync_end` waits on the tasks of its channel (`Channel{Any}`) from a
  task of its own whose closure captures the event as an `Any`: a `Task` of a closure over a
  value of a type not known at compile time. The overlay takes the event as the `Task` it is.
- **Backtraces.** `catch_backtrace` asks the runtime for the exception's backtrace
  (`jl_get_backtrace`), which a Wasm module does not have: an empty backtrace.
- **`mktemp(f)`, `mktempdir(f)`.** Their cleanup logs a failure with `exception = (ex,
  catch_backtrace())`, a tuple of a value of a type not known at compile time, which WasmCodegen
  does not compile: every function that makes a temporary directory traps. Here the failure is
  logged by a function of its own, so only a failed cleanup reaches the unsupported construct.
- **`sprint(showerror, e)`** of a caught exception (of a type not known at compile time): the call
  packs `e` in a `Tuple{Any}` for `sprint`'s varargs, which WasmCodegen does not compile, so every
  function that shows a caught error traps. The overlay takes `e` as one argument and shows it as
  WasmCompat's `showerror_hook` does, else as WasmCodegen's runtime does
  (`Runtime.Host.error_text`: the `showerror` of the exception's type where the module can
  compile it, else the text of Base's usual exceptions).
- **`gethostname`.** WASI has no host name: `"localhost"`.
- **`hash(::SHA1)`** (`Dict{SHA1}` keys: artifacts, tree hashes). Base hashes `(SHA1, a.bytes)`,
  and the type's hash is `jl_type_hash`, a call of the runtime: taken when the extension loads,
  so the values are the native ones (also for the `Dict`s of the image).
"""
module WasmCompatBaseExt

import WasmCodegen
import WasmCompat
using Base.ScopedValues: AbstractScopedValue, hasdefault, getdefault
using Base: AnnotatedIOBuffer

## Scoped values: no scope is active
Base.Experimental.@overlay WasmCodegen.Runtime.WASM_METHODS function Base.ScopedValues.get(
        val::AbstractScopedValue{T}) where {T}
    hasdefault(val) || return nothing
    return Some{T}(getdefault(val))
end

## Styled display in the program's one world
Base.Experimental.@overlay WasmCodegen.Runtime.WASM_METHODS Base.AnnotatedDisplay.ansi_write_(
        f::F, io::IO, x::X) where {F <: Function, X} = Base.AnnotatedDisplay.ansi_write(f, io, x)
Base.Experimental.@overlay WasmCodegen.Runtime.WASM_METHODS Base.AnnotatedDisplay.styled_print_(
        io::AnnotatedIOBuffer, msg::M, kwargs::K) where {M, K} = Base.AnnotatedDisplay.styled_print(io, msg, kwargs)::Nothing
Base.Experimental.@overlay WasmCodegen.Runtime.WASM_METHODS Base.AnnotatedDisplay.show_annot_(
        io::IO, x::X) where {X} = Base.AnnotatedDisplay.show_annot(io, x)::Nothing
Base.Experimental.@overlay WasmCodegen.Runtime.WASM_METHODS Base.AnnotatedDisplay.show_annot_(
        io::IO, m::MIME, x::X) where {X} = Base.AnnotatedDisplay.show_annot(io, m, x)::Nothing

## `Experimental.@sync`: the events are the tasks `@async`/`@spawn` put in the channel
Base.Experimental.@overlay WasmCodegen.Runtime.WASM_METHODS function Base.Experimental.sync_end(c::Channel{Any})
    if !isready(c)
        # there must be at least one item to begin with
        close(c)
        return
    end
    nremaining::Int = 0
    while true
        event = take!(c)
        if event === :__completion__
            nremaining -= 1
            if nremaining == 0
                break
            end
        else
            nremaining += 1
            task = event::Task
            schedule(Task(() -> begin
                try
                    wait(task)
                    put!(c, :__completion__)
                catch e
                    close(c, e::Exception)
                end
            end))
        end
    end
    close(c)
    nothing
end

## No backtraces
Base.Experimental.@overlay WasmCodegen.Runtime.WASM_METHODS Base.catch_backtrace() =
    Vector{Union{Ptr{Nothing}, Base.InterpreterIP}}()

## Temporary files and directories: the cleanup's failure logged apart
@noinline log_cleanup_failure(what::String, @nospecialize(ex)) =
    @error what _group = :file exception = (ex, catch_backtrace())

Base.Experimental.@overlay WasmCodegen.Runtime.WASM_METHODS function Base.Filesystem.mktempdir(
        fn::Function, parent::AbstractString = tempdir(); prefix::AbstractString = Base.Filesystem.temp_prefix)
    tmpdir = mktempdir(parent; prefix = prefix)
    try
        fn(tmpdir)
    finally
        Base.Filesystem.temp_cleanup_forget(tmpdir)
        try
            if ispath(tmpdir)
                Base.Filesystem.prepare_for_deletion(tmpdir)
                rm(tmpdir, recursive = true)
            end
        catch ex
            log_cleanup_failure("mktempdir cleanup", ex)
            Base.Filesystem.temp_cleanup_later(tmpdir, asap = true)
        end
    end
end

Base.Experimental.@overlay WasmCodegen.Runtime.WASM_METHODS function Base.Filesystem.mktemp(
        fn::Function, parent::AbstractString = tempdir())
    (tmp_path, tmp_io) = mktemp(parent)
    try
        fn(tmp_path, tmp_io)
    finally
        Base.Filesystem.temp_cleanup_forget(tmp_path)
        try
            close(tmp_io)
            ispath(tmp_path) && rm(tmp_path)
        catch ex
            log_cleanup_failure("mktemp cleanup", ex)
            Base.Filesystem.temp_cleanup_later(tmp_path, asap = true)
        end
    end
end

## `hash(::SHA1)` with the type's hash of this Julia
const SHA1_TYPE_HASH = Base._jl_type_hash(Base.SHA1)
Base.Experimental.@overlay WasmCodegen.Runtime.WASM_METHODS Base.hash(a::Base.SHA1, h::UInt) =
    hash((SHA1_TYPE_HASH, a.bytes), h)

## `sprint(showerror, e)` of an exception of a type not known at compile time
Base.Experimental.@overlay WasmCodegen.Runtime.WASM_METHODS function Base.sprint(::typeof(showerror), @nospecialize(e))
    io = IOBuffer()
    WasmCompat.showerror_hook(io, e) && return String(take!(io))
    return WasmCodegen.Runtime.Host.error_text(e)
end

## No host name in WASI
Base.Experimental.@overlay WasmCodegen.Runtime.WASM_METHODS Base.Libc.gethostname() = "localhost"

end # module
