import JSON
import Downloads
using Git: git
using Base.BinaryPlatforms: Platform, triplet

const VERSIONS_URL = "https://julialang-s3.julialang.org/bin/versions.json"

function get_julia_release(spec::String)
    dirpath = mktempdir()
   if spec == "nightly"
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
        Pkg.PlatformEngines.download_verify_unpack(url, nothing, dirpath;
                                                   ignore_existence=true)
    else
        @debug "Checking if '$spec' is an official release..."

        # the spec needs to be a valid version number
        version_spec = tryparse(VersionNumber, spec)
        if isnothing(version_spec)
            @warn "Not a valid release name"
            return nothing
        end

        # download the versions.json and look up the version
        versions = JSON.parse(sprint(io->Downloads.download(VERSIONS_URL, io)))
        if !haskey(versions, string(version_spec))
            @warn "Unknown release name '$spec'"
            return nothing
        end
        files = versions[string(version_spec)]["files"]

        # find a file entry for our machine
        platform = parse(Platform, Sys.MACHINE) # don't use Sys.MACHINE directly as it may
                                                # contain unnecessary tags, like -pc-
        i = findfirst(files) do file
            file["triplet"] == triplet(platform)
        end
        if isnothing(i)
            @error "Release unavailable for $(Sys.MACHINE)"
            return nothing
        end
        file = files[i]

        # download and extract to a temporary directory
        filename = basename(file["url"])
        filepath = joinpath(download_dir, filename)
        Pkg.PlatformEngines.download_verify_unpack(file["url"], file["sha256"], dirpath;
                                                   tarball_path=filepath, force=true,
                                                   ignore_existence=true)
    end
    return dirpath
end

# NOTE: Julia repo dir isn't cached, as it's only checked-out once and removed afterwards
get_julia_repo(spec) = get_github_repo(spec, "JuliaLang/julia")

function get_repo_details(repo)
    version = VersionNumber(read(joinpath(repo, "VERSION"), String))
    hash = chomp(read(`$(git()) -C $repo rev-parse --verify HEAD`, String))
    shorthash = hash[1:10]
    return (; version, hash, shorthash)
end

function get_julia_build(repo)
    @debug "Trying to download a Julia build..."
    repo_details = get_repo_details(repo)
    if Sys.islinux() && Sys.ARCH == :x86_64
        url = "https://julialangnightlies.s3.amazonaws.com/bin/linux/x64/$(repo_details.version.major).$(repo_details.version.minor)/julia-$(repo_details.shorthash)-linux64.tar.gz"
    elseif Sys.islinux() && Sys.ARCH == :aarch64
        url = "https://julialangnightlies.s3.amazonaws.com/bin/linux/aarch64/$(repo_details.version.major).$(repo_details.version.minor)/julia-$(repo_details.shorthash)-linuxaarch64.tar.gz"
    else
        @debug "Don't know how to get build for $(Sys.MACHINE)"
        return nothing
    end

    # download and extract to a temporary directory
    filename = basename(url)
    filepath = joinpath(download_dir, filename)
    dirpath = mktempdir()
    try
        Pkg.PlatformEngines.download_verify_unpack(url, nothing, dirpath;
                                                   tarball_path=filepath, force=true,
                                                   ignore_existence=true)
        return dirpath
    catch err
        @debug "Could not download build" exception=(err, catch_backtrace())
        return nothing
    end
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
    install_dir = build_julia(repo_path, config)

Build the Julia check-out at `repo_path` with the properties (build flags, command, and
resulting Julia binary) from `config`.
"""
function build_julia(_repo_path::String, config::Configuration)
    repo_details = get_repo_details(_repo_path)
    println("Building Julia...")

    # copy the repository so that we can mutate it (add Make.user, build in-place, etc)
    repo_path = mktempdir()
    cp(_repo_path, repo_path; force=true)

    # Pre-populate the srccache and save the downloaded files
    srccache = joinpath(download_dir, "srccache")
    repo_srccache = joinpath(repo_path, "deps", "srccache")
    cp(srccache, repo_srccache)
    cd(repo_path) do
        run(ignorestatus(`make -C deps getall NO_GIT=1`))
    end
    for file in readdir(repo_srccache)
        if !ispath(joinpath(srccache, file))
            cp(joinpath(repo_srccache, file), joinpath(srccache, file))
        end
    end

    # Define a Make.user
    open("$repo_path/Make.user", "w") do io
        println(io, "prefix=/install")

        for flag in config.buildflags
            println(io, "override $flag")
        end

        if !any(startswith("JULIA_CPU_TARGET"), config.buildflags)
            println(io, "JULIA_CPU_TARGET=$default_cpu_target")
        end
    end

    # build and install Julia
    install_dir = mktempdir()
    build_config = Configuration(; rootfs="package_linux.x86_64", xvfb=false)
    mounts = Dict(
        "/source:rw"    => repo_path,
        "/install:rw"   => install_dir
    )
    script = raw"""
        set -ue
        cd /source
        cp LICENSE.md /install

        # prevent building documentation
        mkdir -p doc/_build/html/en
        touch doc/_build/html/en/index.html

        export MAKEFLAGS="-j$(nproc)"
    """ * config.buildcommands * "\n" * raw"""
        contrib/fixup-libgfortran.sh /install/lib/julia
        contrib/fixup-libstdc++.sh /install/lib /install/lib/julia
    """
    try
        sandboxed_cmd(build_config, `/bin/bash -c $script`; mounts)
    catch err
        rm(install_dir; recursive=true)
        rethrow()
    finally
        rm(repo_path; recursive=true)
    end

    return install_dir
end

function _install_julia(config::Configuration)
    if can_use_binaries(config)
        # check if it's an official release
        dir = get_julia_release(config.julia)
        if dir !== nothing
            return joinpath(dir, only(readdir(dir)))
        end
    end

    # try to resolve to a Julia repository and hash
    repo = get_julia_repo(config.julia)
    if repo === nothing
        error("Could not check-out Julia repository for $(config.julia)")
    end
    try
        repo_details = get_repo_details(repo)
        @debug "Julia $config.julia resolved to v$(repo_details.version), Git SHA $(repo_details.hash)"

        if can_use_binaries(config)
            # see if we can download a build
            dir = get_julia_build(repo)
            if dir !== nothing
                return joinpath(dir, only(readdir(dir)))
            end
        end

        # perform a build
        build_julia(repo, config)
    finally
        rm(repo; recursive=true)
    end
end

const julia_lock = ReentrantLock()
const julia_cache = Dict()
function install_julia(config::Configuration)
    lock(julia_lock) do
        key = (config.julia, config.buildflags, config.buildcommands)
        dir = get(julia_cache, key, nothing)
        if dir === nothing || !isdir(dir)
            julia_cache[key] = _install_julia(config)
        end
        return julia_cache[key]
    end
end
