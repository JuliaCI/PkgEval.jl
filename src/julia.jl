using BinaryBuilder
using Downloads
using LibGit2
import SHA: sha256


#
# Utilities
#

function purge()
    # remove old builds
    vers = TOML.parse(read(extra_versions_file(), String))
    rm(extra_versions_file())
    open(extra_versions_file(); append=true) do io
        for (ver, data) in vers
            @assert haskey(data, "file")
            @assert !haskey(data, "url")

            path = download_dir(data["file"])
            if round(now() - unix2datetime(mtime(path)), Dates.Week) < Dates.Week(1)
                println(io, "[\"$ver\"]")
                for (key, value) in data
                    println(io, "$key = $(repr(value))")
                end
                println(io)
            else
                rm(path)
                rm(path * ".sha256"; force=true)
            end
        end
    end
end

function hash_file(path)
    open(path, "r") do f
        bytes2hex(sha256(f))
    end
end

function installed_julia_dir(jp)
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

read_versions() = merge(TOML.parse(read(versions_file(), String)),
                        TOML.parse(read(extra_versions_file(), String)))

"""
    prepare_julia(the_ver, dir=mktempdir())

Download and extract the specified version of Julia using the information provided in
`Versions.toml` to the directory `dir`.
"""
function prepare_julia(the_ver::VersionNumber, dir::String=mktempdir())
    vers = read_versions()
    for (ver, data) in vers
        ver == string(the_ver) || continue
        if haskey(data, "url")
            url = data["url"]

            file = get(data, "file", "julia-$ver.tar.gz")
            @assert !isabspath(file)
            file = download_dir(file)
            mkpath(dirname(file))

            Pkg.PlatformEngines.download_verify_unpack(url, data["sha"], dir;
                                                       tarball_path=file, force=true,
                                                       ignore_existence=true)
        else
            file = data["file"]
            !isabspath(file) && (file = download_dir(file))
            Pkg.PlatformEngines.verify(file, data["sha"])
            Pkg.PlatformEngines.unpack(file, dir)
        end
        return dir
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
        base, ext = splitext(filename)
    end

    # download
    filepath = download_dir(filename)
    duplicates = 0
    while ispath(filepath)
        duplicates += 1
        filepath = download_dir("$(base).$(duplicates)$(ext)")
    end
    mkpath(dirname(filepath))
    Downloads.download(url, filepath)

    # get version
    version = mktempdir() do install
        Pkg.PlatformEngines.unpack(filepath, install)
        get_julia_version(install)
    end

    versions = read_versions()
    if haskey(versions, string(version))
        @info "Julia $name (version $version) already available"
        rm(filepath)
    else
        # always use the hash of the downloaded file to force a check during `prepare_julia`
        filehash = hash_file(filepath)

        # rename to include the version
        filename = "julia-$version$ext"
        if ispath(download_dir(filename))
            @warn "Destination file $filename already exists, assuming it matches"
            rm(filepath)
        else
            mv(filepath, download_dir(filename))
        end

        # Update Versions.toml
        version_stanza = """
            ["$version"]
            file = "$filename"
            sha = "$filehash"
            """
        open(extra_versions_file(); append=true) do f
            println(f, version_stanza)
        end
    end

    return version
end


#
# Builds
#

# get a repository handle, cloning or updating the repository along the way
function get_repo(name)
    repo_path = download_dir(name)
    if !isdir(repo_path)
        @debug "Cloning $name to $repo_path..."
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
    shorthash = LibGit2.GitShortHash(chomp(read(`git -C $(download_dir(repo_name)) rev-parse --short $hash`, String)))
    version = VersionNumber(string(version) * "-" * string(shorthash))
    # NOTE: we append the hash to differentiate commits with identical VERSION files
    #       (we can't only do this for -DEV versions because of backport branches)

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
        filepath = download_dir(filename)
        if ispath(filepath)
            @warn "Destination file $filename already exists, assuming it matches"
        else
            Downloads.download(url, filepath)
        end
        filehash = hash_file(filepath)

        # Update Versions.toml
        version_stanza = """
            ["$version"]
            file = "$filename"
            sha = "$filehash"
            """
        open(extra_versions_file(); append=true) do f
            println(f, version_stanza)
        end

        return version
    catch ex
        # assume this was a download failure, and proceed to build Julia ourselves
        # TODO: check this was actually a 404
        isa(ex, ErrorException) || rethrow()
        bt = catch_backtrace()
        @error "Could not download Julia $spec (version $version), performing a build" exception=(ex,bt)
        perform_julia_build(spec, repo_name)
    end
end

"""
    version = perform_julia_build(spec::String="master";
                                  binarybuilder_args::Vector{String}=String[]
                                  buildflags::Vector{String}=String[])

Check-out and build Julia at git reference `spec` using BinaryBuilder.
Returns the `version` (what other functions use to identify this build).
This version will be added to Versions.toml.
"""
function perform_julia_build(spec::String="master", repo_name::String="JuliaLang/julia";
                             binarybuilder_args::Vector{String}=String[],
                             buildflags::Vector{String}=String[])
    version, hash, shorthash = get_julia_repoversion(spec, repo_name)
    if !isempty(buildflags)
        version = VersionNumber(version.major, version.minor, version.patch,
                                (version.prerelease...,
                                 "build-$(string(Base.hash(buildflags), base=16))"))
    end
    versions = read_versions()
    if haskey(versions, string(version))
        return version
    end

    # Collection of sources required to build julia
    # NOTE: we need to check out Julia ourselves, because BinaryBuilder does not know how to
    #       fetch and checkout remote refs.
    repo = get_repo(repo_name)
    LibGit2.checkout!(repo, hash)
    repo_path = download_dir(repo_name)
    sources = [
        DirectorySource(repo_path; target="julia"),
        DirectorySource(srccache_dir(); target="srccache")
    ]
    mkpath(srccache_dir())

    # Default flags
    prepend!(buildflags, [
        "JULIA_CPU_TARGET='generic;sandybridge,-xsaveopt,clone_all;haswell,-rdrnd,base(1)'"
    ])

    # Bash recipe for building across all platforms
    script = raw"""
    cd $WORKSPACE/srcdir/julia
    ln -s $WORKSPACE/srcdir/srccache deps/srccache
    mount -t devpts -o newinstance jrunpts /dev/pts
    mount -o bind /dev/pts/ptmx /dev/ptmx

    make -j${nproc} """ * join(buildflags, " ") * raw"""

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
        build_tarballs(binarybuilder_args, "julia", version, sources, script, platforms,
                       products, dependencies, preferred_gcc_version=v"7", skip_audit=true,
                       verbose=isdebug(:binarybuilder))
    end
    filepath, filehash = product_hashes[platforms[1]]
    filename = basename(filepath)
    if endswith(filename, ".tar.gz")
        ext = ".tar.gz"
        base = filename[1:end-7]
    else
        base, ext = splitext(filename)
    end

    # Copy the generated tarball to the downloads folder
    new_filepath = download_dir(filename)
    duplicates = 0
    while ispath(new_filepath)
        duplicates += 1
        new_filepath = download_dir("$(base).$(duplicates)$(ext)")
    end
    mv(filepath, download_dir(filename))

    # Update Versions.toml
    version_stanza = """
        ["$version"]
        file = "$filename"
        sha = "$filehash"
        """
    open(extra_versions_file(); append=true) do f
        println(f, version_stanza)
    end

    # clean-up
    rm(joinpath(dirname(@__DIR__), "deps", "build"); recursive=true, force=true)
    rm(joinpath(dirname(@__DIR__), "deps", "products"); recursive=true, force=true)

    return version
end
