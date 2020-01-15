using BinaryBuilder
using LibGit2
import SHA: sha256


#
# Utilities
#

function purge()
    # prune Versions.toml: only keep versions that have an URL (i.e. removing local stuff)
    versions = read_versions()
    rm(versions_file())
    open(versions_file(); append=true) do io
        for version in sort(collect(keys(versions)))
            data = versions[version]
            if haskey(data, "url")
                println(io, "[\"$version\"]")
                for (key, value) in data
                    println(io, "$key = $(repr(value))")
                end
                println(io)
            else
                rm(downloads_dir(data["file"]); force=true)
                rm(downloads_dir(data["file"]) * ".sha256"; force=true)
            end
        end
    end

    # remove extracted trees
    rm(joinpath(dirname(@__DIR__), "deps", "usr"); recursive=true, force=true)
end

function hash_file(path)
    open(path, "r") do f
        bytes2hex(sha256(f))
    end
end

function installed_julia_dir(ver)
     jp = julia_path(ver)
     jp_contents = readdir(jp)
     # Allow the unpacked directory to either be insider another directory (as produced by
     # the buildbots) or directly inside the mapped directory (as produced by the BB script)
     if length(jp_contents) == 1
         jp = joinpath(jp, first(jp_contents))
     end
     jp
end


#
# Versions
#

# a version is identified by a specific unique version, includes a hash to verify, and
# points to a local file or a remove resource.

versions_file() = joinpath(dirname(@__DIR__), "deps", "Versions.toml")

read_versions() = TOML.parse(read(versions_file(), String))

"""
    prepare_julia(the_ver)

Download and extract the specified version of Julia using the information provided in
`Versions.toml`.
"""
function prepare_julia(the_ver::VersionNumber)
    vers = read_versions()
    for (ver, data) in vers
        ver == string(the_ver) || continue
        dir = julia_path(ver)
        mkpath(dirname(dir))
        if haskey(data, "url")
            url = data["url"]

            file = get(data, "file", "julia-$ver.tar.gz")
            @assert !isabspath(file)
            file = downloads_dir(file)
            mkpath(dirname(file))

            Pkg.PlatformEngines.download_verify_unpack(url, data["sha"], dir;
                                                       tarball_path=file, force=true)
        else
            file = data["file"]
            !isabspath(file) && (file = downloads_dir(file))
            Pkg.PlatformEngines.verify(file, data["sha"])
            isdir(dir) || Pkg.PlatformEngines.unpack(file, dir)
        end
        return
    end
    error("Requested Julia version $the_ver not found")
end

function obtain_julia(spec::String)::VersionNumber
    try
        # maybe it's a named release
        # NOTE: check this first, because "1.3" could otherwise be interpreted as v"1.3.0"
        obtain_julia_release(spec)
    catch
        try
            # maybe it already refers to a version in Versions.toml
            version = VersionNumber(spec)
            prepare_julia(version)
            version
        catch
            # assume it points to something in our Git repository
            obtain_julia_build(spec)
        end
    end
end


#
# Releases
#

# a release is identified by name, points to an online resource, but does not have a version
# number. it will be downloaded, probed, and added to Versions.toml.

releases_file() = joinpath(dirname(@__DIR__), "deps", "Releases.toml")

read_releases() = TOML.parsefile(releases_file())

# get the Julia version and short hash from a Julia installation
function get_julia_version(base)
    version = VersionNumber(read(`$(installed_julia_dir(base))/bin/julia -e 'print(Base.VERSION_STRING)'`, String))
    if version.prerelease != ()
        shorthash = read(`$(installed_julia_dir(base))/bin/julia -e 'print(Base.GIT_VERSION_INFO.commit_short)'`, String)
        version = VersionNumber(string(version) * string("-", shorthash))
    end
    return version
end

"""
    version = obtain_julia_release(name::String)

Download Julia from an on-line source listed in Releases.toml as identified by `name`.
Returns the `version` (what other functions use to identify this build).
This version will be added to Versions.toml.
"""
function obtain_julia_release(name::String)
    releases = read_releases()
    @assert haskey(releases, name) "Julia release $name is not registered in Releases.toml"
    data = releases[name]

    # get the filename and extension from the url
    url = data["url"]
    filename = basename(url)
    if endswith(filename, ".tar.gz")
        ext = ".tar.gz"
        base = filename[1:end-7]
    else
        ext, base = splitext(filename)
    end

    # download
    filepath = downloads_dir(base)
    mkpath(dirname(filepath))
    ispath(filepath) && rm(filepath)
    Pkg.PlatformEngines.download(url, filepath)

    # unpack
    tempdir = julia_path(base)
    ispath(tempdir) && rm(tempdir; recursive=true)
    Pkg.PlatformEngines.unpack(filepath, tempdir)

    version = get_julia_version(base)
    versions = read_versions()
    if haskey(versions, string(version))
        @info "Julia $name (version $version) already available"
        rm(filepath)
    else
        # always use the hash of the downloaded file to force a check during `prepare_julia`
        filehash = hash_file(filepath)

        # move to its final location
        filename = "julia-$version$ext"
        if ispath(downloads_dir(filename))
            @warn "Destination file $filename already exists, assuming it matches"
            rm(filepath)
        else
            mv(filepath, downloads_dir(filename))
        end

        # Update Versions.toml
        version_stanza = """
            ["$version"]
            file = "$filename"
            sha = "$filehash"
            """
        open(versions_file(); append=true) do f
            println(f, version_stanza)
        end
    end

    rm(tempdir; recursive=true) # let `prepare_julia` unpack; keeps code simpler here
    return version
end


#
# Builds
#

# get a repository handle, cloning or updating the repository along the way
function get_repo(name)
    repo_path = downloads_dir(name)
    if !isdir(repo_path)
        @info "Cloning $name..."
        repo = LibGit2.clone("https://github.com/$name", repo_path)
    else
        repo = LibGit2.GitRepo(repo_path)
        LibGit2.fetch(repo)

        # prune to get rid of nonexisting branches (like the pull/PR/merge ones)
        remote = LibGit2.get(LibGit2.GitRemote, repo, "origin")
        fo = LibGit2.FetchOptions(prune=true)
        LibGit2.fetch(remote, String[]; options=fo)
    end

    return repo
end

# look up a refspec in a git repository
function get_repo_commit(repo::LibGit2.GitRepo, spec)
    try
        # maybe it's a remote branch
        remote = LibGit2.get(LibGit2.GitRemote, repo, "origin")
        LibGit2.GitCommit(repo, "refs/remotes/origin/$spec")
    catch err
        isa(err, LibGit2.GitError) || rethrow()
        try
            # maybe it's a version tag
            LibGit2.GitCommit(repo, "refs/tags/v$spec")
        catch err
            isa(err, LibGit2.GitError) || rethrow()
            try
                # maybe it's a remote ref, and we need to fetch it first
                remote = LibGit2.get(LibGit2.GitRemote, repo, "origin")
                LibGit2.fetch(remote, ["+refs/$spec:refs/remotes/origin/$spec"])
                LibGit2.GitCommit(repo, "refs/remotes/origin/$spec")
            catch err
                isa(err, LibGit2.GitError) || rethrow()

                # give up and assume it's a commit or something
                LibGit2.GitCommit(repo, spec)
            end
        end
    end
end

# get the Julia version and short hash corresponding with a refspec in a Julia repo
function get_julia_repoversion(spec, repo_name)
    # get the Julia repo
    repo = get_repo(repo_name)
    commit = get_repo_commit(repo, spec)

    # lookup the version number and commit hash
    tree = LibGit2.peel(LibGit2.GitTree, commit)
    version = VersionNumber(chomp(LibGit2.content(tree["VERSION"])))
    hash = LibGit2.GitHash(commit)
    # FIXME: no way to get the short hash with LibGit2? It just uses the length argument.
    #shorthash = LibGit2.GitShortHash(hash, 7)
    shorthash = LibGit2.GitShortHash(chomp(read(`git -C $(downloads_dir(repo_name)) rev-parse --short $hash`, String)))
    if version.prerelease != ()
        version = VersionNumber(string(version) * "-" * string(shorthash))
    end

    return version, string(hash), string(shorthash)
end

function obtain_julia_build(spec::String="master", repo_name::String="JuliaLang/julia")
    version, hash, shorthash = get_julia_repoversion(spec, repo_name)
    versions = read_versions()
    if haskey(versions, string(version))
        return version
    end

    # try downloading it from the build bots
    url = "https://julialangnightlies.s3.amazonaws.com/bin/linux/x64/$(version.major).$(version.minor)/julia-$(shorthash)-linux64.tar.gz"
    try
        filename = basename(url)
        filepath = downloads_dir(filename)
        if ispath(filepath)
            @warn "Destination file $filename already exists, assuming it matches"
        else
            download(url, filepath)
        end
        filehash = hash_file(filepath)

        # Update Versions.toml
        version_stanza = """
            ["$version"]
            file = "$filename"
            sha = "$filehash"
            """
        open(versions_file(); append=true) do f
            println(f, version_stanza)
        end

        return version
    catch ex
        # assume this was a download failure, and proceed to build Julia ourselves
        # TODO: check this was actually a 404
        isa(ex, ProcessFailedException) || rethrow()
        bt = catch_backtrace()
        @error "Could not download Julia $spec (version $version), performing a build" exception=(ex,bt)
        perform_julia_build(spec, repo_name)
    end
end

"""
    version = perform_julia_build(spec::String="master"; precompile::Bool=true
                                  binarybuilder_args::Vector{String}=String[])

Check-out and build Julia at git reference `spec` using BinaryBuilder.
Returns the `version` (what other functions use to identify this build).
This version will be added to Versions.toml.
"""
function perform_julia_build(spec::String="master", repo_name::String="JuliaLang/julia";
                             binarybuilder_args::Vector{String}=String[],
                             precompile::Bool=true)
    version, hash, shorthash = get_julia_repoversion(spec, repo_name)
    versions = read_versions()
    if haskey(versions, string(version))
        return version
    end

    # Collection of sources required to build julia
    # NOTE: we need to check out Julia ourselves, because BinaryBuilder does not know how to
    #       fetch and checkout remote refs.
    repo = get_repo(repo_name)
    LibGit2.checkout!(repo, hash)
    repo_path = downloads_dir(repo_name)
    sources = [
        repo_path
    ]

    # Define a Make.user
    make_user = """
        JULIA_CPU_TARGET=generic;sandybridge,-xsaveopt,clone_all;haswell,-rdrnd,base(1)
        """
    if !precompile
        make_user *= """
            JULIA_PRECOMPILE=0
            """
    end

    # Bash recipe for building across all platforms
    script = raw"""
    cd $WORKSPACE/srcdir
    mount -t devpts -o newinstance jrunpts /dev/pts
    mount -o bind /dev/pts/ptmx /dev/ptmx

    cat > Make.user <<EOF
    """ * make_user * raw"""
    EOF
    make -j${nproc}

    # prevent building documentation
    mkdir -p doc/_build/html/en
    touch doc/_build/html/en/index.html

    make install
    cp LICENSE.md ${prefix}
    contrib/fixup-libgfortran.sh ${prefix}/lib/julia
    contrib/fixup-libstdc++.sh ${prefix}/lib ${prefix}/lib/julia
    """

    # These are the platforms we will build for by default, unless further
    # platforms are passed in on the command line
    platforms = [
        Linux(:x86_64, libc=:glibc)
    ]

    # The products that we will ensure are always built
    products = Product[
        ExecutableProduct("julia", :julia)
    ]

    # Dependencies that must be installed before this package can be built
    dependencies = []

    # Build the tarballs
    product_hashes = cd(joinpath(@__DIR__, "..", "deps")) do
        build_tarballs(binarybuilder_args, "julia", version, sources, script, platforms, products, dependencies, preferred_gcc_version=v"7", skip_audit=true)
    end
    filepath, filehash = product_hashes[platforms[1]]
    filename = basename(filepath)

    # Update Versions.toml
    version_stanza = """
        ["$version"]
        file = "$filename"
        sha = "$filehash"
        """
    open(versions_file(); append=true) do f
        println(f, version_stanza)
    end

    # Copy the generated tarball to the downloads folder
    if ispath(downloads_dir(filename))
        # NOTE: we can't use the previous file here (like in `download_julia`)
        #       because the hash will most certainly be different
        @warn "Destination file $filename already exists, overwriting"
    end
    mv(filepath, downloads_dir(filename))

    # clean-up
    rm(joinpath(dirname(@__DIR__), "deps", "build"); recursive=true, force=true)
    rm(joinpath(dirname(@__DIR__), "deps", "products"); recursive=true, force=true)

    return version
end
