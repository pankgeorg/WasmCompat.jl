# Compile the package manager (the patched Pkg behind the entry shim) to Wasm with WasmCodegen.
#
#   julia test/pkg/build.jl [--shim DIR] [--work DIR] [--out DIR] [--patch FILE ...] [--load DIR ...]
#                           [--trim safe|unsafe] [--verify error|warn|off] [--tasks none|jspi]
#                           [--wasm-opt "-O3 -g"] [--setup-only]
#
# --shim   the entry shim package (default test/pkg/shim/<the one package there>): its module
#          defines `pkgentry_abi_version()`, `pkgentry_init()` and `pkgentry_main()` (each
#          `::Int32`, the module's exports of the same names; see js/run.mjs) and optionally
#          `sanitize_globals!()` (a pre-image hook)
# --work   apply_patches.jl's work dir (default test/pkg/work): Pkg.jl, WasmCodegen.jl,
#          WasmBuilder.jl, IRStructurizer.jl, WasmHost.jl, LibGit2_wasm_jll.jl, PCRE2_wasm_jll.jl
# --out    outputs (default test/pkg/out): module/pkgentry.wasm (+ libpcre2-8.wasm, libgit2.wasm
#          beside it), module/pkgentry.wasm.build.toml (the build report), build-env/, and the
#          relocation test's sentinel/ and relocation-cache/
# --patch  extra patch files (`Config(extra_patches)`; they see the shim module by its name and `Pkg`),
#          after test/pkg/patches/*.jl and <shim>/../build-patches/*.jl (the harness's and the
#          shim's patches, always applied, each in name order)
# --load   extra packages, added to the build environment and loaded before compiling
# --wasm-opt  Binaryen's wasm-opt options (`Config(optimize)`; default "-O3 -g": optimized, with
#          the name section kept for trap stacks). Always optimized: they must include -O3.
#
# The build runs in a generated environment whose [sources] point at the checkouts and at this
# repository (WasmCompat). Before the shim is loaded, the environment-derived inputs are set to
# *sentinels*: anything the image captures from the build host's environment instead of reading
# it at run time shows up as a sentinel string in the module bytes, which this script reports
# and the relocation test (scenarios.jl relocation) fails on. Pkg's session state is poisoned
# for the same test (poison!).

import TOML
include(joinpath(@__DIR__, "imagescan.jl"))
include(joinpath(@__DIR__, "base_globals.jl"))

const HERE = @__DIR__
const REPO = normpath(joinpath(HERE, "..", ".."))   # WasmCompat.jl
const NODE = get(ENV, "NODE", "node")
const PKG_UUID = Base.UUID("44cfe95a-1eb2-52ea-b672-e2afdf69b78f")
const SOURCES = ["WasmCodegen", "WasmBuilder", "IRStructurizer", "WasmHost", "Pkg", "LibGit2_wasm_jll", "PCRE2_wasm_jll"]

function parse_args(args)
    o = Dict{String, Any}("work" => joinpath(HERE, "work"), "out" => joinpath(HERE, "out"), "patches" => String[],
                          "load" => String[], "trim" => "unsafe", "verify" => "warn", "tasks" => "jspi",
                          "setup_only" => false, "wasm_opt" => "-O3 -g")
    i = 1
    val() = (i < length(args) || error("$(args[i]) needs a value"); i += 1; args[i])
    while i <= length(args)
        a = args[i]
        if a == "--shim"; o["shim"] = abspath(val())
        elseif a == "--work"; o["work"] = abspath(val())
        elseif a == "--out"; o["out"] = abspath(val())
        elseif a == "--patch"; push!(o["patches"], abspath(val()))
        elseif a == "--load"; push!(o["load"], abspath(val()))
        elseif a == "--trim"; o["trim"] = val()
        elseif a == "--verify"; o["verify"] = val()
        elseif a == "--tasks"; o["tasks"] = val()
        elseif a == "--wasm-opt"; o["wasm_opt"] = val()
        elseif a == "--setup-only"; o["setup_only"] = true
        else error("unknown argument $a")
        end
        i += 1
    end
    if !haskey(o, "shim")
        d = joinpath(HERE, "shim")
        c = isdir(d) ? filter(x -> isfile(joinpath(d, x, "Project.toml")), readdir(d)) : String[]
        length(c) == 1 || error("--shim: test/pkg/shim/ holds $(length(c)) packages ($(c)); name one")
        o["shim"] = joinpath(d, only(c))
    end
    o["trim"] in ("safe", "unsafe") || error("--trim must be safe or unsafe")
    o["verify"] in ("error", "warn", "off") || error("--verify must be error, warn or off")
    o["tasks"] in ("none", "jspi") || error("--tasks must be none or jspi")
    for n in SOURCES
        isfile(joinpath(o["work"], n * ".jl", "Project.toml")) || error("no $n checkout in $(o["work"]) (run apply_patches.jl)")
    end
    jls(d) = isdir(d) ? sort!(filter(f -> endswith(f, ".jl"), readdir(d; join = true))) : String[]
    o["patches"] = [jls(joinpath(HERE, "patches")); jls(joinpath(dirname(o["shim"]), "build-patches")); o["patches"]]
    for p in o["patches"]
        isfile(p) || error("patch file $p does not exist")
    end
    o["module"] = joinpath(o["out"], "module", "pkgentry.wasm")
    return o
end

sentinel_root(o) = joinpath(o["out"], "sentinel")
cache_poison_root(o) = joinpath(o["out"], "relocation-cache")
# Values the image must not capture; the entry's init reads the real ones from WASI's env. They
# are real directories (each with a SENTINEL file), which the relocation test preopens as decoys
# to show that they are never accessed.
sentinels(o) = Dict(
    "HOME" => joinpath(sentinel_root(o), "home"),
    "TMPDIR" => joinpath(sentinel_root(o), "tmp"),
    "JULIA_DEPOT_PATH" => joinpath(sentinel_root(o), "depot"),
    "JULIA_PROJECT" => joinpath(sentinel_root(o), "project"),
    "PWD" => joinpath(sentinel_root(o), "cwd"),
    "JULIA_PKG_SERVER" => "http://pkgentry-sentinel.invalid",
    "JULIA_PKG_OFFLINE" => "true",                   # must not leak into the image's OFFLINE_MODE
    "JULIA_PKG_GC_AUTO" => "true",
    "JULIA_PKG_PRECOMPILE_AUTO" => "1",
)
const BUILD_HOME = homedir()   # (before the sentinels replace HOME)
# Strings whose presence in the module means a build-host value was embedded.
host_markers(o, env_dir) = unique!(filter(!isempty, [
    "pkgentry-sentinel", sentinel_root(o), o["out"], o["work"], REPO, env_dir, Sys.BINDIR, BUILD_HOME, homedir(), DEPOT_PATH...,
]))

function git_info(dir)
    q(c) = readchomp(pipeline(c; stderr = devnull))
    rev = try q(`git -C $dir rev-parse HEAD`) catch; "unknown (not a git checkout)" end
    dirty = try !isempty(q(`git -C $dir status --porcelain --untracked-files=no`)) catch; true end
    return Dict("path" => dir, "commit" => rev, "dirty" => dirty)
end

# The build environment: the checkouts, this repository and the shim, by path.
function setup_env(o)
    env = joinpath(o["out"], "build-env")
    mkpath(env)
    deps, sources = Dict{String, String}(), Dict{String, Any}()
    for dir in [[joinpath(o["work"], n * ".jl") for n in SOURCES]; REPO; o["shim"]; o["load"]]
        p = TOML.parsefile(joinpath(dir, "Project.toml"))
        deps[p["name"]] = p["uuid"]
        sources[p["name"]] = Dict("path" => dir)
    end
    # the standard libraries the program and WasmCompat's extensions use
    for (n, u) in ("LibGit2" => "76f85450-5226-5b5a-8eaa-529ad045b433", "TOML" => "fa267f1f-6049-4f14-aa54-33bafae1ed76",
                   "Tar" => "a4e569a6-e804-4fa4-b0f3-eef7a1d5b13e", "ArgTools" => "0dad84c5-d112-42e6-8d28-ef12dabb789f",
                   "Artifacts" => "56f22d72-fd6d-98f1-02f0-08ddc0907c33", "Logging" => "56ddb016-857b-54e1-b83d-db4d58db5568",
                   "FileWatching" => "7b1f6079-737a-58dc-b8bc-7a2ca5c1b5ee")
        deps[n] = u
    end
    open(io -> TOML.print(io, Dict("deps" => deps, "sources" => sources); sorted = true), joinpath(env, "Project.toml"), "w")
    rm(joinpath(env, "Manifest.toml"); force = true)   # (re-resolved against the checkouts)
    return env
end

function module_interface(file)
    js = """
    const m = new WebAssembly.Module(require('fs').readFileSync(process.argv[1]));
    console.log(JSON.stringify({imports: WebAssembly.Module.imports(m).map(i => i.module + '.' + i.name + ':' + i.kind),
                                exports: WebAssembly.Module.exports(m).map(e => e.name + ':' + e.kind)}));"""
    out = read(`$NODE -e $js $file`, String)
    m = match(r"\"imports\":\[(.*?)\],\"exports\":\[(.*?)\]", out)
    split_list(s) = isempty(s) ? String[] : [strip(x, '"') for x in split(s, "\",\"")]
    return split_list(m.captures[1]), split_list(m.captures[2])
end

function main(args)
    o = parse_args(args)
    env = setup_env(o)
    run(`$(Base.julia_cmd()) --startup-file=no --project=$env -e "import Pkg; Pkg.instantiate(); Pkg.status()"`)
    Base.ACTIVE_PROJECT[] = env
    o["setup_only"] && (println("build env ready: $env"); return 0)

    for d in ("home", "tmp", "depot", "project", "cwd")
        mkpath(joinpath(sentinel_root(o), d))
        write(joinpath(sentinel_root(o), d, "SENTINEL"), "build-time sentinel; must never be accessed at run time\n")
    end
    for (k, v) in sentinels(o)
        ENV[k] = v
    end
    shim = Symbol(TOML.parsefile(joinpath(o["shim"], "Project.toml"))["name"])
    @eval using WasmCodegen, WasmCompat, WasmHost, PCRE2_wasm_jll, LibGit2_wasm_jll, LibGit2
    @eval using $shim
    for dir in o["load"]
        n = Symbol(TOML.parsefile(joinpath(dir, "Project.toml"))["name"])
        @eval using $n
    end
    # the Pkg compiled must be the patched checkout
    P = Base.loaded_modules[Base.PkgId(PKG_UUID, "Pkg")]
    pkgdir = joinpath(o["work"], "Pkg.jl")
    startswith(pathof(P), pkgdir * "/") || error("build.jl: the shim loaded Pkg from $(pathof(P)), not from $pkgdir")
    o["pkg_loaded_from"] = pathof(P)
    # anything that captures DEPOT_PATH/LOAD_PATH at build time captures the sentinels too
    push!(DEPOT_PATH, joinpath(sentinel_root(o), "depot"))
    push!(LOAD_PATH, joinpath(sentinel_root(o), "project"))
    latest(name) = Base.invokelatest(getfield, Main, name)
    return Base.invokelatest(build, o, env, latest(:WasmCodegen), latest(:WasmCompat), latest(shim), P)
end

# Pkg's in-memory state, poisoned with distinguishable build-time values, so that an image
# that captures it instead of re-initialising it fails the relocation scenarios:
#  - REGISTRY_CACHE holds a decoy "General" (same UUID, only a fake Example 9.9.9, package info
#    parsed) loaded from <relocation-cache>/depot. The cache is keyed by path and validated only
#    by tree hash, so the decoy claims the *frozen* tree hash: the relocation case
#    "S-add@cache-key" runs S-add with its depot at exactly that path, and a surviving cache then
#    serves the decoy (no JSON, Example 9.9.9): a divergence;
#  - UPDATED_REGISTRY_THIS_SESSION = true (would skip the registry update S-fail/S-add do);
#  - OFFLINE_MODE = true (would make S-add/S-fail fail without network).
frozen_tree_hash() = TOML.parsefile(joinpath(HERE, "fixtures", "frozen.toml"))["registry_tree_hash"]

function write_decoy_registry(depot)
    r = joinpath(depot, "registries", "General")
    mkpath(joinpath(r, "E", "Example"))
    write(joinpath(r, "Registry.toml"), """
        name = "General"
        uuid = "23338594-aafe-5451-b93e-139f81909106"
        repo = "https://pkgentry-sentinel.invalid/decoy-General.git"
        description = "DECOY registry from the build host; must never be used at runtime"
        [packages]
        7876af07-990d-54b4-ab0e-23690620f79a = { name = "Example", path = "E/Example" }
        """)
    write(joinpath(r, "E", "Example", "Package.toml"), """
        name = "Example"
        uuid = "7876af07-990d-54b4-ab0e-23690620f79a"
        repo = "https://pkgentry-sentinel.invalid/Example.jl.git"
        """)
    write(joinpath(r, "E", "Example", "Versions.toml"), """
        ["9.9.9"]
        git-tree-sha1 = "0000000000000000000000000000000000000000"
        """)
    write(joinpath(r, ".tree_info.toml"), "git-tree-sha1 = \"$(frozen_tree_hash())\"\n")
    return r
end

function poison!(o, P::Module)
    done = String[]
    depot = joinpath(cache_poison_root(o), "depot")
    rm(cache_poison_root(o); force = true, recursive = true)
    write_decoy_registry(depot)
    try
        regs = P.Registry.reachable_registries(; depots = [depot])
        for reg in regs, (uuid, pkg) in reg   # (package info parsed and cached)
            P.Registry.registry_info(reg, pkg)
        end
        push!(done, "REGISTRY_CACHE: decoy General ($(length(P.Registry.REGISTRY_CACHE)) entries)")
    catch e
        push!(done, "REGISTRY_CACHE: NOT poisoned ($(sprint(showerror, e)))")
    end
    for g in (:UPDATED_REGISTRY_THIS_SESSION, :OFFLINE_MODE)
        if isdefined(P, g)
            getfield(P, g)[] = true
            push!(done, "Pkg.$g = true")
        else
            push!(done, "Pkg.$g: not defined")
        end
    end
    return done
end

# Strings only the poisoned build-time state contains: the decoy registry's description and
# repo. If the image holds the build-time REGISTRY_CACHE (or any registry object loaded from
# the decoy), these bytes are in the module.
const POISON_MARKERS = ["DECOY registry from the build host", "decoy-General.git", "pkgentry-sentinel.invalid/Example.jl"]

function build(o, env, WC::Module, WCompat::Module, S::Module, P::Module)
    poisoned = poison!(o, P)
    bad = filter(p -> occursin("NOT poisoned", p) || occursin("not defined", p), poisoned)
    isempty(bad) || error("build.jl: poisoning Pkg's state failed, refusing to build (the relocation test would be vacuous):\n  " * join(bad, "\n  "))

    for f in (:pkgentry_abi_version, :pkgentry_init, :pkgentry_main)
        isdefined(S, f) || error("build.jl: the shim $(nameof(S)) defines no $f")
    end
    entries = [WC.Entry(getfield(S, f), (); name = string(f)) for f in (:pkgentry_abi_version, :pkgentry_init, :pkgentry_main)]
    # Base's and the shim's globals, emptied inside compile right before the image is emitted
    hooks, hook_report = Any[BuildBaseGlobals.sanitize_base_globals!], ["BuildBaseGlobals.sanitize_base_globals!"]
    if isdefined(S, :sanitize_globals!)
        push!(hooks, getfield(S, :sanitize_globals!)); push!(hook_report, "$(nameof(S)).sanitize_globals!")
    end
    config = WC.Config(;
        host = :wasi, host_extensions = [:julia_io],
        pre_image_hooks = hooks,
        trim = Symbol(o["trim"]), verify = Symbol(o["verify"]),
        tasks = Symbol(o["tasks"]),
        optimize = Cmd(String.(split(o["wasm_opt"]))),
        on_unsupported = o["trim"] == "safe" ? :error : :trap,
        extra_patches = o["patches"], patch_bindings = Pair{Symbol, Any}[nameof(S) => S, :Pkg => P])
    # Base's Regex on PCRE2 and LibGit2 on libgit2, both compiled to Wasm (WasmCompat's
    # backends); their modules go next to the program, where js/run.mjs looks for them
    config = Base.invokelatest(WCompat.pcre2_config, config)
    mkpath(dirname(o["module"]))
    cp(Base.invokelatest(WCompat.pcre2_module), joinpath(dirname(o["module"]), "libpcre2-8.wasm"); force = true)
    config = Base.invokelatest(WCompat.libgit2_config, config)
    cp(Base.invokelatest(WCompat.libgit2_module), joinpath(dirname(o["module"]), "libgit2.wasm"); force = true)
    # Only optimized modules are tested: the final config must run wasm-opt -O3 (never
    # `optimize = nothing`, never a raw module)
    opt = getfield(config, :optimize)
    (opt isa Cmd && "-O3" in opt.exec) ||
        error("build.jl: Config(optimize) is $(repr(opt)); modules are only tested optimized with wasm-opt -O3")
    optimize = join(opt.exec, ' ')

    t0 = time()
    status, err, comp, err_bt = "ok", "", nothing, ""
    failure_diags = String[]      # (trim = :safe: the constructs of an UnsupportedConstructs)
    verifier_report = nothing     # juliac's verifier (TrimFailure, or the world's trim_report)
    try
        comp = Base.invokelatest(WC.compile, entries; config)
    catch e
        status, err = "failed", sprint(showerror, e)
        err_bt = sprint(Base.show_backtrace, catch_backtrace())
        if hasfield(typeof(e), :errors) && e.errors isa Vector
            failure_diags = [string(mi, " => ", sprint(showerror, d)) for (mi, d) in e.errors]
        end
        if hasfield(typeof(e), :report) && e.report isa String
            verifier_report = e.report
        end
    end
    if comp !== nothing && hasfield(typeof(comp.world), :trim_report) && isassigned(comp.world.trim_report)
        verifier_report = comp.world.trim_report[]
    end
    elapsed = round(time() - t0; digits = 1)

    binaryen = get(Base.loaded_modules, Base.PkgId(Base.UUID("a54ac8ab-712d-5a0e-8e11-9296c0d3c20e"), "Binaryen_jll"), nothing)
    # (Binaryen_jll's product is `wasmdis`)
    wasm_dis = "wasm-dis"
    for n in (:wasmdis_path, :wasm_dis_path)
        binaryen !== nothing && isdefined(binaryen, n) && (wasm_dis = getfield(binaryen, n); break)
    end
    ENV["WASM_DIS"] = wasm_dis
    report = Dict{String, Any}(
        "status" => status, "error" => first(err, 20_000),
        "date" => string(Libc.strftime("%Y-%m-%dT%H:%M:%S", time())),
        "julia" => string(VERSION),
        "inputs" => merge(Dict(n => git_info(joinpath(o["work"], n * ".jl")) for n in SOURCES),
                          Dict("WasmCompat" => git_info(REPO), "shim" => git_info(o["shim"]), "patches" => o["patches"],
                               "load" => [git_info(d) for d in o["load"]], "pkg_loaded_from" => o["pkg_loaded_from"])),
        "config" => Dict("trim" => o["trim"], "verify" => o["verify"], "tasks" => o["tasks"], "host" => "wasi",
                         "optimize" => optimize,
                         "host_extensions" => ["julia_io"]),
        "sentinels" => sentinels(o),
        "poisoned" => poisoned,
        "pre_image_hooks" => hook_report,
        "wasm_dis" => wasm_dis,
        "optimize" => optimize,
        "elapsed_s" => elapsed, "maxrss_mib" => round(Sys.maxrss() / 2^20; digits = 1))
    isempty(err_bt) || (report["error_backtrace"] = first(err_bt, 60_000))
    if !isempty(failure_diags)
        report["diagnostics_count"] = length(failure_diags)
        report["diagnostics"] = first(failure_diags, 2000)
    end
    if verifier_report !== nothing
        vfile = o["module"] * ".verifier.txt"
        write(vfile, verifier_report)
        report["verifier_errors"] = length(collect(eachmatch(r"^Error #\d+:"m, verifier_report)))
        report["verifier_warnings"] = length(collect(eachmatch(r"^Warning #\d+:"m, verifier_report)))
        report["verifier_report_file"] = vfile
        report["verifier_report_head"] = first(verifier_report, 4_000)
    end
    if comp !== nothing
        write(o["module"], comp.bytes)
        diags = comp.cgm.diagnostics
        report["size_bytes"] = length(comp.bytes)
        report["diagnostics_count"] = length(diags)
        report["diagnostics"] = first([string(mi, " => ", sprint(showerror, d)) for (mi, d) in diags], 500)
        imps, exps = module_interface(o["module"])
        report["imports"] = imps
        report["exports"] = exps
        report["host_markers"] = host_markers(o, env)
        report["poison_markers"] = [POISON_MARKERS; joinpath(cache_poison_root(o), "depot", "registries", "General")]
        report["cache_poison_root"] = cache_poison_root(o)
        # log-macro source paths (`.jl` files of the checked-out source trees) are exempt and
        # reported separately; every other build-host string is flagged
        # (every checked-out source tree compiled into the module: the work dir's checkouts, this
        # repository's src/ and ext/, the shim, the standard library)
        roots = [[joinpath(o["work"], n * ".jl") for n in SOURCES]; joinpath(REPO, "src"); joinpath(REPO, "ext"); o["shim"]; Sys.STDLIB]
        report["exempt_source_roots"] = roots
        try
            fm, flagged, ignored = classify_host_strings(o["module"], report["host_markers"], roots)
            report["embedded_host_strings"] = fm
            report["embedded_host_strings_flagged"] = first(flagged, 200)
            report["ignored_source_paths"] = ignored
            report["ignored_source_paths_count"] = length(ignored)
        catch e
            report["embedded_host_strings"] = ["scan failed: " * sprint(showerror, e)]
        end
        report["poison_strings_found"] = try scan_markers(o["module"], report["poison_markers"]) catch e; ["scan failed: " * sprint(showerror, e)] end
    end
    open(io -> TOML.print(io, report; sorted = true), o["module"] * ".build.toml", "w")
    println("build $status in $(elapsed)s; report: $(o["module"]).build.toml")
    for k in ("optimize", "size_bytes", "diagnostics_count", "verifier_errors", "verifier_warnings", "maxrss_mib", "embedded_host_strings",
              "poison_strings_found", "ignored_source_paths_count")
        haskey(report, k) && println("  ", k, " = ", report[k])
    end
    for x in first(get(report, "embedded_host_strings_flagged", String[]), 20)
        println("  flagged_host_string = ", repr(x))
    end
    ign = get(report, "ignored_source_paths", String[])
    for x in first(ign, 30)
        println("  ignored_source_path = ", x)
    end
    length(ign) > 30 && println("  ignored_source_path = ... ($(length(ign) - 30) more in the build report)")
    status == "ok" || println(stderr, err, "\n", err_bt)
    return status == "ok" ? 0 : 1
end

if abspath(PROGRAM_FILE) == @__FILE__
    exit(main(ARGS))
end
