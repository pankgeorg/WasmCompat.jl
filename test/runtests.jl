# Native tests of WasmCompat's extensions: each typed replacement against the standard library's
# own code, byte for byte, and the overlays' presence in WasmCodegen's table. The programs in
# test/wasm/ check the same in Wasm (they need Node; see test/wasm/README.md).

using Test
using WasmCodegen, WasmCompat
import TOML, Logging, Tar, ArgTools, Artifacts, Dates
import PCRE2_wasm_jll
import LibGit2, LibGit2_wasm_jll
using Base: UUID, SHA1, IdSet
using Random: Xoshiro

struct Opaque end

ext(name) = something(Base.get_extension(WasmCompat, name), nothing)
const TOMLExt = ext(:WasmCompatTOMLExt)
const LoggingExt = ext(:WasmCompatLoggingExt)
const TarExt = ext(:WasmCompatTarExt)
const ArgToolsExt = ext(:WasmCompatArgToolsExt)
const ArtifactsExt = ext(:WasmCompatArtifactsExt)
const PCRE2Ext = ext(:WasmCompatPCRE2Ext)
const LibGit2Ext = ext(:WasmCompatLibGit2Ext)

# the methods of WasmCodegen's overlay table defined by module `m`
function overlays(m::Module)
    found = Method[]
    Base.visit(WasmCodegen.Runtime.WASM_METHODS) do meth
        meth.module === m && push!(found, meth)
    end
    return found
end

@testset "WasmCompat" begin
    @testset "extensions load" begin
        @test TOMLExt isa Module
        @test LoggingExt isa Module
        @test TarExt isa Module
        @test ArgToolsExt isa Module
        @test ArtifactsExt isa Module
        @test PCRE2Ext isa Module
        @test LibGit2Ext isa Module
    end

    @testset "TOML: typed printer = TOML.print" begin
        typed(d; sorted = false, by = identity, inline_tables = IdSet{Dict{String}}(), f = identity) =
            sprint(io -> TOMLExt.print_table(f, io, d, String[], 0, true, sorted, inline_tables, by))
        stock(d; sorted = false, by = identity, inline_tables = IdSet{Dict{String}}(), f = identity) =
            sprint(io -> TOML.print(f, io, d; sorted, by, inline_tables))
        doc = """
        name = "Example"
        version = "0.5.4"
        authors = ["A <a@example.com>", "B"]
        [deps]
        Alpha = "11111111-2222-3333-4444-555555555555"
        "needs quotes" = "x"
        [[arr]]
        x = 1
        [[arr]]
        x = 2.5
        y = [true, false, 3, "mixed"]
        z = 0x7f
        [nested.inner]
        when = 1979-05-27T07:32:00Z
        day = 1979-05-27
        at = 07:32:00.5
        s = "line\\nbreak \\"q\\" \\u00e9 \\t"
        inf = inf
        nan = nan
        neg = -0.0
        empty = {}
        inl = {a = 1, b = [1, 2]}
        [nested.empty]
        """
        d = TOML.parse(doc)
        @test typed(d) == stock(d)
        @test typed(d; sorted = true) == stock(d; sorted = true)
        order = Dict("name" => 0, "version" => 1)
        by = k -> (get(order, k, 9), k)
        @test typed(d; sorted = true, by) == stock(d; sorted = true, by)

        # a project-like table: a conversion function, inline tables, `by`
        p = Dict{String, Any}("name" => "X", "uuid" => UUID("7876af07-990d-54b4-ab0e-23690620f79a"),
            "version" => v"1.2.3", "deps" => Dict{String, Any}("B" => "b", "A" => "a"),
            "sources" => Dict{String, Any}("B" => Dict{String, Any}("url" => "https://example.com/B.jl", "rev" => "main")),
            "extras" => Dict{String, String}("T" => "t"), "targets" => Dict{String, Any}("test" => ["T"]),
            "compat" => Dict{String, Any}("julia" => "1.10"), "nothing" => nothing, "sym" => :s)
        inline = IdSet{Dict}()
        push!(inline, p["sources"]["B"])
        conv = x -> x isa Union{UUID, VersionNumber, Nothing, Symbol} ? string(x) : error("unhandled")
        for sorted in (false, true)
            @test typed(p; f = conv, sorted, by, inline_tables = inline) == stock(p; f = conv, sorted, by, inline_tables = inline)
        end
        # a manifest-like table (arrays of tables of several element types, dates)
        m = Dict{String, Any}("julia_version" => "1.13.2", "manifest_format" => "2.0",
            "deps" => Dict{String, Vector{Dict{String, Any}}}("A" => [Dict{String, Any}("uuid" => "u", "version" => "1.0.0",
                "deps" => ["B", "C"], "git-tree-sha1" => "abc"), Dict{String, Any}("uuid" => "v")]),
            "usage" => Dict{String, Vector{Dict{String, Dates.DateTime}}}("/x" => [Dict("time" => Dates.DateTime(2026, 11, 5, 12, 30, 1, 5))]),
            "dates" => [Dates.Date(2026, 1, 2), Dates.Date(2026, 3, 4)])
        @test typed(m; sorted = true) == stock(m; sorted = true)
        # random tables of the kinds of values the printer knows
        rng = Xoshiro(7)
        leaf() = rand(rng, (() -> rand(rng, Int), () -> rand(rng), () -> rand(rng, Bool),
                            () -> string("s", rand(rng, 1:99)), () -> [rand(rng, Int) for _ in 1:rand(rng, 0:3)],
                            () -> String[string(i) for i in 1:rand(rng, 0:3)]))()
        function table(depth)
            t = Dict{String, Any}()
            for i in 1:rand(rng, 0:5)
                k = rand(rng, ("a", "b", "c d", "é", "x$i", ""))
                t[k] = depth > 0 && rand(rng) < 0.3 ? table(depth - 1) :
                       depth > 0 && rand(rng) < 0.15 ? Dict{String, Any}[table(depth - 1) for _ in 1:2] : leaf()
            end
            return t
        end
        for _ in 1:200
            t = table(3)
            @test typed(t; sorted = true) == stock(t; sorted = true)
            @test typed(t) == stock(t)
        end
        # errors as Base's: no conversion function, a conversion to a non-TOML value
        @test_throws ErrorException typed(Dict{String, Any}("u" => UUID(0)))
        @test_throws ErrorException typed(Dict{String, Any}("u" => UUID(0)); f = x -> x)
        # a value of a type the closed-world printer does not know
        @test_throws ErrorException typed(Dict{String, Any}("o" => [Opaque()]))
        # the overlays: print_table, and the four integer parsers
        @test length(overlays(TOMLExt)) >= 5
    end

    @testset "Logging: Wasm logger = ConsoleLogger" begin
        # (ConsoleLogger on a stream without color, sized as `displaysize()`, as stderr redirected to a file)
        function stock(f)
            buf = IOBuffer()
            Logging.with_logger(f, Logging.ConsoleLogger(buf, Logging.Info))
            return String(take!(buf))
        end
        typed(level, msg, kw; mod = Main, file = "/a/b.jl", line = 3, id = :x) = sprint() do io
            LoggingExt.log_record(io, level, msg, mod, id, file, line, kw)
        end
        # each record as the macro would pass it (`_file`/`_line` given, so both sides agree)
        cases = [
            (Logging.Info, "plain", (;)),
            (Logging.Info, "values", (; n = 3, s = "str", sym = :abc, ver = v"1.2.3", u = UUID(1), b = true, f = 1.5)),
            (Logging.Warn, "warn", (; key = :sym)),
            (Logging.Error, "err", (; exception = ErrorException("boom"))),
            (Logging.Warn, "arg", (; e = ArgumentError("bad"))),
            (Logging.Info, "multi\nline\nmessage", (; x = "a\nb")),
        ]
        for (level, msg, kw) in cases
            native = stock() do
                Base.CoreLogging.handle_message(Logging.current_logger(), level, msg, Main, :g, :x, "/a/b.jl", 3; kw...)
            end
            @test typed(level, msg, kw) == native
        end
        # maxlog: counted per id
        empty!(LoggingExt.MAXLOG)
        outs = [typed(Logging.Warn, "once", (; maxlog = 1, i = i); id = :once) for i in 1:3]
        @test outs[1] != "" && outs[2] == "" && outs[3] == ""
        # a value of a type it does not know
        @test occursin("(a value of type", typed(Logging.Info, "m", (; t = (1, 2))))
        # the program's exceptions
        @test LoggingExt.showerror_any(IOBuffer(), ErrorException("x")) === nothing
        @test length(overlays(LoggingExt)) == 1
    end

    @testset "Tar: version field without a regex" begin
        r = Tar.index_range(:version)
        fields = [UInt8[], b"00", b"  ", b"0 ", b"00 ", b"0 0", b"01", b"\n", b"00\n", b"0 \n", b"0\n\n", b" 0", b"0\x00x", b"\x00", b"ab"]
        for f in fields
            buf = zeros(UInt8, 512)
            buf[first(r):first(r) + min(length(f), length(r)) - 1] .= f[1:min(length(f), length(r))]
            @test TarExt.version_field_ok(buf) == occursin(r"^0* *$", Tar.read_header_str(buf, :version))
        end
        @test length(overlays(TarExt)) >= 16 # the generated callback specializations + check_version_field
        @test length(overlays(ArgToolsExt)) >= 12
        @test length(overlays(ArtifactsExt)) == 1
    end

    @testset "PCRE2: the configuration and the module" begin
        m = WasmCompat.pcre2_module()
        @test isfile(m) && read(m, 4) == b"\0asm"
        # the module's PCRE2 is the compiling Julia's (error messages and offsets differ between minors)
        native = PCRE2Ext.native_pcre2_version()
        @test (native.major, native.minor) == (pkgversion(PCRE2_wasm_jll).major, pkgversion(PCRE2_wasm_jll).minor)
        # one function per PCRE2 call Base's pcre.jl makes outside its JIT stacks and match contexts
        names = Set(first(k) for (k, _) in PCRE2Ext.FUNCTIONS)
        @test length(names) == 13 && all(k -> k[2] == "libpcre2-8", first.(PCRE2Ext.FUNCTIONS))
        @test :pcre2_match_8 in names && :pcre2_substring_copy_bynumber_8 in names
        if hasfield(WasmCodegen.Config, :foreign_functions) && hasfield(WasmCodegen.Config, :import_libraries)
            c = WasmCompat.pcre2_config(WasmCodegen.Config(host = :wasi, import_libraries = ["other"]))
            @test length(c.foreign_functions) == 13 && c.import_libraries == ["other", "pcre2"]
            @test WasmCompat.pcre2_config(c).import_libraries == ["other", "pcre2"]
            @test_throws ArgumentError WasmCompat.pcre2_config(WasmCodegen.Config(host = :js))
        else
            @test_throws ErrorException WasmCompat.pcre2_config(WasmCodegen.Config(host = :wasi))
        end
    end

    @testset "LibGit2: the configuration, the module and the overlays" begin
        m = WasmCompat.libgit2_module()
        @test isfile(m) && read(m, 4) == b"\0asm"
        @test LibGit2.version() == VersionNumber(pkgversion(LibGit2_wasm_jll).major, pkgversion(LibGit2_wasm_jll).minor,
                                                 pkgversion(LibGit2_wasm_jll).patch)
        fs = LibGit2Ext.FUNCTIONS
        @test all(k -> k[2] == LibGit2.LibGit2_jll.libgit2, first.(fs))
        names = Set(first(k) for (k, _) in fs)
        @test length(names) == length(fs)
        @test :git_repository_open in names && :git_revparse_single in names && :git_oid_fromraw in names
        # the calls with structs or pointer arrays are overlays, not foreign functions
        @test !(:git_clone in names) && !(:git_remote_fetch in names) && !(:git_checkout_tree in names)
        @test length(overlays(LibGit2Ext)) >= 30
        if hasfield(WasmCodegen.Config, :foreign_functions) && hasfield(WasmCodegen.Config, :import_libraries)
            c = WasmCompat.libgit2_config(WasmCodegen.Config(host = :wasi, import_libraries = ["other"]))
            @test length(c.foreign_functions) == length(fs) && c.import_libraries == ["other", "libgit2"]
            @test_throws ArgumentError WasmCompat.libgit2_config(WasmCodegen.Config(host = :js))
        end
    end

    include("simd.jl")

    @testset "generated overlays are current" begin
        # (the generator writes for this Julia's Tar and ArgTools; compare when they are the ones generated)
        for (mod, sub) in ((Tar, "TarExt"), (ArgTools, "ArgToolsExt"))
            file = joinpath(dirname(@__DIR__), "ext", sub, "specialized_$(pkgversion(mod)).jl")
            @test isfile(file)
        end
    end
end
