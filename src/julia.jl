import JSON3
import Downloads
using Git: git
using Base.BinaryPlatforms: Platform, triplet

const VERSIONS_URL = "https://julialang-s3.julialang.org/bin/versions.json"

function get_julia_nightly()
    @debug "Downloading nightly build..."

    url = if Sys.islinux() && Sys.ARCH == :x86_64
        "https://julialangnightlies-s3.julialang.org/bin/linux/x64/julia-latest-linux64.tar.gz"
    elseif Sys.islinux() && Sys.ARCH == :i686
        "https://julialangnightlies-s3.julialang.org/bin/linux/x86/julia-latest-linux32.tar.gz"
    elseif Sys.islinux() && Sys.ARCH == :aarch64
        "https://julialangnightlies-s3.julialang.org/bin/linux/aarch64/julia-latest-linuxaarch64.tar.gz"
    else
        error("Don't know how to get nightly build for $(Sys.MACHINE)")
    end

    # download and extract to a temporary directory, but don't keep the tarball
    dir = mktempdir(prefix="pkgeval_julia_")
    Pkg.PlatformEngines.download_verify_unpack(url, nothing, dir;
                                               ignore_existence=true)
    return only(readdir(dir; join=true))
end

function get_julia_release(config::Configuration)
    can_use_binaries(config) || return

    @debug "Checking if '$(config.julia)' is an official release..."

    # special case: nightly
    if config.julia == "nightly"
        return get_julia_nightly()
    end

    # download the versions.json
    version_db = JSON3.read(sprint(io->Downloads.download(VERSIONS_URL, io)))

    # special case: stable
    if config.julia == "stable"
        versions = VersionNumber.(String.(keys(version_db)))
        filter!(versions) do version
            isempty(version.prerelease)
        end
        version_spec = maximum(versions)

    # in all other cases, the spec needs to be a valid version number
    else
        version_spec = tryparse(VersionNumber, config.julia)
        if isnothing(version_spec)
            @debug "Not a valid release name"
            return nothing
        end
    end

    # look up the version
    version_db = JSON3.read(sprint(io->Downloads.download(VERSIONS_URL, io)))
    if !haskey(version_db, string(version_spec))
        @debug "Unknown release name '$(config.julia)'"
        return nothing
    end
    files = version_db[string(version_spec)]["files"]

    # find a file entry for our machine
    platform = parse(Platform, Sys.MACHINE) # don't use Sys.MACHINE directly as it may
                                            # contain unnecessary tags, like -pc-
    i = findfirst(files) do file
        file["triplet"] == triplet(platform)
    end
    if isnothing(i)
        @debug "Release unavailable for $(Sys.MACHINE)"
        return nothing
    end
    file = files[i]

    # download and extract to a temporary directory
    @debug "Found a matching release for '$(config.julia)': $(file["url"])"
    filename = basename(file["url"])
    filepath = joinpath(download_dir, filename)
    dir = mktempdir(prefix="pkgeval_julia_")
    Pkg.PlatformEngines.download_verify_unpack(file["url"], file["sha256"], dir;
                                                tarball_path=filepath, force=true,
                                                ignore_existence=true)
    return only(readdir(dir; join=true))
end

function get_julia_build(config)
    can_use_binaries(config) || return
    repo, ref = parse_repo_spec(config.julia, "JuliaLang/julia")

    if !haskey(ENV, "BUILDKITE_TOKEN")
        @debug "No Buildkite token found, skipping..."
        return nothing
    end

    # get statuses
    statuses = first(GitHub.statuses(repo, ref; auth=github_auth()))
    status_idx = findfirst(status->status.context == "Build", statuses)
    if status_idx === nothing
        @debug "No build status found for $repo@$ref"
        return nothing
    end
    status = statuses[status_idx]

    # get Buildkite job
    job = BuildkiteJob(string(status.target_url))
    ## navigate to the relevant build
    job = if Sys.islinux() && Sys.ARCH == :x86_64
        PkgEval.find_sibling_buildkite_job(job, "build_x86_64-linux-gnu")
    elseif Sys.islinux() && Sys.ARCH == :i686
        PkgEval.find_sibling_buildkite_job(job, "build_i686-linux-gnu")
    elseif Sys.islinux() && Sys.ARCH == :aarch64
        PkgEval.find_sibling_buildkite_job(job, "build_aarch64-linux-gnu")
    else
        @debug "No Buildkite job found for $repo#$ref on $(Sys.MACHINE)"
        nothing
    end
    if job === nothing
        return nothing
    end

    # get Buildkite artifacts
    artifacts = get_buildkite_job_artifacts(job)
    if isempty(artifacts)
        @debug "No artifacts found for $repo@$ref"
        return nothing
    end
    artifact = first(artifacts)

    # download and extract to a temporary directory
    @debug "Found a matching artifact for $repo#$ref: $(artifact.url)"
    filepath = download(artifact)
    dir = mktempdir(prefix="pkgeval_julia_")
    Pkg.PlatformEngines.unpack(filepath, dir)
    return only(readdir(dir; join=true))
end

# to get closer to CI-generated binaries, use a multiversioned build
const default_cpu_target = if Sys.ARCH == :x86_64
    "generic;sandybridge,-xsaveopt,clone_all;haswell,-rdrnd,base(1)"
elseif Sys.ARCH == :i686
    "pentium4;sandybridge,-xsaveopt,clone_all"
elseif Sys.ARCH == :armv7l
    "armv7-a;armv7-a,neon;armv7-a,neon,vfp4"
elseif Sys.ARCH == :aarch64
    "generic;cortex-a57;thunderx2t99;carmel"
elseif Sys.ARCH == :powerpc64le
    "pwr8"
else
    @warn "Cannot determine JULIA_CPU_TARGET for unknown architecture $(Sys.ARCH)"
    ""
end

"""
    install_dir = build_julia(config)

Build Julia from the given `config` and return the path to the installation directory.
"""
function build_julia(config::Configuration)
    repo, ref = parse_repo_spec(config.julia, "JuliaLang/julia")
    checkout = get_github_checkout(repo, ref)

    if checkout === nothing
        error("Could not check-out Julia repository for $(config.julia)")
    end

    try
        # perform a build
        println("Building Julia...")
        build_julia!(config, checkout)
    finally
        rm(checkout; recursive=true)
    end
end
function build_julia!(config::Configuration, checkout::String)
    # Pre-populate the srccache and save the downloaded files
    srccache = joinpath(download_dir, "srccache")
    repo_srccache = joinpath(checkout, "deps", "srccache")
    cp(srccache, repo_srccache)
    run(ignorestatus(setenv(`make -C deps getall NO_GIT=1`; dir=checkout)),
        devnull, devnull, devnull)
    for file in readdir(repo_srccache)
        if !ispath(joinpath(srccache, file))
            cp(joinpath(repo_srccache, file), joinpath(srccache, file))
        end
    end

    # Define a Make.user
    open("$checkout/Make.user", "w") do io
        println(io, "prefix=/install")

        for flag in config.buildflags
            println(io, "override $flag")
        end

        if !any(startswith("JULIA_CPU_TARGET"), config.buildflags)
            println(io, "JULIA_CPU_TARGET=$default_cpu_target")
        end
    end

    # build and install Julia
    install_dir = mktempdir(prefix="pkgeval_julia_")
    build_config = Configuration(; rootfs="package_linux", xvfb=false)
    mounts = Dict(
        "/source:rw"    => checkout,
        "/install:rw"   => install_dir
    )
    script = raw"""
        set -ue
        cd /source

        # prevent building documentation
        mkdir -p doc/_build/html/en
        touch doc/_build/html/en/index.html

        export MAKEFLAGS="-j$(nproc)"
    """ * config.buildcommands * "\n" * raw"""
        contrib/fixup-libgfortran.sh /install/lib/julia
        contrib/fixup-libstdc++.sh /install/lib /install/lib/julia
    """

    output = Pipe()
    proc = sandboxed_cmd(build_config, `/bin/bash -c $script`; wait=false, mounts,
                         stdin=devnull, stdout=output, stderr=output)
    close(output.in)

    # collect output
    log_monitor = @async begin
        io = IOBuffer()
        while !eof(output)
            line = readline(output; keep=true)
            isdebug(:sandbox) && print(line)
            print(io, line)
        end
        return String(take!(io))
    end

    wait(proc)
    close(output)
    log = fetch(log_monitor)

    if success(proc)
        @debug "Successfully built Julia:\n$log"
        return install_dir
    else
        @error "Error building Julia:\n$log"
        rm(install_dir; recursive=true)
        error("Error building Julia")
    end
end

function _install_julia(config::Configuration)
    # check if it's an official release
    dir = get_julia_release(config)
    if dir !== nothing
        return dir
    end

     # try to download a Buildkite artifact
    dir = get_julia_build(config)
    if dir !== nothing
        return dir
    end

    # finally, just build Julia
    return build_julia(config)
end

const julia_lock = ReentrantLock()
const julia_cache = Dict()
function install_julia(config::Configuration)
    if ispath(config.julia)
        return config.julia
    end

    lock(julia_lock) do
        key = (config.julia, config.buildflags, config.buildcommands)
        dir = get(julia_cache, key, nothing)
        if dir === nothing || !isdir(dir)
            julia_cache[key] = _install_julia(config)
        end
        return julia_cache[key]
    end
end


## version identification

# normally we'd look at VERSION + commit and do something like commit-name.sh,
# but we don't necessarily have a source tree so need to run the actual binary.

function _julia_version(config::Configuration)
    p = Pipe()
    close(p.in)
    PkgEval.sandboxed_julia(config, `-e 'print(VERSION)'`; stdout=p.out)
    VersionNumber(read(p.out, String))
end

const julia_version_lock = ReentrantLock()
const julia_version_cache = Dict()
function julia_version(config::Configuration)
    lock(julia_version_lock) do
        get!(julia_version_cache, config.julia) do
            _julia_version(config)
        end
    end
end
