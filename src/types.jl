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
    name::String = "unnamed"

    # Julia properties
    julia::Setting{String} = Default("nightly")
    buildflags::Setting{Vector{String}} = Default(String[])
    buildcommands::Setting{String} = Default("make install")
    environment::Setting{Vector{String}} = Default(String[])
    julia_install_dir::Setting{String} = Default("/opt/julia")
    julia_binary::Setting{String} = Default("julia")
    ## additional Julia arguments to pass to the process
    julia_args::Setting{Cmd} = Default(``)

    # registry properties
    registry::Setting{String} = Default("master")

    # rootfs properties
    rootfs::Setting{String} = Default("debian")
    uid::Setting{Int} = Default(1000)
    user::Setting{String} = Default("pkgeval")
    gid::Setting{Int} = Default(1000)
    group::Setting{String} = Default("pkgeval")
    home::Setting{String} = Default("/home/pkgeval")

    # execution properties
    ## a list of CPUs to restrict the Julia process to (or empty if unconstrained).
    ## if set, JULIA_CPU_THREADS will also be set to a number equaling the number of CPUs.
    cpus::Setting{Vector{Int}} = Default(Int[])
    xvfb::Setting{Bool} = Default(true)
    rr::Setting{Bool} = Default(false)
    depwarn::Setting{Bool} = Default(false)
    log_limit::Setting{Int} = Default(2^20) # 1 MB
    time_limit::Setting{Float64} = Default(45*60) # 45 mins
    compiled::Setting{Bool} = Default(false)
    compile_time_limit::Setting{Float64} = Default(30*60) # 30 mins

end

function Base.show(io::IO, cfg::Configuration)
    function show_setting(field)
        setting = getfield(cfg, Symbol(field))
        print(io, "  - $field: ")
        if get(io, :color, false)
            Base.printstyled(io, setting[]; color=setting.modified ? :red : :green)
        else
            print(io, setting[], " (", setting.modified ? "modified" : "default", ")")
        end
        println(io)
    end
    println(io, "PkgEval configuration '$(cfg.name)' (")

    println(io, "  # Julia properties")
    show_setting.(["julia", "buildflags", "buildcommands", "environment", "julia_install_dir", "julia_binary", "julia_args"])
    println(io)

    println(io, "  # Registry properties")
    show_setting.(["registry"])
    println(io)

    println(io, "  # Rootfs properties")
    show_setting.(["rootfs", "uid", "user", "gid", "group", "home"])
    println(io)

    println(io, "  # Execution properties")
    show_setting.(["cpus", "xvfb", "rr", "depwarn", "log_limit", "time_limit", "compiled", "compile_time_limit"])

    print(io, ")")
end

# when requested, return the underlying value
function Base.getproperty(cfg::Configuration, field::Symbol)
    val = getfield(cfg, field)
    if val isa Setting
        return val[]
    else
        return val
    end
end

function ismodified(cfg::Configuration, field::Symbol)
    val = getfield(cfg, field)
    if val isa Setting
        return val.modified
    else
        return false
    end
end
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
    uuid::Base.UUID = find_package_uuid(name)
    version::Union{Nothing,VersionNumber} = nothing
    url::Union{Nothing,String} = nothing
    rev::Union{Nothing,String} = nothing
end

function find_package_uuid(name)
    # TODO: if this is performance sensitive, build a map on first use
    registries = Pkg.Registry.reachable_registries()
    for reg in registries
        for (_, pkg) in reg
            if name == pkg.name
                return pkg.uuid
            end
        end
    end
    error("Package $name not found in any reachable registry")
end

# convert a Package to a tuple that's Pkg.add'able
function package_spec_tuple(pkg::Package)
    spec = (;)
    for field in (:name, :uuid, :version, :url, :rev)
        val = getfield(pkg, field)
        if val !== nothing
            spec = merge(spec, NamedTuple{(field,)}((val,)))
        end
    end
    spec
end


## test job

struct Job
    config::Configuration
    package::Package

    use_cache::Bool
end
