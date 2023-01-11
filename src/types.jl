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

    # when a setting below is documented to be a repo spec, that means it can be either a
    # branch name (e.g. "master"), optionally prefixed by the GitHub repo (e.g.
    # "JuliaLang/General#master"), or a path to a local check-out of said repository.

    # Julia properties
    ## the name of the Julia release to test (from versions.toml), or a repo spec.
    ## in addition, the special "nightly" release name is supported ad well
    julia::Setting{String} = Default("nightly")
    ## flags and commands to use to build Julia (this disables use of prebuilt binaries)
    buildflags::Setting{Vector{String}} = Default(String[])
    buildcommands::Setting{String} = Default("make install")
    ## where to install Julia, and what the name of the generated binary is
    julia_install_dir::Setting{String} = Default("/opt/julia")
    julia_binary::Setting{String} = Default("julia")
    ## additional Julia arguments to pass to the process
    julia_flags::Setting{Vector{String}} = Default(String[])

    # registry properties
    ## the repo spec of the registry to use
    registry::Setting{String} = Default("master")

    # rootfs properties
    ## the name of the rootfs artifact to use (needs to be available from Artifacts.toml)
    rootfs::Setting{String} = Default("debian")
    ## properties of the environment wherein the tests are run
    uid::Setting{Int} = Default(1000)
    user::Setting{String} = Default("pkgeval")
    gid::Setting{Int} = Default(1000)
    group::Setting{String} = Default("pkgeval")
    home::Setting{String} = Default("/home/pkgeval")

    # execution properties
    ## a list of environment variables to set in the sandbox
    env::Setting{Vector{String}} = Default(String[])
    ## a list of CPUs to restrict the Julia process to (or empty if unconstrained).
    ## if set, JULIA_CPU_THREADS will also be set to a number equaling the number of CPUs.
    cpus::Setting{Vector{Int}} = Default(Int[])
    ## whether to spawn a virtual X server and expose that to the sandbox
    xvfb::Setting{Bool} = Default(true)
    ## whether to run under record-replay (rr). traces will be uploaded to AWS S3, so you
    ## additionally need to set PKGEVAL_RR_BUCKET and some S3 authentication env vars.
    rr::Setting{Bool} = Default(false)
    ## whether to separately precompile packages before testing.
    ## disabling this can be useful to trap precompilation-related issues under rr.
    precompile::Setting{Bool} = Default(true)
    ## limits imposed on the test process
    log_limit::Setting{Int} = Default(2^20) # 1 MB
    time_limit::Setting{Float64} = Default(45*60) # 45 mins
    ## compiled mode: first generating a system image containing each package under test,
    ##                then running tests using that system image.
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
    show_setting.(["julia", "buildflags", "buildcommands", "julia_install_dir", "julia_binary", "julia_flags"])
    println(io)

    println(io, "  # Registry properties")
    show_setting.(["registry"])
    println(io)

    println(io, "  # Rootfs properties")
    show_setting.(["rootfs", "uid", "user", "gid", "group", "home"])
    println(io)

    println(io, "  # Execution properties")
    show_setting.(["env", "cpus", "xvfb", "rr", "precompile", "log_limit", "time_limit", "compiled", "compile_time_limit"])

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
        delete!(kwargs, field)
    end
    if !isempty(kwargs)
        throw(ArgumentError("unknown keyword arguments: $(join(keys(kwargs), ", "))"))
    end
    Configuration(; merged_kwargs...)
end


## package selection

Base.@kwdef struct Package
    # source of the package; forwarded to PackageSpec
    name::String
    uuid::Union{Nothing,UUID} = nothing
    version::Union{Nothing,String,VersionNumber} = nothing
    url::Union{Nothing,String} = nothing
    rev::Union{Nothing,String} = nothing
end

# copy constructor that allows overriding specific fields
function Package(cfg::Package; kwargs...)
    kwargs = Dict(kwargs...)
    merged_kwargs = Dict()
    for field in fieldnames(Package)
        merged_kwargs[field] = get(kwargs, field, getfield(cfg, field))
        delete!(kwargs, field)
    end
    if !isempty(kwargs)
        throw(ArgumentError("unknown keyword arguments: $(join(keys(kwargs), ", "))"))
    end
    Package(; merged_kwargs...)
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
