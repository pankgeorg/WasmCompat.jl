"""
    PkgEntry

Entry points of a package manager compiled to WebAssembly: stock Pkg (whatever `Pkg` the build
environment resolves to; no Pkg source here) behind a small command-line interface, as functions
a host calls (`pkgentry_abi_version`, `pkgentry_init`, `pkgentry_main`). What Pkg needs beyond its
own code to compile is in WasmCompat's and WasmHost's package extensions (`WasmCompatPkgExt`,
`WasmHostPkgExt`, ...); this module holds only what a program has to do itself:

- the exports and their interface version;
- the command line, as the Pkg REPL mode reads it (`add`, `develop`, `rm`, `resolve`,
  `instantiate`, `status`, `gc`, `registry add|rm|update|status`);
- Pkg's session globals, set as `Pkg.__init__` sets them (a module's `__init__` does not run in
  Wasm), and reset before the image is written;
- the standard libraries' metadata, read when the build loads this package (a Wasm host has no
  standard library directory), kept in the image;
- errors reported as the Pkg REPL mode reports them (`ERROR: ` and the message).
"""
module PkgEntry

import Pkg
using Pkg: Types, API, Registry, REPLMode, PlatformEngines, GitTools, Resolve
using Pkg.Types: PackageSpec

"""
    init_runtime()

Base's runtime globals (`ARGS`, `ENV`, `DEPOT_PATH`, `LOAD_PATH`, the active project, the working
directory). Natively Julia's startup has set them: nothing to do. The Wasm build redefines it with
the code generator's runtime.
"""
init_runtime()::Nothing = nothing

# The standard libraries' metadata (names, UUIDs, versions, dependencies), read from the build
# Julia's stdlib directory when the build loads this package: the image keeps it.
__init__() = (Types.stdlib_infos(); nothing)

const ABI_VERSION = Int32(1)
pkgentry_abi_version() = ABI_VERSION

"""
    sanitize_globals!()

Pkg's session globals back to a fresh session's values (the build calls it right before the image
is written; `pkgentry_init` again). `Types.STDLIB` is kept (see `__init__`).
"""
function sanitize_globals!()
    Pkg.DEFAULT_IO[] = nothing
    Pkg.OFFLINE_MODE[] = false
    Pkg.UPDATED_REGISTRY_THIS_SESSION[] = false
    Pkg.RESPECT_SYSIMAGE_VERSIONS[] = true
    Pkg.PREV_ENV_PATH[] = ""
    Pkg._auto_gc_enabled[] = true
    empty!(Pkg.DEPOT_ORPHANAGE_TIMESTAMPS)
    for cache in (Types.TOML_CACHE, Registry.TOML_CACHE)
        empty!(cache.d)
        Base.TOML.reinit!(cache.p, ""; filepath = nothing)
    end
    empty!(PlatformEngines.AUTH_ERROR_HANDLERS)
    empty!(Registry.REGISTRY_CACHE)
    empty!(API.undo_entries)
    API.saved_initial_snapshot[] = false
    empty!(GitTools.GIT_PROTOCOLS)
    empty!(GitTools.GIT_USERS)
    return nothing
end

"What `Pkg.__init__` does for a command-line session."
function init_globals!()
    sanitize_globals!()
    Pkg.OFFLINE_MODE[] = Base.get_bool_env("JULIA_PKG_OFFLINE", false)
    Pkg._auto_gc_enabled[] = Base.get_bool_env("JULIA_PKG_GC_AUTO", true)
    return nothing
end

function pkgentry_init()::Int32
    return try
        init_runtime()
        init_globals!()
        Int32(0)
    catch e
        report_error(e)
        Int32(1)
    end
end

pkgentry_main()::Int32 = pkgentry_main(ARGS)

function pkgentry_main(args::Vector{String})::Int32
    return try
        run_command(args)
        Int32(0)
    catch e
        report_error(e)
        Int32(1)
    end
end

const COMMANDS = "add, develop, rm, resolve, instantiate, status, gc, registry"

# `<cmd> [words...]`, as the Pkg REPL mode takes them
function run_command(args::Vector{String})
    isempty(args) && Types.pkgerror("usage: <command> [packages...]; commands: ", COMMANDS)
    cmd = args[1]
    cmd == "registry" && return run_registry_command(args[2:end])
    cmd == "gc" && return run_gc_command(args[2:end])
    words = args[2:end]
    pkgs = cmd == "add" || cmd == "develop" ?
        REPLMode.parse_package(REPLMode.QString[REPLMode.QString(w, false) for w in words], nothing; add_or_dev = true) :
        PackageSpec[PackageSpec(name) for name in words]
    if cmd == "add"
        isempty(pkgs) && Types.pkgerror("add: no packages given")
        API.add(pkgs)
    elseif cmd == "develop"
        isempty(pkgs) && Types.pkgerror("develop: no packages given")
        API.develop(pkgs)
    elseif cmd == "rm"
        isempty(pkgs) && Types.pkgerror("rm: no packages given")
        API.rm(pkgs)
    elseif cmd == "resolve"
        length(args) == 1 || Types.pkgerror("resolve takes no arguments")
        API.resolve()
    elseif cmd == "instantiate"
        length(args) == 1 || Types.pkgerror("instantiate takes no arguments")
        API.instantiate()
    elseif cmd == "status"
        API.status(pkgs)
    else
        Types.pkgerror("unknown command `", cmd, "`; supported: ", COMMANDS)
    end
    return nothing
end

function run_gc_command(args::Vector{String})
    verbose = false
    for w in args
        if w == "-v" || w == "--verbose"
            verbose = true
        elseif w != "--all"
            Types.pkgerror("gc: unknown option `", w, "`; usage: gc [-v|--verbose] [--all]")
        end
    end
    API.gc(; verbose)
    return nothing
end

const REGISTRY_SUBCOMMANDS = ("add", "rm", "update", "status")

function run_registry_command(args::Vector{String})
    isempty(args) && Types.pkgerror("usage: registry <add|rm|update|status> [registries...]")
    sub = args[1]
    words = args[2:end]
    sub = sub == "remove" ? "rm" : sub == "up" ? "update" : sub == "st" ? "status" : sub
    sub in REGISTRY_SUBCOMMANDS ||
        Types.pkgerror("unknown registry command `", args[1], "`; supported: add, rm, update, status")
    lo, hi = sub == "rm" ? (1, typemax(Int)) : sub == "status" ? (0, 0) : (0, typemax(Int))
    lo <= length(words) <= hi || Types.pkgerror("Wrong number of arguments")
    regs = Registry.RegistrySpec[REPLMode.parse_registry(w; add = sub == "add") for w in words]
    if sub == "add"
        Registry.add(regs)
    elseif sub == "rm"
        Registry.rm(regs)
    elseif sub == "update"
        Registry.update(regs)
    else
        Registry.status()
    end
    return nothing
end

# Errors are reported as the Pkg REPL mode reports them: `ERROR: ` and the message, no backtrace.
function report_error(@nospecialize(e))
    io = Pkg.stderr_f()
    c = Base.error_color()
    c isa Symbol ? printstyled(io, "ERROR: "; color = c, bold = true) :
        printstyled(io, "ERROR: "; color = c::Int, bold = true)
    show_error(io, e)
    println(io)
    return nothing
end

# `showerror(io, e)` of the errors the commands throw, told apart by type (the same text as
# `showerror`): in Wasm the exception's type is not known at compile time, and `showerror(io, e)`
# of it is a dynamic call. Other exceptions go to `show_other_error`, a function of its own.
function show_error(io::IO, @nospecialize(e))
    if e isa Types.PkgError
        print(io, e.msg)
    elseif e isa Resolve.ResolverError
        m = e.msg
        print(io, m isa String ? m : m isa SubString{String} ? m : "(a message this build cannot print)")
    elseif e isa ErrorException
        print(io, message_text(e.msg))
    elseif e isa ArgumentError
        print(io, "ArgumentError: ", message_text(e.msg))
    elseif e isa Base.IOError
        print(io, "IOError: ", e.msg)
    elseif e isa SystemError
        print(io, "SystemError: ", e.prefix, ": ", Libc.strerror(e.errnum))
    elseif e isa PlatformEngines.Downloads.RequestError
        showerror(io, e)
    elseif e isa Base.TOML.ParserError
        showerror(io, e)
    else
        show_other_error(io, e)
    end
    return nothing
end
@noinline show_other_error(io::IO, @nospecialize(e)) = showerror(io, e)
message_text(@nospecialize(m)) = m isa String ? m : m isa SubString{String} ? String(m) : "(a message this build cannot print)"

end # module PkgEntry
