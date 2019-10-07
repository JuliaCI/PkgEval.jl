using BinaryBuilder
using GitHub
using Base64

# This is a global github authentication token that is set the first time
# we authenticate and then reused
const _github_auth = Ref{GitHub.Authorization}()
function github_auth()
    if !isassigned(_github_auth) || _github_auth[] isa GitHub.AnonymousAuth
        # If the user is feeding us a GITHUB_AUTH token, use it
        auth = get(ENV, "GITHUB_AUTH", nothing)
        _github_auth[] = (auth === nothing ? GitHub.AnonymousAuth() : GitHub.authenticate(auth))
    end
    return _github_auth[]
end

function get_julia_version(ref::String="master")
    file = GitHub.file("JuliaLang/julia", "VERSION";
                       params = Dict("ref" => ref), auth=github_auth())
    @assert file.encoding == "base64" # GitHub says this will always be the case
    str = String(base64decode(chomp(file.content)))
    return VersionNumber(chomp(str))
end

"""
    version_id = build_julia(ref::String="master"; binarybuilder_args::Vector{String}=String["--verbose"])

Download and build julia at git reference `ref` using BinaryBuilder. Return the `version_id` (what other functions use
to identify this build).
"""
function build_julia(ref::String="master"; binarybuilder_args::Vector{String}=String["--verbose"])
    # This errors if `ref` cannot be found, error message is pretty ok
    version = get_julia_version(ref)

    reference = GitHub.reference("JuliaLang/julia", "heads/$(ref)"; handle_error=false, auth=github_auth())
    if reference.object == nothing
        reference = GitHub.reference("JuliaLang/julia", "tags/$(ref)"; handle_error=false, auth=github_auth())
    end
    if reference.object == nothing
        commit_hash = GitHub.commit("JuliaLang/julia", ref; auth=github_auth()).sha
    else
        commit_hash = reference.object["sha"]
    end

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
    LLVM_ASSERTIONS=1
    LIBSSH2_ENABLE_TESTS=0
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
    products(prefix) = [
        LibraryProduct(prefix, "sys", :sys),
        ExecutableProduct(prefix, "julia", :julia)
    ]

    # Dependencies that must be installed before this package can be built
    dependencies = []

    # Build the tarballs, and possibly a `build.jl` as well.
    product_hashes = cd(joinpath(@__DIR__, "..", "deps")) do
        build_tarballs(binarybuilder_args, "julia", version, sources, script, platforms, products, dependencies)
    end
    tarball, hash = product_hashes["x86_64-linux-gnu"]

    version_stanza = """
    ["$version"]
    file = "$tarball"
    sha = "$hash"
    """
    download_path = joinpath(@__DIR__, "..", "deps", "downloads")
    if isfile(joinpath(download_path, tarball))
        @warn "$tarball already exists in deps/downloads folder. Not copying."
        println("You may manually copy the file from products/ and add the following stanza to Versions.toml:")
        println(version_stanza)
    else
        mkpath(download_path)
        cp(joinpath(@__DIR__, "..", "deps", "products", tarball), joinpath(download_path, tarball))
        open(versions_file(); append=true) do f
            println(f, version_stanza)
        end
    end
    return version
end
