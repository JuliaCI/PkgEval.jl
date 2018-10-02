# Note that this script can accept some limited command-line arguments, run
# `julia build_tarballs.jl --help` to see a usage message.
using BinaryBuilder

name = "julia"
version = v"1.1.0"

# Collection of sources required to build julia
sources = [
    "https://github.com/JuliaLang/julia.git" =>
    "a43bf9569342c1ecfffe854792b5a5d31c2b0b56",
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
EOF
make -j${nproc}
make install
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
build_tarballs(ARGS, name, version, sources, script, platforms, products, dependencies)
