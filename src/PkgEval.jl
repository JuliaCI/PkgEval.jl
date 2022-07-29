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

skip_list = String[]
retry_list = String[]

export Configuration, Package, evaluate

Base.@kwdef struct Configuration
    julia::String = "nightly"
    buildflags::Vector{String} = String[]
    depwarn::Bool = false
    log_limit::Int = 2^20 # 1 MB
    time_limit = 60*60 # 1 hour
    compiled::Bool = false
    compile_time_limit::Int = 30*60 # 30 mins

    # the directory where Julia is installed in the run-time environment
    julia_install_dir::String = "/opt/julia"

    # whether to launch Xvfb before starting Julia
    xvfb::Bool = true

    # a list of CPUs to restrict the Julia process to (or empty if unconstrained).
    # if set, JULIA_CPU_THREADS will also be set to a number equaling the number of CPUs.
    cpus::Vector{Int} = Int[]

    # additional Julia arguments to pass to the process
    julia_args::Cmd = ``

    # rootfs properties
    distro::String = "debian"
    uid::Int = 1000
    user::String = "pkgeval"
    gid::Int = 1000
    group::String = "pkgeval"
    home::String = "/home/pkgeval"
end

Base.@kwdef struct Package
    # source of the package; forwarded to PackageSpec
    name::String
    version::Union{Nothing,VersionNumber} = nothing
    url::Union{Nothing,String} = nothing
    rev::Union{Nothing,String} = nothing

    retries::Int = 0
end

# convert a Package to a tuple that's Pkg.add'able
function package_spec_tuple(pkg::Package)
    spec = (;)
    for field in (:name, :version, :url, :rev)
        val = getfield(pkg, field)
        if val !== nothing
            spec = merge(spec, NamedTuple{(field,)}((val,)))
        end
    end
    spec
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

    # read Packages.toml
    packages = TOML.parsefile(joinpath(dirname(@__DIR__), "Packages.toml"))
    global skip_list = get(packages, "skip", String[])
    global retry_list = get(packages, "retry", String[])
end

end # module
