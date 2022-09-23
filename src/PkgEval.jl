module PkgEval

using Pkg, LazyArtifacts
import Pkg.TOML

import Scratch: @get_scratch!
download_dir = ""
storage_dir = ""

using s5cmd_jll: s5cmd

skip_list = String[]

include("types.jl")
include("registry.jl")
include("rootfs.jl")
include("julia.jl")
include("sandbox.jl")
include("evaluate.jl")
include("utils.jl")

function __init__()
    global download_dir = @get_scratch!("downloads")
    mkpath(joinpath(download_dir, "srccache"))

    global storage_dir = @get_scratch!("storage")
    mkpath(joinpath(storage_dir, "artifacts"))
    mkpath(joinpath(storage_dir, "packages"))

    # read Packages.toml
    packages = TOML.parsefile(joinpath(dirname(@__DIR__), "Packages.toml"))
    global skip_list = get(packages, "skip", String[])
end

end # module
