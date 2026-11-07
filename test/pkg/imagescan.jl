# Find build-host strings in a WasmCodegen module.
#
#   julia test/pkg/imagescan.jl <module.wasm> <marker>...      prints the markers found
#
# WasmCodegen serialises image Strings as GC byte arrays (packed i8), small ones as constant
# `array.new_fixed $T n (i32.const b)...` expressions, so the bytes are *not* contiguous in
# the binary and a raw byte search misses them. This decodes every such i8-valued constant
# array via Binaryen's `wasm-dis` and searches those strings as well as the raw module
# bytes (data segments).
#
# Scope: recognises the array type forms Binaryen 132 prints for ordinary packed-i8
# arrays ((array [mut] i8), (sub [final] [$parent] ...)), which is what WasmCodegen emits
# (layout.jl ArrayType(FieldType(storage, true))). It is not a full type parser: e.g. `shared`
# arrays are not recognised. An empty scan is evidence for these representations only; the
# relocation test's behavioural S-add@cache-key case does not depend on it.

# Binaryen's wasm-dis: $WASM_DIS (build.jl records Binaryen_jll's in the build report), else PATH's
wasm_dis() = get(ENV, "WASM_DIS", "wasm-dis")

# All byte strings of constant byte arrays in the module, plus the raw module bytes.
# Only arrays whose type has a packed i8 element are decoded; each `i32.const` operand is
# stored as its low 8 bits (wasm packed-field semantics), so any i32 value is accepted and
# truncated. Arrays of other element types are not byte strings.
function image_byte_strings(wasm::AbstractString)
    found = Vector{UInt8}[read(wasm)]
    text = read(pipeline(`$(wasm_dis()) $wasm`; stderr = devnull), String)
    i8types = Set{String}()
    for m in eachmatch(r"\(type (\$\S+) (?:\(sub (?:final )?(?:\$\S+ )?)?\(array (?:\(mut i8\)|i8)\)", text)
        push!(i8types, m.captures[1])
    end
    lines = split(text, '\n')
    i = 1
    while i <= length(lines)
        m = match(r"\(array\.new_fixed (\$\S+) (\d+)\s*$", lines[i])
        i += 1
        (m === nothing || !(m.captures[1] in i8types)) && continue
        n = parse(Int, m.captures[2])
        buf = UInt8[]
        j = i
        while length(buf) < n && j <= length(lines)
            c = match(r"^\s*\(i32\.const (-?\d+)\)\s*$", lines[j])
            c === nothing && break          # non-constant operand: not a literal string
            push!(buf, UInt8(parse(Int, c.captures[1]) & 0xff))
            j += 1
        end
        length(buf) == n && n > 0 && push!(found, buf)
    end
    return found
end

function scan_markers(wasm::AbstractString, markers)
    strs = image_byte_strings(wasm)
    hay = join((String(copy(s)) for s in strs), '\0')
    return sort!(unique!([m for m in markers if !isempty(m) && occursin(m, hay)]))
end

# The embedded strings that contain a marker: each decoded constant byte array that contains
# one, and, in the raw module bytes, the run of printable bytes around each occurrence.
function marker_strings(wasm::AbstractString, markers)
    strs = image_byte_strings(wasm)
    found = Set{String}()
    printable(b) = 0x20 <= b <= 0x7e
    for (k, bytes) in enumerate(strs), m in markers
        isempty(m) && continue
        mb = Vector{UInt8}(codeunits(m))
        if k > 1   # (a decoded string: the whole string)
            occursin(m, String(copy(bytes))) && push!(found, String(copy(bytes)))
            continue
        end
        i = 1
        while (r = findnext(mb, bytes, i)) !== nothing
            lo, hi = first(r), last(r)
            while lo > 1 && printable(bytes[lo - 1]); lo -= 1; end
            while hi < length(bytes) && printable(bytes[hi + 1]); hi += 1; end
            push!(found, String(bytes[lo:hi]))
            i = last(r) + 1
        end
    end
    return sort!(collect(found))
end

# Log-macro source paths (`@warn`/`@error`'s `__source__.file`) are exempt, narrowly: a string
# that is exactly the (normalized) path of a `.jl` file inside one of `source_roots` (the
# checked-out source trees compiled into the module). Returns (flagged markers, flagged strings, ignored strings); a marker is flagged when
# any string containing it is not exempt.
function classify_host_strings(wasm::AbstractString, markers, source_roots)
    roots = [rstrip(r, '/') * "/" for r in source_roots if !isempty(r)]
    exempt(x) = endswith(x, ".jl") && !occursin(r"[\s\x00;:]", x) && any(r -> startswith(x, r), roots) &&
                normpath(x) == x
    flagged, ignored = String[], String[]
    for x in marker_strings(wasm, markers)
        push!(exempt(x) ? ignored : flagged, x)
    end
    fm = sort!(unique!([m for m in markers if !isempty(m) && any(x -> occursin(m, x), flagged)]))
    return fm, flagged, ignored
end

if abspath(PROGRAM_FILE) == @__FILE__
    length(ARGS) >= 2 || (println(stderr, "usage: imagescan.jl <module.wasm> <marker>..."); exit(2))
    foreach(println, scan_markers(ARGS[1], ARGS[2:end]))
end
