"""
    WasmCompatLibGit2Ext

Julia's `LibGit2` standard library on libgit2 itself, compiled to WebAssembly: LibGit2_wasm_jll's
standalone module `libgit2.wasm`, which the host instantiates and gives the program as the import
module `"libgit2"` (`WasmCodegen.Config(import_libraries)`; `js/libgit2.mjs`). That module has its
own memory and its own WASI instance over the program's preopens; https goes through the host's
fetch (WasmHost's `wasm_host.http_request`). `LibGit2`'s code runs, and so does its callers' (Pkg's
`GitTools`, `Types`, `Operations` and `Registry`, unchanged).

`LibGit2`'s handle types hold the module's addresses in their `ptr` fields: integers that Julia passes
around and never dereferences. Two mechanisms carry `LibGit2`'s calls to the module:

- **Foreign functions** (`Config(foreign_functions)`) for the `ccall`s that take and return handles,
  integers, strings and object ids (51 of them: open, revparse, lookup, peel, tree entries, references,
  remotes, signatures, rebase steps, diffs, ...). A string or id argument is copied into the module's
  memory for the call; a string or id result is a Julia-owned copy, which `LibGit2` reads as it reads
  libgit2's memory natively.
- **Overlays** (`WasmCodegen.Runtime.WASM_METHODS`) of the methods whose `ccall` passes an option struct,
  an array of pointers, or an out-struct of pointers (`clone`, `fetch`, `checkout_tree`, `reset!`,
  `GitRebase`, `add!`, `merge_analysis`, `remotes`, `branch`, `get` of a configuration string, the last
  error, `Signature(ptr)` and `iterate(::GitRebase)`, which read the module's signatures and rebase
  operations): WasmCodegen loads plain bits through a pointer a foreign function receives, but not
  pointers inside structs or arrays. Each overlay is `LibGit2`'s method with its `ccall` made with the
  struct's fields and the handles. A few more overlays are closed-world forms of `LibGit2`'s own code
  with the same results: `GitObject(repo, ptr)` and `T(repo, spec)` (a constructor per object type, type
  names in the error message), `commit` (no splat), and `close` of the handle types (`LibGit2` names
  `git_<type>_free` with a `String`, which `foreign_functions` does not match), and `copy` of a
  `LibGit2.Callbacks` (Pkg's shallow clones copy it; `copy` of a `Dict` copies its memory of
  `Tuple{Ptr{Cvoid}, Any}`, a tuple of an abstract type, which WasmCodegen does not do): the same
  entries, one by one.

libgit2 calls no Julia callback here: `credentials_cb()`, `certificate_cb()` and `fetchhead_foreach_cb()` are null,
`RemoteCallbacks(::Callbacks)` drops the callbacks, and the credential payload has nothing to approve or
reject. Remotes are public https (TLS is the host's) and local paths; a remote that asks for
credentials is libgit2's `EAUTH` error ("remote authentication required but no callback set"), and
transfer progress is not reported. `LibGit2.initialize()` is `git_libgit2_init` only (no certificate
locations, no `atexit`), and `rawcontent(::GitBlob)` copies the bytes out of the module.

Differences from native that are WASI preview 1's: no permission bits (the module sets
`core.filemode = false` for every repository it opens, so work trees are not dirty by mode, and
checkouts make no file executable), no ssh, no processes (no credential helpers). Not in Wasm:
non-fast-forward `merge!`, `merge!` of FETCH_HEAD, and `CheckoutOptions(paths)` (Pkg uses none).
Finalizers do not run in a module: objects `LibGit2` does not `close` are not freed.
"""
module WasmCompatLibGit2Ext

using WasmCodegen
import LibGit2, LibGit2_wasm_jll, WasmCompat
using LibGit2: GitHash, Buffer, StrArrayStruct, SignatureStruct, TimeStruct,
    RebaseOperation, CheckoutOptions, CloneOptions, FetchOptions, DiffOptionsStruct, RebaseOptions,
    Consts, Error
using LibGit2.Error: ErrorStruct

"The library `LibGit2` names in its `ccall`s (`LibGit2_jll.libgit2`)."
const LIB = LibGit2.LibGit2_jll.libgit2

## the module's exports (the import module "libgit2"): wasm32, so addresses and sizes are UInt32

malloc(n::UInt32) = ccall((:malloc, "libgit2"), UInt32, (UInt32,), n)
free(a::UInt32) = ccall((:free, "libgit2"), Cvoid, (UInt32,), a)
load8(a::UInt32) = ccall((:mem_load8, "libgit2"), UInt32, (UInt32,), a)
load32(a::UInt32) = ccall((:mem_load32, "libgit2"), UInt32, (UInt32,), a)
load64(a::UInt32) = ccall((:mem_load64, "libgit2"), UInt64, (UInt32,), a)
store8(a::UInt32, v::UInt32) = ccall((:mem_store8, "libgit2"), Cvoid, (UInt32, UInt32), a, v)
store32(a::UInt32, v::UInt32) = ccall((:mem_store32, "libgit2"), Cvoid, (UInt32, UInt32), a, v)
store64(a::UInt32, v::UInt64) = ccall((:mem_store64, "libgit2"), Cvoid, (UInt32, UInt64), a, v)

## memory of the module that a call uses: freed when the call returns

const TEMPS = UInt32[]

function tmp(n::Integer)
    a = malloc(UInt32(max(n, 1)))
    a == 0 && throw(OutOfMemoryError())
    push!(TEMPS, a)
    return a
end

function release!()
    for a in TEMPS
        free(a)
    end
    empty!(TEMPS)
    return nothing
end

"A 4-byte slot of the module, zeroed: for an out-pointer."
slot() = (a = tmp(8); store64(a, UInt64(0)); a)

## copies between Julia's memory and the module's

"Copies `n` bytes from `p` (Julia's memory) to `a` (the module's)."
function copyin!(a::UInt32, p::Ptr{UInt8}, n::Int)
    i = 0
    while i + 8 <= n
        v = UInt64(0)
        for k in 1:8
            v |= UInt64(unsafe_load(p, i + k)) << (8 * (k - 1))
        end
        store64(a + UInt32(i), v)
        i += 8
    end
    while i < n
        store8(a + UInt32(i), UInt32(unsafe_load(p, i + 1)))
        i += 1
    end
    return nothing
end

"The `n` bytes at `a` (the module's memory)."
function copyout(a::UInt32, n::Int)
    v = Vector{UInt8}(undef, n)
    i = 0
    while i + 8 <= n
        w = load64(a + UInt32(i))
        for k in 1:8
            v[i + k] = (w >> (8 * (k - 1))) % UInt8
        end
        i += 8
    end
    while i < n
        v[i + 1] = load8(a + UInt32(i)) % UInt8
        i += 1
    end
    return v
end

"The string `s` NUL-terminated in the module's memory (freed when the call returns)."
function cin_string(s::String)
    n = ncodeunits(s)
    a = tmp(n + 1)
    GC.@preserve s copyin!(a, pointer(s), n)
    store8(a + UInt32(n), UInt32(0))
    return a
end
"A C string of the caller in the module's memory, or 0 for a null one."
cin(s::String) = cin_string(s)
cin(s::Cstring) = convert(Ptr{UInt8}, s) == C_NULL ? UInt32(0) : cin_string(unsafe_string(s))
cin(p::Ptr{UInt8}) = p == C_NULL ? UInt32(0) : cin_string(unsafe_string(p))

"The NUL-terminated string at `a` (the module's memory)."
function cout(a::UInt32)
    n = 0
    while load8(a + UInt32(n)) != 0
        n += 1
    end
    return String(copyout(a, n))
end

# Julia-owned copies that `LibGit2`'s code reads through the pointers this extension returns. Each
# is read (`unsafe_load`, `unsafe_string`) right after the call that made it, before another call
# of the extension, except the strings of signatures and string arrays, which `LibGit2` reads while
# holding the object: those are kept until the program ends (they are small and few).
const KEEP = Any[]
keep!(x) = (push!(KEEP, x); x)

"A Julia-owned C string with the bytes of the module's string at `a` (null for 0)."
function jcstr(a::UInt32)
    a == 0 && return Cstring(C_NULL)
    s = keep!(cout(a))
    return Cstring(pointer(s))
end

## object ids

oid_bytes(h::GitHash) = h.val
function oid_in(p::Ptr{GitHash})
    p == C_NULL && return UInt32(0)
    h = unsafe_load(p)
    a = tmp(20)
    v = h.val
    for k in 1:20
        store8(a + UInt32(k - 1), UInt32(v[k]))
    end
    return a
end
oid_at(a::UInt32) = GitHash(ntuple(k -> load8(a + UInt32(k - 1)) % UInt8, Val(20)))
oid_out!(p::Ptr{GitHash}, a::UInt32) = (unsafe_store!(p, oid_at(a)); nothing)

"A Julia-owned copy of the id at `a`, as libgit2 returns `const git_oid *` (null for 0)."
function jcoid(a::UInt32)
    a == 0 && return Ptr{GitHash}(C_NULL)
    r = keep!(Ref(oid_at(a)))
    return Base.unsafe_convert(Ptr{GitHash}, r)
end

## handles: the module's addresses, held as integers in `ptr` fields

ha(p::Ptr) = UInt32(UInt(p))
hp(a::UInt32) = Ptr{Cvoid}(UInt(a))
out_handle!(p::Ptr{Ptr{Cvoid}}, a::UInt32) = (unsafe_store!(p, hp(load32(a))); nothing)

## string arrays: Julia strings as a `git_strarray` in the module's memory (freed when the call returns)

function strarray(v::Vector{String})
    isempty(v) && return UInt32(0)
    n = length(v)
    arr = tmp(4n)
    for i in 1:n
        store32(arr + UInt32(4(i - 1)), cin(v[i]))
    end
    s = tmp(8)
    store32(s, arr)
    store32(s + UInt32(4), UInt32(n))
    return s
end

"The strings of the module's `git_strarray` at `a` (which is disposed)."
function strings_of(a::UInt32)
    arr = load32(a)
    n = Int(load32(a + UInt32(4)))
    v = String[cout(load32(arr + UInt32(4(i - 1)))) for i in 1:n]
    ccall((:git_strarray_dispose, "libgit2"), Cvoid, (UInt32,), a)
    return v
end

"The module's array of the handles `hs` (freed when the call returns)."
function handles(hs::Vector{Ptr{Cvoid}})
    arr = tmp(4 * length(hs))
    for i in eachindex(hs)
        store32(arr + UInt32(4(i - 1)), ha(hs[i]))
    end
    return arr
end

# Signatures (`GitSignature`) and rebase operations are the module's, like handles: LibGit2 reads
# them through `Signature(ptr)` and `iterate(::GitRebase)`, overlaid below.

## the foreign functions: `LibGit2`'s ccalls, with their argument and result types

# init and errors
git_libgit2_init() = ccall((:lg2w_libgit2_init, "libgit2"), Int32, ())
git_libgit2_shutdown() = ccall((:git_libgit2_shutdown, "libgit2"), Int32, ())
function git_libgit2_version(major::Ptr{Cint}, minor::Ptr{Cint}, rev::Ptr{Cint})
    v = Int32(ccall((:lg2w_version, "libgit2"), UInt32, ()))
    unsafe_store!(major, v ÷ Int32(10000)); unsafe_store!(minor, (v ÷ Int32(100)) % Int32(100))
    unsafe_store!(rev, v % Int32(100))
    return Cint(0)
end
# handle -> int
for (f, RT) in ((:git_repository_is_bare, Cint), (:git_repository_is_shallow, Cint), (:git_repository_head_unborn, Cint),
                (:git_repository_head_detached, Cint), (:git_reference_type, Cint),
                (:git_diff_num_deltas, Cint), (:git_index_write, Cint))
    @eval $f(h::Ptr{Cvoid}) = $RT(ccall(($(QuoteNode(f)), "libgit2"), Int32, (UInt32,), ha(h)))
end
git_object_type(h::Ptr{Cvoid}) = Consts.OBJECT(ccall((:git_object_type, "libgit2"), Int32, (UInt32,), ha(h)))
git_blob_rawsize(h::Ptr{Cvoid}) = ccall((:git_blob_rawsize, "libgit2"), Int64, (UInt32,), ha(h))

# handle -> string
for f in (:git_repository_path, :git_reference_shorthand, :git_reference_name,
          :git_reference_symbolic_target, :git_remote_url)
    @eval $f(h::Ptr{Cvoid}) = jcstr(ccall(($(QuoteNode(f)), "libgit2"), UInt32, (UInt32,), ha(h)))
end

# handle -> id
git_object_id(h::Ptr{Cvoid}) = Ptr{UInt8}(jcoid(ccall((:git_object_id, "libgit2"), UInt32, (UInt32,), ha(h))))
git_reference_target(h::Ptr{Cvoid}) = Ptr{UInt8}(jcoid(ccall((:git_reference_target, "libgit2"), UInt32, (UInt32,), ha(h))))
git_annotated_commit_id(h::Ptr{Cvoid}) = jcoid(ccall((:git_annotated_commit_id, "libgit2"), UInt32, (UInt32,), ha(h)))

# ids, in Julia
function git_oid_fromraw(out::Ptr{GitHash}, raw::Ptr{UInt8})
    unsafe_store!(out, GitHash(ntuple(k -> unsafe_load(raw, k), Val(20))))
    return Cint(0)
end
function git_oid_cmp(a::Ptr{GitHash}, b::Ptr{GitHash})
    x, y = unsafe_load(a).val, unsafe_load(b).val
    for k in 1:20
        x[k] == y[k] || return Cint(Int(x[k]) - Int(y[k]))
    end
    return Cint(0)
end

# calls that make a handle (the first argument, an out-pointer), with handles, strings, ids and ints
macro outcall(name, cname, args...)
    # args: `x::kind` with kind h (handle), s (C string), o (id), i (Cint), u (Cuint)
    sig = Any[:(out::Ptr{Ptr{Cvoid}})]
    vals = Any[:o]
    types = Any[:UInt32]
    for a in args
        n, k = a.args
        if k === :h
            push!(sig, :($n::Ptr{Cvoid})); push!(vals, :(ha($n))); push!(types, :UInt32)
        elseif k === :s
            push!(sig, n); push!(vals, :(cin($n))); push!(types, :UInt32)
        elseif k === :o
            push!(sig, :($n::Ptr{GitHash})); push!(vals, :(oid_in($n))); push!(types, :UInt32)
        elseif k === :i
            push!(sig, n); push!(vals, :(Int32($n))); push!(types, :Int32)
        elseif k === :u
            push!(sig, n); push!(vals, :(UInt32($n))); push!(types, :UInt32)
        else
            error("@outcall: kind $k")
        end
    end
    # (all of it in the caller's scope: the slot `o` is one of the arguments)
    esc(quote
        function $name($(sig...))
            try
                o = slot()
                rc = ccall(($(QuoteNode(cname)), "libgit2"), Int32, ($(types...),), $(vals...))
                rc == 0 && out_handle!(out, o)
                return Cint(rc)
            finally
                release!()
            end
        end
    end)
end

@outcall git_repository_open lg2w_repository_open path::s
@outcall git_repository_init lg2w_repository_init path::s bare::u
@outcall git_repository_head git_repository_head repo::h
@outcall git_repository_config git_repository_config repo::h
@outcall git_repository_index git_repository_index repo::h
@outcall git_revparse_single git_revparse_single repo::h spec::s
@outcall git_object_lookup git_object_lookup repo::h id::o type::i
@outcall git_object_peel git_object_peel obj::h type::i
@outcall git_tree_entry_bypath git_tree_entry_bypath tree::h path::s
@outcall git_tree_entry_to_object git_tree_entry_to_object repo::h entry::h
@outcall git_reference_lookup git_reference_lookup repo::h name::s
@outcall git_reference_set_target git_reference_set_target ref::h id::o msg::s
@outcall git_reference_create git_reference_create repo::h name::s id::o force::i msg::s
@outcall git_config_open_default git_config_open_default
@outcall git_remote_lookup git_remote_lookup repo::h name::s
@outcall git_remote_create_anonymous git_remote_create_anonymous repo::h url::s
@outcall git_annotated_commit_from_ref git_annotated_commit_from_ref repo::h ref::h
@outcall git_annotated_commit_lookup git_annotated_commit_lookup repo::h id::o
@outcall git_branch_upstream git_branch_upstream ref::h
@outcall git_config_open_level git_config_open_level cfg::h level::i
@outcall git_annotated_commit_from_fetchhead git_annotated_commit_from_fetchhead repo::h branch::s url::s id::o
@outcall git_branch_create git_branch_create repo::h name::s commit::h force::i

function git_config_set_string(cfg::Ptr{Cvoid}, name::Cstring, value::Cstring)
    try
        return Cint(ccall((:git_config_set_string, "libgit2"), Int32, (UInt32, UInt32, UInt32), ha(cfg), cin(name), cin(value)))
    finally
        release!()
    end
end

"libgit2's error (class `klass`, message `msg`) for what the module does not do: -1."
function unsupported(klass::Int32, msg::String)
    try
        ccall((:git_error_set_str, "libgit2"), Int32, (Int32, UInt32), klass, cin(msg))
    finally
        release!()
    end
    return Cint(-1)
end
# merges that are not fast-forwards and FETCH_HEAD's callback (LibGit2.merge! reaches them; Pkg merges by
# fast-forward, from a branch)
git_merge(repo, heads, n, mopts, copts) = unsupported(Int32(22), "a merge that is not a fast-forward is not supported in Wasm")
git_repository_fetchhead_foreach(repo, cb, payload) =
    unsupported(Int32(22), "the FETCH_HEAD callback (merge! of FETCH_HEAD) is not supported in Wasm")

# calls that fill an id
function git_reference_name_to_id(out::Ptr{GitHash}, repo::Ptr{Cvoid}, name::Cstring)
    try
        o = tmp(20)
        rc = ccall((:git_reference_name_to_id, "libgit2"), Int32, (UInt32, UInt32, UInt32), o, ha(repo), cin(name))
        rc == 0 && oid_out!(out, o)
        return Cint(rc)
    finally
        release!()
    end
end
function git_index_write_tree(out::Ptr{GitHash}, idx::Ptr{Cvoid})
    try
        o = tmp(20)
        rc = ccall((:git_index_write_tree, "libgit2"), Int32, (UInt32, UInt32), o, ha(idx))
        rc == 0 && oid_out!(out, o)
        return Cint(rc)
    finally
        release!()
    end
end

# status (LibGit2.isdirty). LibGit2's `diff_tree` passes its `pathspecs` *string* where libgit2 takes a
# `git_diff_options *` (null for "", which is what `isdirty` and Pkg pass): libgit2's default options are used
function git_diff_tree_to_workdir_with_index(out::Ptr{Ptr{Cvoid}}, repo::Ptr{Cvoid}, tree::Ptr{Cvoid}, opts)
    try
        o = slot()
        rc = ccall((:git_diff_tree_to_workdir_with_index, "libgit2"), Int32, (UInt32, UInt32, UInt32, UInt32),
                   o, ha(repo), ha(tree), UInt32(0))
        rc == 0 && out_handle!(out, o)
        return Cint(rc)
    finally
        release!()
    end
end
function git_diff_tree_to_index(out::Ptr{Ptr{Cvoid}}, repo::Ptr{Cvoid}, tree::Ptr{Cvoid}, index::Ptr{Cvoid}, opts)
    try
        o = slot()
        rc = ccall((:git_diff_tree_to_index, "libgit2"), Int32, (UInt32, UInt32, UInt32, UInt32, UInt32),
                   o, ha(repo), ha(tree), ha(index), UInt32(0))
        rc == 0 && out_handle!(out, o)
        return Cint(rc)
    finally
        release!()
    end
end
git_object_free(h::Ptr{Cvoid}) = ccall((:git_object_free, "libgit2"), Cvoid, (UInt32,), ha(h))

# rebase: the operation is the module's (`iterate(::GitRebase)` reads it)
function git_rebase_next(out::Ptr{Ptr{RebaseOperation}}, rb::Ptr{Cvoid})
    try
        o = slot()
        rc = ccall((:git_rebase_next, "libgit2"), Int32, (UInt32, UInt32), o, ha(rb))
        rc == 0 && unsafe_store!(out, Ptr{RebaseOperation}(UInt(load32(o))))
        return Cint(rc)
    finally
        release!()
    end
end
function git_rebase_commit(id::Ptr{GitHash}, rb::Ptr{Cvoid}, author::Ptr{SignatureStruct},
                           committer::Ptr{SignatureStruct}, enc::Ptr{UInt8}, msg::Ptr{UInt8})
    try
        o = tmp(20)
        rc = ccall((:git_rebase_commit, "libgit2"), Int32, (UInt32, UInt32, UInt32, UInt32, UInt32, UInt32),
                   o, ha(rb), ha(author), ha(committer), cin(enc), cin(msg))
        rc == 0 && oid_out!(id, o)
        return Error.Code(rc)
    finally
        release!()
    end
end
git_rebase_finish(rb::Ptr{Cvoid}, sig::Ptr{SignatureStruct}) =
    Csize_t(reinterpret(UInt32, ccall((:git_rebase_finish, "libgit2"), Int32, (UInt32, UInt32), ha(rb), ha(sig))))
git_rebase_abort(rb::Ptr{Cvoid}) =
    Csize_t(reinterpret(UInt32, ccall((:git_rebase_abort, "libgit2"), Int32, (UInt32,), ha(rb))))

# signatures: the module's (`Signature(ptr)` reads one)
function git_signature_default(out::Ptr{Ptr{SignatureStruct}}, repo::Ptr{Cvoid})
    try
        o = slot()
        rc = ccall((:git_signature_default, "libgit2"), Int32, (UInt32, UInt32), o, ha(repo))
        rc == 0 && unsafe_store!(out, Ptr{SignatureStruct}(UInt(load32(o))))
        return Cint(rc)
    finally
        release!()
    end
end
function git_signature_new(out::Ptr{Ptr{SignatureStruct}}, name::Cstring, email::Cstring, time::Int64, offset::Cint)
    try
        o = slot()
        rc = ccall((:git_signature_new, "libgit2"), Int32, (UInt32, UInt32, UInt32, Int64, Int32),
                   o, cin(name), cin(email), time, Int32(offset))
        rc == 0 && unsafe_store!(out, Ptr{SignatureStruct}(UInt(load32(o))))
        return Cint(rc)
    finally
        release!()
    end
end
git_signature_free(p::Ptr{SignatureStruct}) = ccall((:git_signature_free, "libgit2"), Cvoid, (UInt32,), ha(p))

const FUNCTIONS = Pair{Tuple{Symbol,String},Any}[(f, LIB) => getfield(@__MODULE__, f) for f in (
    :git_libgit2_init, :git_libgit2_shutdown, :git_libgit2_version,
    :git_repository_is_bare, :git_repository_is_shallow, :git_repository_head_detached, :git_reference_type,
    :git_diff_num_deltas, :git_index_write, :git_object_type, :git_blob_rawsize,
    :git_repository_path, :git_reference_shorthand, :git_reference_name, :git_reference_symbolic_target,
    :git_remote_url, :git_object_id, :git_reference_target, :git_annotated_commit_id,
    :git_oid_fromraw, :git_oid_cmp,
    :git_repository_open, :git_repository_init, :git_repository_head, :git_repository_config,
    :git_repository_index, :git_revparse_single, :git_object_lookup, :git_object_peel,
    :git_tree_entry_bypath, :git_tree_entry_to_object, :git_reference_lookup, :git_reference_set_target,
    :git_reference_create, :git_config_open_default, :git_remote_lookup, :git_remote_create_anonymous,
    :git_annotated_commit_from_ref, :git_annotated_commit_lookup,
    :git_reference_name_to_id, :git_index_write_tree,
    :git_diff_tree_to_workdir_with_index, :git_diff_tree_to_index, :git_object_free,
    :git_rebase_next, :git_rebase_commit, :git_rebase_finish, :git_rebase_abort,
    :git_signature_default, :git_signature_new, :git_signature_free,
    :git_repository_head_unborn, :git_branch_upstream, :git_config_set_string, :git_merge,
    :git_repository_fetchhead_foreach, :git_config_open_level, :git_annotated_commit_from_fetchhead,
    :git_branch_create)]

## overlays

Base.Experimental.@overlay WasmCodegen.Runtime.WASM_METHODS LibGit2.credentials_cb() = C_NULL
Base.Experimental.@overlay WasmCodegen.Runtime.WASM_METHODS LibGit2.certificate_cb() = C_NULL
Base.Experimental.@overlay WasmCodegen.Runtime.WASM_METHODS LibGit2.fetchhead_foreach_cb() = C_NULL

Base.Experimental.@overlay WasmCodegen.Runtime.WASM_METHODS function LibGit2.initialize()
    LibGit2.@check ccall((:git_libgit2_init, LIB), Cint, ())
    return nothing
end

Base.Experimental.@overlay WasmCodegen.Runtime.WASM_METHODS function LibGit2.rawcontent(blob::LibGit2.GitBlob)
    LibGit2.ensure_initialized()
    n = Int(length(blob))
    a = ccall((:git_blob_rawcontent, "libgit2"), UInt32, (UInt32,), ha(blob.ptr))
    return copyout(a, n)
end

# Closed-world forms of three methods of LibGit2 (the same results):
# (`@check` is `rc < 0 && throw(Error.GitError(rc))` in the overlays below, as LibGit2's macro expands)
# `GitObject(repo, ptr)` (types.jl) calls the type `objtype` returns: here one constructor per type of object
Base.Experimental.@overlay WasmCodegen.Runtime.WASM_METHODS function LibGit2.GitObject(repo::LibGit2.GitRepo, ptr::Ptr{Cvoid})::LibGit2.GitObject
    t = Consts.OBJECT(ptr)
    t == Consts.OBJ_COMMIT && return LibGit2.GitCommit(repo, ptr)
    t == Consts.OBJ_TREE && return LibGit2.GitTree(repo, ptr)
    t == Consts.OBJ_BLOB && return LibGit2.GitBlob(repo, ptr)
    # (libgit2's objects are of these four types: four, not LibGit2's five, keep the result a union
    # inference splits, as LibGit2's callers need)
    t == Consts.OBJ_TAG || throw(Error.GitError(Error.Object, Error.ERROR, "object of an unexpected type"))
    return LibGit2.GitTag(repo, ptr)
end

objtype_name(t::Consts.OBJECT) =
    t == Consts.OBJ_COMMIT ? "LibGit2.GitCommit" : t == Consts.OBJ_TREE ? "LibGit2.GitTree" :
    t == Consts.OBJ_BLOB ? "LibGit2.GitBlob" : t == Consts.OBJ_TAG ? "LibGit2.GitTag" : "LibGit2.GitUnknownObject"

# `T(repo, spec)` (repository.jl) interpolates types into its error message: here their names
Base.Experimental.@overlay WasmCodegen.Runtime.WASM_METHODS function (::Type{T})(repo::LibGit2.GitRepo, spec::AbstractString) where T<:LibGit2.GitObject
    LibGit2.ensure_initialized()
    obj_ptr_ptr = Ref{Ptr{Cvoid}}(C_NULL)
    @assert repo.ptr != C_NULL
    LibGit2.@check ccall((:git_revparse_single, LIB), Cint,
                         (Ptr{Ptr{Cvoid}}, Ptr{Cvoid}, Cstring), obj_ptr_ptr, repo, spec)
    obj_ptr = obj_ptr_ptr[]
    if T != LibGit2.GitObject && T != LibGit2.GitUnknownObject
        t = Consts.OBJECT(obj_ptr)
        if t != Consts.OBJECT(T)
            obj_ptr != C_NULL && ccall((:git_object_free, LIB), Cvoid, (Ptr{Cvoid},), obj_ptr)
            throw(Error.GitError(Error.Object, Error.ERROR, string("Expected object of type ", objtype_name(Consts.OBJECT(T)),
                                                                   ", received object of type ", objtype_name(t))))
        end
    end
    return T(repo, obj_ptr)::T
end

# `commit(repo, msg; ...)` (commit.jl) splats its parents into the varargs method, which passes their pointers
# as an array: here the module gets the array of handles
Base.Experimental.@overlay WasmCodegen.Runtime.WASM_METHODS function LibGit2.commit(repo::LibGit2.GitRepo, msg::AbstractString;
        refname::AbstractString = Consts.HEAD_FILE, author::LibGit2.Signature = LibGit2.Signature(repo),
        committer::LibGit2.Signature = LibGit2.Signature(repo), tree_id::GitHash = GitHash(),
        parent_ids::Vector{GitHash} = GitHash[])
    if LibGit2.iszero(tree_id)
        tree_id = LibGit2.with(LibGit2.write_tree!, LibGit2.GitIndex, repo)
    end
    if isempty(parent_ids)
        try
            Base.push!(parent_ids, GitHash(repo, refname))
        catch
        end
    end
    commit_id = GitHash()
    tree = LibGit2.GitTree(repo, tree_id)
    auth_sig = convert(LibGit2.GitSignature, author)
    comm_sig = convert(LibGit2.GitSignature, committer)
    parents = LibGit2.GitCommit[]
    try
        for id in parent_ids
            Base.push!(parents, LibGit2.GitCommit(repo, id))
        end
        LibGit2.ensure_initialized()
        o = tmp(20)
        arr = handles(Ptr{Cvoid}[c.ptr for c in parents])
        rc = ccall((:git_commit_create, "libgit2"), Int32,
                   (UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32),
                   o, ha(repo.ptr), isempty(refname) ? UInt32(0) : cin(String(refname)), ha(auth_sig.ptr),
                   ha(comm_sig.ptr), UInt32(0), cin(String(msg)), ha(tree.ptr), UInt32(length(parents)), arr)
        rc < 0 && throw(Error.GitError(rc))
        commit_id = oid_at(o)
    finally
        for parent in parents
            close(parent)
        end
        close(tree)
        close(auth_sig)
        close(comm_sig)
        release!()
    end
    return commit_id
end


## LibGit2's methods that pass libgit2 option structs, arrays of pointers or out-structs of pointers

# WasmCodegen loads and stores plain bits through a pointer a foreign function receives (ids, string
# bytes, handles stored into a `Ref`), but not pointers held in structs or arrays: these methods make
# the same libgit2 calls by fields and handles. Each is the stdlib's, with the call replaced.

const OV = WasmCodegen.Runtime.WASM_METHODS

Base.Experimental.@overlay OV function Base.copy(callbacks::LibGit2.Callbacks)
    c = LibGit2.Callbacks()
    for (k, v) in callbacks
        c[k] = v
    end
    return c
end

"The scalar fields of a `CheckoutOptions`, and its strings in the module (freed when the call returns)."
function checkout_fields(c::CheckoutOptions)
    c.paths.count == 0 || throw(ArgumentError("WasmCompat: CheckoutOptions(paths) is not supported in Wasm"))
    return (c.checkout_strategy, c.disable_filters, c.dir_mode, c.file_mode, c.file_open_flags, c.notify_flags,
            UInt32(0), cin(c.target_directory), cin(c.ancestor_label), cin(c.our_label), cin(c.their_label))
end

# types.jl: libgit2 calls no Julia callback in Wasm (see the module's documentation), so the callbacks a
# caller passes are not given to it, and no credential is ever used (nothing to approve or reject)
Base.Experimental.@overlay OV LibGit2.RemoteCallbacks(c::LibGit2.Callbacks) = LibGit2.RemoteCallbacks()
Base.Experimental.@overlay OV LibGit2.approve(p::LibGit2.CredentialPayload; shred::Bool = true) = nothing
Base.Experimental.@overlay OV LibGit2.reject(p::LibGit2.CredentialPayload; shred::Bool = true) = nothing

# WASI preview 1 has no permission bits, so the files the module writes are not executable: the entries git
# records as executable (100755) of the tree checked out under `root` are made so here, through the
# program's `chmod` (WasmCodegen: the host's `julia_io` file modes; without them, nothing changes).
function exec_bits!(repo::Ptr{Cvoid}, spec::String, root::String)
    rc = try
        ccall((:lg2w_ls_tree, "libgit2"), Int32, (UInt32, UInt32), ha(repo), cin(spec))
    finally
        release!()
    end
    rc < 0 && return nothing
    out = String(copyout(ccall((:lg2w_out_ptr, "libgit2"), UInt32, ()), Int(ccall((:lg2w_out_len, "libgit2"), UInt32, ()))))
    for rec in split(out, '\0'; keepempty = false)       # "<mode> <type> <id>\t<path>"
        startswith(rec, "100755 ") || continue
        t = findfirst('\t', rec)
        t === nothing && continue
        f = joinpath(root, String(SubString(rec, nextind(rec, t))))
        try
            chmod(f, 0o755)
        catch
        end
    end
    return nothing
end

# error.jl: the last error, read from the module
Base.Experimental.@overlay OV function LibGit2.Error.last_error()
    LibGit2.ensure_initialized()
    a = ccall((:git_error_last, "libgit2"), UInt32, ())
    a == 0 && return (Error.Class(0), "No errors")
    return (Error.Class(reinterpret(Int32, load32(a + UInt32(4)))), cout(load32(a)))
end

# reference.jl
Base.Experimental.@overlay OV function LibGit2.branch(ref::LibGit2.GitReference)
    isempty(ref) && return ""
    LibGit2.ensure_initialized()
    try
        o = slot()
        rc = ccall((:git_branch_name, "libgit2"), Int32, (UInt32, UInt32), o, ha(ref.ptr))
        rc < 0 && throw(Error.GitError(rc))
        return cout(load32(o))
    finally
        release!()
    end
end

# config.jl
Base.Experimental.@overlay OV function LibGit2.get(::Type{<:AbstractString}, c::LibGit2.GitConfig, name::AbstractString)
    LibGit2.ensure_initialized()
    try
        b = tmp(12)
        store32(b, UInt32(0)); store64(b + UInt32(4), UInt64(0))
        rc = ccall((:git_config_get_string_buf, "libgit2"), Int32, (UInt32, UInt32, UInt32), b, ha(c.ptr), cin(String(name)))
        rc < 0 && throw(Error.GitError(rc))
        str = String(copyout(load32(b), Int(load32(b + UInt32(8)))))
        ccall((:git_buf_dispose, "libgit2"), Cvoid, (UInt32,), b)
        return str
    finally
        release!()
    end
end

# repository.jl
Base.Experimental.@overlay OV function LibGit2.remotes(repo::LibGit2.GitRepo)
    LibGit2.ensure_initialized()
    @assert repo.ptr != C_NULL
    try
        s = tmp(8)
        store64(s, UInt64(0))
        rc = ccall((:git_remote_list, "libgit2"), Int32, (UInt32, UInt32), s, ha(repo.ptr))
        rc < 0 && throw(Error.GitError(rc))
        return strings_of(s)
    finally
        release!()
    end
end

Base.Experimental.@overlay OV function LibGit2.clone(repo_url::AbstractString, repo_path::AbstractString,
                                                     clone_opts::CloneOptions)
    LibGit2.ensure_initialized()
    try
        o = slot()
        f = clone_opts.fetch_opts
        rc = ccall((:lg2w_clone_raw, "libgit2"), Int32,
                   (UInt32, UInt32, UInt32, Int32, UInt32, UInt32, Int32, Int32, Int32, Int32, Int32),
                   o, cin(String(repo_url)), cin(String(repo_path)), clone_opts.bare, cin(clone_opts.checkout_branch),
                   clone_opts.checkout_opts.checkout_strategy, f.prune, f.update_fetchhead, f.download_tags,
                   reinterpret(Int32, f.depth), reinterpret(Int32, f.follow_redirects))
        rc < 0 && throw(Error.GitError(rc))
        repo = LibGit2.GitRepo(hp(load32(o)))
        clone_opts.bare == 0 && exec_bits!(repo.ptr, "HEAD^{tree}", String(repo_path))
        return repo
    finally
        release!()
    end
end

Base.Experimental.@overlay OV function LibGit2.checkout_tree(repo::LibGit2.GitRepo, obj::LibGit2.GitObject;
                                                             options::CheckoutOptions = CheckoutOptions())
    LibGit2.ensure_initialized()
    @assert repo.ptr != C_NULL
    try
        a = checkout_fields(options)
        rc = ccall((:lg2w_checkout_tree_raw, "libgit2"), Int32,
                   (UInt32, UInt32, UInt32, Int32, UInt32, UInt32, Int32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32),
                   ha(repo.ptr), ha(obj.ptr), a[1], a[2], a[3], a[4], a[5], a[6], a[7], a[8], a[9], a[10], a[11])
        rc < 0 && throw(Error.GitError(rc))
        td = options.target_directory
        root = convert(Ptr{UInt8}, td) == C_NULL ? LibGit2.path(repo) : unsafe_string(td)
        exec_bits!(repo.ptr, string(GitHash(obj)), root)
        return Cint(rc)
    finally
        release!()
    end
end

Base.Experimental.@overlay OV function LibGit2.reset!(repo::LibGit2.GitRepo, obj::LibGit2.GitObject, mode::Cint;
                                                      checkout_opts::CheckoutOptions = CheckoutOptions())
    LibGit2.ensure_initialized()
    @assert repo.ptr != C_NULL
    try
        a = checkout_fields(checkout_opts)
        rc = ccall((:lg2w_reset_raw, "libgit2"), Int32,
                   (UInt32, UInt32, Int32, UInt32, Int32, UInt32, UInt32, Int32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32),
                   ha(repo.ptr), ha(obj.ptr), Int32(mode), a[1], a[2], a[3], a[4], a[5], a[6], a[7], a[8], a[9], a[10], a[11])
        rc < 0 && throw(Error.GitError(rc))
        mode == Cint(Consts.RESET_HARD) && !LibGit2.isbare(repo) && exec_bits!(repo.ptr, "HEAD^{tree}", LibGit2.path(repo))
    finally
        release!()
    end
    return LibGit2.head_oid(repo)
end

# remote.jl
Base.Experimental.@overlay OV function LibGit2.fetch(rmt::LibGit2.GitRemote, refspecs::Vector{<:AbstractString};
                                                     options::FetchOptions = FetchOptions(), msg::AbstractString = "")
    LibGit2.ensure_initialized()
    msg = "libgit2.fetch: $msg"
    try
        rc = ccall((:lg2w_remote_fetch_raw, "libgit2"), Int32,
                   (UInt32, UInt32, UInt32, Int32, Int32, Int32, Int32, Int32),
                   ha(rmt.ptr), strarray(String[String(x) for x in refspecs]), cin(String(msg)), options.prune,
                   options.update_fetchhead, options.download_tags, reinterpret(Int32, options.depth),
                   reinterpret(Int32, options.follow_redirects))
        rc < 0 && throw(Error.GitError(rc))
        return Cint(rc)
    finally
        release!()
    end
end

# index.jl
Base.Experimental.@overlay OV function LibGit2.add!(idx::LibGit2.GitIndex, files::AbstractString...;
                                                    flags::Cuint = Consts.INDEX_ADD_DEFAULT)
    LibGit2.ensure_initialized()
    try
        rc = ccall((:git_index_add_all, "libgit2"), Int32, (UInt32, UInt32, UInt32, UInt32, UInt32),
                   ha(idx.ptr), strarray(String[String(f) for f in files]), UInt32(flags), UInt32(0), UInt32(0))
        rc < 0 && throw(Error.GitError(rc))
        return Cint(rc)
    finally
        release!()
    end
end

# merge.jl
Base.Experimental.@overlay OV function LibGit2.merge_analysis(repo::LibGit2.GitRepo, anns::Vector{LibGit2.GitAnnotated})
    LibGit2.ensure_initialized()
    try
        a, p = tmp(4), tmp(4)
        arr = handles(Ptr{Cvoid}[x.ptr for x in anns])
        rc = ccall((:git_merge_analysis, "libgit2"), Int32, (UInt32, UInt32, UInt32, UInt32, UInt32),
                   a, p, ha(repo.ptr), arr, UInt32(length(anns)))
        rc < 0 && throw(Error.GitError(rc))
        return reinterpret(Int32, load32(a)), reinterpret(Int32, load32(p))
    finally
        release!()
    end
end

# rebase.jl
Base.Experimental.@overlay OV function LibGit2.GitRebase(repo::LibGit2.GitRepo, branch::LibGit2.GitAnnotated,
                                                         upstream::LibGit2.GitAnnotated;
                                                         onto::Union{LibGit2.GitAnnotated, Nothing} = nothing,
                                                         opts::RebaseOptions = RebaseOptions())
    LibGit2.ensure_initialized()
    try
        o = slot()
        rc = ccall((:lg2w_rebase_init_raw, "libgit2"), Int32,
                   (UInt32, UInt32, UInt32, UInt32, UInt32, Int32, Int32, UInt32),
                   o, ha(repo.ptr), ha(branch.ptr), ha(upstream.ptr), onto === nothing ? UInt32(0) : ha(onto.ptr),
                   opts.quiet, opts.inmemory, cin(opts.rewrite_notes_ref))
        rc < 0 && throw(Error.GitError(rc))
        return LibGit2.GitRebase(repo, hp(load32(o)))
    finally
        release!()
    end
end

Base.Experimental.@overlay OV function Base.iterate(rb::LibGit2.GitRebase, state = nothing)
    LibGit2.ensure_initialized()
    try
        o = slot()
        err = ccall((:git_rebase_next, "libgit2"), Int32, (UInt32, UInt32), o, ha(rb.ptr))
        if err == Cint(Error.GIT_OK)
            a = load32(o)       # git_rebase_operation: type, id, exec
            return RebaseOperation(reinterpret(Int32, load32(a)), oid_at(a + UInt32(4)), jcstr(load32(a + UInt32(24)))), nothing
        elseif err == Cint(Error.ITEROVER)
            return nothing
        else
            throw(Error.GitError(err))
        end
    finally
        release!()
    end
end

# signature.jl: a signature of the module (git_signature: name, email, when{time, offset, sign})
Base.Experimental.@overlay OV function LibGit2.Signature(ptr::Ptr{SignatureStruct})
    @assert ptr != C_NULL
    a = ha(ptr)
    return LibGit2.Signature(cout(load32(a)), cout(load32(a + UInt32(4))), reinterpret(Int64, load64(a + UInt32(8))),
                             reinterpret(Int32, load32(a + UInt32(16))))
end

# `close` of the handle types (types.jl), with `git_<type>_free` as a Symbol
for (T, cname) in ((:GitRepo, :git_repository), (:GitConfig, :git_config), (:GitIndex, :git_index),
                   (:GitRemote, :git_remote), (:GitReference, :git_reference), (:GitDiff, :git_diff),
                   (:GitAnnotated, :git_annotated_commit), (:GitRebase, :git_rebase),
                   (:GitUnknownObject, :git_object), (:GitCommit, :git_commit), (:GitBlob, :git_blob),
                   (:GitTree, :git_tree), (:GitTag, :git_tag), (:GitTreeEntry, :git_tree_entry))
    free = QuoteNode(Symbol(cname, :_free))
    @eval Base.Experimental.@overlay WasmCodegen.Runtime.WASM_METHODS function Base.close(obj::LibGit2.$T)
        if obj.ptr != C_NULL
            LibGit2.ensure_initialized()
            ccall(($free, "libgit2"), Cvoid, (UInt32,), ha(obj.ptr))
            obj.ptr = C_NULL
            if Threads.atomic_sub!(LibGit2.REFCOUNT, 1) == 1
                ccall((:git_libgit2_shutdown, "libgit2"), Cint, ())
            end
        end
    end
end

## the build's side

function WasmCompat.libgit2_module()
    return LibGit2_wasm_jll.libgit2_wasm32_wasm
end

function WasmCompat.libgit2_config(config::WasmCodegen.Config; check_version::Bool = true)
    hasfield(WasmCodegen.Config, :import_libraries) && hasfield(WasmCodegen.Config, :foreign_functions) ||
        error("WasmCompat: the LibGit2 backend needs WasmCodegen's Config(foreign_functions) and Config(import_libraries)")
    config.host === :wasi ||
        throw(ArgumentError("WasmCompat.libgit2_config: the libgit2 module is a host import, for Config(host = :wasi)"))
    if check_version
        native = LibGit2.version()
        wasm = pkgversion(LibGit2_wasm_jll)
        (native.major, native.minor, native.patch) == (wasm.major, wasm.minor, wasm.patch) ||
            error("WasmCompat: LibGit2_wasm_jll is libgit2 $(wasm.major).$(wasm.minor).$(wasm.patch), the compiling ",
                  "Julia's libgit2 is $native: install the LibGit2_wasm_jll of the same version (or pass check_version = false)")
    end
    kw = Dict{Symbol,Any}(k => getfield(config, k) for k in fieldnames(WasmCodegen.Config))
    kw[:foreign_functions] = [config.foreign_functions; FUNCTIONS]
    kw[:import_libraries] = unique!([config.import_libraries; "libgit2"])
    return WasmCodegen.Config(; kw...)
end

end # module
