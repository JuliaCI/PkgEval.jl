using BinaryBuilder
using GitHub
using Base64

function get_julia_version(ref::String="master")
    file = GitHub.file("JuliaLang/julia", "VERSION";
                        params = Dict("ref" => ref))
    @assert file.encoding == "base64" # GitHub says this will always be the case
    str = String(base64decode(chomp(file.content)))
    return chomp(str)
end

"""
    build_julia(ref::String="master"; binarybuilder_args::Vector{String}=String["--verbose"])

Downloads and builds julia at `ref` using BinaryBuilder.
"""
function build_julia(ref::String="master"; binarybuilder_args::Vector{String}=String["--verbose"])
    name = "julia"
    sanitized_ref = replace(ref, "/" => ".")
    julia_version = get_julia_version(ref)
    version = VersionNumber("$(julia_version)-$(sanitized_ref)")
    @show version
    commit_hash = GitHub.reference("JuliaLang/julia", "heads/$(ref)").object["sha"]
        
    @show commit_hash
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
    USE_BINARYBUILDER_OPENBLAS=1
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
    product_hashes = build_tarballs(binarybuilder_args, name, version, sources, script, platforms, products, dependencies)
    tarball, hash = product_hashes["x86_64-linux-gnu"]

    version_stanza = """
    ["$version"]
    file = "$tarball"
    sha = "$hash"
    """
    @show tarball
    @show hash
    download_path = joinpath(@__DIR__, "..", "deps", "downloads")
    if isfile(joinpath(download_path, tarball))
        @warn "$tarball already exists in deps/downloads folder. Not copying."
        println("You may manually copy the file from products/ and add the following stanza to Versions.toml:")
        println(version_stanza)
    else
        mkpath(download_path)
        cp(joinpath(@__DIR__, "..", "products", tarball), joinpath(download_path, tarball))
        open(joinpath(@__DIR__, "..", "deps", "Versions.toml"); append=true) do f
            println(f, version_stanza)
        end
    end
end
