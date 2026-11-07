# The scenarios of fixtures/scenarios.toml, natively and in Wasm. Julia 1.13.
#
#   julia test/pkg/scenarios.jl prepare [--force]
#       Build the initial states fixtures/initial/{empty,registry,two,two-compressed} with the
#       native Pkg through the frozen server (fills fixtures/cache).
#   julia test/pkg/scenarios.jl baseline [S...]
#       Run scenarios natively and store <out>/native/<S>/ (project/, out/, server.log,
#       summary.toml): the expected results of the Wasm runs.
#   julia test/pkg/scenarios.jl run --impl native|wasm [--wasm FILE] [S...]
#       Run scenarios into <out>/wasm/<S>/ (native: <out>/native-rerun/<S>/) and compare each
#       with <out>/native/<S>.
#       (--impl native: a second native run, which checks that the scenario is deterministic.)
#   julia test/pkg/scenarios.jl relocation --wasm FILE [S...]
#       The relocation test of a build.jl module (see relocation()).
#   julia test/pkg/scenarios.jl report [--require S,...] [--native-only]
#       A Markdown table (scenario | Wasm | native | EQUIVALENT?) of <out>/results/, on stdout;
#       exit 1 unless every scenario's Wasm run (and relocation, if it ran) is EQUIVALENT to
#       its native baseline (--native-only: the native rerun instead of the Wasm run).
#
# Options of every subcommand:
#   --work DIR   the sources (apply_patches.jl's work dir; default test/pkg/work): the native
#                Pkg is <work>/Pkg.jl, the Node adapters <work>/WasmCodegen.jl/js and
#                <work>/WasmHost.jl/js/node
#   --out DIR    outputs (default test/pkg/out)
#   --offline    the frozen server serves only fixtures/cache
#
# With no scenario names, all scenarios in fixtures/scenarios.toml run, in file order. Each
# command runs in a fresh process (native) or a fresh Wasm instance. Every `run` writes
# <out>/results/<impl>-<S>.toml. Exit status: 0 iff every scenario is equivalent.

import TOML
include(joinpath(@__DIR__, "compare.jl"))
include(joinpath(@__DIR__, "imagescan.jl"))

const ROOT = @__DIR__
const FIX = realpath(joinpath(ROOT, "fixtures"))   # (a real path: outputs name the run dir one way only)
const FROZEN = TOML.parsefile(joinpath(FIX, "frozen.toml"))
const SCEN_FILE = joinpath(FIX, "scenarios.toml")
scenario_names() = [String(m.captures[1]) for m in eachmatch(r"^\[(S-[A-Za-z0-9-]+)\]"m, read(SCEN_FILE, String))]
const SCENARIOS = TOML.parsefile(SCEN_FILE)
const JULIA_EXE = joinpath(Sys.BINDIR, Base.julia_exename())
const NODE = get(ENV, "NODE", "node")
# (Node 24 aborts when a node:wasi fast API call allocates on a JSPI stack)
const NODE_FLAGS = split(get(ENV, "NODE_FLAGS", "--no-turbo-fast-api-calls"))

# set by main()
const OPT = Dict{String, String}("work" => joinpath(ROOT, "work"), "out" => joinpath(ROOT, "out"))
work_dir() = OPT["work"]
out_dir() = OPT["out"]
pkg_dir() = joinpath(work_dir(), "Pkg.jl")

# ---------------------------------------------------------------- frozen server
struct Server
    proc::Base.Process
    url::String
end
function start_server(log::AbstractString; offline::Bool = false)
    args = [NODE, joinpath(ROOT, "js", "pkgserver.mjs"), "--log", log]
    offline && push!(args, "--offline")
    out = Pipe()
    proc = run(pipeline(Cmd(args); stdout = out, stderr = stderr); wait = false)
    close(out.in)
    t = @async readline(out)
    if timedwait(() -> istaskdone(t), 30.0) !== :ok
        kill(proc, Base.SIGKILL)
        error("frozen server printed no LISTENING line within 30 s")
    end
    line = fetch(t)
    m = match(r"^LISTENING (http://127\.0\.0\.1:\d+)$", line)
    m === nothing && (kill(proc, Base.SIGKILL); error("frozen server failed to start: $(repr(line))"))
    return Server(proc, m.captures[1])
end
# SIGTERM (the server aborts fills and exits within 2 s), then SIGKILL after 10 s; always reaped.
function stop_server(s::Server)
    process_running(s.proc) && kill(s.proc)
    if timedwait(() -> !process_running(s.proc), 10.0) !== :ok
        kill(s.proc, Base.SIGKILL)
    end
    wait(s.proc)
    return nothing
end

# ---------------------------------------------------------------- the native Pkg
# An environment that tracks the patched Pkg by path, and a depot stacked *behind* each
# scenario depot that holds its precompiled cache (primed once), so scenario depots stay free
# of compiled/ and native runs don't recompile Pkg.
native_env_dir() = joinpath(out_dir(), "native-pkg-env")
native_cache_depot() = joinpath(out_dir(), "native-depot")
const NATIVE_READY = Ref(false)
function ensure_native()
    NATIVE_READY[] && return
    isfile(joinpath(pkg_dir(), "Project.toml")) || error("no Pkg checkout at $(pkg_dir()); run apply_patches.jl first")
    env, depot = native_env_dir(), native_cache_depot()
    mkpath(env); mkpath(depot)
    e = Dict{String, String}(k => v for (k, v) in ENV if !startswith(k, "JULIA_"))
    e["JULIA_DEPOT_PATH"] = depot * ":"
    e["JULIA_PKG_OFFLINE"] = "true"
    e["JULIA_PKG_PRECOMPILE_AUTO"] = "0"
    m = joinpath(env, "Manifest.toml")
    if !(isfile(m) && occursin(repr(pkg_dir()), read(m, String)))
        rm(m; force = true)
        run(setenv(`$JULIA_EXE --startup-file=no --project=$env -e 'import Pkg; Pkg.develop(path = ARGS[1])' $(pkg_dir())`, e))
    end
    # prime the cache (in the cache depot, then the first depot), checking it is the patched Pkg
    code = "pushfirst!(LOAD_PATH, $(repr(env))); P = Base.require(Base.PkgId(Base.UUID(\"44cfe95a-1eb2-52ea-b672-e2afdf69b78f\"), \"Pkg\")); " *
           "startswith(pathof(P), $(repr(pkg_dir() * "/"))) || error(\"loaded \$(pathof(P))\"); println(\"native Pkg: \", pathof(P))"
    run(setenv(`$JULIA_EXE --startup-file=no -e $code`, e))
    for sub in ("registries", "packages")   # (Pkg.develop must not have installed any)
        rm(joinpath(depot, sub); force = true, recursive = true)
    end
    NATIVE_READY[] = true
end

# The native host platform's tags, which the Wasm runner passes to the module (its
# HostPlatform() is then the same, and so is the Julia-System header it sends). julia_version
# is the module's own.
function platform_tags()
    t = Base.BinaryPlatforms.tags(Base.BinaryPlatforms.HostPlatform())
    return sort!([(String(k), String(v)) for (k, v) in t if k != "julia_version"])
end

# ---------------------------------------------------------------- environments
# The env policy (frozen.toml [env]) plus per-run paths. Nothing else is inherited except
# PATH, so the caller's JULIA_* settings cannot leak into the results.
function run_env(rundir::AbstractString, server::Server; native::Bool)
    env = Dict{String, String}(String(k) => String(v) for (k, v) in FROZEN["env"])
    env["PATH"] = get(ENV, "PATH", "/usr/bin:/bin")
    env["HOME"] = joinpath(rundir, "home")
    env["TMPDIR"] = joinpath(rundir, "tmp")
    env["PWD"] = rundir
    env["JULIA_PROJECT"] = joinpath(rundir, "project")
    # native: the cache depot of the native Pkg, then (trailing ':') the bundled depots
    # (precompiled stdlibs, no registries); wasm: the scenario depot only
    env["JULIA_DEPOT_PATH"] = joinpath(rundir, "depot") * (native ? ":" * native_cache_depot() * ":" : "")
    env["JULIA_PKG_SERVER"] = server.url
    haskey(ENV, "PKGENTRY_TRACE") && (env["PKGENTRY_TRACE"] = ENV["PKGENTRY_TRACE"])
    return env
end
# a scenario's own env entries (`env = {...}` in scenarios.toml)
scenario_env!(env, sc) = (for (k, v) in get(sc, "env", Dict{String, Any}()); env[String(k)] = String(v); end; env)
# `{rundir}` in a command's arguments (file:// URLs of the fixture repositories)
expand_args(args, rundir) = String[replace(a, "{rundir}" => rstrip(rundir, '/')) for a in args]

# ---------------------------------------------------------------- initial states
const INIT_KINDS = ("empty", "registry", "two", "two-compressed")
initial_dir(kind) = joinpath(FIX, "initial", kind)

function fresh_rundir(rundir)
    rm(rundir; force = true, recursive = true)
    for d in ("depot", "project", "home", "tmp", "out")
        mkpath(joinpath(rundir, d))
    end
    return rundir
end

# Remove depot state that is host/time specific and not part of the fixture.
function scrub_depot(depot)
    for d in ("logs", "compiled", "servers")
        rm(joinpath(depot, d); force = true, recursive = true)
    end
end

function native_cmd(rundir, env, args; errfile = "")
    ensure_native()
    e = copy(env)
    e["PKGENTRY_NATIVE_PKG_ENV"] = native_env_dir()
    e["PKGENTRY_NATIVE_PKG_DIR"] = pkg_dir()
    isempty(errfile) || (e["PKGENTRY_ERROR_FILE"] = errfile)
    return setenv(`$JULIA_EXE --startup-file=no --history-file=no $(joinpath(ROOT, "native_pkg.jl")) $args`, e; dir = rundir)
end

# A template is valid if it holds exactly the frozen registry (content-verified), or no
# registry for "empty", and every Manifest source is installed.
function template_errors(kind)
    dir = initial_dir(kind)
    s = summarize(dir)
    kind == "empty" && return isempty(s["registries"]) && isempty(s["packages"]) ? String[] : ["empty template is not empty"]
    return validity_errors(dir, s)
end

# Native runs append the native Pkg's cache depot and the bundled depots after the scenario
# depot. They must not hold package or registry inputs, or native runs could use sources the
# Wasm run (scenario depot only) cannot see.
function check_extra_depots(depots)
    for d in depots, sub in ("registries", "packages")
        p = joinpath(d, sub)
        isdir(p) && !isempty(readdir(p)) && error("extra depot $d has a non-empty $sub/; native runs would see non-fixture inputs")
    end
end
const BUNDLED_DEPOTS = [abspath(Sys.BINDIR, "..", "local", "share", "julia"), abspath(Sys.BINDIR, "..", "share", "julia")]
native_extra_depots() = [BUNDLED_DEPOTS; native_cache_depot()]

function prepare(; force = false, offline = false)
    ensure_native()
    check_extra_depots(native_extra_depots())
    mkpath(joinpath(FIX, "initial"))
    work = joinpath(FIX, "initial", ".work")
    rm(work; force = true, recursive = true)
    server = start_server(joinpath(FIX, "initial", "prepare-server.log"); offline)
    try
        for kind in INIT_KINDS
            dst = initial_dir(kind)
            if isdir(dst) && !force
                v = template_errors(kind)
                isempty(v) || error("prepare: existing template $kind is invalid (rebuild with --force):\n  " * join(v, "\n  "))
                println("prepare: $kind exists and is valid (use --force to rebuild)")
                continue
            end
            fresh_rundir(work)
            env = run_env(work, server; native = true)
            if kind == "registry" || kind == "two"
                e = copy(env); e["JULIA_PKG_UNPACK_REGISTRY"] = "true"
                run(native_cmd(work, e, ["registry-add-default"]))
            end
            if kind == "two"
                run(native_cmd(work, env, ["add", "Example", "JSON"]))
            end
            if kind == "two-compressed"
                # the "two" recipe with the registry in stock layout, registries/{CACHEDIR.TAG,
                # General.toml, General.tar.zst}, as stock Pkg 1.13 writes it by default (no
                # JULIA_PKG_UNPACK_REGISTRY)
                run(native_cmd(work, env, ["registry-add-default"]))
                run(native_cmd(work, env, ["add", "Example", "JSON"]))
                isempty(packed_layout_errors(joinpath(work, "depot"), nothing)) ||
                    error("prepare two-compressed: not the stock packed layout: $(packed_layout_errors(joinpath(work, "depot"), nothing))")
            end
            scrub_depot(joinpath(work, "depot"))
            rm(dst; force = true, recursive = true)
            mkpath(dst)
            for d in ("depot", "project")
                mv(joinpath(work, d), joinpath(dst, d))
            end
            v = template_errors(kind)
            isempty(v) || error("prepare: freshly built template $kind is invalid:\n  " * join(v, "\n  "))
            println("prepare: built $kind")
        end
    finally
        stop_server(server)
        rm(work; force = true, recursive = true)
    end
end

# Setup steps named in scenarios.toml
function apply_setup(step, rundir)
    proj = joinpath(rundir, "project")
    if step == "edit-resolve"
        f = joinpath(proj, "Project.toml")
        p = TOML.parsefile(f)
        delete!(p["deps"], "JSON")
        p["compat"] = Dict("Example" => "0.5")
        open(io -> TOML.print(io, p; sorted = true), f, "w")
    elseif step == "git-fixture"
        # the package repository and git registry of the git scenarios, in <rundir>/git
        isdefined(@__MODULE__, :GitFixture) || include(joinpath(ROOT, "git_fixture.jl"))
        Base.invokelatest(getfield(@__MODULE__, :GitFixture).make, rundir)
    elseif step == "rm-artifacts"
        # (before a command) the installed artifacts leave the depot
        adir = joinpath(rundir, "depot", "artifacts")
        for n in (isdir(adir) ? readdir(adir) : String[])
            occursin(r"^[0-9a-f]{40}$", n) || continue
            run(`chmod -R u+w $(joinpath(adir, n))`)   # (in case the tree is read-only)
            rm(joinpath(adir, n); recursive = true)
        end
    elseif step == "copy-instantiate"
        for f in ("Project.toml", "Manifest.toml")
            cp(joinpath(FIX, "instantiate", f), joinpath(proj, f); force = true)
        end
    else
        error("unknown setup step $(repr(step))")
    end
end

function setup_scenario(name, rundir)
    sc = SCENARIOS[name]
    fresh_rundir(rundir)
    src = initial_dir(sc["init"])
    isdir(src) || error("initial state $(sc["init"]) missing; run `scenarios.jl prepare` first")
    for d in ("depot", "project")
        rm(joinpath(rundir, d); recursive = true)
        run(`cp -a $(joinpath(src, d)) $(joinpath(rundir, d))`)
    end
    for step in get(sc, "setup", String[])
        apply_setup(step, rundir)
    end
end

# ---------------------------------------------------------------- run one scenario
# The Node runner's adapters: WasmCodegen's js/ (julia_io, julia_task) and WasmHost's js/node
wcg_js() = get(ENV, "WCG_JS", joinpath(work_dir(), "WasmCodegen.jl", "js"))
wasmhost_js() = get(ENV, "WASMHOST_JS", joinpath(work_dir(), "WasmHost.jl", "js", "node"))

function wasm_cmd(rundir, env, args; wasm, network, trace = "", extra_dirs = String[])
    # js/run.mjs: identity-mapped preopen of the run dir only (plus decoys for the relocation
    # test), explicit env, networking off for offline scenarios, every path access traced, the
    # native host's platform tags.
    flags = ["--wasm", wasm, "--dir", rundir]
    for d in extra_dirs
        push!(flags, "--dir", d)
    end
    isempty(trace) || push!(flags, "--trace-fs", trace, "--timing", trace * ".timing.json")
    for k in sort!(collect(keys(env)))
        k == "PATH" && continue
        push!(flags, "--env", "$k=$(env[k])")
    end
    network || push!(flags, "--no-network")
    for (k, v) in platform_tags()
        push!(flags, "--platform-tag", "$k=$v")
    end
    e = Dict{String, String}("PATH" => get(ENV, "PATH", "/usr/bin:/bin"), "WCG_JS" => wcg_js(), "WASMHOST_JS" => wasmhost_js())
    return setenv(`$NODE $NODE_FLAGS $(joinpath(ROOT, "js", "run.mjs")) $flags -- $args`, e; dir = rundir)
end

# Stock packed-registry layout (S-compressed): depot/registries holds exactly CACHEDIR.TAG,
# General.toml, General.tar.zst, with the two registry files byte-identical to the template's
# (no unpack, no rewrite), and no registries/General dir.
const PACKED_FILES = ["CACHEDIR.TAG", "General.tar.zst", "General.toml"]
function packed_layout_errors(depot, template_depot)
    d = String[]
    regs = joinpath(depot, "registries")
    got = isdir(regs) ? sort(readdir(regs)) : String[]
    got == PACKED_FILES || push!(d, "registries/ holds $(got), expected exactly $(PACKED_FILES)")
    if template_depot !== nothing
        for f in ("General.toml", "General.tar.zst")
            a, b = joinpath(template_depot, "registries", f), joinpath(regs, f)
            isfile(b) && read(a) == read(b) || push!(d, "registries/$f is not byte-identical to the template")
        end
    end
    return d
end

# Expected registry layout after command i: `registry_layout = "packed"` (every step) or
# `registry_layout_steps = ["packed", ..., "none"]` (registry rm). "none": no registry
# files at all in depot/registries (CACHEDIR.TAG may remain).
function layout_at(sc, i)
    steps = get(sc, "registry_layout_steps", nothing)
    steps === nothing || return steps[i]
    return get(sc, "registry_layout", "")
end
last_layout(sc) = layout_at(sc, length(sc["commands"]))
function step_layout_errors(sc, i, rundir)
    l = layout_at(sc, i)
    l == "packed" && return packed_layout_errors(joinpath(rundir, "depot"), joinpath(initial_dir(sc["init"]), "depot"))
    if l == "none"
        regs = joinpath(rundir, "depot", "registries")
        left = isdir(regs) ? filter(!=("CACHEDIR.TAG"), readdir(regs)) : String[]
        return isempty(left) ? String[] : ["registries/ still holds $(left)"]
    end
    return String[]
end

# The native Pkg on a *copy* of the final depot + project (the run dir stays the comparison
# input): the registry must still load as :packed, and Registry.status/status/resolve work.
function stock_packed_check(rundir)
    ensure_native()
    ad = joinpath(rundir, "stock-after")
    rm(ad; force = true, recursive = true); mkpath(ad)
    for x in ("depot", "project", "home", "tmp")
        run(`cp -a $(joinpath(rundir, x)) $(joinpath(ad, x))`)
    end
    srv = start_server(joinpath(ad, "server.log"); offline = true)
    code = try
        e = run_env(ad, srv; native = true)
        prog = "pushfirst!(LOAD_PATH, $(repr(native_env_dir()))); " *
               "Pkg = Base.require(Base.PkgId(Base.UUID(\"44cfe95a-1eb2-52ea-b672-e2afdf69b78f\"), \"Pkg\")); popfirst!(LOAD_PATH); " *
               "Pkg.Registry.status(); Pkg.status(); Pkg.resolve(); " *
               "r = only(Pkg.Registry.reachable_registries()); " *
               "Pkg.Registry.get_registry_type(r) == :packed || error(\"registry is not :packed\")"
        run(pipeline(ignorestatus(setenv(`$JULIA_EXE --startup-file=no -e $prog`, e; dir = ad));
                     stdout = joinpath(ad, "stdout.txt"), stderr = joinpath(ad, "stderr.txt"))).exitcode
    finally
        stop_server(srv)
    end
    return code == 0 ? String[] : ["native Pkg on a copy of the final depot: exit $code (see $ad/stderr.txt)"]
end

# Per-command evidence: the environment, the installed packages and the server requests made
# by command i (the server log is written synchronously per request).
function record_step(rundir, i)
    out = joinpath(rundir, "out")
    pdir = mkpath(joinpath(out, "$i.project"))
    for f in ("Project.toml", "Manifest.toml")
        src = joinpath(rundir, "project", f)
        isfile(src) && cp(src, joinpath(pdir, f); force = true)
    end
    open(io -> TOML.print(io, package_summary(joinpath(rundir, "depot")); sorted = true),
         joinpath(out, "$i.packages.toml"), "w")
    # installed artifacts (hash => content tree hash) after this command
    open(io -> TOML.print(io, artifact_summary(joinpath(rundir, "depot")); sorted = true),
         joinpath(out, "$i.artifacts.toml"), "w")
    # path-tracked sources (develop): their trees after this command
    open(io -> TOML.print(io, path_sources(joinpath(rundir, "project")); sorted = true),
         joinpath(out, "$i.path_sources.toml"), "w")
    # the registries after this command (identity, storage, content) and the keys of Pkg's
    # registry update log (scratchspaces/<Pkg uuid>/registry_updates.toml; timestamps ignored)
    regs = Dict{String, Any}("registries" => registry_summary(joinpath(rundir, "depot")),
                             "listing" => registry_listing(joinpath(rundir, "depot")),
                             "update_log_keys" => registry_update_log_keys(joinpath(rundir, "depot")))
    open(io -> TOML.print(io, regs; sorted = true), joinpath(out, "$i.registries.toml"), "w")
    log = readlines_or_empty(joinpath(rundir, "server.log"))
    seen = sum((length(readlines_or_empty(joinpath(out, "$j.requests"))) for j in 1:i-1); init = 0)
    write(joinpath(out, "$i.requests"), join(log[seen+1:end], "\n") * (length(log) > seen ? "\n" : ""))
end

function run_scenario(name, rundir; impl = "native", wasm = "", offline = false, extra_dirs = String[])
    sc = SCENARIOS[name]
    impl == "wasm" || (ensure_native(); check_extra_depots(native_extra_depots()))
    setup_scenario(name, rundir)
    network = get(sc, "network", true)
    server = start_server(joinpath(rundir, "server.log"); offline)
    layout_viol = String[]
    t0 = time()
    try
        for (i, args) in enumerate(sc["commands"])
            # `before = { <i> = [steps...] }`: setup steps applied right before command i
            for step in get(get(sc, "before", Dict{String, Any}()), string(i), String[])
                apply_setup(step, rundir)
            end
            env = scenario_env!(run_env(rundir, server; native = impl != "wasm"), sc)
            args = expand_args(args, rundir)
            out = joinpath(rundir, "out")
            cmd = impl == "wasm" ? wasm_cmd(rundir, env, args; wasm, network, extra_dirs, trace = joinpath(out, "$i.fstrace")) :
                                   native_cmd(rundir, env, args; errfile = joinpath(out, "$i.error"))
            p = run(pipeline(ignorestatus(cmd); stdout = joinpath(out, "$i.stdout"), stderr = joinpath(out, "$i.stderr")))
            write(joinpath(out, "$i.exit"), string(p.exitcode))
            record_step(rundir, i)
            for e in step_layout_errors(sc, i, rundir)
                push!(layout_viol, "after command $i: $e")
            end
            # (a Wasm run reports its error text only on stderr; compare.jl matches the tail)
        end
    finally
        stop_server(server)
    end
    elapsed = round(time() - t0; digits = 1)
    viol = copy(layout_viol)
    last_layout(sc) == "packed" && append!(viol, stock_packed_check(rundir))
    if impl == "wasm"
        # every path the module touched is inside the scenario dir
        # (trace lines: import \t dirfd \t raw \t resolved; "!..." = absolute/unknown-fd/unreadable)
        root = rstrip(rundir, '/')
        for i in eachindex(sc["commands"]), l in readlines_or_empty(joinpath(rundir, "out", "$i.fstrace"))
            f = split(l, '\t')
            if length(f) != 4
                push!(viol, "command $i: malformed trace record $(repr(l))")
                continue
            end
            f[1] == "wasi.fd_renumber" && !startswith(f[4], "!") && continue   # provenance record
            p = unescape_trace(f[4])
            startswith(p, root * "/") || p == root || push!(viol, "command $i accessed $(repr(p)) outside the scenario dir ($l)")
        end
    end
    if !network
        reqs = isfile(joinpath(rundir, "server.log")) ? readlines(joinpath(rundir, "server.log")) : String[]
        isempty(reqs) || push!(viol, "offline scenario made $(length(reqs)) server request(s): $(first(reqs))")
    end
    return elapsed, viol
end

# Canonical path: resolve symlinks of the nearest existing ancestor.
function canonpath(p)
    p = abspath(p); rest = String[]
    while !ispath(p) && dirname(p) != p
        pushfirst!(rest, basename(p)); p = dirname(p)
    end
    return joinpath(realpath(p), rest...)
end
path_inside(p, root) = startswith(canonpath(p) * "/", rstrip(canonpath(root), '/') * "/")
readlines_or_empty(f) = isfile(f) ? readlines(f) : String[]
# inverse of run.mjs's escField: \\ \t \n \r
unescape_trace(x) = replace(x, r"\\[\\tnr]" => m -> m[2] == '\\' ? "\\" : m[2] == 't' ? "\t" : m[2] == 'n' ? "\n" : "\r")

baseline_dir(name) = joinpath(out_dir(), "native", name)
compare_with_baseline(name, rundir) =
    compare(baseline_dir(name), rundir; bytes = true,
            compare_error = get(SCENARIOS[name], "compare_error", false),
            compare_stdout = get(SCENARIOS[name], "compare_stdout", false),
            compare_stderr = get(SCENARIOS[name], "compare_stderr", false),
            mask_rundir = get(SCENARIOS[name], "mask_rundir", false),
            final_registry = get(SCENARIOS[name], "final_registry", "frozen"))

# One result file per scenario and implementation, for `report`
function write_result(impl, name, ok, checks, elapsed; rundir = "", notes = String[])
    d = joinpath(out_dir(), "results")
    mkpath(d)
    exits = isdir(joinpath(rundir, "out")) ? command_outputs(rundir)[1] : Int[]
    r = Dict{String, Any}("scenario" => name, "impl" => impl, "equivalent" => ok, "elapsed_s" => elapsed,
                          "exits" => exits, "expect_exit" => get(get(SCENARIOS, name, Dict{String, Any}()), "expect_exit", Int[]),
                          "failed_checks" => [c.name for c in checks if !c.ok],
                          "details" => [l for c in checks if !c.ok for l in first(c.detail, 5)],
                          "notes" => notes)
    open(io -> TOML.print(io, r; sorted = true), joinpath(d, "$impl-$name.toml"), "w")
end

# The relocation test: the module was built by build.jl with sentinel env/paths
# (<out>/sentinel/*) and poisoned Pkg state (decoy registry cache, flags). Run scenarios with
# those sentinel dirs preopened as decoys, and assert: results equivalent; no traced access
# under the sentinel root; sentinel dirs byte-identical afterwards; the build report lists no
# embedded host strings. S-add/S-fail need fresh registry discovery and network, so a
# build-time cached decoy registry, OFFLINE_MODE or UPDATED_REGISTRY_THIS_SESSION surviving
# into the image (build.jl poisons all three) makes them diverge.
function relocation(; wasm, names = ["S-status", "S-resolve", "S-rm", "S-add", "S-fail"])
    sroot = joinpath(out_dir(), "sentinel")
    isdir(sroot) || error("no $sroot: build the module with build.jl (same --out) first")
    decoys = sort!(filter(isdir, readdir(sroot; join = true)))
    snapshot() = Dict(d => tree_hash_string(d) * ":" * join(sort(readdir(d)), ",") for d in decoys)
    before = snapshot()
    allok = true
    out = joinpath(out_dir(), "relocation")
    for name in names
        rundir = joinpath(out, name)
        elapsed, viol = run_scenario(name, rundir; impl = "wasm", wasm, extra_dirs = decoys)
        checks, br = compare_with_baseline(name, rundir)
        # (accesses to the decoys are already flagged as "outside the scenario dir")
        isempty(viol) || push!(checks, Check("relocation", false, viol))
        ok = report(stdout, checks, br; label = "$name [relocation, $(elapsed)s]")
        write_result("relocation", name, ok, checks, elapsed; rundir)
        allok &= ok
    end
    # cache-key collision: build.jl cached a decoy registry (frozen tree hash, Example 9.9.9
    # only) under <cache_poison_root>/depot; S-add run at exactly that path diverges if the
    # build-time REGISTRY_CACHE survived into the image.
    rep0 = wasm * ".build.toml"
    croot = isfile(rep0) ? get(TOML.parsefile(rep0), "cache_poison_root", "") : ""
    ck = if isempty(croot)
        [Check("cache-key", false, ["build report has no cache_poison_root"])]
    elseif path_inside(wasm, croot) || path_inside(rep0, croot)
        # (setup wipes croot; never delete the module under test)
        [Check("cache-key", false, ["module $wasm lies inside the cache-collision dir $croot, which this case wipes; build it elsewhere"])]
    else
        elapsed, viol = run_scenario("S-add", croot; impl = "wasm", wasm, extra_dirs = decoys)
        c, _ = compare(baseline_dir("S-add"), croot; bytes = true)
        isempty(viol) || push!(c, Check("relocation", false, viol))
        c
    end
    ok = report(stdout, ck, String[]; label = "S-add@cache-key [relocation]")
    write_result("relocation", "S-add@cache-key", ok, ck, 0.0)
    allok &= ok
    after = snapshot()
    d = String[]
    notes = String[]
    before == after || push!(d, "sentinel dirs changed: $(setdiff(collect(before), collect(after)))")
    if isfile(rep0)
        r = TOML.parsefile(rep0)
        # the build's scan of the module (decoded GC byte arrays + raw bytes) for its markers;
        # rescanned here when the build's wasm-dis exists on this machine (it may not: CI runs
        # the relocation test on another runner)
        rescan = isfile(get(r, "wasm_dis", ""))
        rescan && (ENV["WASM_DIS"] = r["wasm_dis"])
        # build-host strings, except log-macro source paths (`.jl` files of the source trees),
        # which are listed with a count
        if haskey(r, "host_markers")
            fm, flagged, ignored = rescan ? classify_host_strings(wasm, r["host_markers"], get(r, "exempt_source_roots", String[])) :
                (get(r, "embedded_host_strings", ["build report lacks embedded_host_strings"]),
                 get(r, "embedded_host_strings_flagged", String[]), get(r, "ignored_source_paths", String[]))
            isempty(fm) || push!(d, "module embeds build-host strings: $(fm)" *
                                    (isempty(flagged) ? "" : "\n  e.g. " * join(repr.(first(flagged, 10)), "\n  e.g. ")))
            push!(notes, "ignored $(length(ignored)) log-macro source path(s) (.jl files of the source trees)" *
                         (isempty(ignored) ? "" : ": " * join(ignored, ", ")))
        else
            push!(d, "build report lacks host_markers")
        end
        hits = haskey(r, "poison_markers") ? (rescan ? scan_markers(wasm, r["poison_markers"]) : get(r, "poison_strings_found", ["build report lacks poison_strings_found"])) :
               ["build report lacks poison_markers"]
        isempty(hits) || push!(d, "module embeds build-time poisoned Pkg state: $(hits)")
        p = get(r, "poisoned", String[])
        (length(p) >= 3 && !any(x -> occursin("NOT", x) || occursin("not defined", x), p)) ||
            push!(d, "build was not fully poisoned: $(p)")
    else
        push!(d, "no build report $rep0")
    end
    sc = [Check("sentinels", isempty(d), d)]
    ok = report(stdout, sc, String[]; label = "relocation sentinels")
    foreach(n -> println("  note      ", n), notes)
    write_result("relocation", "sentinels", ok, sc, 0.0; notes)
    return allok & ok
end

function baseline(names; offline = false)
    allok = true
    for name in names
        tmp = joinpath(out_dir(), "native", ".run-" * name)
        dst = baseline_dir(name)
        rm(dst; force = true, recursive = true)
        elapsed, viol = run_scenario(name, tmp; impl = "native", offline)
        v = copy(viol)
        append!(v, validity_errors(tmp, summarize(tmp); registry = get(SCENARIOS[name], "final_registry", "frozen")))
        exits = command_outputs(tmp)[1]
        exits == SCENARIOS[name]["expect_exit"] || push!(v, "exits $exits != expected $(SCENARIOS[name]["expect_exit"]); see $tmp/out")
        ok = isempty(v)
        checks = ok ? Check[] : [Check("baseline", false, v)]
        write_result("baseline", name, ok, checks, elapsed; rundir = tmp)
        if !ok
            println("baseline $name: FAILED ($(elapsed)s)\n  ", join(v, "\n  "))
            for i in eachindex(exits)   # (the stderr of each failed command, for the log)
                exits[i] == SCENARIOS[name]["expect_exit"][i] && continue
                f = joinpath(tmp, "out", "$i.stderr")
                isfile(f) && println("  --- command $i stderr (tail)\n", indent_tail(read(f, String)))
            end
            allok = false
            continue
        end
        sm = summarize(tmp)
        sm["kind"] = "baseline"
        open(io -> TOML.print(io, sm; sorted = true), joinpath(tmp, "summary.toml"), "w")
        mkpath(dst)
        for d in ("project", "out")
            cp(joinpath(tmp, d), joinpath(dst, d))
        end
        for f in ("server.log", "summary.toml")
            cp(joinpath(tmp, f), joinpath(dst, f))
        end
        rm(tmp; recursive = true)
        println("baseline $name: ok ($(elapsed)s, exits $exits)")
    end
    return allok
end
indent_tail(s; n = 40) = (l = split(rstrip(s), '\n'); "    " * join(l[max(1, end - n + 1):end], "\n    "))

function run_and_compare(names; impl, wasm, offline)
    allok = true
    for name in names
        # (native: a rerun, beside the baselines, never over them)
        rundir = joinpath(out_dir(), impl == "native" ? "native-rerun" : impl, name)
        if !isdir(baseline_dir(name))
            ck = [Check("baseline", false, ["no native baseline $(baseline_dir(name)) (run `scenarios.jl baseline` first, or it failed)"])]
            report(stdout, ck, String[]; label = "$name [$impl]")
            write_result(impl, name, false, ck, 0.0)
            allok = false
            continue
        end
        elapsed, viol = run_scenario(name, rundir; impl, wasm, offline)
        checks, br = compare_with_baseline(name, rundir)
        isempty(viol) || push!(checks, Check("run", false, viol))   # network / layout / access checks
        ok = report(stdout, checks, br; label = "$name [$impl, $(elapsed)s]")
        write_result(impl, name, ok, checks, elapsed; rundir)
        allok &= ok
    end
    return allok
end

# ---------------------------------------------------------------- report
function report_table(io::IO; require = String[], native_only = false)
    d = joinpath(out_dir(), "results")
    res = Dict{Tuple{String, String}, Dict{String, Any}}()
    for f in (isdir(d) ? readdir(d; join = true) : String[])
        endswith(f, ".toml") || continue
        r = TOML.parsefile(f)
        res[(r["impl"], r["scenario"])] = r
    end
    cell(r) = r === nothing ? "–" :
        string(r["equivalent"] ? "✅" : "❌", " exits ", join(r["exits"], ","), " (", r["elapsed_s"], " s)",
               isempty(r["failed_checks"]) ? "" : ": " * join(r["failed_checks"], ", "))
    names = isempty(require) ? scenario_names() : require
    allok = true
    println(io, "| scenario | Wasm | native | EQUIVALENT? |")
    println(io, "|---|---|---|---|")
    for n in names
        w, b = get(res, ("wasm", n), nothing), get(res, ("baseline", n), nothing)
        nat = get(res, ("native", n), nothing)
        eq = b !== nothing && b["equivalent"] &&
             (native_only ? nat !== nothing && nat["equivalent"] : w !== nothing && w["equivalent"])
        allok &= eq
        ncell = b === nothing ? "–" : string(b["equivalent"] ? "✅" : "❌", " exits ", join(b["exits"], ","), " (", b["elapsed_s"], " s)",
                                             nat === nothing ? "" : nat["equivalent"] ? ", rerun ✅" : ", rerun ❌ " * join(nat["failed_checks"], ", "))
        println(io, "| ", n, " | ", cell(w), " | ", ncell, " | ", eq ? "**EQUIVALENT**" : "NOT EQUIVALENT", " |")
    end
    reloc = sort!([k[2] for k in keys(res) if k[1] == "relocation"])
    if !isempty(reloc)
        println(io, "\n| relocation | result |\n|---|---|")
        for n in reloc
            r = res[("relocation", n)]
            allok &= r["equivalent"]
            println(io, "| ", n, " | ", cell(r), " |")
        end
        s = get(res, ("relocation", "sentinels"), nothing)
        if s !== nothing
            for l in get(s, "details", String[])
                println(io, "\n- sentinels: ", replace(first(l, 2000), "\n" => " "))
            end
            for l in get(s, "notes", String[])
                println(io, "\n- sentinels: ", first(l, 6000))
            end
        end
    end
    return allok
end

function main(args)
    isempty(args) && (println(stderr, "usage: see the header of test/pkg/scenarios.jl"); return 2)
    sub, rest = args[1], args[2:end]
    opt(flag, default) = (i = findfirst(==(flag), rest)) === nothing ? default : (v = rest[i + 1]; deleteat!(rest, i:i+1); v)
    flag(f) = (i = findfirst(==(f), rest)) === nothing ? false : (deleteat!(rest, i); true)
    OPT["work"] = abspath(opt("--work", OPT["work"]))
    OPT["out"] = abspath(opt("--out", OPT["out"]))
    offline = flag("--offline")
    names() = isempty(rest) ? scenario_names() : rest
    if sub == "prepare"
        prepare(; force = flag("--force"), offline)
        return 0
    elseif sub == "baseline"
        return baseline(names(); offline) ? 0 : 1
    elseif sub == "run"
        impl = opt("--impl", "native")
        wasm = abspath(opt("--wasm", joinpath(out_dir(), "module", "pkgentry.wasm")))
        impl in ("native", "wasm") || error("unknown --impl $impl")
        return run_and_compare(names(); impl, wasm, offline) ? 0 : 1
    elseif sub == "relocation"
        wasm = abspath(opt("--wasm", joinpath(out_dir(), "module", "pkgentry.wasm")))
        return relocation(; wasm, (isempty(rest) ? () : (; names = rest))...) ? 0 : 1
    elseif sub == "report"
        req = opt("--require", "")
        native_only = flag("--native-only")
        return report_table(stdout; require = isempty(req) ? String[] : split(req, ','), native_only) ? 0 : 1
    else
        println(stderr, "unknown subcommand $sub")
        return 2
    end
end

if abspath(PROGRAM_FILE) == @__FILE__
    exit(main(ARGS))
end
