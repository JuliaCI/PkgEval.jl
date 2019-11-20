using BinaryBuilder
using LibGit2
using Base64

"""
    version_id = build_julia(ref::String="master"; binarybuilder_args::Vector{String}=String["--verbose"])

Download and build julia at git reference `ref` using BinaryBuilder. Return the `version_id`
(what other functions use to identify this build).
"""
function build_julia(ref::String="master"; binarybuilder_args::Vector{String}=String["--verbose"])
    # get the Julia repo
    repo_path = downloads_dir("julia")
    if !isdir(repo_path)
        @info "Cloning Julia repository..."
        repo = LibGit2.clone("https://github.com/JuliaLang/julia", repo_path)
    else
        repo = LibGit2.GitRepo(repo_path)
        LibGit2.fetch(repo)
    end

    # lookup the version number and commit hash
    reference = LibGit2.GitCommit(repo, ref)
    tree = LibGit2.peel(LibGit2.GitTree, reference)
    version = VersionNumber(chomp(LibGit2.content(tree["VERSION"])))
    commit_hash = string(LibGit2.GitHash(reference))

    if version.prerelease != ()
        contrib_path = joinpath(Sys.BINDIR, "..", "..", "contrib")
        found_buildname = false
        if isdir(contrib_path)
            try
                cd(contrib_path) do
                    version = VersionNumber(read(`./commit-name.sh $commit_hash`, String))
                end
                found_buildname = true
            catch e
                @error "failed to get build number" exception=e
            end
        end
        if !found_buildname
            version = VersionNumber(string(version) * string("-", commit_hash[1:6]))
        end
    end

    # Collection of sources required to build julia
    sources = [
        "https://github.com/JuliaLang/julia.git" => commit_hash,
    ]

    # Bash recipe for building across all platforms
    script = raw"""
    cd $WORKSPACE/srcdir
    mount -t devpts -o newinstance jrunpts /dev/pts
    mount -o bind /dev/pts/ptmx /dev/ptmx

    cd julia
    cat > Make.user <<EOF
    JULIA_CPU_TARGET=generic;sandybridge,-xsaveopt,clone_all;haswell,-rdrnd,base(1)
    EOF
    make -j${nproc}

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
    products = [
        ExecutableProduct("julia", :julia)
    ]

    # Dependencies that must be installed before this package can be built
    dependencies = []

    # Build the tarballs, and possibly a `build.jl` as well.
    product_hashes = cd(joinpath(@__DIR__, "..", "deps")) do
        build_tarballs(binarybuilder_args, "julia", version, sources, script, platforms, products, dependencies, preferred_gcc_version=v"7", skip_audit=true)
    end
    tarball, hash = product_hashes[platforms[1]]

    # Update versions.toml
    version_stanza = """
        ["$version"]
        file = "$tarball"
        sha = "$hash"
    """
    if haskey(read_versions(), version)
        # TODO: overwrite automatically, since the hash will have changed
        @warn "$version already exists in Versions.toml. Not adding."
        println("You may manually add the following stanza to $(versions_file()):")
        println(version_stanza)
    else
        open(versions_file(); append=true) do f
            println(f, version_stanza)
        end
    end

    # Copy the generated tarball to the downloads folder
    download_path = joinpath(@__DIR__, "..", "deps", "downloads")
    if isfile(joinpath(download_path, tarball))
        @warn "$tarball already exists in deps/downloads folder. Not copying."
        println("You may manually copy the file from products/.")
    else
        mkpath(download_path)
        cp(joinpath(@__DIR__, "..", "deps", "products", tarball), joinpath(download_path, tarball))
    end

    return version
end
