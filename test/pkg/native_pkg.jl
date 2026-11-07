# Native command driver: the native twin of the Wasm module's entry point.
#
#   julia --startup-file=no test/pkg/native_pkg.jl <cmd> [words...]
#
# cmd ∈ add, develop, rm, resolve, instantiate, status, gc (gc [-v|--verbose] [--all]),
# registry (registry <add|rm|update|status> [regs...]); add/develop with arguments other than
# package names (`url#rev`, paths, `:subdir`) go through the Pkg REPL's syntax, as the Wasm
# entry parses them.
#
# Pkg: the checkout named by PKGENTRY_NATIVE_PKG_ENV, an environment whose manifest tracks the
# patched Pkg by path (scenarios.jl makes it), loaded instead of the standard library's Pkg;
# without it, the standard library's. The environment (depot, project, server, Pkg knobs)
# comes from the caller, exactly as the Wasm runner passes it through WASI. Exit code: 0 on
# success, 1 on a reported error (its text printed with `showerror` to stderr and also written
# to $PKGENTRY_ERROR_FILE if set, for compare.jl).

const PKG_UUID = Base.UUID("44cfe95a-1eb2-52ea-b672-e2afdf69b78f")

const P = let env = get(ENV, "PKGENTRY_NATIVE_PKG_ENV", "")
    if isempty(env)
        Base.require(Base.PkgId(PKG_UUID, "Pkg"))
    else
        # only while loading Pkg: the commands see the caller's load path
        pushfirst!(LOAD_PATH, env)
        try
            Base.require(Base.PkgId(PKG_UUID, "Pkg"))
        finally
            popfirst!(LOAD_PATH)
        end
    end
end
let want = get(ENV, "PKGENTRY_NATIVE_PKG_DIR", "")
    # the Pkg under test, never the standard library's by accident
    isempty(want) || startswith(pathof(P), rstrip(want, '/') * "/") ||
        error("native_pkg.jl: loaded Pkg from $(pathof(P)), not from $want")
end

function run_cmd(args::Vector{String})
    isempty(args) && throw(ArgumentError("usage: native_pkg.jl <add|develop|rm|resolve|instantiate|status|gc|registry> [words...]"))
    cmd, pkgs = args[1], args[2:end]
    # (the REPL-in-a-script warning is not printed: the Wasm entry doesn't print it)
    quiet_repl() = isdefined(P.REPLMode, :PRINTED_REPL_WARNING) && (P.REPLMode.PRINTED_REPL_WARNING[] = true)
    if (cmd == "add" || cmd == "develop") && !all(p -> occursin(r"^[A-Za-z_][A-Za-z0-9_]*$", p), pkgs)
        quiet_repl()
        P.REPLMode.pkgstr(cmd * " " * join(pkgs, " "))
    elseif cmd == "add"
        isempty(pkgs) && throw(ArgumentError("add needs at least one package"))
        P.add(pkgs)
    elseif cmd == "develop"
        isempty(pkgs) && throw(ArgumentError("develop needs at least one package"))
        P.develop(pkgs)
    elseif cmd == "rm"
        isempty(pkgs) && throw(ArgumentError("rm needs at least one package"))
        P.rm(pkgs)
    elseif cmd == "resolve"
        isempty(pkgs) || throw(ArgumentError("resolve takes no packages"))
        P.resolve()
    elseif cmd == "instantiate"
        isempty(pkgs) || throw(ArgumentError("instantiate takes no packages"))
        P.instantiate()
    elseif cmd == "status"
        isempty(pkgs) || throw(ArgumentError("status takes no packages"))
        P.status()
    elseif cmd == "gc"
        quiet_repl()
        P.REPLMode.pkgstr(join(["gc"; pkgs], " "))
    elseif cmd == "registry"
        quiet_repl()
        P.REPLMode.pkgstr("registry " * join(pkgs, " "))
    elseif cmd == "registry-add-default"
        # (scenarios.jl prepare: the initial states' registry, as `Pkg.Registry.add()`)
        P.Registry.add()
    else
        throw(ArgumentError("unknown command $(repr(cmd))"))
    end
    return nothing
end

function main(args)
    try
        run_cmd(args)
        return 0
    catch e
        msg = sprint(showerror, e)
        print(stderr, msg)
        println(stderr)
        errfile = get(ENV, "PKGENTRY_ERROR_FILE", "")
        isempty(errfile) || write(errfile, msg)
        return 1
    end
end

exit(main(ARGS))
