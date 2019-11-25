module NewPkgEval

import Pkg.TOML
using Pkg
using Base: UUID
using Dates

downloads_dir(name) = joinpath(dirname(@__DIR__), "deps", "downloads", name)
julia_path(ver) = joinpath(dirname(@__DIR__), "deps", "julia-$ver")
versions_file() = joinpath(dirname(@__DIR__), "deps", "Versions.toml")
registry_path(name) = joinpath(first(DEPOT_PATH), "registries", name)
registries_file() = joinpath(dirname(@__DIR__), "deps", "Registries.toml")
builds_file() = joinpath(dirname(@__DIR__), "deps", "Builds.toml")
log_path(julia) = joinpath(dirname(@__DIR__), "logs/logs-$julia")

"""
    read_versions() -> Dict

Parse the `deps/Versions.toml` file containing download and verification information for
various versions of Julia.
"""
read_versions() = TOML.parse(read(versions_file(), String))

"""
    read_registries() -> Dict

Parse the `deps/Registries.toml` file containing a URL and packages to skip for listed
registries.
"""
read_registries() = TOML.parsefile(registries_file())

"""
    read_builds() -> Dict

Parse the `deps/Builds.toml` file containing download information for various Julia builds.
"""
read_builds() = TOML.parsefile(builds_file())

include("registry.jl")
include("julia.jl")
include("run.jl")

end # module
