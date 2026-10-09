# Run in its own process: it replaces methods to fake a compiled environment.
# Package P has extensions ExtA (trigger A) and ExtB (trigger B), and depends on
# both A and B, so each extension loads during the other's compile.
client, pdir = ARGS
include(client)
const C = PkgEvalCacheClient
U(n) = Base.UUID("c0ffee00-0000-0000-0000-00000000000$n")
env = Dict{Base.UUID,Tuple{String,Dict{String,Any}}}(
    U(1) => ("P", Dict{String,Any}("version" => "1.0.0", "git-tree-sha1" => "11"^20, "deps" => ["A", "B"])),
    U(2) => ("A", Dict{String,Any}("version" => "1.0.0", "git-tree-sha1" => "22"^20)),
    U(3) => ("B", Dict{String,Any}("version" => "1.0.0", "git-tree-sha1" => "33"^20)))
@eval C dep_build_id(id::Base.PkgId) = (; build_id=UInt128(1), canonical=true)
Base.locate_package(id::Base.PkgId) = id.uuid == U(1) ? joinpath(pdir, "src", "P.jl") : nothing
ext(name) = Base.PkgId(Base.uuid5(U(1), name), name)
function keys_in_order(names)
    empty!(C.CTX_CACHE)
    ctxs = Dict(n => C._build_ext_context(ext(n), env, Set{Base.UUID}()) for n in names)
    return Dict(n => (c === nothing ? nothing : c.key) for (n, c) in ctxs)
end
# keying must not depend on which extension the driver reaches first
ab, ba = keys_in_order(["ExtA", "ExtB"]), keys_in_order(["ExtB", "ExtA"])
print(any(isnothing, values(ab)) ? "unkeyable" : ab == ba ? "keyed" : "order-dependent")
