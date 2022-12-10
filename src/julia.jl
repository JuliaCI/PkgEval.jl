import JSON3
import Downloads
using Git: git
using Base.BinaryPlatforms: Platform, triplet

const VERSIONS_URL = "https://julialang-s3.julialang.org/bin/versions.json"

function get_julia_nightly(config::Configuration)
    @debug "Downloading nightly build..."

    url = if Sys.islinux() && config.arch == "x86_64"
        "https://julialangnightlies-s3.julialang.org/bin/linux/x64/julia-latest-linux64.tar.gz"
    elseif Sys.islinux() && config.arch == "i686"
        "https://julialangnightlies-s3.julialang.org/bin/linux/x86/julia-latest-linux32.tar.gz"
    elseif Sys.islinux() && config.arch == "aarch64"
        "https://julialangnightlies-s3.julialang.org/bin/linux/aarch64/julia-latest-linux-aarch64.tar.gz"
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
        return get_julia_nightly(config)
    end

    # in all other cases, the spec needs to be a valid version number
    version_spec = tryparse(VersionNumber, config.julia)
    if isnothing(version_spec)
        @debug "Not a valid release name"
        return nothing
    end

    # download the versions.json and look up the version
    versions = JSON3.read(sprint(io->Downloads.download(VERSIONS_URL, io)))
    if !haskey(versions, string(version_spec))
        @debug "Unknown release name '$(config.julia)'"
        return nothing
    end
    files = versions[string(version_spec)]["files"]

    # find a file entry for our machine
    i = findfirst(files) do file
        file["triplet"] == "$(config.arch)-linux-gnu"
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

    if config.arch != String(Sys.ARCH)
        @error "Cross compilation of Julia has not been implemented yet"
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
    job = if Sys.islinux() && config.arch == "x86_64"
        PkgEval.find_sibling_buildkite_job(job, "build_x86_64-linux-gnu")
    elseif Sys.islinux() && config.arch == "i686"
        PkgEval.find_sibling_buildkite_job(job, "build_i686-linux-gnu")
    elseif Sys.islinux() && config.arch == "aarch64"
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
function get_cpu_target(config)
    if config.arch == "x86_64"
        "generic;sandybridge,-xsaveopt,clone_all;haswell,-rdrnd,base(1)"
    elseif config.arch == "i686"
        "pentium4;sandybridge,-xsaveopt,clone_all"
    elseif config.arch == "armv7l"
        "armv7-a;armv7-a,neon;armv7-a,neon,vfp4"
    elseif config.arch == "aarch64"
        "generic;cortex-a57;thunderx2t99;carmel"
    elseif config.arch == "powerpc64le"
        "pwr8"
    else
        @warn "Cannot determine JULIA_CPU_TARGET for unknown architecture $(config.arch)"
        ""
    end
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
            println(io, "JULIA_CPU_TARGET=$(get_cpu_target(config))")
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
        @debug "Successfully build Julia:\n$log"
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
    lock(julia_lock) do
        key = (config.julia, config.arch, config.buildflags, config.buildcommands)
        dir = get(julia_cache, key, nothing)
        if dir === nothing || !isdir(dir)
            julia_cache[key] = _install_julia(config)
        end
        return julia_cache[key]
    end
end
