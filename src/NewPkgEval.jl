module NewPkgEval

import Pkg.TOML
using Pkg
using Base: UUID
using Dates
using ProgressMeter
using DataFrames
using Random
using Mustache
using CUDAapi

downloads_dir(name) = joinpath(dirname(@__DIR__), "deps", "downloads", name)
julia_path(ver) = joinpath(dirname(@__DIR__), "deps", "usr", "julia-$ver")
registry_path(name) = joinpath(first(DEPOT_PATH), "registries", name)
registries_file() = joinpath(dirname(@__DIR__), "deps", "Registries.toml")

read_registries() = TOML.parsefile(registries_file())

include("registry.jl")
include("julia.jl")
include("run.jl")
include("report.jl")

function __init__()
    Pkg.PlatformEngines.probe_platform_engines!()
    chmod(versions_file(), 0o644) # mutated by this package
end

end # module
