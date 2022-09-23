using Sandbox: Sandbox, SandboxConfig, UnprivilegedUserNamespacesExecutor, cleanup

"""
    run_sandbox(config::Configuration, setup, args...; wait=true,
                stdin=stdin, stdout=stdout, stderr=stderr, kwargs...)

Run stuff in a sandbox. The actual sandbox command is set-up by calling `setup`, passing
along arguments and keyword arguments that are not processed by this function.
"""
function run_sandbox(config::Configuration, setup, args...; wait=true,
                     stdin=stdin, stdout=stdout, stderr=stderr, kwargs...)
    # XXX: even when preferred_executor() returns UnprivilegedUserNamespacesExecutor,
    #      sometimes a stray sudo happens at run time? no idea how.
    exe_typ = UnprivilegedUserNamespacesExecutor
    exe = exe_typ()

    sandbox_config, cmd = setup(config, args...; kwargs...)
    sandbox_cmd = Sandbox.build_executor_command(exe, sandbox_config, cmd)
    proc = run(pipeline(sandbox_cmd; stdin, stderr, stdout); wait)

    # TODO: introduce a --stats flag that has the sandbox trace and report on CPU, network, ... usage

    if wait
        cleanup(exe)
    else
        @async begin
            try
                Base.wait(proc)
                cleanup(exe)
            catch err
                @error "Unexpected error while cleaning up process" exception=(err, catch_backtrace())
            end
        end
    end

    return proc
end


## generic sandbox

# global Xvfb process for use by all containers
const xvfb_lock = ReentrantLock()
const xvfb_proc = Ref{Union{Base.Process,Nothing}}(nothing)

function setup_generic_sandbox(config::Configuration, cmd::Cmd;
                               env::Dict{String,String}=Dict{String,String}(),
                               mounts::Dict{String,String}=Dict{String,String}())
    # split mounts into read-only and read-write maps
    read_only_maps = Dict{String,String}()
    read_write_maps = Dict{String,String}()
    for (dst, src) in mounts
        if endswith(dst, ":ro")
            read_only_maps[dst[begin:end-3]] = src
        elseif endswith(dst, ":rw")
            read_write_maps[dst[begin:end-3]] = src
        else
            error("Unknown type of mount ('$dst' -> '$src'), please append :ro or :rw")
        end
    end

    rootfs = create_rootfs(config)
    read_only_maps["/"] = rootfs

    env = merge(env, Dict(
        # some essential env vars (since we don't run from a shell)
        "PATH" => "/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin",
        "HOME" => config.home,
    ))
    if haskey(ENV, "TERM")
        env["TERM"] = ENV["TERM"]
    end

    if config.xvfb
        lock(xvfb_lock) do
            if xvfb_proc[] === nothing || !process_running(xvfb_proc[])
                proc = run(`Xvfb :1 -screen 0 1024x768x16`; wait=false)
                sleep(1)
                process_running(proc) || error("Could not start Xvfb")

                xvfb_proc[] === nothing && atexit() do
                    kill(xvfb_proc[])
                    wait(xvfb_proc[])
                end
                xvfb_proc[] = proc
            end
        end

        env["DISPLAY"] = ":1"
        read_write_maps["/tmp/.X11-unix"] = "/tmp/.X11-unix"
    end

    # NOTE: we use persist=true so that modifications to the rootfs are backed by
    #       actual storage on the host, and not just the (1G hard-coded) tmpfs,
    #       because some packages like to generate a lot of data during testing.

    sandbox_config = SandboxConfig(read_only_maps, read_write_maps, env;
                                   config.uid, config.gid, pwd=config.home, persist=true,
                                   verbose=isdebug(:sandbox))
    return sandbox_config, cmd
end

sandboxed_cmd(config::Configuration, args...; kwargs...) =
    run_sandbox(config, setup_generic_sandbox, args...; kwargs...)


## Julia sandbox

function setup_julia_sandbox(config::Configuration, args=``;
                             env::Dict{String,String}=Dict{String,String}(),
                             mounts::Dict{String,String}=Dict{String,String}())
    install = install_julia(config)
    registry = get_registry(config)
    packages = joinpath(storage_dir, "packages")
    artifacts = joinpath(storage_dir, "artifacts")
    mounts = merge(mounts, Dict(
        "$(config.julia_install_dir):ro"                    => install,
        "/usr/local/share/julia/registries/General:ro"      => registry,
        joinpath(config.home, ".julia", "packages")*":rw"   => packages,
        joinpath(config.home, ".julia", "artifacts")*":rw"  => artifacts
    ))

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
        cmd = `/usr/bin/taskset --cpu-list $(join(config.cpus, ',')) $cmd`
        env["JULIA_CPU_THREADS"] = string(length(config.cpus)) # JuliaLang/julia#35787
        env["OPENBLAS_NUM_THREADS"] = string(length(config.cpus)) # defaults to Sys.CPU_THREADS
        env["JULIA_NUM_PRECOMPILE_TASKS"] = string(length(config.cpus)) # defaults to Sys.CPU_THREADS
    end

    setup_generic_sandbox(config, `$cmd $(config.julia_args) $args`; env, mounts)
end

sandboxed_julia(config::Configuration, args...; kwargs...) =
    run_sandbox(config, setup_julia_sandbox, args...; kwargs...)
