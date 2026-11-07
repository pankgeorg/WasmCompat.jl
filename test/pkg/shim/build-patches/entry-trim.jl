# Build patch for the package manager's entry shim: trim patches the program needs that WasmCodegen and
# WasmCompat do not provide. (TOML long integers, Tar and ArgTools callbacks: WasmCompat's
# extensions, loaded with `--load`.) Method definitions only (deleted when the patch session ends).

## 1. `show(::IO, ::Tar.Header)` without Base's expression printer (Tar's error messages `repr`
## headers). The root fix is `show(::IO, ::Symbol)` without the expression printer,
## JuliaLang/julia#64448 (Julia 1.14); a WasmCodegen trim patch for older Julia would replace this.

let Tar = Base.maybe_root_module(Base.PkgId(Base.UUID("a4e569a6-e804-4fa4-b0f3-eef7a1d5b13e"), "Tar"))
    if Tar !== nothing
        # what `show(io, Symbol(Char(b)))` prints for each byte b (natively, now)
        # (byte 0 has no Symbol; Tar maps it to :file)
        flag_texts = Tuple(b == 0 ? "" : repr(Symbol(Char(b))) for b in 0:255)
        @eval Tar begin
            # what `show(io, ::Symbol)` prints (Base's `show_unquoted_quote_expr`): `:(name)`
            # for Base's quoted symbols, `:name` for an identifier or an operator but `'`,
            # else `Symbol("...")`
            function wasm_show_symbol(io::IO, s::Symbol)
                str = String(s)
                if length(str) == 1 && UInt32(str[1]) <= 0xff
                    print(io, $flag_texts[Int(UInt32(str[1])) + 1])
                elseif s === :(:) || s === :(::) || s === :(:=) || s === :(=) || s === :(==) || s === :(===) || s === :(=>)
                    print(io, ":(", String(s), ')')
                elseif Base.isidentifier(s)
                    # (Tar's own names; multi-character operators are not header types)
                    print(io, ':', String(s))
                else
                    print(io, "Symbol(")
                    show(io, String(s))
                    print(io, ')')
                end
            end
            function Base.show(io::IO, hdr::Header)
                # (as `show(io, Header)` prints it from Main, which does not import Tar's
                # unexported Header, without type printing)
                print(io, "Tar.Header")
                print(io, "(")
                show(io, hdr.path)
                print(io, ", ")
                wasm_show_symbol(io, hdr.type)
                print(io, ", 0o", string(hdr.mode, base=8, pad=3), ", ")
                show(io, hdr.size)
                print(io, ", ")
                show(io, hdr.link)
                print(io, ")")
            end
        end
    end
end

## 2. Base's printing entry points without an IO argument
# `stdout`/`stderr` are globals of type `IO`: `print(x)`, `println(x)`, ... are dynamic calls
# in a closed world. Here they print to `Core.stdout`/`Core.stderr` (WasmCodegen's standard streams:
# `Runtime.IO.write_byte` over WASI `fd_write`), which the image's Base streams are.

let out = :(Core.stdout), err = :(Core.stderr)
    @eval Base begin
        print(x) = print($out, x)
        print(x1, x2) = print($out, x1, x2)
        println(x) = print($out, x, "\n")
        println(x1, x2) = print($out, x1, x2, "\n")
        print(xs...) = print($out, xs...)
        println(xs...) = print($out, xs..., "\n")
        show(x) = show($out, x)
        @constprop :none printstyled(msg...; bold::Bool=false, italic::Bool=false, underline::Bool=false,
                                     blink::Bool=false, reverse::Bool=false, hidden::Bool=false,
                                     color::Union{Int,Symbol}=:normal) =
            printstyled($out, msg...; bold=bold, italic=italic, underline=underline,
                        blink=blink, reverse=reverse, hidden=hidden, color=color)
        display_error(stack::ExceptionStack) = display_error($err, stack)
        display_error(er, bt=nothing) = display_error($err, er, bt)
    end
    @eval Base.Multimedia function display(x)
        io = $out
        show(io, MIME"text/plain"(), x)
        println(io)
        return nothing
    end
end
