"""
    WasmCompatSIMDExt

SIMD.jl for WasmCodegen's closed world. SIMD.jl's `Vec` operations end in the functions of
`SIMD.Intrinsics`, each a `Base.llvmcall` of LLVM IR (or a `ccall` of an LLVM intrinsic), which
WasmCodegen does not compile: every function that uses a `Vec` would trap. Loaded with WasmCodegen
and SIMD.

Here each intrinsic is the same operation on each lane, in Julia: an overlay in WasmCodegen's
method table, so native SIMD.jl is unchanged. The lanes stay `NTuple{N,VecElement{T}}`, so code
written with `SIMD.Vec` compiles as it is. Each overlay is also a function of this module,
`lane_<name>` (e.g. `lane_fadd`), with the same arguments, which the native tests compare with
SIMD.jl's own intrinsic.

Covered: arithmetic, bitwise and shift operations of floats and integers, with fast-math flags
ignored; unary float functions (`sqrt`, `sin`, `exp`, `log`, rounding, ...), `pow`, `minnum`,
`maxnum`, `minimum`, `maximum`, `copysign`, `fma`, `fmuladd`; integer `bswap`, `bitreverse`,
`ctpop`, `ctlz`, `cttz`, funnel shifts, saturating and overflow-checked arithmetic; comparisons and
`select`; loads and stores through pointers, masked, expanding and compressing; gather and scatter;
`extractelement`, `insertelement`, `constantvector`, `shufflevector`; conversions and `bitcast`;
horizontal reductions and `bitmask`.

Differences from native SIMD.jl, by design:
- a horizontal float reduction (`reduce_fadd`, `reduce_fmul`; `sum` and `prod` of a `Vec`) adds
  the lanes left to right, where LLVM may associate in any order: the last bits can differ;
- `fmuladd` is `muladd`, fused or not as WebAssembly computes it (core WebAssembly has no fused
  multiply-add), and `fma` is Julia's `fma`, exact as natively;
- there is no SIMD128: each lane is a scalar operation. A loop over `Vec`s computes what it
  computes natively, at scalar speed (for PureBLAS's kernels, 20-40× below native).
"""
module WasmCompatSIMDExt

import WasmCodegen
import SIMD
const SI = SIMD.Intrinsics
const LVec = SIMD.LVec
const FT = SIMD.FloatingTypes
const IT = SI.IntegerTypes
const MT = WasmCodegen.Runtime.WASM_METHODS

# `@lane [@inline] SI.f(args...) where {...} = body`: the overlay of `SI.f`, and the same method as
# `lane_f` of this module (for the native tests)
function _rename_head!(ex, name)
    ex isa Expr || return false
    if ex.head === :call && ex.args[1] isa Expr && ex.args[1].head === :. && ex.args[1].args[1] === :SI
        ex.args[1] = Symbol("lane_", (ex.args[1].args[2]::QuoteNode).value)
        return true
    end
    for a in ex.args
        _rename_head!(a, name) && return true
    end
    return false
end
macro lane(ex)
    plain = deepcopy(ex)
    _rename_head!(plain, nothing) || error("@lane: no SI.f(...) in the definition")
    return esc(quote
        $plain
        Base.Experimental.@overlay $MT $ex
    end)
end

@inline _m1(f, x::LVec{N}) where {N} = ntuple(i -> VecElement(f(x[i].value)), Val(N))
@inline _m2(f, x::LVec{N}, y::LVec{N}) where {N} = ntuple(i -> VecElement(f(x[i].value, y[i].value)), Val(N))
@inline _m3(f, x::LVec{N}, y::LVec{N}, z::LVec{N}) where {N} =
    ntuple(i -> VecElement(f(x[i].value, y[i].value, z[i].value)), Val(N))

## Binary operations (LLVM instructions)
_shl(a, b) = a << (b % UInt64); _ashr(a, b) = signed(a) >> (b % UInt64); _lshr(a, b) = unsigned(a) >>> (b % UInt64)
for (f, g) in ((:fadd, :(Base.add_float)), (:fsub, :(Base.sub_float)), (:fmul, :(Base.mul_float)),
               (:fdiv, :(Base.div_float)), (:frem, :rem))
    @eval begin
        @lane @inline SI.$f(x::LVec{N,T}, y::LVec{N,T}, ::F = nothing) where {N, T <: FT, F <: SI.FPFlags} = _m2($g, x, y)
        @lane @inline SI.$f(x::T, y::T, ::F = nothing) where {T <: FT, F <: SI.FPFlags} = $g(x, y)
    end
end
for (f, g) in ((:add, :+), (:sub, :-), (:mul, :*), (:and, :&), (:or, :|), (:xor, :⊻),
               (:shl, :_shl), (:ashr, :_ashr), (:lshr, :_lshr),
               (:sdiv, :(Base.sdiv_int)), (:udiv, :(Base.udiv_int)), (:srem, :(Base.srem_int)), (:urem, :(Base.urem_int)))
    @eval begin
        @lane @inline SI.$f(x::LVec{N,T}, y::LVec{N,T}, ::F = nothing) where {N, T <: IT, F <: SI.FPFlags} =
            _m2((a, b) -> $g(a, b) % T, x, y)
        @lane @inline SI.$f(x::T, y::T, ::F = nothing) where {T <: IT, F <: SI.FPFlags} = $g(x, y) % T
    end
end
@lane @inline SI.fneg(x::LVec{N,T}, ::F = nothing) where {N, T <: FT, F <: SI.FPFlags} = _m1(Base.neg_float, x)
@lane @inline SI.fneg(x::T, ::F = nothing) where {T <: FT, F <: SI.FPFlags} = Base.neg_float(x)

## Unary float intrinsics (NaN outside the domain, as LLVM's, where Julia's functions throw)
_nan(x) = oftype(x, NaN)
_sqrt(x) = Base.sqrt_llvm(x)
_periodic(f) = x -> isfinite(x) ? f(x) : _nan(x)
_logarithm(f) = x -> x >= 0 ? f(x) : _nan(x)
for (f, g) in ((:sqrt, :_sqrt), (:sin, :(_periodic(sin))), (:cos, :(_periodic(cos))), (:exp, :exp), (:exp2, :exp2),
               (:log, :(_logarithm(log))), (:log10, :(_logarithm(log10))), (:log2, :(_logarithm(log2))), (:fabs, :abs), (:floor, :floor), (:ceil, :ceil),
               (:trunc, :trunc), (:rint, :(x -> round(x, RoundNearest))),
               (:nearbyint, :(x -> round(x, RoundNearest))), (:round, :(x -> round(x, RoundNearestTiesAway))))
    @eval begin
        @lane @inline SI.$f(x::LVec{N,T}) where {N, T <: FT} = _m1($g, x)
        @lane @inline SI.$f(x::T) where {T <: FT} = $g(x)
    end
end

## Binary float intrinsics (minnum/maxnum: the operand that is not NaN; minimum/maximum: NaN wins)
_minnum(a, b) = isnan(a) ? b : isnan(b) ? a : min(a, b)
_maxnum(a, b) = isnan(a) ? b : isnan(b) ? a : max(a, b)
for (f, g) in ((:minnum, :_minnum), (:maxnum, :_maxnum), (:minimum, :min), (:maximum, :max),
               (:copysign, :copysign), (:pow, :^))
    @eval @lane @inline SI.$f(x::LVec{N,T}, y::LVec{N,T}, ::F = nothing) where {N, T <: FT, F <: SI.FPFlags} = _m2($g, x, y)
end
for (f, g) in ((:fma, :fma), (:fmuladd, :muladd))
    @eval @lane @inline SI.$f(a::LVec{N,T}, b::LVec{N,T}, c::LVec{N,T}) where {N, T <: FT} = _m3($g, a, b, c)
end

## Integer intrinsics
_ctlz(a) = leading_zeros(a) % typeof(a); _cttz(a) = trailing_zeros(a) % typeof(a); _ctpop(a) = count_ones(a) % typeof(a)
for (f, g) in ((:bswap, :bswap), (:bitreverse, :bitreverse), (:ctpop, :_ctpop), (:ctlz, :_ctlz), (:cttz, :_cttz))
    @eval begin
        @lane @inline SI.$f(x::LVec{N,T}) where {N, T <: IT} = _m1($g, x)
        @lane @inline SI.$f(x::T) where {T <: IT} = $g(x)
    end
end
# funnel shifts: the high (fshl) or low (fshr) half of (a:b) shifted by c mod the width
function _fshl(a::T, b::T, c::T) where {T}
    w = 8 * sizeof(T); s = Int(unsigned(c) % unsigned(T(w)))
    return s == 0 ? a : ((a << s) | (unsigned(b) >>> (w - s))) % T
end
function _fshr(a::T, b::T, c::T) where {T}
    w = 8 * sizeof(T); s = Int(unsigned(c) % unsigned(T(w)))
    return s == 0 ? b : ((a << (w - s)) | (unsigned(b) >>> s)) % T
end
for (f, g) in ((:fshl, :_fshl), (:fshr, :_fshr))
    @eval begin
        @lane @inline SI.$f(a::LVec{N,T}, b::LVec{N,T}, c::LVec{N,T}) where {N, T <: IT} = _m3($g, a, b, c)
        @lane @inline SI.$f(a::T, b::T, c::T) where {T <: IT} = $g(a, b, c)
    end
end
# (in Int128, exact for integers of up to 64 bits, signed or unsigned)
_sat(f, a::T, b::T) where {T} = T(clamp(f(Int128(a), Int128(b)), Int128(typemin(T)), Int128(typemax(T))))
for (f, g, conv) in ((:sadd_sat, :+, :signed), (:ssub_sat, :-, :signed), (:uadd_sat, :+, :unsigned), (:usub_sat, :-, :unsigned))
    @eval @lane @inline SI.$f(x::LVec{N,T}, y::LVec{N,T}) where {N, T <: IT} =
        _m2((a, b) -> reinterpret(T, _sat($g, $conv(a), $conv(b))), x, y)
end
for (f, g, conv) in ((:sadd_with_overflow, :add_with_overflow, :signed), (:uadd_with_overflow, :add_with_overflow, :unsigned),
                     (:ssub_with_overflow, :sub_with_overflow, :signed), (:usub_with_overflow, :sub_with_overflow, :unsigned),
                     (:smul_with_overflow, :mul_with_overflow, :signed), (:umul_with_overflow, :mul_with_overflow, :unsigned))
    @eval @lane @inline function SI.$f(x::LVec{N,T}, y::LVec{N,T}) where {N, T <: IT}
        r = ntuple(i -> Base.Checked.$g($conv(x[i].value), $conv(y[i].value)), Val(N))
        return (ntuple(i -> VecElement(reinterpret(T, r[i][1])), Val(N)), ntuple(i -> VecElement(r[i][2]), Val(N)))
    end
end

## Comparisons (lanes of Bool) and select
for (flag, g) in ((:oeq, :(==)), (:one, :((a, b) -> !isnan(a) & !isnan(b) & (a != b))),
                  (:ogt, :>), (:oge, :>=), (:olt, :<), (:ole, :<=),
                  (:ord, :((a, b) -> !isnan(a) & !isnan(b))), (:uno, :((a, b) -> isnan(a) | isnan(b))),
                  (:ueq, :((a, b) -> isnan(a) | isnan(b) | (a == b))), (:une, :!=),
                  (:ugt, :((a, b) -> !(a <= b))), (:uge, :((a, b) -> !(a < b))),
                  (:ult, :((a, b) -> !(a >= b))), (:ule, :((a, b) -> !(a > b))),
                  (:false, :((a, b) -> false)), (:true, :((a, b) -> true)))
    f = Symbol("fcmp_", flag)
    @eval @lane @inline SI.$f(x::LVec{N,T}, y::LVec{N,T}, ::F = nothing) where {N, T <: FT, F <: SI.FPFlags} = _m2($g, x, y)
end
for (flag, g) in ((:eq, :(==)), (:ne, :!=), (:sgt, :((a, b) -> signed(a) > signed(b))),
                  (:sge, :((a, b) -> signed(a) >= signed(b))), (:slt, :((a, b) -> signed(a) < signed(b))),
                  (:sle, :((a, b) -> signed(a) <= signed(b))), (:ugt, :((a, b) -> unsigned(a) > unsigned(b))),
                  (:uge, :((a, b) -> unsigned(a) >= unsigned(b))), (:ult, :((a, b) -> unsigned(a) < unsigned(b))),
                  (:ule, :((a, b) -> unsigned(a) <= unsigned(b))))
    f = Symbol("icmp_", flag)
    @eval @lane @inline SI.$f(x::LVec{N,T}, y::LVec{N,T}) where {N, T <: IT} = _m2($g, x, y)
end
@lane @inline SI.select(c::LVec{N,Bool}, x::LVec{N,T}, y::LVec{N,T}) where {N, T} =
    ntuple(i -> VecElement(ifelse(c[i].value, x[i].value, y[i].value)), Val(N))

## Memory: element by element through the pointer
@lane @inline SI.load(::Type{LVec{N,T}}, p::Ptr{T}, ::Val{Al} = Val(false), ::Val{Te} = Val(false)) where {N, T, Al, Te} =
    ntuple(i -> VecElement(unsafe_load(p, i)), Val(N))
@lane @inline SI.maskedload(p::Ptr{T}, m::LVec{N,Bool}, ::Val{Al} = Val(false), ::Val{Te} = Val(false)) where {N, T, Al, Te} =
    ntuple(i -> VecElement(m[i].value ? unsafe_load(p, i) : zero(T)), Val(N))
@lane @inline function SI.store(x::LVec{N,T}, p::Ptr{T}, ::Val{Al} = Val(false), ::Val{Te} = Val(false)) where {N, T, Al, Te}
    for i in 1:N
        unsafe_store!(p, x[i].value, i)
    end
    return nothing
end
@lane @inline function SI.maskedstore(x::LVec{N,T}, p::Ptr{T}, m::LVec{N,Bool}, ::Val{Al} = Val(false), ::Val{Te} = Val(false)) where {N, T, Al, Te}
    for i in 1:N
        m[i].value && unsafe_store!(p, x[i].value, i)
    end
    return nothing
end
# expanding load / compressing store: the selected lanes from / to consecutive elements
@lane @inline function SI.maskedexpandload(p::Ptr{T}, m::LVec{N,Bool}) where {N, T}
    k = Ref(0)
    return ntuple(Val(N)) do i
        m[i].value || return VecElement(zero(T))
        k[] += 1
        VecElement(unsafe_load(p, k[]))
    end
end
@lane @inline function SI.maskedcompressstore(x::LVec{N,T}, p::Ptr{T}, m::LVec{N,Bool}) where {N, T}
    k = 0
    for i in 1:N
        m[i].value && (k += 1; unsafe_store!(p, x[i].value, k))
    end
    return nothing
end
@lane @inline SI.maskedgather(ptrs::LVec{N,Ptr{T}}, m::LVec{N,Bool}, ::Val{Al} = Val(false)) where {N, T, Al} =
    ntuple(i -> VecElement(m[i].value ? unsafe_load(ptrs[i].value) : zero(T)), Val(N))
@lane @inline function SI.maskedscatter(x::LVec{N,T}, ptrs::LVec{N,Ptr{T}}, m::LVec{N,Bool}, ::Val{Al} = Val(false)) where {N, T, Al}
    for i in 1:N
        m[i].value && unsafe_store!(ptrs[i].value, x[i].value)
    end
    return nothing
end

## Lanes
@lane @inline SI.extractelement(x::LVec{N,T}, i::I) where {N, T, I <: IT} = x[Int(i) + 1].value
@lane @inline SI.insertelement(x::LVec{N,T}, v::T, i::IT) where {N, T} =
    ntuple(k -> VecElement(k == Int(i) + 1 ? v : x[k].value), Val(N))
@lane @inline SI.constantvector(v::T, ::Type{LVec{N,T}}) where {N, T} = ntuple(_ -> VecElement(v), Val(N))
@inline _lane(x, y, ::Val{N}, j) where {N} = j < N ? x[j + 1].value : y[j - N + 1].value
@lane @inline SI.shufflevector(x::LVec{N,T}, y::LVec{N,T}, ::Val{I}) where {N, T, I} =
    ntuple(k -> VecElement(_lane(x, y, Val(N), Int(I[k]))), Val(length(I)))
@lane @inline SI.shufflevector(x::LVec{N,T}, ::Val{I}) where {N, T, I} =
    ntuple(k -> VecElement(x[Int(I[k]) + 1].value), Val(length(I)))

## Conversions
for f in (:fptrunc, :fpext, :fptoui, :fptosi, :uitofp, :sitofp)
    @eval @lane @inline SI.$f(::Type{LVec{N,T2}}, x::LVec{N,T1}) where {N, T1, T2} = _m1(a -> T2(a), x)
end
@lane @inline SI.trunc(::Type{LVec{N,T2}}, x::LVec{N,T1}) where {N, T1 <: IT, T2 <: IT} = _m1(a -> a % T2, x)
@lane @inline SI.zext(::Type{LVec{N,T2}}, x::LVec{N,T1}) where {N, T1 <: IT, T2 <: IT} = _m1(a -> unsigned(a) % T2, x)
@lane @inline SI.sext(::Type{LVec{N,T2}}, x::LVec{N,T1}) where {N, T1 <: IT, T2 <: IT} = _m1(a -> signed(a) % T2, x)
@lane @inline SI.bitcast(::Type{LVec{N,T1}}, x::LVec{N,T2}) where {N, T1, T2} = _m1(a -> reinterpret(T1, a), x)
@lane @inline SI.bitcast(::Type{T1}, x::T2) where {T1 <: Union{FT, IT}, T2 <: Union{FT, IT}} = reinterpret(T1, x)

## Horizontal reductions (left to right; see the module's documentation)
@inline _red(f, x::LVec{N}) where {N} = (s = x[1].value; for i in 2:N; s = f(s, x[i].value); end; s)
@lane @inline SI.reduce_fadd(x::LVec{N,T}, ::F = nothing) where {N, T <: FT, F <: SI.FPFlags} = _red(+, x)
@lane @inline SI.reduce_fmul(x::LVec{N,T}, ::F = nothing) where {N, T <: FT, F <: SI.FPFlags} = _red(*, x)
for (f, g) in ((:reduce_fmaximum, :max), (:reduce_fminimum, :min), (:reduce_fmax, :_maxnum), (:reduce_fmin, :_minnum))
    isdefined(SI, f) && @eval @lane @inline SI.$f(x::LVec{N,T}) where {N, T <: FT} = _red($g, x)
end
for (f, g) in ((:reduce_and, :&), (:reduce_or, :|), (:reduce_mul, :*), (:reduce_add, :+),
               (:reduce_smax, :((a, b) -> signed(a) > signed(b) ? a : b)), (:reduce_smin, :((a, b) -> signed(a) < signed(b) ? a : b)),
               (:reduce_umax, :((a, b) -> unsigned(a) > unsigned(b) ? a : b)), (:reduce_umin, :((a, b) -> unsigned(a) < unsigned(b) ? a : b)))
    @eval @lane @inline SI.$f(x::LVec{N,T}) where {N, T <: IT} = _red((a, b) -> $g(a, b) % T, x)
end
@lane @inline SI.reduce_add(x::LVec{N,Bool}) where {N} = (s = 0; for i in 1:N; s += x[i].value; end; s)
@lane @inline function SI.bitmask(x::LVec{N,Bool}) where {N}
    U = N <= 8 ? UInt8 : N <= 16 ? UInt16 : N <= 32 ? UInt32 : N <= 64 ? UInt64 : UInt128
    m = zero(U)
    for i in 1:N
        m |= U(x[i].value) << (i - 1)
    end
    return m
end

end # module
