"""
    WasmCompatBaseExt

Base for WasmCodegen's closed world: constructs of Base's own code that a program reaches without
asking for them, and that WasmCodegen does not compile. Loaded with WasmCodegen alone.

- **`Base.generating_output()`** asks the runtime whether the process is writing a code cache
  (`ccall(:jl_generating_output)`, which WasmCodegen does not compile). A compiled program never
  is: `false`. Among others, `Base.OncePerProcess`'s initializer reaches it through
  `__precompile__(false)`, so every first call of a `OncePerProcess` value trapped.
"""
module WasmCompatBaseExt

import WasmCodegen

Base.Experimental.@overlay WasmCodegen.Runtime.WASM_METHODS Base.generating_output(
    incremental::Union{Bool,Nothing} = nothing) = false

end # module
