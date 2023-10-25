module PkgEval

using Pkg, LazyArtifacts, Random
import Pkg.TOML
import GitHub
using Base: UUID

import Scratch: @get_scratch!
download_dir = ""
storage_dir = ""
const storage_lock = ReentrantLock()

using rsync_jll
using s5cmd_jll
using crun_jll

skip_list = String[]
skip_rr_list = String[]
important_list = String[]
slow_list = String[]

# due to containers/crun#1092, we really need to use unique container names,
# and not reuse, e.g., when running in a testset
const rng = MersenneTwister()

include("types.jl")
include("registry.jl")
include("rootfs.jl")
include("buildkite.jl")
include("julia.jl")
include("sandbox.jl")
include("evaluate.jl")
include("utils.jl")

function __init__()
    global download_dir = @get_scratch!("downloads")
    mkpath(joinpath(download_dir, "srccache"))
    mkpath(joinpath(download_dir, "rootfs"))

    global storage_dir = @get_scratch!("storage")
    mkpath(joinpath(storage_dir, "artifacts"))
    mkpath(joinpath(storage_dir, "packages"))

    # read Packages.toml
    packages = TOML.parsefile(joinpath(dirname(@__DIR__), "Packages.toml"))
    global skip_list = get(packages, "skip", String[])
    global skip_rr_list = get(packages, "skip_rr", String[])
    global important_list = get(packages, "important", String[])
    global slow_list = get(packages, "slow", String[])

    global container_root = mktempdir(prefix="pkgeval_containers_")

    # we only support unified cgroupv2
    if isdir("/sys/fs/cgroup/unified")
        @error "Unsupported hybdir cgroup v1/v2 setup detected; resource limits will not be enforced"
    elseif isdir("/sys/fs/cgroup")
        minfo = mount_info("/sys/fs/cgroup")
        if minfo === nothing
            @error "Failed to determine cgroup filesystem type; resource limits will not be enforced"
        elseif minfo.type != "cgroup2"
            @error "Unsupported cgroup type, only unified cgroupv2 is supported; resource limits will not be enforced"
        else
            controllers = get_cgroup_controllers()
            "cpuset" in controllers ||
                @error "No access to cpuset cgroup controller; CPU resource limits will not be enforced"
            "memory" in controllers ||
                @error "No access to memory cgroup controller; memory resource limits will not be enforced"
            "pids" in controllers ||
                @error "No access to pids cgroup controller; process limits will not be enforced"
        end
    else
        @error "No cgroup set-up detected; resource limits will not be enforced"
    end

    Random.seed!(rng)
end

end # module
