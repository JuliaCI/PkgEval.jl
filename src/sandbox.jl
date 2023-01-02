using Sandbox: Sandbox, SandboxConfig, UnprivilegedUserNamespacesExecutor, cleanup

"""
    run_sandbox(config::Configuration, setup, args...; wait=true, executor=nothiong,
                stdin=stdin, stdout=stdout, stderr=stderr, kwargs...)

Run stuff in a sandbox. The actual sandbox command is set-up by calling `setup`, passing
along arguments and keyword arguments that are not processed by this function.
If no `executor` is passed, one will be created and cleaned-up after the sandbox completes.
"""
function run_sandbox(config::Configuration, setup, args...; executor=nothing, wait=true,
                     stdin=stdin, stdout=stdout, stderr=stderr, kwargs...)
    do_cleanup = false
    if executor === nothing
        executor = UnprivilegedUserNamespacesExecutor()
        do_cleanup = true
    end

    sandbox_config, cmd = setup(config, args...; kwargs...)
    sandbox_cmd = Sandbox.build_executor_command(executor, sandbox_config, cmd)
    proc = run(pipeline(sandbox_cmd; stdin, stderr, stdout); wait)

    # TODO: introduce a --stats flag that has the sandbox trace and report on CPU, network, ... usage

    if do_cleanup
        if wait
            cleanup(executor)
        else
            @async begin
                try
                    Base.wait(proc)
                    cleanup(executor)
                catch err
                    @error "Unexpected error while cleaning up process" exception=(err, catch_backtrace())
                end
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
                config = Configuration(; rootfs="xvfb", xvfb=false, uid=0, gid=0)

                # find a free display number and launch a server
                # (UNIX sockets aren't unique across containers)
                for disp in 1:10
                    proc = sandboxed_cmd(config, `/usr/bin/Xvfb :$disp -screen 0 1024x768x16`;
                                         stdin=devnull, stdout=devnull, stderr=devnull,
                                         mounts, wait=false)
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
        read_write_maps["/tmp/.X11-unix"] = xvfb.socket
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

        # disable automatic precompilation on Pkg.add, because the generated images
        # aren't usable for testing anyway (which runs with different options)
        "JULIA_PKG_PRECOMPILE_AUTO" => "0",

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

function sandboxed_julia(config::Configuration, args=``; stdout=stdout, kwargs...)
    run_sandbox(config, setup_julia_sandbox, args; stdout, kwargs...)
end
