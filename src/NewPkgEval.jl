module NewPkgEval

import Pkg.TOML
using Pkg
using Base: UUID
using Dates
using ProgressMeter
using DataFrames
using Random
using Mustache
using JSON

downloads_dir(name) = joinpath(dirname(@__DIR__), "deps", "downloads", name)
julia_path(ver) = joinpath(dirname(@__DIR__), "deps", "usr", "julia-$ver")
registry_path(name) = joinpath(first(DEPOT_PATH), "registries", name)
registries_file() = joinpath(dirname(@__DIR__), "deps", "Registries.toml")
log_path(julia) = joinpath(dirname(@__DIR__), "logs/logs-$julia")

read_registries() = TOML.parsefile(registries_file())

include("registry.jl")
include("julia.jl")
include("run.jl")
include("report.jl")

end # module
