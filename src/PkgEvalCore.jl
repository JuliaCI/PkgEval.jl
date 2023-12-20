module PkgEvalCore

using Pkg
using Base: UUID

export Configuration, ismodified, Package,
       package_spec_tuple, can_use_binaries,
       RREnabled, RREnabledOnRetry, RRDisabled


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
Base.convert(::Type{Setting{T}}, val) where {T} = Setting{T}(convert(T, val), true)

# ... unless the Default constructor is used
Default(val::T) where {T} = Setting{T}(val, false)


## configuration: groups settings

@enum RecordReplayMode begin
    RREnabled
    RREnabledOnRetry
    RRDisabled
end
Base.convert(::Type{RecordReplayMode}, x::Bool) = x ? RREnabled : RRDisabled

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
    buildcommands::Setting{String} = Default("make binary-dist")
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
    cpus::Setting{Vector{Int}} = Default(Int[])
    ## how many threads the Julia process should use
    threads::Setting{Int} = Default(1)
    ## whether to spawn a virtual X server and expose that to the sandbox
    xvfb::Setting{Bool} = Default(true)
    ## whether to run under record-replay (rr). traces will be uploaded to AWS S3, so you
    ## additionally need to set PKGEVAL_RR_BUCKET and some S3 authentication env vars.
    rr::Setting{RecordReplayMode} = Default(RRDisabled)
    ## whether to separately precompile packages before testing.
    ## disabling this can be useful to trap precompilation-related issues under rr.
    precompile::Setting{Bool} = Default(true)
    ## limits imposed on the test process
    log_limit::Setting{Int} = Default(2^20) # 1 MiB
    time_limit::Setting{Float64} = Default(45*60) # 45 mins
    memory_limit::Setting{Int} = Default(32*2^30) # 32 GiB
    process_limit::Setting{Int} = Default(512)
    ## compiled mode: first generating a system image containing each package under test,
    ##                then running tests using that system image.
    compiled::Setting{Bool} = Default(false)
    compile_time_limit::Setting{Float64} = Default(30*60) # 30 mins
end

function durationstring(seconds)
    components = String[]
    divisions = [3600 => "hour", 60 => "min", 1 => "sec"]
    for (div, name) in divisions
        if seconds >= div
            push!(components, "$(Int(seconds ÷ div)) $name")
            seconds %= div
        end
    end
    if isempty(components)
        "0 sec"
    else
        join(components, " ")
    end
end

# verbose printing
function Base.show(io::IO, ::MIME"text/plain", cfg::Configuration)
    function show_setting(field, renderer=identity)
        setting = getfield(cfg, Symbol(field))
        value_str = renderer(setting[])

        print(io, "  - $field: ")
        if get(io, :color, false)
            Base.printstyled(io, value_str; color=setting.modified ? :red : :green)
        else
            print(io, value_str, " (", setting.modified ? "modified" : "default", ")")
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
    show_setting.(["env", "cpus", "threads", "xvfb", "rr", "precompile", "compiled", "process_limit"])
    show_setting.(["log_limit", "memory_limit"], Base.format_bytes)
    show_setting.(["time_limit", "compile_time_limit"], durationstring)

    print(io, ")")
end

# compact printing, making sure the output is parseable again
function Base.show(io::IO, cfg::Configuration)
    default_cfg = Configuration()
    print(io, "Configuration(")
    got_fields = false
    for field in fieldnames(Configuration)
        if getproperty(cfg, field) != getproperty(default_cfg, field)
            got_fields && print(io, ", ")
            print(io, field, "=", repr(getproperty(cfg, field)))
            got_fields = true
        end
    end
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
function Base.convert(::Type{Pkg.Types.PackageSpec}, pkg::Package)
    spec = (;)
    for field in (:name, :uuid, :version, :url, :rev)
        val = getfield(pkg, field)
        if val !== nothing
            spec = merge(spec, NamedTuple{(field,)}((val,)))
        end
    end
    PackageSpec(; spec...)
end

# compact printing, making sure the output is parseable again
function Base.show(io::IO, pkg::Package)
    print(io, "Package(")
    got_fields = false
    for field in fieldnames(Package)
        val = getfield(pkg, field)
        if val !== nothing
            got_fields && print(io, ", ")
            print(io, field, "=", repr(val))
            got_fields = true
        end
    end
    print(io, ")")
end

end
