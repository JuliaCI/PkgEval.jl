export Configuration, ismodified, Package


## individual settings, keeping track of modifications

struct Setting{T}
    val::T
    modified::Bool
end

Base.getindex(x::Setting) = x.val

# conversions from differently-typed settings
Base.convert(::Type{Setting{T}}, setting::Setting{T}) where {T} = setting
Base.convert(::Type{Setting{T}}, setting::Setting) where {T} =
    Setting{T}(convert(T, setting.val), setting.modified)

# conversions from values are marked as modified settings...
Base.convert(::Type{Setting{T}}, val::T) where {T} = Setting{T}(val, true)

# ... unless the Default constructor is used
Default(val::T) where {T} = Setting{T}(val, false)


## configuration: groups settings

Base.@kwdef struct Configuration
    # Julia properties
    julia::Setting{String} = Default("nightly")
    buildflags::Setting{Vector{String}} = Default(String[])
    buildcommands::Setting{String} = Default("make install")

    # registry properties
    registry::Setting{String} = Default("master")

    # rootfs properties
    distro::Setting{String} = Default("debian")
    uid::Setting{Int} = Default(1000)
    user::Setting{String} = Default("pkgeval")
    gid::Setting{Int} = Default(1000)
    group::Setting{String} = Default("pkgeval")
    home::Setting{String} = Default("/home/pkgeval")

    rr::Setting{Bool} = Default(false)
    depwarn::Setting{Bool} = Default(false)
    log_limit::Setting{Int} = Default(2^20) # 1 MB
    time_limit::Setting{Float64} = Default(45*60) # 45 mins
    compiled::Setting{Bool} = Default(false)
    compile_time_limit::Setting{Float64} = Default(30*60) # 30 mins

    # the directory where Julia is installed in the run-time environment
    julia_install_dir::Setting{String} = Default("/opt/julia")

    # the name of the Julia binary
    julia_binary::Setting{String} = Default("julia")

    # whether to launch Xvfb before starting Julia
    xvfb::Setting{Bool} = Default(true)

    # a list of CPUs to restrict the Julia process to (or empty if unconstrained).
    # if set, JULIA_CPU_THREADS will also be set to a number equaling the number of CPUs.
    cpus::Setting{Vector{Int}} = Default(Int[])

    # additional Julia arguments to pass to the process
    julia_args::Setting{Cmd} = Default(``)
end

# when requested, return the underlying value
Base.getproperty(cfg::Configuration, field::Symbol) = getfield(cfg, field)[]

ismodified(cfg::Configuration, field::Symbol) = getfield(cfg, field).modified
can_use_binaries(cfg::Configuration) =
    !ismodified(cfg, :buildflags) && !ismodified(cfg, :buildcommands)

# copy constructor that allows overriding specific fields
function Configuration(cfg::Configuration; kwargs...)
    kwargs = Dict(kwargs...)
    merged_kwargs = Dict()
    for field in fieldnames(Configuration)
        merged_kwargs[field] = get(kwargs, field, getfield(cfg, field))
    end
    Configuration(; merged_kwargs...)
end


## package selection

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
