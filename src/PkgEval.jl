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
