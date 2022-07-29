export Configuration, Package

Base.@kwdef struct Configuration
    # Julia properties
    julia::String = "nightly"
    buildflags::Vector{String} = String[]

    # rootfs properties
    distro::String = "debian"
    uid::Int = 1000
    user::String = "pkgeval"
    gid::Int = 1000
    group::String = "pkgeval"
    home::String = "/home/pkgeval"

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
