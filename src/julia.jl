import JSON
import Downloads
using Git: git
using BinaryBuilder: DirectorySource, ExecutableProduct, build_tarballs

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
        i = findfirst(files) do file
            file["triplet"] == Sys.MACHINE
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

function get_julia_repo(spec)
    # split the spec into the repository and commit (e.g. `maleadt/julia#master`)
    parts = split(spec, '#')
    repo_spec, commit_spec = if length(parts) == 2
        parts
    elseif length(parts) == 1
        "JuliaLang/julia", spec
    else
        error("Invalid repository/commit specification $spec")
        return nothing
    end

    # perform a bare check-out of the repo
    # TODO: check-out different repositories into a single bare check-out under different
    #       remotes? most objects are going to be shared, so this would save time and space.
    @debug "Cloning/updating $repo_spec..."
    bare_checkout = joinpath(download_dir, repo_spec)
    if ispath(joinpath(bare_checkout, "config"))
        run(`$(git()) -C $bare_checkout fetch --quiet`)
    else
        run(`$(git()) clone --quiet --bare https://github.com/$(repo_spec).git $bare_checkout`)
    end

    # check-out the actual source code into a temporary directory
    julia_checkout = mktempdir()
    run(`$(git()) clone --quiet $bare_checkout $julia_checkout`)
    run(`$(git()) -C $julia_checkout checkout --quiet $commit_spec`)
    return julia_checkout
end

function get_repo_details(repo)
    version = VersionNumber(read(joinpath(repo, "VERSION"), String))
    hash = chomp(read(`$(git()) -C $repo rev-parse --verify HEAD`, String))
    shorthash = hash[1:10]
    return (; version, hash, shorthash)
end

function get_julia_build(repo)
    @debug "Trying to download a Julia build..."
    repo_details = get_repo_details(repo)
    if Sys.MACHINE == "x86_64-linux-gnu"
        url = "https://julialangnightlies.s3.amazonaws.com/bin/linux/x64/$(repo_details.version.major).$(repo_details.version.minor)/julia-$(repo_details.shorthash)-linux64.tar.gz"
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

"""
    version = perform_julia_build(spec::String="master";
                                  flags::Vector{String}=String[])

Check-out and build Julia at git reference `spec` using BinaryBuilder.
Returns the `version` (what other functions use to identify this build).
This version will be added to Versions.toml.
"""
function build_julia(repo_path::String;
                     flags::Vector{String}=String[])
    repo_details = get_repo_details(repo_path)
    println("Building Julia...")

    # NOTE: for simplicity, we don't cache the build (we'd need to include the flags, etc)

    # Define a Make.user
    open("$repo_path/Make.user", "w") do io
        cpu_target = if Sys.ARCH == :x86_64
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
            nothing
        end
        if cpu_target !== nothing
            println(io, "JULIA_CPU_TARGET=$cpu_target")
        end

        for flag in flags
            println(io, flag)
        end
    end

    # Collection of sources required to build julia
    sources = [
        DirectorySource(repo_path),
    ]

    # Pre-populate the srccache and save the downloaded files
    srccache = joinpath(download_dir, "srccache")
    repo_srccache = joinpath(repo_path, "deps", "srccache")
    cp(srccache, repo_srccache)
    cd(repo_path) do
        Base.run(ignorestatus(`make -C deps getall NO_GIT=1`))
    end
    for file in readdir(repo_srccache)
        if !ispath(joinpath(srccache, file))
            cp(joinpath(repo_srccache, file), joinpath(srccache, file))
        end
    end

    # Bash recipe for building across all platforms
    script = raw"""
        cd $WORKSPACE/srcdir
        mount -t devpts -o newinstance jrunpts /dev/pts
        mount -o bind /dev/pts/ptmx /dev/ptmx

        make -j${nproc}

        # prevent building documentation
        mkdir -p doc/_build/html/en
        touch doc/_build/html/en/index.html

        make install -j${nproc}

        cp LICENSE.md ${prefix}
        contrib/fixup-libgfortran.sh ${prefix}/lib/julia
        contrib/fixup-libstdc++.sh ${prefix}/lib ${prefix}/lib/julia
    """

    # These are the platforms we will build for by default, unless further
    # platforms are passed in on the command line
    platforms = [
        Base.BinaryPlatforms.HostPlatform()
    ]

    # The products that we will ensure are always built
    products = [
        ExecutableProduct("julia", :julia)
    ]

    # Dependencies that must be installed before this package can be built
    dependencies = []

    # Build the tarballs and extract to a temporary directory
    install_dir = mktempdir()
    mktempdir() do dir
        product_hashes = cd(dir) do
            build_tarballs(binarybuilder_args, "julia", repo_details.version, sources,
                           script, platforms, products, dependencies,
                           preferred_gcc_version=v"7", skip_audit=true,
                           verbose=isdebug(:binarybuilder))
        end
        filepath, _ = product_hashes[platforms[1]]
        Pkg.unpack(filepath, install_dir)
    end

    return install_dir
end

function install_julia(config::Configuration)
    if isempty(config.buildflags)
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

        if isempty(config.buildflags)
            # see if we can download a build
            dir = get_julia_build(repo)
            if dir !== nothing
                return joinpath(dir, only(readdir(dir)))
            end
        end

        # perform a build
        build_julia(repo; flags=config.buildflags)
    finally
        rm(repo; recursive=true)
    end
end
