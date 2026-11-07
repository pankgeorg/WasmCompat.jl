# Base's globals of the build process, emptied before the image is emitted
# (a `Config(pre_image_hooks)` entry; WasmCodegen has the hook mechanism but no such hook),
# plus the image's standard streams. It lives beside build.jl, not in a patch file: a hook must
# exist when the `Config` is made, before the patch session opens. The program initializes
# these globals at run time (the entry shim's init). Natively the restore puts everything back when the compilation ends.

module BuildBaseGlobals

"""
    sanitize_base_globals!() -> restore

Empty Base's globals of the build process's state (so that the image is relocatable),
returning a function that restores them (a pre-image hook's restore, see `Config`):

| Global | In the image |
|---|---|
| `DEPOT_PATH`, `LOAD_PATH`, `DL_LOAD_PATH`, `ARGS` | empty (initialized at run time) |
| `ACTIVE_PROJECT[]`, `HOME_PROJECT[]`, `LOADING_CACHE[]` | `nothing` |
| `TOML_CACHE` (parsed TOML files, by path, and its parser: the last input, path, tree) | empty, a fresh parser |
| `loaded_modules`, `loaded_modules_order`, `loaded_precompiles` | the modules of the sysimage only (`_sysimage_modules`), as a new process has them |
| `EXT_DORMITORY`, `EXT_DORMITORY_FAILED` | empty |
| `pkgorigins`, `EXT_PRIMED` (loaded packages) | empty |
| `Filesystem.TEMP_CLEANUP` (temporary paths to remove at exit) | empty |
| `PROGRAM_FILE`, `Sys.BINDIR`, `Sys.STDLIB` | `""` |
| `have_color`, `have_truecolor` | `nothing` (as before stdio is initialized) |
| `stdout`, `stderr`, `stdin` | `Core.stdout`, `Core.stderr`, `devnull` (no libuv stream of the build process) |

(Not reset: the cached terminfo of `Base.current_terminfo`, which only colored output to a
terminal reads: the module's streams have no color.) `ENV` holds no state (the host's
environment is read at run time).
"""
function sanitize_base_globals!()
    vecs = (Base.DEPOT_PATH, Base.LOAD_PATH, Base.DL_LOAD_PATH, Base.ARGS)
    saved_vecs = map(copy, vecs)
    refs = (Base.ACTIVE_PROJECT, Base.HOME_PROJECT, Base.LOADING_CACHE)
    saved_refs = map(r -> r[], refs)
    dicts = (Base.TOML_CACHE.d, Base.pkgorigins, Base.EXT_PRIMED, Base.Filesystem.TEMP_CLEANUP,
             Base.EXT_DORMITORY)
    saved_dicts = map(copy, dicts)
    globals = ((Base, :PROGRAM_FILE, ""), (Base.Sys, :BINDIR, ""), (Base.Sys, :STDLIB, ""),
               (Base, :have_color, nothing), (Base, :have_truecolor, nothing),
               (Base, :stdout, Core.stdout), (Base, :stderr, Core.stderr), (Base, :stdin, devnull))
    # the TOML parser (its last input, file path and tree), reset in place (its fields saved)
    parser = Base.TOML_CACHE.p
    PT = typeof(parser)
    parser_fields = [i for i in 1:fieldcount(PT) if !isconst(PT, i) && isdefined(parser, i)]
    saved_parser = Any[getfield(parser, i) for i in parser_fields]
    # the loaded modules: those of the sysimage, as a new process has them
    sysimage = Set(Base._sysimage_modules)
    saved_loaded = copy(Base.loaded_modules)
    saved_order = copy(Base.loaded_modules_order)
    saved_precompiles = copy(Base.loaded_precompiles)
    saved_failed = copy(Base.EXT_DORMITORY_FAILED)
    saved_globals = map(((m, s, _),) -> getglobal(m, s), globals)
    restore = function ()
        for (v, s) in zip(vecs, saved_vecs)
            append!(empty!(v), s)
        end
        for (r, s) in zip(refs, saved_refs)
            r[] = s
        end
        for (d, s) in zip(dicts, saved_dicts)
            merge!(empty!(d), s)
        end
        for ((m, s, _), v) in zip(globals, saved_globals)
            setglobal!(m, s, v)
        end
        for (i, v) in zip(parser_fields, saved_parser)
            setfield!(parser, i, v)
        end
        merge!(empty!(Base.loaded_modules), saved_loaded)
        append!(empty!(Base.loaded_modules_order), saved_order)
        merge!(empty!(Base.loaded_precompiles), saved_precompiles)
        append!(empty!(Base.EXT_DORMITORY_FAILED), saved_failed)
        return nothing
    end
    try
        foreach(empty!, vecs)
        foreach(r -> r[] = nothing, refs)
        foreach(empty!, dicts)
        for (m, s, v) in globals
            setglobal!(m, s, v)
        end
        # (fresh collections first: reinit! empties them in place, and the saved ones are
        # restored with their contents)
        for i in parser_fields
            v = getfield(parser, i)
            v isa Union{AbstractVector,AbstractDict,AbstractSet} && setfield!(parser, i, typeof(v)())
        end
        Base.TOML.reinit!(parser, ""; filepath=nothing)
        filter!(((k, _),) -> k in sysimage, Base.loaded_modules)
        keep = Set(values(Base.loaded_modules))
        filter!(m -> m in keep, Base.loaded_modules_order)
        filter!(((k, _),) -> k in sysimage, Base.loaded_precompiles)
        empty!(Base.EXT_DORMITORY_FAILED)
    catch
        restore()   # (what was changed before the failure)
        rethrow()
    end
    return restore
end

end # module
