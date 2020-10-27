module NewPkgEval

import Pkg.TOML
using Pkg
using Base: UUID
using Dates
using ProgressMeter
using DataFrames
using Random
using Libdl
using Sockets
using JSON
using Printf

# immutable: in package directory
versions_file() = joinpath(dirname(@__DIR__), "deps", "Versions.toml")
releases_file() = joinpath(dirname(@__DIR__), "deps", "Releases.toml")
registries_file() = joinpath(dirname(@__DIR__), "deps", "Registries.toml")

# mutable: in .cache directory
cache_dir() = joinpath(get(ENV, "XDG_CACHE_HOME", joinpath(homedir(), ".cache")), "NewPkgEval")
download_dir(name) = joinpath(cache_dir(), "downloads", name)
storage_dir() = joinpath(cache_dir(), "storage")
extra_versions_file() = joinpath(cache_dir(), "Versions.toml")

# fixed locations
registry_dir() = joinpath(first(DEPOT_PATH), "registries")
registry_dir(name) = joinpath(registry_dir(), name)

# utils
isdebug(group) = Base.CoreLogging.current_logger_for_env(Base.CoreLogging.Debug, group, NewPkgEval) !== nothing

include("registry.jl")
include("julia.jl")
include("run.jl")
include("report.jl")

function __init__()
    mkpath(cache_dir())
    touch(extra_versions_file())
end

end # module
