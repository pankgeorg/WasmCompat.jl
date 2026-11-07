"""
    WasmCompatArtifactsExt

Artifacts for WasmCodegen's closed world. One overlay (a method of
`WasmCodegen.Runtime.WASM_METHODS`, used only when compiling to Wasm):

- `Artifacts.parse_mapping` of a table (an `Overrides.toml` UUID entry; `load_overrides` runs on
  every `artifact_exists`/`artifact_path` lookup). The stdlib builds the `Dict` from a generator of
  `k => parse_mapping(v, ...)` pairs: each `v` is an `Any` (a dynamic call), and the generator's
  element type is the abstract `Pair{String}`, which WasmCodegen does not represent. Here the
  table is filled in a loop and each value's method is chosen by `isa`: the same methods, the
  same values, the same `Dict{String, Any}`.
- `Artifacts.artifact_meta(name, artifact_dict, artifacts_toml; platform)` (every artifact selection,
  `select_downloadable_artifacts`): an artifact with platform variants is tested as an abstract
  `Vector` and iterated as one (a dynamic `getindex`). TOML arrays of tables are `Vector{Any}`:
  tested as such, the same entries, the same messages.
- `BinaryPlatforms.platforms_match(a::Platform, b::Platform)`: each tag is compared by the
  platforms' comparison strategy, a `Function` from a `Dict{String, Function}`, called through
  `@invokelatest`: a dynamic call. Base sets three strategies: `compare_default`,
  `compare_version_cap` (`HostPlatform(p)`) and the `julia_version` closure of the `Platform`
  constructor; each is called directly by its identity or type (another one is an error here).
- `BinaryPlatforms.select_platform(download_info, platform)`: the same selection, the value looked up
  directly instead of with `@invokelatest getindex(...)`.
"""
module WasmCompatArtifactsExt

import Artifacts
import WasmCodegen
using Base.BinaryPlatforms: BinaryPlatforms, Platform, AbstractPlatform, tags, triplet,
    compare_default, compare_version_cap, get_compare_strategy, platforms_match

Base.Experimental.@overlay WasmCodegen.Runtime.WASM_METHODS function Artifacts.parse_mapping(
        mapping::Dict{String, Any}, name::String, override_file::String)
    d = Dict{String, Any}()
    for (k, v) in mapping
        d[k] = v isa String ? Artifacts.parse_mapping(v, name, override_file) :
               v isa Dict{String, Any} ? Artifacts.parse_mapping(v, name, override_file) :
               nothing # (`parse_mapping(mapping, name, override_file) = nothing`, the stdlib's fallthrough)
    end
    return d
end

Base.Experimental.@overlay WasmCodegen.Runtime.WASM_METHODS function Artifacts.artifact_meta(
        name::String, artifact_dict::Dict, artifacts_toml::String; platform::AbstractPlatform = BinaryPlatforms.HostPlatform())
    if !haskey(artifact_dict, name)
        return nothing
    end
    meta = artifact_dict[name]
    # If it's an array, find the entry that best matches our current platform
    if meta isa Vector{Any}
        dl_dict = Dict{Platform, Dict{String, Any}}()
        for x in meta
            x = x::Dict{String, Any}
            dl_dict[Artifacts.unpack_platform(x, name, artifacts_toml)::Platform] = x
        end
        meta = BinaryPlatforms.select_platform(dl_dict, platform)
    # If it's NOT a dict, complain
    elseif !(meta isa Dict{String, Any})
        @error("Invalid artifacts file at $(artifacts_toml): artifact '$name' malformed, must be array or dict!")
        return nothing
    end
    if meta !== nothing
        meta = meta::Dict{String, Any}
        if !haskey(meta, "git-tree-sha1")
            @error("Invalid artifacts file at $(artifacts_toml): artifact '$name' contains no `git-tree-sha1`!")
            return nothing
        end
    end
    return meta
end

# the type of the `julia_version` strategy the `Platform` constructor sets (a closure of Base)
const JULIA_VERSION_STRATEGY = typeof(Platform("x86_64", "linux"; julia_version = v"1.0.0").compare_strategies["julia_version"])

# a comparison strategy of Base's, called directly
function call_strategy(@nospecialize(f), ak::String, bk::String, a_req::Bool, b_req::Bool)::Bool
    f === compare_default && return compare_default(ak, bk, a_req, b_req)
    f === compare_version_cap && return compare_version_cap(ak, bk, a_req, b_req)
    f isa JULIA_VERSION_STRATEGY && return (f::JULIA_VERSION_STRATEGY)(ak, bk, a_req, b_req)::Bool
    throw(ArgumentError("a platform comparison strategy other than Base's: not supported in this module"))
end

Base.Experimental.@overlay WasmCodegen.Runtime.WASM_METHODS function BinaryPlatforms.platforms_match(a::Platform, b::Platform)
    for k in union(keys(tags(a)::Dict{String, String}), keys(tags(b)::Dict{String, String}))
        ak = get(tags(a), k, nothing)
        bk = get(tags(b), k, nothing)
        if ak === nothing || bk === nothing
            continue
        end
        a_comp = get_compare_strategy(a, k)
        b_comp = get_compare_strategy(b, k)
        if a_comp !== compare_default && b_comp !== compare_default && a_comp !== b_comp
            throw(ArgumentError("Cannot compare Platform objects with two different non-default comparison strategies for the same key \"$(k)\""))
        end
        comparator = a_comp
        if b_comp !== compare_default
            comparator = b_comp
        end
        call_strategy(comparator, ak, bk, a_comp === comparator, b_comp === comparator) || return false
    end
    return true
end

Base.Experimental.@overlay WasmCodegen.Runtime.WASM_METHODS function BinaryPlatforms.select_platform(
        download_info::Dict, platform::AbstractPlatform = BinaryPlatforms.HostPlatform())
    ps = collect(filter(p -> platforms_match(p, platform), keys(download_info)))
    isempty(ps) && return nothing
    function match_loss(a, b)
        a_tags = Set(keys(tags(a)))
        b_tags = Set(keys(tags(b)))
        return length(union(a_tags, b_tags)) - length(intersect(a_tags, b_tags))
    end
    sort!(ps, lt = (a, b) -> begin
        loss_a = match_loss(a, platform)
        loss_b = match_loss(b, platform)
        if loss_a != loss_b
            return loss_a < loss_b
        end
        return triplet(a) > triplet(b)
    end)
    return download_info[first(ps)]
end

end # module
