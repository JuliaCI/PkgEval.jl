abstract type AbstractMount end
Base.@kwdef struct OverlayMount <: AbstractMount
    lower::String
    upper::String
    work::String
end
Base.@kwdef struct BindMount <: AbstractMount
    source::String
    writable::Bool
end

Base.@kwdef struct Sandbox
    name::String
    rootfs::String
    runtime::Symbol=:crun
    env::Dict{String,String}=Dict{String,String}()
    mounts::Array{Pair{String,AbstractMount}}=Pair{String,AbstractMount}[]
    cpus::Vector{Int}=String[]
    memory::Int=0
    pids::Int=0
    cwd::String="/root"
    uid::Int=0
    gid::Int=0
end

function build_oci_config(sandbox::Sandbox, cmd::Cmd; terminal::Bool)
    config = Dict()
    config["ociVersion"] = v"1.0.1"
    config["platform"] = (os="linux", arch="amd64")

    config["root"] = (; path=sandbox.rootfs, readonly=true)

    mounts = []
    for (destination, mount) in sandbox.mounts
        if mount isa BindMount
            # preserve mount options that restrict allowed operations, as not all container
            # runtimes do this for us (opencontainers/runc#1603, opencontainers/runc#1523).
            mount_options = filter(mount_info(mount.source).opts) do option
                option in ["nodev", "nosuid", "noexec"]
            end
            push!(mounts, (; destination, mount.source, type="none",
                             options=["bind", mount.writable ? "rw" : "ro", mount_options...]))
        elseif mount isa OverlayMount
            extra_options = [
                # needed for unprivileged use
                "userxattr",
                # needed for off-line access to the lower dir
                "xino=off",
                "metacopy=off",
                "index=off"
            ]
            if !haskey(ENV, "GITHUB_ACTIONS")
                # XXX: for some reason, this option results in mount failure (EINVAL) when
                #      running on GitHub Actions, and we lack permission to check dmesg...
                push!(extra_options, "redirect_dir=off")
            end
            push!(mounts, (; destination, type="overlay",
                             options=["lowerdir=$(mount.lower)",
                                      "upperdir=$(mount.upper)",
                                      "workdir=$(mount.work)",
                                      extra_options...]))
        else
            error("Unknown mount type: $(typeof(mount))")
        end
    end
    ## Linux stuff
    push!(mounts, (destination="/proc", type="proc", source="proc"))
    push!(mounts, (destination="/dev", type="tmpfs", source="tmpfs",
                   options=["nosuid", "strictatime", "mode=755", "size=65536k"]))
    push!(mounts, (destination="/dev/pts", type="devpts", source="devpts",
                   options=["nosuid", "noexec", "newinstance",
                            "ptmxmode=0666", "mode=0620"]))
    push!(mounts, (destination="/dev/shm", type="tmpfs", source="shm",
                   options=["nosuid", "noexec", "nodev", "mode=1777", "size=65536k"]))
    push!(mounts, (destination="/dev/mqueue", type="mqueue", source="mqueue",
                   options=["nosuid", "noexec", "nodev"]))
    if sandbox.runtime === :runc
        # XXX: runc cannot mount sysfs in rootless mode (opencontainers/runc#3672)
        push!(mounts, (destination="/sys", type="none", source="/sys",
                       options=["rbind", "nosuid", "noexec", "nodev", "ro"]))
    else
        push!(mounts, (destination="/sys", type="sysfs", source="sysfs",
                       options=["nosuid", "noexec", "nodev"]))
    end
    push!(mounts, (destination="/sys/fs/cgroup", type="cgroup", source="cgroup",
                   options=["nosuid", "noexec", "nodev", "relatime", "ro"]))
    config["mounts"] = mounts

    process = Dict()
    process["terminal"] = terminal
    cmd′ = setenv(cmd, sandbox.env)
    if cmd.env !== nothing
        cmd′ = addenv(cmd, cmd.env; inherit=false)
    end
    process["env"] = cmd′.env
    process["args"] = cmd′.exec
    process["cwd"] = isempty(cmd.dir) ? sandbox.cwd : cmd.dir
    process["user"] = if sandbox.runtime == :runc
        @warn "runc does not support non-root users in rootless sandboxes" maxlog=1
        # XXX: this also breaks building Julia, as tar-as-root tries to chown files.
        #      workaround: TAR_OPTIONS="--no-same-owner --no-same-permissions"
        (; uid=0, gid=0)
    else
        (; sandbox.uid, sandbox.gid)
    end
    ## POSIX stuff
    process["rlimits"] = [
        (type="RLIMIT_NOFILE", hard=1024, soft=1024),
    ]
    ## Linux stuff
    process["capabilities"] = (
        bounding = ["CAP_AUDIT_WRITE", "CAP_KILL", "CAP_NET_BIND_SERVICE"],
        permitted = ["CAP_AUDIT_WRITE", "CAP_KILL", "CAP_NET_BIND_SERVICE"],
        inheritable = ["CAP_AUDIT_WRITE", "CAP_KILL", "CAP_NET_BIND_SERVICE"],
        effective = ["CAP_AUDIT_WRITE", "CAP_KILL"],
        ambient = ["CAP_NET_BIND_SERVICE"],
    )
    process["noNewPrivileges"] = true
    config["process"] = process

    config["hostname"] = sandbox.name

    # Linux platform configuration
    # https://github.com/opencontainers/runtime-spec/blob/main/config-linux.md
    linux = Dict()
    linux["resources"] = Dict()
    linux["resources"]["devices"] = [
        (allow=false, access="rwm")
    ]
    if !isempty(sandbox.cpus)
        linux["resources"]["cpu"] = (; cpus=join(sandbox.cpus, ","))
    end
    if sandbox.memory != 0
        # the swap limit is memory+swap, so we disable swap by setting both identically
        linux["resources"]["memory"] = (; limit=sandbox.memory, swap=sandbox.memory)
    end
    if sandbox.pids != 0
        linux["resources"]["pids"] = (; limit=sandbox.pids)
    end
    linux["namespaces"] = [
        (type="pid",),
        (type="ipc",),
        (type="uts",),
        (type="mount",),
        (type="user",),
        (type="cgroup",),
    ]
    linux["uidMappings"] = [
        (hostID=getuid(), containerID=sandbox.uid, size=1),
    ]
    linux["gidMappings"] = [
        (hostID=getgid(), containerID=sandbox.gid, size=1),
    ]
    config["linux"] = linux

    return config
end

"""
    run_sandbox(config::Configuration, setup, args...; wait=true, workdir=nothing,
                stdin=stdin, stdout=stdout, stderr=stderr, kwargs...)

Run stuff in a sandbox. The actual sandbox command is set-up by calling `setup`, passing
along arguments and keyword arguments that are not processed by this function.
If no `workdir` is passed, one will be created and cleaned-up after the sandbox completes.
"""
function run_sandbox(config::Configuration, setup, args...; workdir=nothing, wait=true,
                     stdin=stdin, stdout=stdout, stderr=stderr, kwargs...)
    do_cleanup = false
    if workdir === nothing
        workdir = mktempdir(prefix="pkgeval_sandbox_")
        do_cleanup = true
    end

    sandbox, cmd = setup(config, args...; workdir, kwargs...)
    sandbox_config = build_oci_config(sandbox, cmd; terminal=isa(stdin, Base.TTY))

    bundle_path = joinpath(workdir, "bundle")
    mkdir(bundle_path)
    config_path = joinpath(bundle_path, "config.json")
    open(config_path, "w") do io
        JSON3.write(io, sandbox_config)
    end

    sandbox_cmd = if sandbox.runtime === :crun
        `$(crun()) --systemd-cgroup run`
    elseif sandbox.runtime === :runc
        # runc always wants to create its own cgroups, so requires delegation:
        # $ systemd-run --user --scope -p Delegate=yes julia ...
        `$(runc()) run`
    else
        error("Unknown runtime: $(sandbox.runtime)")
    end
    proc = run(pipeline(`$sandbox_cmd --bundle $bundle_path $(sandbox.name)`;
                        stdin, stderr, stdout); wait)

    # XXX: once `crun` support `stats` like `runc`, use that for resource usage reporting
    #      and inactivity detection

    if do_cleanup
        function cleanup()
            try
                if VERSION < v"1.9-"    # JuliaLang/julia#47650
                    chmod_recursive(workdir, 0o777)
                end
                rm(workdir; recursive=true)
            catch err
                @error "Unexpected error while cleaning up process" exception=(err, catch_backtrace())
            end
        end

        if wait
            cleanup()
        else
            @async begin
                Base.wait(proc)
                cleanup()
            end
        end
    end

    return proc
end


## X server

# global Xvfb process for use by all containers
const xvfb_lock = ReentrantLock()
const xvfb_proc = Ref{Base.Process}()
const xvfb_sock = Ref{String}()
const xvfb_disp = Ref{Int}()

function setup_xvfb()
    if !isassigned(xvfb_proc) || !process_running(xvfb_proc[])
        lock(xvfb_lock) do
            # temporary directory to put the Xvfb socket in
            if !isassigned(xvfb_sock)
                xvfb_sock[] = mktempdir(prefix="pkgeval_xvfb_")
            end

            # launch an Xvfb container
            if !isassigned(xvfb_proc) || !process_running(xvfb_proc[])
                mounts = Dict(
                    "/tmp/.X11-unix:rw" => xvfb_sock[],
                )
                config = Configuration(; rootfs="xvfb", xvfb=false,
                                         uid=0, gid=0, home="/root")

                # find a free display number and launch a server
                # (UNIX sockets aren't unique across containers)
                for disp in 1:10
                    proc = sandboxed_cmd(config, `/usr/bin/Xvfb :$disp -screen 0 1024x768x16`;
                                         stdin=devnull, stdout=devnull, stderr=devnull,
                                         mounts, wait=false, name="xvfb")
                    sleep(1)
                    if process_running(proc)
                        atexit() do
                            recursive_kill(proc, Base.SIGTERM)
                        end
                        xvfb_proc[] = proc
                        xvfb_disp[] = disp
                        break
                    end
                end

                if !isassigned(xvfb_proc)
                    error("Failed to start Xvfb")
                end
            end
        end
    end

    return (; socket=xvfb_sock[], display=xvfb_disp[])
end


## generic sandbox

abs2rel(path) = path[1] == '/' ? path[2:end] : path

function setup_generic_sandbox(config::Configuration, cmd::Cmd; workdir::String,
                               env::Dict{String,String}=Dict{String,String}(),
                               mounts::Dict{String,String}=Dict{String,String}(),
                               name::String=randstring(32))
    rootfs = create_rootfs(config)

    # make sure certain common directories are writable
    # XXX: Sandbox.jl simply overlays the entire rootfs, which crun/runc doesn't support.
    #      it may also be unwanted for packages to be able to write to the rootfs.
    mounts = [
        "/tmp"      => joinpath(rootfs, "tmp"),
        "/var/tmp"  => joinpath(rootfs, "var/tmp"),
        config.home => joinpath(rootfs, abs2rel(config.home)),
        mounts...]

    sandbox_mounts = Pair{String,AbstractMount}[]
    for (destination, source) in mounts
        # if explicitly :ro or :rw, just bind mount
        if endswith(destination, ":ro")
            push!(sandbox_mounts, destination[begin:end-3] => BindMount(; source, writable=false))
        elseif endswith(destination, ":rw")
            push!(sandbox_mounts, destination[begin:end-3] => BindMount(; source, writable=true))
        # in other cases, use overlays so that we can write without changing the host
        else
            lower = source
            upper = joinpath(workdir, "upper", abs2rel(destination))
            work = joinpath(workdir, "work", abs2rel(destination))
            mkpath(upper)
            mkpath(work)
            push!(sandbox_mounts, destination => OverlayMount(; lower, upper, work))
        end
    end

    env = merge(env, Dict(
        # some essential env vars (since we don't run from a shell)
        "PATH" => "/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin",
        "HOME" => config.home,
    ))
    if haskey(ENV, "TERM")
        env["TERM"] = ENV["TERM"]
    end

    for flag in config.env
        key, value = split(flag, '='; limit=2)
        if (value[begin] == value[end] == '"') || (value[begin] == value[end] == '\'')
            value = value[2:end-1]
        end
        env[key] = value
    end

    if config.xvfb
        xvfb = setup_xvfb()
        env["DISPLAY"] = ":$(xvfb.display)"
        push!(sandbox_mounts, "/tmp/.X11-unix" => BindMount(xvfb.socket, true))
    end

    sandbox_config = Sandbox(; name, rootfs,
                             env, mounts=sandbox_mounts,
                             config.uid, config.gid, cwd=config.home,
                             config.cpus, memory=config.memory_limit,
                             pids=config.process_limit)

    return sandbox_config, cmd
end

sandboxed_cmd(config::Configuration, args...; kwargs...) =
    run_sandbox(config, setup_generic_sandbox, args...; kwargs...)


## Julia sandbox

function setup_julia_sandbox(config::Configuration, args=``;
                             env::Dict{String,String}=Dict{String,String}(),
                             mounts::Dict{String,String}=Dict{String,String}(), kwargs...)
    install = install_julia(config)
    registry = get_registry(config)
    mounts = merge(mounts, Dict(
        "$(config.julia_install_dir):ro"                    => install,
        "/usr/local/share/julia/registries/General:ro"      => registry,
    ))
    # NOTE: we only mount immutable data here that cannot be broken by the sandbox.

    env = merge(env, Dict(
        # PkgEval detection
        "CI" => "true",
        "PKGEVAL" => "true",
        "JULIA_PKGEVAL" => "true",

        # use the provided registry
        # NOTE: putting a registry in a non-primary depot entry makes Pkg use it as-is,
        #       without needing to set Pkg.UPDATED_REGISTRY_THIS_SESSION.
        "JULIA_DEPOT_PATH" => "::/usr/local/share/julia",
    ))

    cmd = `$(config.julia_install_dir)/bin/$(config.julia_binary)`

    # restrict resource usage
    if !isempty(config.cpus)
        env["JULIA_CPU_THREADS"] = string(length(config.cpus)) # JuliaLang/julia#35787
        env["OPENBLAS_NUM_THREADS"] = string(length(config.cpus)) # defaults to Sys.CPU_THREADS
        env["JULIA_NUM_PRECOMPILE_TASKS"] = string(length(config.cpus)) # defaults to Sys.CPU_THREADS
    end

    setup_generic_sandbox(config, `$cmd $(config.julia_args) $args`;
                          env, mounts, kwargs...)
end

function sandboxed_julia(config::Configuration, args=``; stdout=stdout, kwargs...)
    run_sandbox(config, setup_julia_sandbox, args; stdout, kwargs...)
end


## dependencies

# TODO: replace with JLLs

function crun()
    version = v"1.7.2"
    filename = if Sys.islinux() && Sys.ARCH == :x86_64
        "crun-$(version)-linux-amd64"
    elseif Sys.islinux() && Sys.ARCH == :aarch64
        "crun-$(version)-linux-arm64"
    else
        error("Unsupported platform")
    end
    path = joinpath(download_dir, filename)
    if !isfile(path)
        Downloads.download("https://github.com/containers/crun/releases/download/$version/$filename", path)
        chmod(path, 0o755)
    end
    `$(path)`
end

function runc()
    version = v"1.1.4"
    filename = if Sys.islinux() && Sys.ARCH == :x86_64
        "runc.amd64"
    elseif Sys.islinux() && Sys.ARCH == :aarch64
        "runc.arm64"
    else
        error("Unsupported platform")
    end
    path = joinpath(download_dir, filename)
    if !isfile(path)
        Downloads.download("https://github.com/opencontainers/runc/releases/download/v$version/$filename", path)
        chmod(path, 0o755)
    end
    `$(path)`
end
