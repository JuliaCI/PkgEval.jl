module PkgEval

using Pkg
import Pkg.TOML

import Scratch: @get_scratch!
download_dir = ""
storage_dir = ""

skip_list = String[]
retry_list = String[]

# utils
isdebug(group) =
    Base.CoreLogging.current_logger_for_env(Base.CoreLogging.Debug, group, PkgEval) !== nothing

include("types.jl")
include("registry.jl")
include("julia.jl")
include("evaluate.jl")
include("report.jl")

function __init__()
    global download_dir = @get_scratch!("downloads")
    mkpath(joinpath(download_dir, "srccache"))

    global storage_dir = @get_scratch!("storage")

    # read Packages.toml
    packages = TOML.parsefile(joinpath(dirname(@__DIR__), "Packages.toml"))
    global skip_list = get(packages, "skip", String[])
    global retry_list = get(packages, "retry", String[])
end

end # module
