# WasmCompatSIMDExt: SIMD.jl `Vec` code as written (arithmetic, muladd, comparisons and vifelse, vload/vstore and
# masked forms, shuffles, conversions, reductions, a dot product over an array); WasmCompatBaseExt: a
# `Base.OncePerProcess` value (its initializer asks `generating_output`). Values are chosen so that every lane order
# of a reduction gives the same bits.
module Prog
using SIMD
out(s) = write(Core.stdout, s)
show_vec(v::Vec) = string("<", join((string(v[i]) for i in 1:length(v)), ", "), ">")

function dot_simd(a::Vector{Float64}, b::Vector{Float64})
    acc = Vec{4,Float64}(0.0)
    @inbounds for i in 1:4:length(a)
        acc = muladd(vload(Vec{4,Float64}, a, i), vload(Vec{4,Float64}, b, i), acc)
    end
    return sum(acc)
end

const ONCE = Base.OncePerProcess{Int}(() -> 42)

function main()
    x = Vec{4,Float64}((1.5, -2.0, 3.25, 4.0)); y = Vec{4,Float64}((0.5, 4.0, -1.0, 2.0))
    out("x + y = $(show_vec(x + y))\n")
    out("x * y = $(show_vec(x * y))\n")
    out("x / y = $(show_vec(x / y))\n")
    out("muladd = $(show_vec(muladd(x, y, x)))\n")
    out("sqrt(y*y) = $(show_vec(sqrt(y * y)))\n")
    out("abs, floor, round = $(show_vec(abs(x))) $(show_vec(floor(x))) $(show_vec(round(x)))\n")
    out("min, max = $(show_vec(min(x, y))) $(show_vec(max(x, y)))\n")
    m = x > y
    out("x > y = $(show_vec(m)), any $(any(m)), all $(all(m))\n")
    out("vifelse = $(show_vec(vifelse(m, x, y)))\n")
    out("sum, prod, maximum = $(sum(x)) $(prod(y)) $(maximum(x))\n")
    out("shuffle = $(show_vec(shufflevector(x, y, Val((0, 5, 2, 7)))))\n")
    i = Vec{4,Int32}((1, -7, 100, typemax(Int32)))
    out("int + 1 = $(show_vec(i + Int32(1)))\n")
    out("int << 2, >> 1 = $(show_vec(i << 2)) $(show_vec(i >> 1))\n")
    out("int xor = $(show_vec(i ⊻ Int32(5)))\n")
    out("convert Float64 = $(show_vec(convert(Vec{4,Float64}, i)))\n")
    out("count_ones = $(show_vec(count_ones(i)))\n")
    a = collect(1.0:16.0); b = fill(0.5, 16)
    out("dot = $(dot_simd(a, b))\n")
    c = zeros(8)
    vstore(x, c, 3)
    vstore(y, c, 1, Vec{4,Bool}((true, false, true, false)))
    out("stores = $(join(c, ", "))\n")
    out("masked load = $(show_vec(vload(Vec{4,Float64}, a, 5, Vec{4,Bool}((false, true, true, false)))))\n")
    out("OncePerProcess = $(ONCE())\n")
    return 0
end
end
