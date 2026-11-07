# Equivalence oracle. Native Julia 1.13.2, stock stdlibs only.
#
#   julia test/pkg/compare.jl summarize <rundir> [<out.toml>]
#   julia test/pkg/compare.jl compare <expected> <actual> [--bytes] [--scenario NAME]
#
# A *run dir* is what test/pkg/scenarios.jl produces for one scenario:
#   <rundir>/project/{Project,Manifest}.toml   final environment
#   <rundir>/depot/                            final depot
#   <rundir>/out/<i>.{exit,stdout,stderr[,error]}   per command (i = 1, 2, ...)
#   <rundir>/server.log                        frozen-server request log
# A *baseline dir* (<out>/native/<S>, written by `scenarios.jl baseline`) holds project/, out/, server.log and
# summary.toml (the depot is summarised, not stored). `expected` and `actual` may each be
# a run dir or a baseline dir. A run dir (it has depot/) is always summarised from its live
# files; a summary.toml inside it is ignored.
#
# Checks (all must pass):
#   project   parsed Project.toml equal (every key)
#   manifest  parsed Manifest.toml equal (every key: julia_version, manifest_format,
#             project_hash, [registries], deps, versions, tree hashes, weakdeps, extensions ...)
#   packages  same set of depot/packages/<Name>/<slug> dirs, each with the same git tree
#             hash (computed from the extracted directory; covers file modes/exec bits),
#             and that hash equals the Manifest's git-tree-sha1 for that slug
#   registry  same installed registries by (name, uuid, tree hash); storage may differ
#             (unpacked directory vs tarball). Both get a content check: the directory's,
#             or the decompressed tarball's, git tree hash must equal the recorded hash.
#   exit      same exit code per command
#   error     (scenarios with compare_error) the normalised stderr of the actual run ends
#             with the normalised error text recorded by the expected run
#   stdout    (scenarios with compare_stdout, e.g. S-status) normalised stdout equal
#   frozen    every run ends with exactly the frozen registry (fixtures/frozen.toml)
#   sources   every Manifest entry with a tree hash is installed in the scenario depot
#   steps     per command: Project/Manifest, installed packages and fetched payloads after
#             each command (first instantiate installs, second is a no-op)
#   headers   same set of Julia-System request header values (the client's platform)
#   requests  same set of (method, path, status) requests to the frozen server, discovery
#             (/registries) included; sets, so repeat counts don't matter
#   --bytes   optional, reported separately: byte-identical Project/Manifest files
#
# Exit status: 0 equivalent, 1 not equivalent, 2 usage error.

import TOML, SHA, Tar, Zstd_jll

# Registry storage comparison. false: storage-agnostic (directory vs tarball allowed, identity
# + content only). true: same listing, storage and byte-identical descriptor/archive.
const STRICT_REGISTRY_LAYOUT = true
using Base: SHA1

# The host's platform triplet, as native Pkg sends it in the Julia-System header (the Wasm runner
# passes the same tags to the module)
host_triplet() = Base.BinaryPlatforms.triplet(Base.BinaryPlatforms.HostPlatform())

# ---------------------------------------------------------------- git tree hash
# Same algorithm as Pkg.GitTools.tree_hash (git's tree object hash, SHA-1), reimplemented
# here so the oracle does not depend on the Pkg under test. Empty directories are skipped
# like git does; modes are 100755 (any user-exec bit), 100644, 120000 (symlink), 40000.
function tree_hash(root::AbstractString; skip = ())
    ctx_entries = Tuple{String, String, Vector{UInt8}}[]   # (mode, name, raw hash)
    for name in readdir(root; sort = false)
        name in skip && continue                             # top level only
        path = joinpath(root, name)
        if islink(path)
            push!(ctx_entries, ("120000", name, blob_hash(Vector{UInt8}(readlink(path)))))
        elseif isdir(path)
            name == ".git" && continue
            h = tree_hash(path)
            h === nothing && continue
            push!(ctx_entries, ("40000", name, h))
        elseif isfile(path)
            mode = (filemode(path) & 0o100) != 0 ? "100755" : "100644"
            push!(ctx_entries, (mode, name, blob_hash(read(path))))
        else
            error("tree_hash: unsupported file type at $path")
        end
    end
    isempty(ctx_entries) && return nothing
    # git sorts entries by name, with directories compared as if they had a trailing '/'
    sortkey(e) = e[1] == "40000" ? e[2] * "/" : e[2]
    sort!(ctx_entries; by = sortkey)
    io = IOBuffer()
    for (mode, name, h) in ctx_entries
        write(io, mode, ' ', name, '\0', h)
    end
    body = take!(io)
    return SHA.sha1(vcat(Vector{UInt8}("tree $(length(body))\0"), body))
end
blob_hash(data::Vector{UInt8}) = SHA.sha1(vcat(Vector{UInt8}("blob $(length(data))\0"), data))
tree_hash_string(root; skip = ()) = (h = tree_hash(root; skip); h === nothing ? bytes2hex(SHA.sha1(b"tree 0\0")) : bytes2hex(h))

# ---------------------------------------------------------------- text normalisation
const ANSI = r"\e\[[0-9;?]*[ -/]*[@-~]"
function normalize_text(s::AbstractString, rundir::AbstractString = "")
    s = replace(String(s), "\r\n" => "\n", ANSI => "")
    isempty(rundir) || (s = replace(s, rstrip(rundir, '/') => "<RUN>"))
    lines = [rstrip(l) for l in split(s, '\n')]
    return strip(join(lines, '\n'))
end

# ---------------------------------------------------------------- summarise
function registry_summary(depot::AbstractString; content_check::Bool = true)
    regs = Dict{String, Any}[]
    regdir = joinpath(depot, "registries")
    isdir(regdir) || return regs
    for f in sort(readdir(regdir))
        p = joinpath(regdir, f)
        if isfile(p) && endswith(f, ".toml")
            d = TOML.parsefile(p)
            haskey(d, "path") || continue           # tarball registry pointer file
            tarball = joinpath(regdir, d["path"])
            e = Dict{String, Any}(
                "name" => f[1:end-5], "uuid" => d["uuid"], "tree_hash" => d["git-tree-sha1"],
                "storage" => "tarball", "tarball_present" => isfile(tarball),
                # for strict layout comparison: exact descriptor and archive bytes
                "descriptor_sha256" => bytes2hex(SHA.sha256(read(p))),
                "tarball_name" => d["path"],
                "tarball_sha256" => isfile(tarball) ? bytes2hex(open(SHA.sha256, tarball)) : "missing")
            # content: the git tree hash of the decompressed archive (encoding-agnostic)
            content_check && (e["content_hash"] = isfile(tarball) ? tarball_tree_hash(tarball) : "missing")
            push!(regs, e)
        elseif isdir(p) && isfile(joinpath(p, "Registry.toml")) && isdir(joinpath(p, ".git"))
            # a git registry: the tree of its HEAD; its work tree must be that
            # tree. Across runs it is identified by its files with the run dir masked (the fixture
            # registry records paths in the run dir)
            r = TOML.parsefile(joinpath(p, "Registry.toml"))
            th = readchomp(`git -C $p rev-parse HEAD^\{tree\}`)
            e = Dict{String, Any}("name" => r["name"], "uuid" => r["uuid"], "tree_hash" => th,
                                  "storage" => "git", "dirname" => f,
                                  "masked_files" => masked_digest(p, dirname(abspath(depot))))
            content_check && (e["content_hash"] = tree_hash_string(p))
            push!(regs, e)
        elseif isdir(p) && isfile(joinpath(p, "Registry.toml"))
            r = TOML.parsefile(joinpath(p, "Registry.toml"))
            ti = joinpath(p, ".tree_info.toml")
            th = isfile(ti) ? TOML.parsefile(ti)["git-tree-sha1"] : ""   # "" = git clone, unsupported here
            e = Dict{String, Any}("name" => r["name"], "uuid" => r["uuid"], "tree_hash" => th,
                                  "storage" => "directory", "dirname" => f)
            if content_check
                # .tree_info.toml is not part of the registry tree
                e["content_hash"] = tree_hash_string(p; skip = (".tree_info.toml",))
            end
            push!(regs, e)
        end
    end
    return regs
end

# SHA-256 over the files of a directory (outside .git; sorted relative paths, link targets,
# contents) with `rundir` replaced by <RUN>
function masked_digest(root::AbstractString, rundir::AbstractString)
    ctx = SHA.SHA256_CTX()
    for (dir, dirs, files) in walkdir(root)
        filter!(!=(".git"), dirs)
        for f in sort(files)
            p = joinpath(dir, f)
            body = islink(p) ? "-> " * readlink(p) : read(p, String)
            SHA.update!(ctx, codeunits(string(relpath(p, root), '\0', replace(body, rstrip(rundir, '/') => "<RUN>"), '\0')))
        end
    end
    return bytes2hex(SHA.digest!(ctx))
end

# Git tree hash of a gzip/zstd-compressed tarball, or "unreadable: <why>".
function tarball_tree_hash(file::AbstractString)
    magic = open(io -> read(io, 4), file)
    cmd = length(magic) >= 4 && magic == UInt8[0x28, 0xb5, 0x2f, 0xfd] ? `$(Zstd_jll.zstd()) -dc $file` :
          length(magic) >= 2 && magic[1:2] == UInt8[0x1f, 0x8b] ? `gzip -dc $file` : nothing
    cmd === nothing && return "unreadable: unknown compression magic $(bytes2hex(magic))"
    try
        return open(io -> Tar.tree_hash(io), pipeline(cmd; stderr = devnull))
    catch e
        return "unreadable: " * first(sprint(showerror, e), 200)
    end
end

# Keys (registry UUIDs) of Pkg's registry update log; the values are timestamps (ignored).
function registry_update_log_keys(depot::AbstractString)
    f = joinpath(depot, "scratchspaces", "44cfe95a-1eb2-52ea-b672-e2afdf69b78f", "registry_updates.toml")
    isfile(f) || return String[]
    return sort!(collect(keys(TOML.parsefile(f))))
end

# The names in depot/registries (strict layout comparison)
registry_listing(depot) = (r = joinpath(depot, "registries"); isdir(r) ? sort(readdir(r)) : String[])

function package_summary(depot::AbstractString)
    pkgs = Dict{String, String}()
    pdir = joinpath(depot, "packages")
    isdir(pdir) || return pkgs
    # packages/temp is Pkg's download staging area, not an installed package
    for name in sort(filter(n -> n != "temp" && isdir(joinpath(pdir, n)), readdir(pdir))), slug in sort(readdir(joinpath(pdir, name)))
        p = joinpath(pdir, name, slug)
        isdir(p) || continue
        pkgs["$name/$slug"] = tree_hash_string(p)
    end
    return pkgs
end

# Installed artifacts: depot/artifacts/<git-tree-sha1> => tree hash of its content (each must
# equal its name, checked by validity_errors and compare). Other entries (stock's temporary
# download dirs, pidfiles, CACHEDIR.TAG) are not artifacts.
function artifact_summary(depot::AbstractString)
    arts = Dict{String, String}()
    adir = joinpath(depot, "artifacts")
    isdir(adir) || return arts
    for name in sort(readdir(adir))
        p = joinpath(adir, name)
        (isdir(p) && !islink(p) && occursin(r"^[0-9a-f]{40}$", name)) || continue
        arts[name] = tree_hash_string(p)
    end
    return arts
end
# The non-artifact entries of depot/artifacts (CACHEDIR.TAG; a leftover temp dir or pidfile
# would show here)
# (a hash-named entry that is not a directory, e.g. a file or a symlink, is listed)
is_artifact_dir(a, n) = occursin(r"^[0-9a-f]{40}$", n) && isdir(joinpath(a, n)) && !islink(joinpath(a, n))
artifact_listing(depot) = (a = joinpath(depot, "artifacts"); isdir(a) ? sort(filter(n -> !is_artifact_dir(a, n), readdir(a))) : String[])

# The files Pkg's usage logs (depot/logs/{manifest,artifact,scratch}_usage.toml) record, which
# drive Pkg.gc; timestamps ignored, the run dir masked as <RUN>
function usage_log_keys(depot::AbstractString, rundir::AbstractString)
    d = Dict{String, Any}()
    for f in ("manifest_usage.toml", "artifact_usage.toml", "scratch_usage.toml")
        p = joinpath(depot, "logs", f)
        isfile(p) || continue
        d[f] = sort([replace(k, rstrip(rundir, '/') => "<RUN>") for k in keys(TOML.parsefile(p))])
    end
    return d
end

function request_summary(log::AbstractString)
    isfile(log) || return String[]
    reqs = Set{String}()
    for l in eachline(log)
        parts = split(l)
        length(parts) >= 4 || continue
        push!(reqs, "$(parts[2]) $(parts[3]) $(parts[4])")   # method path status
    end
    return sort!(collect(reqs))
end

# The set of Julia-System header values the frozen server received (log field sys=...,
# URI-encoded; "-" when the header was absent).
# Every request record must carry the field: a record without it, or with an empty value,
# contributes "<missing>" / "<empty>" so it can never vanish from the set.
function julia_system_summary(log::AbstractString)
    isfile(log) || return String[]
    vals = Set{String}()
    for l in eachline(log)
        length(split(l)) >= 4 || continue                 # not a request record (e.g. clientError)
        m = match(r" sys=(\S*)$", l)
        push!(vals, m === nothing ? "<missing>" : m.captures[1] == "" ? "<empty>" :
                    m.captures[1] == "-" ? "-" : unescape_uri(m.captures[1]))
    end
    return sort!(collect(vals))
end
function unescape_uri(x)
    io = IOBuffer(); i = 1; b = codeunits(x)
    while i <= length(b)
        if b[i] == UInt8('%') && i + 2 <= length(b)
            write(io, parse(UInt8, String(b[i+1:i+2]); base = 16)); i += 3
        else
            write(io, b[i]); i += 1
        end
    end
    return String(take!(io))
end

function command_outputs(rundir::AbstractString)
    outdir = joinpath(rundir, "out")
    n = 0
    while isfile(joinpath(outdir, "$(n + 1).exit"))
        n += 1
    end
    exits = [parse(Int, strip(read(joinpath(outdir, "$i.exit"), String))) for i in 1:n]
    errors = String[]
    for i in 1:n
        f = joinpath(outdir, "$i.error")
        push!(errors, isfile(f) ? normalize_text(read(f, String), rundir) : "")
    end
    return exits, errors
end

# Per-command evidence written by scenarios.jl after each command i:
#   out/<i>.packages.toml  depot packages (name/slug => tree hash) after command i
#   out/<i>.requests       server log lines produced during command i
# (and out/<i>.project/{Project,Manifest}.toml, compared directly from files).
function step_summaries(rundir, n)
    steps = Dict{String, Any}[]
    for i in 1:n
        pf = joinpath(rundir, "out", "$i.packages.toml")
        rf = joinpath(rundir, "out", "$i.requests")
        # incomplete step evidence is reported as missing (compare's "steps" check fails),
        # never read as "no requests"
        (isfile(pf) && isfile(rf)) || return Dict{String, Any}[]
        st = Dict{String, Any}("packages" => TOML.parsefile(pf), "requests" => request_summary(rf))
        gf = joinpath(rundir, "out", "$i.registries.toml")
        isfile(gf) && (st["registries"] = TOML.parsefile(gf))
        sf = joinpath(rundir, "out", "$i.path_sources.toml")
        isfile(sf) && (st["path_sources"] = TOML.parsefile(sf))
        af = joinpath(rundir, "out", "$i.artifacts.toml")
        isfile(af) && (st["artifacts"] = TOML.parsefile(af))
        push!(steps, st)
    end
    return steps
end

function summarize(rundir::AbstractString; content_check::Bool = true)
    rundir = abspath(rundir)
    depot = joinpath(rundir, "depot")
    exits, errors = command_outputs(rundir)
    return Dict{String, Any}(
        "rundir" => rundir,
        "steps" => step_summaries(rundir, length(exits)),
        "path_sources" => path_sources(joinpath(rundir, "project")),
        "exits" => exits,
        "errors" => errors,
        "packages" => package_summary(depot),
        "artifacts" => artifact_summary(depot),
        "artifact_listing" => artifact_listing(depot),
        "usage_logs" => usage_log_keys(depot, rundir),
        "registries" => registry_summary(depot; content_check),
        "registry_listing" => registry_listing(depot),
        "requests" => request_summary(joinpath(rundir, "server.log")),
        "julia_system" => julia_system_summary(joinpath(rundir, "server.log")),
    )
end

# A live run dir (it has a depot) is always summarised from its files, so a stale
# summary.toml can never stand in for the evidence; only a compact baseline dir (no depot)
# is read from its stored summary.
# `actual` is always a live run dir, summarised from its files; a missing depot is an
# error, never a reason to trust a stored summary. `expected` is a live run
# dir or a compact baseline whose summary.toml is marked kind = "baseline".
function load_summary(dir; live_only::Bool = false)
    isdir(joinpath(dir, "depot")) && return summarize(dir)
    live_only && error("$dir is not a live run dir (no depot/)")
    f = joinpath(dir, "summary.toml")
    isfile(f) || error("$dir is neither a run dir (no depot/) nor a baseline dir (no summary.toml)")
    s = TOML.parsefile(f)
    get(s, "kind", "") == "baseline" || error("$dir: summary.toml without depot/ is not marked kind = \"baseline\"")
    return s
end

# S-git: the run dir in every string value as <RUN>
function mask_run(x, rundir::AbstractString)
    root = rstrip(rundir, '/')
    x isa AbstractString && return replace(x, root => "<RUN>")
    x isa AbstractVector && return Any[mask_run(v, rundir) for v in x]
    x isa AbstractDict && return Dict{String, Any}(String(k) => mask_run(v, rundir) for (k, v) in x)
    return x
end

# A Manifest's project_hash where the two runs' Projects differ (by run-dir paths): not compared
# across runs, but each must be the hash stock Pkg computes for its own Project ("valid")
function project_hash_status(projdir::AbstractString)
    Pkg = Base.require(Base.PkgId(Base.UUID("44cfe95a-1eb2-52ea-b672-e2afdf69b78f"), "Pkg"))
    m = parse_toml_or_missing(joinpath(projdir, "Manifest.toml"))
    m === nothing && return "no manifest"
    h = Base.invokelatest() do
        Pkg.Types.workspace_resolve_hash(Pkg.Types.EnvCache(joinpath(projdir, "Project.toml")))
    end
    return get(m, "project_hash", nothing) == h ? "valid" : "invalid: $(get(m, "project_hash", nothing)) != $h"
end
function settle_project_hashes!(a, b, da::AbstractString, db::AbstractString)
    (a isa AbstractDict && b isa AbstractDict && haskey(a, "project_hash") && haskey(b, "project_hash")) || return
    pa, pb = joinpath(da, "Project.toml"), joinpath(db, "Project.toml")
    (isfile(pa) && isfile(pb) && read(pa) == read(pb)) && return     # same Project: compared as is
    a["project_hash"] = project_hash_status(da)
    b["project_hash"] = project_hash_status(db)
    return
end

# the sources of path-tracked Manifest entries (develop): name => git tree hash of the directory,
# with the run dir masked in the key's path
function path_sources(projdir::AbstractString)
    m = parse_toml_or_missing(joinpath(projdir, "Manifest.toml"))
    d = Dict{String, Any}()
    m === nothing && return d
    for (name, entries) in get(m, "deps", Dict()), e in entries
        haskey(e, "path") || continue
        p = isabspath(e["path"]) ? e["path"] : normpath(joinpath(projdir, e["path"]))
        d[name] = isdir(p) ? tree_hash_string(p) : "missing"
    end
    return d
end

# ---------------------------------------------------------------- diff
function diff_values!(out::Vector{String}, path::String, a, b)
    if a isa AbstractDict && b isa AbstractDict
        for k in sort!(collect(union(keys(a), keys(b))))
            p = isempty(path) ? string(k) : "$path.$k"
            if !haskey(b, k)
                push!(out, "$p: only in expected ($(repr(a[k])))")
            elseif !haskey(a, k)
                push!(out, "$p: only in actual ($(repr(b[k])))")
            else
                diff_values!(out, p, a[k], b[k])
            end
        end
    elseif a isa AbstractVector && b isa AbstractVector && length(a) == length(b)
        for i in eachindex(a)
            diff_values!(out, "$path[$i]", a[i], b[i])
        end
    elseif !(typeof(a) == typeof(b) && isequal(a, b))
        push!(out, "$path: expected $(repr(a)), actual $(repr(b))")
    end
    return out
end

parse_toml_or_missing(f) = isfile(f) ? TOML.parsefile(f) : nothing

function missing_sources(manifest_file, packages, lbl)
    d = String[]
    man = parse_toml_or_missing(manifest_file)
    man === nothing && return d
    for (name, entries) in get(man, "deps", Dict()), e in entries
        haskey(e, "git-tree-sha1") || continue
        slug = Base.version_slug(Base.UUID(e["uuid"]), SHA1(e["git-tree-sha1"]))
        haskey(packages, "$name/$slug") || push!(d, "$lbl: manifest package $name ($(e["git-tree-sha1"])) not installed at packages/$name/$slug")
    end
    return d
end

# the registries a run must end with: the frozen one, none, or `git:<name>:<uuid>`
function want_registries(final_registry::String, fz)
    final_registry == "none" && return Tuple{String, String, String}[]
    if startswith(final_registry, "git:")
        _, name, uuid = split(final_registry, ':')
        return [(String(name), String(uuid), "git")]
    end
    return [(fz["registry_name"], fz["registry_uuid"], fz["registry_tree_hash"])]
end
final_ident(r) = (r["name"], r["uuid"], get(r, "storage", "") == "git" ? "git" : r["tree_hash"])

# Baseline-independent validity of one run: it ends with exactly the frozen
# registry, content-verified, and every Manifest source is installed.
function validity_errors(dir, s; registry::String = "frozen")
    fz = TOML.parsefile(joinpath(@__DIR__, "fixtures", "frozen.toml"))
    want = registry == "none" ? Tuple{String, String, String}[] : want_registries(registry, fz)
    d = String[]
    got = sort([final_ident(r) for r in s["registries"]])
    got == want || push!(d, "registries $(got) != frozen $(want)")
    for r in s["registries"]
        get(r, "content_hash", "") == r["tree_hash"] ||
            push!(d, "registry $(r["name"]): content $(get(r, "content_hash", "unchecked")) != recorded $(r["tree_hash"])")
    end
    append!(d, missing_sources(joinpath(dir, "project", "Manifest.toml"), s["packages"], "run"))
    # the client platform seen by the server is the native host's
    # (offline scenarios make no requests: an empty set is valid there and only there)
    js = get(s, "julia_system", nothing)
    if js === nothing
        push!(d, "no Julia-System evidence recorded")
    elseif !isempty(s["requests"]) && js != [host_triplet()]
        push!(d, "Julia-System headers $(js) != [the native host's $(repr(host_triplet()))]")
    elseif isempty(s["requests"]) && !isempty(js)
        push!(d, "Julia-System values $(js) without request records")
    end
    # every installed artifact's content has the tree hash it is named by
    for (h, th) in get(s, "artifacts", Dict{String, Any}())
        h == th || push!(d, "run: artifacts/$h has tree hash $th")
    end
    # installed sources must also have the Manifest's tree hash
    man = parse_toml_or_missing(joinpath(dir, "project", "Manifest.toml"))
    if man !== nothing
        for (name, entries) in get(man, "deps", Dict()), e in entries
            haskey(e, "git-tree-sha1") || continue
            key = "$name/$(Base.version_slug(Base.UUID(e["uuid"]), SHA1(e["git-tree-sha1"])))"
            h = get(s["packages"], key, nothing)
            h === nothing || h == e["git-tree-sha1"] || push!(d, "run: packages/$key tree hash $h != manifest $(e["git-tree-sha1"])")
        end
    end
    return d
end

struct Check
    name::String
    ok::Bool
    detail::Vector{String}
end

function compare(expected::AbstractString, actual::AbstractString; bytes::Bool = false, compare_error::Bool = false,
                 compare_stdout::Bool = false, compare_stderr::Bool = false, final_registry::String = "frozen",
                 mask_rundir::Bool = false)
    checks = Check[]
    rundir_of(dir) = isdir(joinpath(dir, "depot")) ? abspath(dir) : get(TOML.parsefile(joinpath(dir, "summary.toml")), "rundir", "")
    mask_file(x, dir) = mask_rundir && x !== nothing ? mask_run(x, rundir_of(dir)) : x
    for (f, name) in (("Project.toml", "project"), ("Manifest.toml", "manifest"))
        a = mask_file(parse_toml_or_missing(joinpath(expected, "project", f)), expected)
        b = mask_file(parse_toml_or_missing(joinpath(actual, "project", f)), actual)
        mask_rundir && f == "Manifest.toml" && settle_project_hashes!(a, b, joinpath(expected, "project"), joinpath(actual, "project"))
        if a === nothing || b === nothing
            ok = a === nothing && b === nothing
            push!(checks, Check(name, ok, ok ? String[] : ["$f present: expected=$(a !== nothing) actual=$(b !== nothing)"]))
        else
            d = diff_values!(String[], "", a, b)
            push!(checks, Check(name, isempty(d), d))
        end
    end
    se = load_summary(expected)
    sa = try
        load_summary(actual; live_only = true)
    catch e
        push!(checks, Check("evidence", false, [sprint(showerror, e)]))
        return checks, String[]
    end
    # (S-git) the run dirs masked in both summaries and in the step files read below
    re_dir, ra_dir = get(se, "rundir", ""), get(sa, "rundir", abspath(actual))
    if mask_rundir
        se, sa = mask_run(se, re_dir), mask_run(sa, ra_dir)
    end
    masked(x, dir) = mask_rundir && x !== nothing ? mask_run(x, dir) : x

    # packages: same dirs, same tree hashes, consistent with the manifest
    d = diff_values!(String[], "packages", se["packages"], sa["packages"])
    man = parse_toml_or_missing(joinpath(actual, "project", "Manifest.toml"))
    if man !== nothing
        for (name, entries) in get(man, "deps", Dict()), e in entries
            haskey(e, "git-tree-sha1") || continue
            slug = Base.version_slug(Base.UUID(e["uuid"]), SHA1(e["git-tree-sha1"]))
            key = "$name/$slug"
            if haskey(sa["packages"], key) && sa["packages"][key] != e["git-tree-sha1"]
                push!(d, "packages.$key: extracted tree hash $(sa["packages"][key]) != manifest $(e["git-tree-sha1"])")
            end
        end
    end
    # path-tracked sources (develop): the same tree in both runs
    diff_values!(d, "path sources", get(se, "path_sources", Dict()), get(sa, "path_sources", Dict()))
    push!(checks, Check("packages", isempty(d), d))

    # artifacts: the same installed artifacts, each with the tree hash it is named by, and the
    # same other entries in depot/artifacts. (Baselines from before artifacts were compared have
    # no such keys: their stock depots had no artifacts, `artifacts` is then empty.)
    d = String[]
    diff_values!(d, "artifacts", get(se, "artifacts", Dict{String, Any}()), get(sa, "artifacts", Dict{String, Any}()))
    for (lbl, sm) in (("expected", se), ("actual", sa)), (h, th) in get(sm, "artifacts", Dict{String, Any}())
        h == th || push!(d, "$lbl: artifacts/$h has tree hash $th")
    end
    get(se, "artifact_listing", String[]) == get(sa, "artifact_listing", String[]) ||
        push!(d, "artifacts/ other entries: expected $(get(se, "artifact_listing", String[])), actual $(get(sa, "artifact_listing", String[]))")
    push!(checks, Check("artifacts", isempty(d), d))
    # Pkg's usage logs (what Pkg.gc reads): the same files recorded
    if haskey(se, "usage_logs")
        d = String[]
        diff_values!(d, "usage logs", se["usage_logs"], get(sa, "usage_logs", Dict{String, Any}()))
        push!(checks, Check("usage", isempty(d), d))
    end

    # registry identity (storage-agnostic) + content check of unpacked registries
    ident(r) = (r["name"], r["uuid"], get(r, "storage", "") == "git" ? get(r, "masked_files", "") : r["tree_hash"])
    d = String[]
    ie, ia = sort(ident.(se["registries"])), sort(ident.(sa["registries"]))
    ie == ia || push!(d, "registries: expected $(ie), actual $(ia)")
    for s in (se, sa), r in s["registries"]
        if haskey(r, "content_hash") && r["content_hash"] != r["tree_hash"]
            push!(d, "registry $(r["name"]) ($(s === se ? "expected" : "actual")): directory content hash $(r["content_hash"]) != recorded $(r["tree_hash"])")
        end
        if get(r, "storage", "") == "tarball" && !get(r, "tarball_present", true)
            push!(d, "registry $(r["name"]): tarball missing")
        end
        if !haskey(r, "content_hash")
            push!(d, "registry $(r["name"]) ($(s === se ? "expected" : "actual")): no content check recorded")
        end
    end
    if STRICT_REGISTRY_LAYOUT
        # registries installed as stock does: same storage, same files,
        # byte-identical descriptor and archive (no directory-vs-tarball tolerance)
        le, la = get(se, "registry_listing", nothing), get(sa, "registry_listing", nothing)
        le == la || push!(d, "registries/ listing: expected $(le), actual $(la)")
        layout(r) = (r["name"], get(r, "storage", ""), get(r, "descriptor_sha256", ""),
                     get(r, "tarball_name", ""), get(r, "tarball_sha256", ""))
        le2, la2 = sort(layout.(se["registries"])), sort(layout.(sa["registries"]))
        le2 == la2 || push!(d, "registry layout (name, storage, descriptor sha256, tarball, tarball sha256): expected $(le2), actual $(la2)")
    end
    push!(checks, Check("registry", isempty(d), d))

    # frozen discovery: every scenario ends with exactly the frozen registry
    fz = TOML.parsefile(joinpath(@__DIR__, "fixtures", "frozen.toml"))
    # (scenarios ending with `registry rm`: final_registry = "none", no registry at the end)
    want = want_registries(final_registry, fz)
    d = String[]
    for (lbl, s) in (("expected", se), ("actual", sa))
        got = sort(final_ident.(s["registries"]))
        got == want || push!(d, "$lbl registries $(got) != frozen $(want)")
    end
    push!(checks, Check("frozen", isempty(d), d))

    # every Manifest entry with a tree hash is installed in the scenario depot (both sides)
    d = String[]
    for (lbl, dir, sm) in (("expected", expected, se), ("actual", actual, sa))
        append!(d, missing_sources(joinpath(dir, "project", "Manifest.toml"), sm["packages"], lbl))
    end
    push!(checks, Check("sources", isempty(d), d))

    # per command (S-instantiate runs twice): state and requests after each command
    d = String[]
    ste, sta = get(se, "steps", []), get(sa, "steps", [])
    if length(ste) != length(se["exits"]) || length(sta) != length(sa["exits"])
        push!(d, "per-command evidence missing (expected $(length(ste))/$(length(se["exits"])), actual $(length(sta))/$(length(sa["exits"])) steps)")
    else
        for i in 1:min(length(ste), length(sta))
            for f in ("Project.toml", "Manifest.toml")
                a = masked(parse_toml_or_missing(joinpath(expected, "out", "$i.project", f)), re_dir)
                b = masked(parse_toml_or_missing(joinpath(actual, "out", "$i.project", f)), ra_dir)
                mask_rundir && f == "Manifest.toml" &&
                    settle_project_hashes!(a, b, joinpath(expected, "out", "$i.project"), joinpath(actual, "out", "$i.project"))
                (a === nothing) == (b === nothing) || (push!(d, "command $i: $f present expected=$(a !== nothing) actual=$(b !== nothing)"); continue)
                a === nothing || diff_values!(d, "command $i $f", a, b)
            end
            diff_values!(d, "command $i packages", ste[i]["packages"], sta[i]["packages"])
            diff_values!(d, "command $i path sources", get(ste[i], "path_sources", Dict()), get(sta[i], "path_sources", Dict()))
            diff_values!(d, "command $i artifacts", get(ste[i], "artifacts", Dict()), get(sta[i], "artifacts", Dict()))
            # registry identity after each command and the registry update log's keys (timestamps ignored)
            if haskey(ste[i], "registries") || haskey(sta[i], "registries")
                re = get(ste[i], "registries", Dict{String, Any}())
                ra = get(sta[i], "registries", Dict{String, Any}())
                idr(x) = sort([(r["name"], r["uuid"], get(r, "storage", "") == "git" ? get(r, "masked_files", "") : r["tree_hash"])
                               for r in get(x, "registries", Any[])])
                idr(re) == idr(ra) || push!(d, "command $i registries: expected $(idr(re)), actual $(idr(ra))")
                for x in (re, ra), r in get(x, "registries", Any[])
                    get(r, "content_hash", r["tree_hash"]) == r["tree_hash"] ||
                        push!(d, "command $i registry $(r["name"]) content $(r["content_hash"]) != $(r["tree_hash"])")
                end
                if STRICT_REGISTRY_LAYOUT
                    get(re, "listing", nothing) == get(ra, "listing", nothing) ||
                        push!(d, "command $i registries/ listing: expected $(get(re, "listing", nothing)), actual $(get(ra, "listing", nothing))")
                    lay(x) = sort([(r["name"], get(r, "storage", ""), get(r, "descriptor_sha256", ""), get(r, "tarball_sha256", ""))
                                   for r in get(x, "registries", Any[])])
                    lay(re) == lay(ra) || push!(d, "command $i registry layout: expected $(lay(re)), actual $(lay(ra))")
                end
                get(re, "update_log_keys", String[]) == get(ra, "update_log_keys", String[]) ||
                    push!(d, "command $i registry update log keys: expected $(get(re, "update_log_keys", String[])), actual $(get(ra, "update_log_keys", String[]))")
            end
            re_i = ste[i]["requests"]
            ra_i = sta[i]["requests"]
            for r in setdiff(re_i, ra_i); push!(d, "command $i request only expected: $r"); end
            for r in setdiff(ra_i, re_i); push!(d, "command $i request only actual: $r"); end
        end
    end
    push!(checks, Check("steps", isempty(d), d))

    push!(checks, Check("exit", se["exits"] == sa["exits"],
        se["exits"] == sa["exits"] ? String[] : ["exit codes: expected $(se["exits"]), actual $(sa["exits"])"]))

    if compare_error
        d = String[]
        for (i, err) in enumerate(se["errors"])
            isempty(err) && continue
            f = joinpath(actual, "out", "$i.stderr")
            got = isfile(f) ? normalize_text(read(f, String), abspath(actual)) : ""
            endswith(got, err) || push!(d, "command $i: stderr does not end with expected error text\n--- expected\n$err\n--- actual stderr (normalised)\n$got")
        end
        push!(checks, Check("error", isempty(d), d))
    end

    if compare_stderr
        # registry commands print to stderr (as the REPL): normalised per command; lines
        # with a date-time (registry update timestamps) are compared with the time masked
        d = String[]
        mask(t) = replace(t, r"\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}:\d{2}(\.\d+)?Z?" => "<TIME>",
                             r"http://127\.0\.0\.1:\d+" => "http://127.0.0.1:<PORT>")   # frozen server port
        for i in eachindex(se["exits"])
            fe, fa = joinpath(expected, "out", "$i.stderr"), joinpath(actual, "out", "$i.stderr")
            te = isfile(fe) ? sort_installed_blocks(mask(normalize_text(read(fe, String), re_dir))) : ""
            ta = isfile(fa) ? sort_installed_blocks(mask(normalize_text(read(fa, String), ra_dir))) : ""
            te == ta || push!(d, "command $i stderr differs\n--- expected\n$te\n--- actual\n$ta")
        end
        push!(checks, Check("stderr", isempty(d), d))
    end

    if compare_stdout
        # status-like commands: their output is the result. Compared after normalisation
        # (ANSI stripped, the run dir replaced by <RUN>, trailing whitespace dropped).
        d = String[]
        for i in eachindex(se["exits"])
            fe, fa = joinpath(expected, "out", "$i.stdout"), joinpath(actual, "out", "$i.stdout")
            te = isfile(fe) ? normalize_text(read(fe, String), re_dir) : ""
            ta = isfile(fa) ? normalize_text(read(fa, String), ra_dir) : ""
            te == ta || push!(d, "command $i stdout differs\n--- expected\n$te\n--- actual\n$ta")
        end
        push!(checks, Check("stdout", isempty(d), d))
    end

    re = se["requests"]
    ra = sa["requests"]
    d = String[]
    for r in setdiff(re, ra); push!(d, "only expected: $r"); end
    for r in setdiff(ra, re); push!(d, "only actual: $r"); end
    push!(checks, Check("requests", isempty(d), d))

    # the module's HostPlatform() (the runner's platform tags, which are the native host's) must
    # give the same Julia-System header the native baseline sent
    d = String[]
    if !haskey(se, "julia_system")
        push!(d, "expected side records no Julia-System headers (regenerate it)")
    elseif se["julia_system"] != sa["julia_system"]
        push!(d, "Julia-System headers: expected $(se["julia_system"]), actual $(sa["julia_system"])")
    end
    push!(checks, Check("headers", isempty(d), d))

    byte_report = String[]
    if bytes
        for f in ("Project.toml", "Manifest.toml")
            a, b = joinpath(expected, "project", f), joinpath(actual, "project", f)
            same = !(isfile(a) && isfile(b)) ? true : mask_rundir ?
                replace(read(a, String), rstrip(re_dir, '/') => "<RUN>") == replace(read(b, String), rstrip(ra_dir, '/') => "<RUN>") :
                read(a) == read(b)
            if !same
                push!(byte_report, "$f differs byte-wise")
            end
        end
    end
    return checks, byte_report
end

# Stock Pkg installs packages and artifacts on concurrent tasks and prints an `Installed ...`
# line as each finishes, so the order of a run of consecutive `Installed` lines is not
# deterministic natively; such a run is compared as a sorted block (the lines themselves, and
# everything around them, exactly).
function sort_installed_blocks(t::AbstractString)
    lines = split(t, '\n')
    out = String[]
    i = 1
    while i <= length(lines)
        if occursin(r"^\s*Installed ", lines[i])
            j = i
            while j < length(lines) && occursin(r"^\s*Installed ", lines[j + 1])
                j += 1
            end
            append!(out, sort(String.(lines[i:j])))
            i = j + 1
        else
            push!(out, String(lines[i]))
            i += 1
        end
    end
    return join(out, '\n')
end

function report(io::IO, checks, byte_report; label = "")
    ok = all(c -> c.ok, checks)
    println(io, ok ? "EQUIVALENT" : "NOT EQUIVALENT", isempty(label) ? "" : " $label")
    for c in checks
        println(io, "  ", rpad(c.name, 10), c.ok ? "ok" : "FAIL")
        for l in c.detail
            println(io, "    ", replace(l, "\n" => "\n    "))
        end
    end
    for l in byte_report
        println(io, "  bytes     ", l)
    end
    return ok
end

function write_summary(rundir, out)
    s = summarize(rundir)
    open(out, "w") do io
        TOML.print(io, s; sorted = true)
    end
    return s
end

function main(args)
    if length(args) >= 2 && args[1] == "summarize"
        out = length(args) >= 3 ? args[3] : joinpath(args[2], "summary.toml")
        write_summary(args[2], out)
        println("wrote $out")
        return 0
    elseif length(args) >= 3 && args[1] == "compare"
        bytes = "--bytes" in args
        scen = (i = findfirst(==("--scenario"), args)) === nothing ? "" : args[i + 1]
        compare_error = compare_stdout = compare_stderr = mask_rundir = false
        final_registry = "frozen"
        if !isempty(scen)
            sc = TOML.parsefile(joinpath(@__DIR__, "fixtures", "scenarios.toml"))
            compare_error = get(sc[scen], "compare_error", false)
            compare_stdout = get(sc[scen], "compare_stdout", false)
            compare_stderr = get(sc[scen], "compare_stderr", false)
            final_registry = get(sc[scen], "final_registry", "frozen")
            mask_rundir = get(sc[scen], "mask_rundir", false)
        end
        checks, br = compare(args[2], args[3]; bytes, compare_error, compare_stdout, compare_stderr, final_registry, mask_rundir)
        return report(stdout, checks, br; label = scen) ? 0 : 1
    else
        println(stderr, "usage: compare.jl summarize <rundir> [out.toml] | compare <expected> <actual> [--bytes] [--scenario NAME]")
        return 2
    end
end

if abspath(PROGRAM_FILE) == @__FILE__
    exit(main(ARGS))
end
