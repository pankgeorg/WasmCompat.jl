"""
    WasmCompatFileWatchingExt

FileWatching for WasmCodegen's closed world. Overlays (methods of `WasmCodegen.Runtime.WASM_METHODS`,
used only when compiling to Wasm):

- **Pidfile locks.** `mkpidlock(f, path; stale_age, ...)` takes a lock between processes: it creates
  the pidfile exclusively (writing the host name, `gethostname`, which WASI does not have), keeps
  it fresh with a libuv `Timer`, and waits and checks for stale locks of other processes (process
  ids, `kill(pid, 0)`), none of which a Wasm module has; a function that calls it traps. A module
  is one process of its own, so the lock is not taken: `f()` runs and its value is returned, and
  no pidfile is left behind, as natively after the lock is released. (Two module instances on one
  depot at the same time are not serialized.) The callback is specialized on (`f::F`): the stdlib
  declares it `::Function` and passes it on, which makes its call dynamic.
"""
module WasmCompatFileWatchingExt

import FileWatching
import WasmCodegen
using FileWatching.Pidfile: Pidfile

Base.Experimental.@overlay WasmCodegen.Runtime.WASM_METHODS Pidfile.mkpidlock(
        f::F, at::String; kwopts...) where {F <: Function} = f()
Base.Experimental.@overlay WasmCodegen.Runtime.WASM_METHODS Pidfile.mkpidlock(
        f::F, at::String, pid::Cint; kwopts...) where {F <: Function} = f()

end # module
