# Build patch for the package manager's entry shim (`PkgEntry`): `PkgEntry.init_runtime()` in Wasm,
# and `@script` load paths. Base's runtime globals (ARGS, ENV, DEPOT_PATH, LOAD_PATH, the active
# project, the working directory) are what Julia's startup sets natively (`Base.__init__`), which a
# Wasm module does not run. WasmCodegen has no `Runtime.init_base_globals!`; when it has one, it is
# used, else this is a port of it on WasmCodegen's runtime (WASI `args_get`, `Runtime.Env`,
# `Runtime.FS.cwd`). Applied with `Config(extra_patches)`, bound: `PkgEntry`. Method definitions only.

if isdefined(PkgEntry, :init_runtime)
    if isdefined(WasmCodegen.Runtime, :init_base_globals!)
        let init = WasmCodegen.Runtime.init_base_globals!
            @eval PkgEntry init_runtime()::Nothing = ($init(); nothing)
        end
    else
        # Without `init_base_globals!`: WASI `args_get` through the runtime's staging memory, the
        # environment snapshot (`Runtime.Env`) and the working directory (`Runtime.FS.cwd`). What Julia's startup does natively
        # (`Base.__init__`), in this order: ARGS (the WASI arguments but the program's name), the
        # environment and the working directory read now, DEPOT_PATH (as `Base.init_depot_path`
        # without a Julia installation's bundled depots), LOAD_PATH (`Base.init_load_path`), the
        # active project (`JULIA_PROJECT`; there is no `--project`). The task RNG is WasmCodegen's
        # (seeded from the host's entropy when the module starts). Not reset: PROGRAM_FILE (the
        # build empties it with the other Base globals before the image is written).
        let RT = WasmCodegen.Runtime, Staging = WasmCodegen.Runtime.Staging, Env = WasmCodegen.Runtime.Env
            @eval PkgEntry begin
                wasi_args_sizes_get(count::UInt32, size::UInt32) =
                    ccall((:args_sizes_get, "wasi_snapshot_preview1"), Int32, (UInt32, UInt32), count, size)
                wasi_args_get(argv::UInt32, buf::UInt32) =
                    ccall((:args_get, "wasi_snapshot_preview1"), Int32, (UInt32, UInt32), argv, buf)

                # the program's arguments (WASI `args_get`), the first its name
                function wasi_args()::Vector{String}
                    return $Staging.with_scope() do
                        $RT.wasi_check(wasi_args_sizes_get($Staging.SCRATCH_OUT, $Staging.SCRATCH_OUT + UInt32(4)), "args_sizes_get")
                        count = $Staging.load32($Staging.SCRATCH_OUT)
                        size = $Staging.load32($Staging.SCRATCH_OUT + UInt32(4))
                        count == 0 && return String[]
                        ptrs = $Staging.alloc_data(4 * Int(count); align = 4)
                        buf = $Staging.alloc_data(max(Int(size), 1); align = 1)
                        $RT.wasi_check(wasi_args_get(ptrs, buf), "args_get")
                        return String[$Env.cstring_at($Staging.load32(ptrs + UInt32(4i))) for i in 0:Int(count)-1]
                    end
                end

                # `Base.init_depot_path`, without the bundled depots: an empty entry adds nothing,
                # and without JULIA_DEPOT_PATH the depot is ~/.julia only
                function wasm_init_depot_path!()
                    D = Base.DEPOT_PATH
                    empty!(D)
                    str = get(ENV, "JULIA_DEPOT_PATH", nothing)
                    if str !== nothing
                        isempty(str) && return nothing
                        pushfirst_default = true
                        for (i, path) in enumerate(eachsplit(str, ':'))
                            isempty(path) && continue
                            p = expanduser(String(path))
                            p in D || push!(D, p)
                            i == 1 && (pushfirst_default = false)
                        end
                        pushfirst_default && pushfirst!(D, joinpath(homedir(), ".julia"))
                    else
                        push!(D, joinpath(homedir(), ".julia"))
                    end
                    return nothing
                end

                # `Base.init_active_project` from JULIA_PROJECT
                function wasm_init_active_project!()
                    project = get(ENV, "JULIA_PROJECT", nothing)
                    Base.ACTIVE_PROJECT[] = project === nothing || isempty(project) ? nothing :
                        startswith(project, "@") ? Base.load_path_expand(project) : abspath(expanduser(project))
                    return nothing
                end

                function init_runtime()::Nothing
                    args = wasi_args()
                    empty!(Base.ARGS)
                    length(args) > 1 && append!(Base.ARGS, args[2:end])
                    $Env.entries()
                    $RT.FS.cwd()
                    wasm_init_depot_path!()
                    Base.init_load_path()
                    wasm_init_active_project!()
                    return nothing
                end
            end
        end

        # `@script` in a load path is the script's (`JLOptions().program_file`): WasmCodegen answers
        # `JLOptions()` with the build process's options, whose program_file is the build
        # script's path. A program in Wasm has no script.
        @eval Base function load_path_expand(env::AbstractString)::Union{String, Nothing}
            if startswith(env, '@')
                env == "@" && return active_project(false)
                env == "@." && return current_project()
                env == "@temp" && return mktempdir()
                # (no standard library directory on a host: `Sys.STDLIB` is empty, no environment)
                env == "@stdlib" && return isempty(Sys.STDLIB) ? nothing : Sys.STDLIB
                startswith(env, "@script") && return nothing
                env = replace(env, '#' => VERSION.major, count=1)
                env = replace(env, '#' => VERSION.minor, count=1)
                env = replace(env, '#' => VERSION.patch, count=1)
                name = env[2:end]
                for depot in DEPOT_PATH
                    path = joinpath(depot, "environments", name)
                    isdir(path) || continue
                    for proj in project_names
                        file = abspath(path, proj)
                        isfile_casesensitive(file) && return file
                    end
                end
                isempty(DEPOT_PATH) && return nothing
                return abspath(DEPOT_PATH[1], "environments", name, project_names[end])
            end
            path = abspath(env)
            if isdir(path)
                for proj in project_names
                    file = joinpath(path, proj)
                    isfile_casesensitive(file) && return file
                end
            end
            return path
        end
    end
end


