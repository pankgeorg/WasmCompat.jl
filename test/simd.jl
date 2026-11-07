# WasmCompatSIMDExt and WasmCompatBaseExt, natively: each lane overlay (`lane_<name>`, the same
# method as the overlay) against SIMD.jl's own LLVM intrinsic, and the overlays' presence in
# WasmCodegen's table. Included by runtests.jl; standalone: julia --project=<env> test/simd.jl
# (an environment with WasmCodegen, WasmCompat, SIMD and Test).
using Test, WasmCodegen, WasmCompat
import SIMD

@testset "SIMD.jl lanes and generating_output" begin
    SIMDExt = Base.get_extension(WasmCompat, :WasmCompatSIMDExt)
    BaseExt = Base.get_extension(WasmCompat, :WasmCompatBaseExt)
    @test SIMDExt isa Module
    @test BaseExt isa Module
    SI = SIMD.Intrinsics
    L(f) = getfield(SIMDExt, Symbol(:lane_, f))
    lv(v) = map(VecElement, Tuple(v))
    vals(t::Tuple) = map(x -> x isa VecElement ? x.value : vals(x), t)
    vals(x) = x
    same(a, b) = isequal(vals(a), vals(b))          # NaN == NaN, -0.0 != 0.0
    near(a, b) = all(isapprox.(vals(a), vals(b); rtol = 4eps(eltype(vals(b)))))

    @testset "overlays are in WasmCodegen's table, one per lane function" begin
        ov = Set{Symbol}()
        Base.visit(WasmCodegen.Runtime.WASM_METHODS) do m
            m.module === SIMDExt && push!(ov, m.name)
        end
        lanes = Set(Symbol(string(n)[6:end]) for n in names(SIMDExt; all = true) if startswith(string(n), "lane_"))
        @test length(lanes) > 90
        @test lanes == ov
        @test all(f -> isdefined(SI, f), lanes)
    end

    @testset "floats: $T" for T in (Float64, Float32)
        x = lv(T[1.5, -2.25, NaN, 7.0]); y = lv(T[0.5, NaN, 3.0, -4.0]); z = lv(T[2.0, 1.0, -1.0, 0.25])
        for f in (:fadd, :fsub, :fmul, :fdiv, :frem, :minimum, :maximum, :copysign)
            @test same(L(f)(x, y), getfield(SI, f)(x, y))
            @test same(L(f)(x, y, SI.FastMathFlags{0}()), getfield(SI, f)(x, y))
        end
        for f in (:fadd, :fsub, :fmul, :fdiv)
            @test same(L(f)(T(1.25), T(-3)), getfield(SI, f)(T(1.25), T(-3)))
        end
        # minnum/maxnum: the operand that is not NaN (and no ±0 pair, whose order LLVM leaves open)
        for f in (:minnum, :maxnum)
            @test same(L(f)(x, y), getfield(SI, f)(x, y))
        end
        @test same(L(:fneg)(x), SI.fneg(x))
        @test same(L(:fma)(x, y, z), SI.fma(x, y, z))
        @test near(L(:fmuladd)(lv(T[1, 2, 3, 4]), z, z), SI.fmuladd(lv(T[1, 2, 3, 4]), z, z))
        p = lv(T[2.25, 0.5, 9.0, 1.0e3]); r = lv(T[-2.5, 2.5, 3.5, -0.5])
        for f in (:sqrt, :fabs, :floor, :ceil, :trunc, :rint, :nearbyint, :round)
            @test same(L(f)(r), getfield(SI, f)(r))
            @test same(L(f)(p), getfield(SI, f)(p))
        end
        for f in (:sin, :cos, :exp, :exp2, :log, :log10, :log2)
            @test near(L(f)(p), getfield(SI, f)(p))
            @test near(L(f)(T(0.75)), getfield(SI, f)(T(0.75)))
        end
        @test near(L(:pow)(p, z), SI.pow(p, z))
        for flag in (:oeq, :one, :ogt, :oge, :olt, :ole, :ord, :uno, :ueq, :une, :ugt, :uge, :ult, :ule, :false, :true)
            f = Symbol("fcmp_", flag)
            @test same(L(f)(x, y), getfield(SI, f)(x, y))
        end
        c = lv(Bool[1, 0, 1, 0])
        @test same(L(:select)(c, x, y), SI.select(c, x, y))
        e = lv(T[1, 2, 3, 4])                     # exact in any order of summation
        @test same(L(:reduce_fadd)(e), SI.reduce_fadd(e))
        @test same(L(:reduce_fmul)(e), SI.reduce_fmul(e))
        @test near(L(:reduce_fadd)(p), SI.reduce_fadd(p))
        for f in (:reduce_fmaximum, :reduce_fminimum, :reduce_fmax, :reduce_fmin)
            isdefined(SI, f) && @test same(L(f)(p), getfield(SI, f)(p))
        end
    end

    @testset "integers: $T" for T in (Int8, UInt8, Int32, UInt32, Int64, UInt64)
        x = lv(T[typemax(T), 3, typemin(T), 100]); y = lv(T[1, 7, 2, 9]); s = lv(T[1, 3, 8 * sizeof(T) - 1, 0])
        for f in (:add, :sub, :mul, :and, :or, :xor, :sdiv, :udiv, :srem, :urem)
            @test same(L(f)(x, y), getfield(SI, f)(x, y))
        end
        @test same(L(:add)(T(5), T(9)), SI.add(T(5), T(9)))
        for f in (:shl, :ashr, :lshr)
            @test same(L(f)(x, s), getfield(SI, f)(x, s))
        end
        for f in (:bswap, :bitreverse, :ctpop, :ctlz, :cttz)
            @test same(L(f)(x), getfield(SI, f)(x))
            @test same(L(f)(T(6)), getfield(SI, f)(T(6)))
        end
        for f in (:fshl, :fshr)
            @test same(L(f)(x, y, s), getfield(SI, f)(x, y, s))
        end
        for f in (:sadd_sat, :uadd_sat, :ssub_sat, :usub_sat)
            @test same(L(f)(x, y), getfield(SI, f)(x, y))
        end
        for f in (:sadd_with_overflow, :uadd_with_overflow, :ssub_with_overflow, :usub_with_overflow,
                  :smul_with_overflow, :umul_with_overflow)
            @test same(L(f)(x, y), getfield(SI, f)(x, y))
        end
        for flag in (:eq, :ne, :sgt, :sge, :slt, :sle, :ugt, :uge, :ult, :ule)
            f = Symbol("icmp_", flag)
            @test same(L(f)(x, y), getfield(SI, f)(x, y))
        end
        for f in (:reduce_and, :reduce_or, :reduce_mul, :reduce_add, :reduce_smax, :reduce_smin, :reduce_umax, :reduce_umin)
            @test same(L(f)(x), getfield(SI, f)(x))
        end
    end

    @testset "lanes, conversions, masks" begin
        x = lv([1.5, -2.0, 3.25, 4.0]); y = lv([10.0, 20.0, 30.0, 40.0])
        @test same(L(:extractelement)(x, 2), SI.extractelement(x, 2))
        @test same(L(:insertelement)(x, 9.0, 1), SI.insertelement(x, 9.0, 1))
        @test same(L(:constantvector)(2.5, SIMD.LVec{4,Float64}), SI.constantvector(2.5, SIMD.LVec{4,Float64}))
        @test same(L(:shufflevector)(x, y, Val((0, 5, 2, 7))), SI.shufflevector(x, y, Val((0, 5, 2, 7))))
        @test same(L(:shufflevector)(x, Val((3, 2, 1, 0, 0))), SI.shufflevector(x, Val((3, 2, 1, 0, 0))))
        i = lv(Int32[-3, 7, 1 << 20, 0])
        @test same(L(:sitofp)(SIMD.LVec{4,Float64}, i), SI.sitofp(SIMD.LVec{4,Float64}, i))
        @test same(L(:fptosi)(SIMD.LVec{4,Int64}, x .|> v -> VecElement(floor(v.value))),
                   SI.fptosi(SIMD.LVec{4,Int64}, x .|> v -> VecElement(floor(v.value))))
        @test same(L(:fptrunc)(SIMD.LVec{4,Float32}, x), SI.fptrunc(SIMD.LVec{4,Float32}, x))
        @test same(L(:fpext)(SIMD.LVec{4,Float64}, lv(Float32[1.5, 2, 3, 4])), SI.fpext(SIMD.LVec{4,Float64}, lv(Float32[1.5, 2, 3, 4])))
        @test same(L(:sext)(SIMD.LVec{4,Int64}, i), SI.sext(SIMD.LVec{4,Int64}, i))
        @test same(L(:zext)(SIMD.LVec{4,UInt64}, lv(UInt32[1, 2, typemax(UInt32), 4])), SI.zext(SIMD.LVec{4,UInt64}, lv(UInt32[1, 2, typemax(UInt32), 4])))
        @test same(L(:trunc)(SIMD.LVec{4,Int8}, i), SI.trunc(SIMD.LVec{4,Int8}, i))
        @test same(L(:bitcast)(SIMD.LVec{4,UInt64}, x), SI.bitcast(SIMD.LVec{4,UInt64}, x))
        @test same(L(:bitcast)(UInt64, 1.5), SI.bitcast(UInt64, 1.5))
        m = lv(Bool[1, 0, 1, 1])
        @test same(L(:bitmask)(m), SI.bitmask(m))
        @test same(L(:reduce_add)(m), SI.reduce_add(m))
    end

    @testset "memory" begin
        a = collect(1.0:8.0); b = zeros(8); c = zeros(8)
        m = lv(Bool[1, 0, 1, 1])
        GC.@preserve a b c begin
            p = pointer(a, 2)
            @test same(L(:load)(SIMD.LVec{4,Float64}, p), SI.load(SIMD.LVec{4,Float64}, p))
            @test same(L(:maskedload)(p, m), SI.maskedload(p, m))
            @test same(L(:maskedexpandload)(p, m), SI.maskedexpandload(p, m))
            ptrs = lv([pointer(a, 8), pointer(a, 1), pointer(a, 5), pointer(a, 3)])
            @test same(L(:maskedgather)(ptrs, m), SI.maskedgather(ptrs, m))
            v = lv([-1.0, -2.0, -3.0, -4.0])
            for (f, args) in ((:store, ()), (:maskedstore, (m,)), (:maskedcompressstore, (m,)))
                fill!(b, 0); fill!(c, 0)
                L(f)(v, pointer(b, 3), args...); getfield(SI, f)(v, pointer(c, 3), args...)
                @test b == c
            end
            fill!(b, 0); fill!(c, 0)
            L(:maskedscatter)(v, lv([pointer(b, 8), pointer(b, 1), pointer(b, 5), pointer(b, 3)]), m)
            SI.maskedscatter(v, lv([pointer(c, 8), pointer(c, 1), pointer(c, 5), pointer(c, 3)]), m)
            @test b == c
        end
    end

    @testset "generating_output: false in Wasm" begin
        ov = Method[]
        Base.visit(m -> m.module === BaseExt && push!(ov, m), WasmCodegen.Runtime.WASM_METHODS)
        @test any(m -> m.name === :generating_output, ov)
    end
end
