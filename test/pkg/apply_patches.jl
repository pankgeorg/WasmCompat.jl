# Check out the sources of test/pkg (patches.toml) and apply their patches.
#
#   julia test/pkg/apply_patches.jl [--work DIR] [--only NAME[,NAME...]] [--keep-going]
#   julia test/pkg/apply_patches.jl --check-heads    which pinned patches/branches have moved
#   julia test/pkg/apply_patches.jl --refresh        re-pin each patch to its current head
#   julia test/pkg/apply_patches.jl --refresh-all    also re-pin each repository to its branch
#
# Each repository goes to <work>/<Name>.jl (default work dir: test/pkg/work), recreated from
# scratch: a fetch of the pinned commit, then each patch in file order, as `git apply -3` of the
# diff `from..to` (both fetched by sha) over its `paths`, committed on its own. One line per
# patch: "applied <name>" or "FAILED to apply <name>" (with git's output). After a failure the
# remaining patches are still tried, each on top of the ones that applied, and the exit status
# is 1 (0 with --keep-going, for jobs that test with what applies while another job reports
# the failure). <work>/sources.toml records what was checked out.
#
# Needs only git and Julia's standard library. Never pushes anything.

import TOML

const HERE = @__DIR__
const PATCHES = joinpath(HERE, "patches.toml")
# the order in which repositories are prepared (`from_sources_of` needs its source first)
const ORDER = ["Pkg", "WasmCodegen", "WasmBuilder", "IRStructurizer", "WasmHost", "LibGit2_wasm_jll", "PCRE2_wasm_jll"]
const IDENT = ["-c", "user.name=apply_patches", "-c", "user.email=apply_patches@localhost", "-c", "commit.gpgsign=false"]

struct GitError <: Exception
    msg::String
end
Base.showerror(io::IO, e::GitError) = print(io, e.msg)

# run git in `dir`; returns (ok, combined output)
function git_try(dir, args...)
    out = IOBuffer()
    p = run(pipeline(ignorestatus(`git -C $dir $IDENT $args`); stdout = out, stderr = out))
    return success(p), String(take!(out))
end
function git(dir, args...)
    ok, out = git_try(dir, args...)
    ok || throw(GitError("git $(join(args, ' ')) (in $dir) failed:\n$out"))
    return chomp(out)
end

ls_remote(url, ref) = (o = git(pwd(), "ls-remote", url, ref); isempty(o) ? "" : String(first(split(o))))
is_sha(s) = occursin(r"^[0-9a-f]{40}$", s)
indent(s) = "    " * replace(rstrip(s), "\n" => "\n    ")

function fetch_shas(dir, url, shas...)
    # by sha: GitHub serves any commit of the repository network, also after a force-push
    ok, out = git_try(dir, "fetch", "-q", "--depth=1", "--no-tags", url, shas...)
    ok && return
    # (a server that refuses unadvertised shas: fall back to a full fetch)
    git(dir, "fetch", "-q", "--no-tags", url, "+refs/heads/*:refs/remotes/src/*", "+refs/pull/*/head:refs/remotes/src/pull/*")
    for s in shas
        git_try(dir, "cat-file", "-e", "$s^{commit}")[1] || throw(GitError("$url: commit $s not found:\n$out"))
    end
end

function checkout(dir, url, sha)
    rm(dir; force = true, recursive = true)
    mkpath(dir)
    git(dir, "init", "-q")
    git(dir, "remote", "add", "origin", url)
    fetch_shas(dir, url, sha)
    git(dir, "checkout", "-q", "--detach", sha)
    git(dir, "switch", "-q", "-c", "patched")
end

# Apply one patch to the checkout in `dir`; returns (ok, message)
function apply_patch!(dir, p)
    name = p["name"]
    fetch_shas(dir, p["repo"], p["from"], p["to"])
    p["from"] == p["to"] && throw(GitError("$name: from == to ($(p["from"])): an empty patch; drop it or refresh"))
    paths = get(p, "paths", String[])
    diff = git(dir, "diff", "--binary", "--full-index", p["from"], p["to"], "--", paths...)
    isempty(diff) && return true, "applied $name (no changes in $(isempty(paths) ? "the tree" : join(paths, ", ")): nothing to do)"
    file = joinpath(dir, ".git", "patch.diff")
    write(file, diff * "\n")
    ok, out = git_try(dir, "apply", "-3", "--index", "--whitespace=nowarn", file)
    # (some git versions exit 0 after a three-way merge that left conflicts)
    ok = ok && !occursin("with conflicts", out) && isempty(git(dir, "diff", "--name-only", "--diff-filter=U"))
    if !ok
        git(dir, "reset", "-q", "--hard", "HEAD")
        git(dir, "clean", "-q", "-fd")
        return false, "FAILED to apply $name ($(p["repo"]) $(p["from"][1:10])..$(p["to"][1:10]))\n" * indent(out)
    end
    git(dir, "commit", "-q", "--allow-empty", "-m", "$name\n\n$(p["repo"]) $(p["from"])..$(p["to"])" *
                       (isempty(paths) ? "" : " -- $(join(paths, ' '))"))
    return true, "applied $name"
end

# the url and commit WasmCodegen's [sources] name for `name`
function sources_entry(srcdir, name)
    proj = TOML.parsefile(joinpath(srcdir, "Project.toml"))
    s = get(get(proj, "sources", Dict()), name, nothing)
    s === nothing && throw(GitError("$srcdir/Project.toml has no [sources] entry for $name"))
    url, rev = s["url"], get(s, "rev", "HEAD")
    sha = is_sha(rev) ? rev : ls_remote(url, rev)
    is_sha(sha) || (sha = ls_remote(url, "refs/heads/$rev"))
    is_sha(sha) || throw(GitError("$url: cannot resolve rev $(repr(rev))"))
    return url, rev, sha
end

function apply_all(cfg, work, only; keep_going = false)
    mkpath(work)
    failed = String[]
    record = Dict{String, Any}()
    for name in ORDER
        haskey(cfg, name) || continue
        isempty(only) || name in only || continue
        c = cfg[name]
        dir = joinpath(work, name * ".jl")
        if haskey(c, "from_sources_of")
            src = joinpath(work, c["from_sources_of"] * ".jl")
            url, rev, sha = sources_entry(src, name)
            if haskey(c, "sha") && !is_sha(rev)
                println("$name: $url at $(c["sha"]) (pinned; $(c["from_sources_of"])'s [sources] say $rev, now $(sha[1:10]))")
                sha = c["sha"]
            else
                println("$name: $url at $rev = $sha (from $(c["from_sources_of"])'s [sources])")
            end
        else
            url, sha = c["repo"], c["sha"]
            println("$name: $url $(get(c, "branch", "")) at $sha")
        end
        checkout(dir, url, sha)
        applied = String[]
        for p in get(c, "patch", Dict{String, Any}[])
            ok, msg = try
                apply_patch!(dir, p)
            catch e
                e isa GitError || rethrow()
                false, "FAILED to apply $(p["name"])\n" * indent(sprint(showerror, e))
            end
            println("  ", replace(msg, "\n" => "\n  "))
            ok ? push!(applied, p["name"]) : push!(failed, p["name"])
        end
        record[name] = Dict("dir" => dir, "repo" => url, "base" => sha, "head" => git(dir, "rev-parse", "HEAD"),
                            "applied" => applied)
    end
    open(io -> TOML.print(io, record; sorted = true), joinpath(work, "sources.toml"), "w")
    if isempty(failed)
        println("all patches applied")
        return 0
    end
    println("FAILED: $(length(failed)) patch(es) did not apply: ", join(failed, "; "))
    return keep_going ? 0 : 1
end

# the current head of a patch's PR or branch
function current_head(p)
    if haskey(p, "branch")
        return ls_remote(p["repo"], "refs/heads/" * p["branch"])
    elseif haskey(p, "pr")
        m = match(r"^([^#]+)#(\d+)$", p["pr"])
        return ls_remote("https://github.com/" * m[1], "refs/pull/$(m[2])/head")
    end
    return ""
end

function check_heads(cfg)
    moved = 0
    for name in ORDER
        c = get(cfg, name, nothing)
        c === nothing && continue
        if haskey(c, "from_sources_of") && haskey(c, "sha")
            dir = joinpath(HERE, "work", c["from_sources_of"] * ".jl")
            if isdir(dir)
                url, rev, h = sources_entry(dir, name)
                h == c["sha"] ? println("$name: $rev at the pinned $(c["sha"][1:10])") :
                    (moved += 1; println("$name: $rev is now $(h[1:10]), pinned $(c["sha"][1:10])"))
            end
        end
        if haskey(c, "branch") && haskey(c, "sha")
            h = ls_remote(c["repo"], "refs/heads/" * c["branch"])
            h == c["sha"] ? println("$name: $(c["branch"]) at the pinned $(c["sha"][1:10])") :
                (moved += 1; println("$name: $(c["branch"]) is now $(h[1:min(end,10)]), pinned $(c["sha"][1:10]) (--refresh-all re-pins)"))
        end
        for p in get(c, "patch", Dict{String, Any}[])
            h = current_head(p)
            if h == p["to"]
                println("  $(p["name"]): at the pinned head $(h[1:10])")
            else
                moved += 1
                println("  $(p["name"]): head is now $(isempty(h) ? "<gone>" : h[1:10]), pinned $(p["to"][1:10]) (--refresh re-pins)")
            end
        end
    end
    return moved
end

# re-pin: `to` = the current head; `from` = merge-base(to, merge_base_with)
function refresh!(cfg; all = false)
    text = read(PATCHES, String)
    tmp = mktempdir()
    git(tmp, "init", "-q", "--bare")
    for name in ORDER
        c = get(cfg, name, nothing)
        c === nothing && continue
        if all && haskey(c, "branch") && haskey(c, "sha")
            h = ls_remote(c["repo"], "refs/heads/" * c["branch"])
            h != c["sha"] && (text = replace(text, "sha = \"$(c["sha"])\"" => "sha = \"$h\""; count = 1))
        end
        for p in get(c, "patch", Dict{String, Any}[])
            to = current_head(p)
            is_sha(to) || (println("$(p["name"]): no current head, left as is"); continue)
            if get(p, "from_parent", false)
                # (a backport: one commit on top of the patches before it)
                git(tmp, "fetch", "-q", "--filter=blob:none", "--no-tags", "--depth=2", p["repo"], to)
                from = git(tmp, "rev-parse", "$to^")
            else
                burl, bref = split(p["merge_base_with"])
                git(tmp, "fetch", "-q", "--filter=blob:none", "--no-tags", burl, "+refs/heads/$bref:refs/base/$(hash(burl * bref))")
                git(tmp, "fetch", "-q", "--filter=blob:none", "--no-tags", p["repo"], to)
                from = git(tmp, "merge-base", to, "refs/base/$(hash(burl * bref))")
            end
            (to == p["to"] && from == p["from"]) && (println("$(p["name"]): unchanged"); continue)
            # the patch's own block: from its `name = ` line to the next table header
            i = findfirst("name = \"$(p["name"])\"", text)
            j = something(findnext(r"^\["m, text, last(i)), lastindex(text) + 1)
            j = j isa UnitRange ? first(j) : j
            block = text[first(i):prevind(text, j)]
            nb = replace(block, "from = \"$(p["from"])\"" => "from = \"$from\"", "to = \"$(p["to"])\"" => "to = \"$to\"")
            text = text[1:prevind(text, first(i))] * nb * text[j:end]
            println("$(p["name"]): from $(from[1:10]) to $(to[1:10]) (was $(p["from"][1:10])..$(p["to"][1:10]))")
        end
    end
    rm(tmp; recursive = true, force = true)
    write(PATCHES, text)
    return 0
end

function main(args)
    work = joinpath(HERE, "work")
    only = String[]
    mode = :apply
    keep_going = false
    i = 1
    while i <= length(args)
        a = args[i]
        if a == "--work"; work = abspath(args[i += 1])
        elseif a == "--only"; only = split(args[i += 1], ',')
        elseif a == "--keep-going"; keep_going = true
        elseif a == "--check-heads"; mode = :check
        elseif a == "--refresh"; mode = :refresh
        elseif a == "--refresh-all"; mode = :refresh_all
        else
            println(stderr, "apply_patches.jl: unknown argument $a"); return 2
        end
        i += 1
    end
    cfg = TOML.parsefile(PATCHES)
    mode === :check && (check_heads(cfg); return 0)
    mode === :refresh && return refresh!(cfg)
    mode === :refresh_all && return refresh!(cfg; all = true)
    return apply_all(cfg, work, only; keep_going)
end

exit(main(ARGS))
