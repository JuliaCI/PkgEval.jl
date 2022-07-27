module PkgEval

import Pkg.TOML
using Pkg
using Base: UUID
using Dates
using ProgressMeter
using DataFrames
using Random
using Sandbox
using LazyArtifacts
using JSON

import Scratch: @get_scratch!
download_dir = ""
storage_dir = ""

export Configuration

Base.@kwdef mutable struct Configuration
    julia::String = "nightly"
    compiled::Bool = false
    buildflags::Vector{String} = String[]
    depwarn::Bool = false
    # TODO: put even more here (rootfs, install_dir, limits, etc)

    # the directory where Julia is installed in the run-time environment
    julia_install_dir::String = "/opt/julia"

    # whether to launch Xvfb before starting Julia
    xvfb::Bool = true

    # a list of CPUs to restrict the Julia process to (or empty if unconstrained).
    # if set, JULIA_CPU_THREADS will also be set to a number equaling the number of CPUs.
    cpus::Vector{Int} = Int[]

    # additional Julia arguments to pass to the process
    julia_args::Cmd = ``
end

# copy constructor that allows overriding specific fields
function Configuration(cfg::Configuration; kwargs...)
    kwargs = Dict(kwargs...)
    merged_kwargs = Dict()
    for field in fieldnames(Configuration)
        merged_kwargs[field] = get(kwargs, field, getfield(cfg, field))
    end
    Configuration(; merged_kwargs...)
end

# behave as a scalar in broadcast expressions
Base.broadcastable(x::Configuration) = Ref(x)

# utils
isdebug(group) =
    Base.CoreLogging.current_logger_for_env(Base.CoreLogging.Debug, group, PkgEval) !== nothing

include("registry.jl")
include("julia.jl")
include("evaluate.jl")
include("report.jl")

function __init__()
    global download_dir = @get_scratch!("downloads")
    mkpath(joinpath(download_dir, "srccache"))

    global storage_dir = @get_scratch!("storage")
end

end # module
