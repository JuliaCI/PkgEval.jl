using LazyArtifacts: @artifact_str
lazy_artifact(x) = @artifact_str(x)

using Tar: extract
using CodecZlib: GzipDecompressorStream
using CodecXz: XzDecompressorStream
using CodecZstd: ZstdDecompressorStream

function _create_rootfs(config::Configuration)
    # a bare rootfs isn't usable out-of-the-box
    derived = mktempdir(prefix="pkgeval_rootfs_")

    # BUG: Pkg installs our artifacts with wrong permissions (JuliaLang/Pkg.jl#/3269)
    if false
        base = lazy_artifact(config.rootfs)
        cp(base, derived; force=true)
    else
        artifacts_toml = TOML.parsefile(joinpath(dirname(@__DIR__), "Artifacts.toml"))
        rootfs_toml = artifacts_toml["$(config.rootfs).$(Sys.ARCH)"]

        # download
        url = rootfs_toml["download"][1]["url"]
        hash = rootfs_toml["download"][1]["sha256"]
        tarball = joinpath(download_dir, hash)
        if !isfile(tarball)
            Pkg.PlatformEngines.download_verify(url, hash, tarball)
        end

        # extract
        open(tarball) do io
            stream = if endswith(url, ".xz")
                XzDecompressorStream(io)
            elseif endswith(url, ".gz")
                GzipDecompressorStream(io)
            elseif endswith(url, ".zst")
                ZstdDecompressorStream(io)
            else
                error("Unknown file extension")
            end
            extract(stream, derived)
        end
    end

    # add a user and group
    chmod(joinpath(derived, "etc/passwd"), 0o644)
    open(joinpath(derived, "etc/passwd"), "a") do io
        println(io, "$(config.user):x:$(config.uid):$(config.gid)::$(config.home):/bin/bash")
    end
    chmod(joinpath(derived, "etc/group"), 0o644)
    open(joinpath(derived, "etc/group"), "a") do io
        println(io, "$(config.group):x:$(config.gid):")
    end

    # replace resolv.conf
    rm(joinpath(derived, "etc/resolv.conf"); force=true)
    write(joinpath(derived, "etc/resolv.conf"), read("/etc/resolv.conf"))

    # create and populate the home directory
    homedir = joinpath(derived, relpath(config.home, "/"))
    mkpath(homedir)
    ## provide at least a single simple font so that Cairo can work
    fontdir = joinpath(homedir, ".local/share/fonts")
    mkpath(fontdir)
    font = "droid-sans-subset.ttf"
    cp(joinpath(@__DIR__, "..", "res", font), joinpath(fontdir, font));

    return derived
end

const rootfs_lock = ReentrantLock()
const rootfs_cache = Dict()
function create_rootfs(config::Configuration)
    lock(rootfs_lock) do
        key = (config.rootfs, config.uid, config.user, config.gid, config.group, config.home)
        dir = get(rootfs_cache, key, nothing)
        if dir === nothing || !isdir(dir)
            rootfs_cache[key] = _create_rootfs(config)
        end
        return rootfs_cache[key]
    end
end
