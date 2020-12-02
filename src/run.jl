export Configuration

uid() = ccall(:getuid, Cint, ())
gid() = ccall(:getgid, Cint, ())

function prepare_runner()
    cd(joinpath(dirname(@__DIR__), "runner")) do
        for runner in ("ubuntu", "arch")
            cmd = `docker build --tag newpkgeval:$runner --file Dockerfile.$runner .`
            if !isdebug(:docker)
                cmd = pipeline(cmd, stdout=devnull, stderr=devnull)
            end
            Base.run(cmd)
        end
    end

    return
end

"""
    run_sandboxed_julia(install::String, args=``; wait=true, interactive=true,
                        stdin=stdin, stdout=stdout, stderr=stderr,
                        cache=nothing, storage=nothing, kwargs...)

Run Julia inside of a sandbox, passing the given arguments `args` to it. The argument
`install` specifies the directory where Julia can be found.

The argument `wait` determines if the process will be waited on, and defaults to true. If
setting this argument to `false`, remember that the sandbox is using on Docker and killing
the process does not necessarily kill the container. It is advised to use the `name` keyword
argument to set the container name, and use that to kill the Julia process.

The `cache` directory is used to cache temporary files across runs, e.g. compilation caches,
and can be expected to be removed at any point. The `storage` directory can be used for more
lasting files, e.g. artifacts.

The keyword argument `interactive` maps to the Docker option, and defaults to true.
"""
function run_sandboxed_julia(install::String, args=``; wait=true,
                             stdin=stdin, stdout=stdout, stderr=stderr, kwargs...)
    cmd = runner_sandboxed_julia(install, args; kwargs...)
    Base.run(pipeline(cmd, stdin=stdin, stdout=stdout, stderr=stderr); wait=wait)
end

function runner_sandboxed_julia(install::String, args=``; interactive=true, tty=true,
                                name=nothing, cpus::Vector{Int}=Int[], tmpfs::Bool=true,
                                storage=nothing, cache=nothing, sysimage=nothing,
                                xvfb::Bool=true, init::Bool=true,
                                runner="ubuntu", user="pkgeval", group="pkgeval",
                                install_dir="/opt/julia")
    ## Docker args

    cmd = `docker run --rm`

    # expose any available GPUs if they are available
    if find_library("libcuda") != ""
        cmd = `$cmd --gpus all -e NVIDIA_VISIBLE_DEVICES=all -e NVIDIA_DRIVER_CAPABILITIES=all`
    end

    # mount data
    julia_path = installed_julia_dir(install)
    @assert isdir(julia_path)
    cmd = ```$cmd --mount type=bind,source=$julia_path,target=$install_dir,readonly
                  --env JULIA_DEPOT_PATH="::/usr/local/share/julia"
                  --env JULIA_PKG_SERVER
          ```

    if storage !== nothing
        cmd = `$cmd --mount type=bind,source=$storage,target=/storage`
    end

    if cache !== nothing
        cmd = `$cmd --mount type=bind,source=$cache,target=/cache`
    end

    # mount working directory in tmpfs
    if tmpfs
        cmd = `$cmd --tmpfs /home/$user:exec`
    end

    # restrict resource usage
    if !isempty(cpus)
        cmd = `$cmd --cpuset-cpus=$(join(cpus, ','))`
    end

    if interactive
        cmd = `$cmd --interactive`
    end

    if tty
        cmd = `$cmd --tty`
    end

    if name !== nothing
        cmd = `$cmd --name $name`
    end

    if init
        cmd = `$cmd --init`
    end

    cmd = `$cmd newpkgeval:$runner`


    ## Entrypoint script args

    # use the current user and group ID to ensure cache and storage are writable
    container_uid = uid()
    container_gid = gid()
    if container_uid < 1000 || container_gid < 1000
        # system ids might conflict with groups/users in the container
        # TODO: can we use userns-remap?
        @warn """"You are running PkgEval as a system user (with id $uid:$gid); this is not compatible with the container set-up.
                  I will be using id 1000:1000, but that means the cache and storage on the host file system will not be owned by you."""
    end

    cmd = `$cmd $user $container_uid $group $container_gid`


    ## Julia args

    if sysimage !== nothing
        args = `--sysimage=$sysimage $args`
    end

    if xvfb
        `$cmd xvfb-run $install_dir/bin/julia $args`
    else
        `$cmd $install_dir/bin/julia $args`
    end
end

"""
    run_sandboxed_test(install::String, pkg; do_depwarns=false,
                       log_limit=2^20, time_limit=60*60)

Run the unit tests for a single package `pkg` inside of a sandbox using a Julia installation
at `install`. If `do_depwarns` is `true`, deprecation warnings emitted while running the
package's tests will cause the tests to fail. Test will be forcibly interrupted after
`time_limit` seconds (defaults to 1h) or if the log becomes larger than `log_limit`
(defaults to 1MB).

A log for the tests is written to a version-specific directory in the PkgEval root
directory.

Refer to `run_sandboxed_julia`[@ref] for more possible `keyword arguments.
"""
function run_sandboxed_test(install::String, pkg; log_limit = 2^20 #= 1 MB =#,
                            time_limit = 60*60, do_depwarns=false,
                            kwargs...)
    # prepare for launching a container
    container = "$(pkg.name)-$(randstring(8))"
    script = raw"""
        try
            using Dates
            print('#'^80, "\n# PkgEval set-up: $(now())\n#\n\n")

            using InteractiveUtils
            versioninfo()
            println()

            using Pkg
            Pkg.UPDATED_REGISTRY_THIS_SESSION[] = true


            print("\n\n", '#'^80, "\n# Installation: $(now())\n#\n\n")

            Pkg.add(ARGS[1])


            print("\n\n", '#'^80, "\n# Testing: $(now())\n#\n\n")

            Pkg.test(ARGS[1])

            println("\nPkgEval succeeded")
        catch err
            print("\nPkgEval failed: ")
            showerror(stdout, err)
            Base.show_backtrace(stdout, catch_backtrace())
            println()
        finally
            print("\n\n", '#'^80, "\n# PkgEval teardown: $(now())\n#\n\n")

            # give the host some time to pick the above marker up, and kill us
            sleep(60)
        end"""
    cmd = do_depwarns ? `--depwarn=error` : ``
    cmd = `$cmd --eval 'eval(Meta.parse(read(stdin,String)))' $(pkg.name)`

    input = Pipe()
    output = Pipe()

    function stop()
        kill_container(container)
    end

    container_lock = ReentrantLock()

    p = run_sandboxed_julia(install, cmd; name=container, tty=false, wait=false,
                                          stdout=output, stderr=output, stdin=input,
                                          kwargs...)
    close(output.in)

    # pass the script over standard input to avoid exceeding max command line size,
    # and keep the process listing somewhat clean
    println(input, script)
    close(input)

    status = nothing
    reason = missing

    # kill on timeout
    t = Timer(time_limit) do timer
        lock(container_lock) do
            process_running(p) || return
            status = :kill
            reason = :time_limit
            stop()
        end
    end

    # kill on inactivity (fewer than 1 second of CPU usage every minute)
    previous_stats = nothing
    t2 = Timer(60; interval=300) do timer
        lock(container_lock) do
            process_running(p) || return
            try
                current_stats = query_container(container)
                if previous_stats !== nothing && previous_stats["cpu_stats"] !== nothing &&
                   current_stats !== nothing && current_stats["cpu_stats"] !== nothing
                    previous_cpu_stats = previous_stats["cpu_stats"]
                    current_cpu_stats = current_stats["cpu_stats"]
                    usage_diff = (current_cpu_stats["cpu_usage"]["total_usage"] -
                                previous_cpu_stats["cpu_usage"]["total_usage"]) / 1e9
                    if 0 <= usage_diff < 1
                        status = :kill
                        reason = :inactivity
                        stop()
                    end
                end
                previous_stats = current_stats
            catch err
                @error "Failed to check for inactivity" exception=(err, catch_backtrace())
            end
        end
    end

    # collect output and stats
    t3 = @async begin
        io = IOBuffer()
        stats = nothing
        while process_running(p) && isopen(output)
            line = readline(output)
            println(io, line)

            # right before the container ends, gather some statistics
            if occursin("PkgEval teardown", line)
                lock(container_lock) do
                    process_running(p) || return
                    stats = query_container(container)
                    stop()
                end
                break
            end

            # kill on too-large logs
            if io.size > log_limit
                lock(container_lock) do
                    process_running(p) || return
                    status = :kill
                    reason = :log_limit
                    close(output)
                    stop()
                end
                break
            end
        end
        write(io, output) # finish copying remaining output from kernel buffer
        return String(take!(io)), stats
    end

    wait(p)
    close(t)
    close(t2)
    log, stats = fetch(t3)
    @assert !isopen(output) && eof(output)

    # append some simple statistics to the log
    # TODO: serialize the statistics
    if stats !== nothing
        io = IOBuffer()

        try
            cpu_stats = stats["cpu_stats"]
            @printf(io, "CPU usage: %.2fs (%.2fs user, %.2fs kernel)\n",
                    cpu_stats["cpu_usage"]["total_usage"]/1e9,
                    cpu_stats["cpu_usage"]["usage_in_usermode"]/1e9,
                    cpu_stats["cpu_usage"]["usage_in_kernelmode"]/1e9)
            println(io)

            println(io, "Network usage:")
            for (network, network_stats) in stats["networks"]
                println(io, "- $network: $(Base.format_bytes(network_stats["rx_bytes"])) received, $(Base.format_bytes(network_stats["tx_bytes"])) sent")
            end
        catch err
            print(io, "Could not render usage statistics: ")
            Base.showerror(io, err)
            Base.show_backtrace(io, catch_backtrace())
            println(io)
        end

        println(io)
        print(io, "Raw statistics: ")
        JSON.print(io, stats)

        log *= String(take!(io))
    else
        log *= "No statistics gathered."
    end

    # pick up the installed package version from the log
    version_match = match(Regex("Installed $(pkg.name) .+ v(.+)"), log)
    version = if version_match !== nothing
        try
            VersionNumber(version_match.captures[1])
        catch
            @error "Could not parse installed package version number '$(version_match.captures[1])'"
            v"0"
        end
    else
        missing
    end

    # try to figure out the failure reason
    if status == nothing
        if occursin("PkgEval succeeded", log)
            status = :ok
        else
            status = :fail

            # figure out a more accurate failure reason from the log
            reason = if occursin("Unsatisfiable requirements detected for package", log)
                # NOTE: might be the package itself, or one of its dependencies
                :unsatisfiable
            elseif occursin("Package $(pkg.name) did not provide a `test/runtests.jl` file", log)
                :untestable
            elseif occursin("cannot open shared object file: No such file or directory", log)
                :binary_dependency
            elseif occursin(r"Package .+ does not have .+ in its dependencies", log)
                :missing_dependency
            elseif occursin(r"Package .+ not found in current path", log)
                :missing_package
            elseif occursin("Some tests did not pass", log) || occursin("Test Failed", log)
                :test_failures
            elseif occursin("ERROR: LoadError: syntax", log)
                :syntax
            elseif occursin("GC error (probable corruption)", log)
                :gc_corruption
            elseif occursin("signal (11): Segmentation fault", log)
                :segfault
            elseif occursin("signal (6): Abort", log)
                :abort
            elseif occursin("Unreachable reached", log)
                :unreachable
            else
                :unknown
            end
        end
    end

    return version, status, reason, log
end

function query_container(container)
    docker = connect("/var/run/docker.sock")
    write(docker, """GET /containers/$container/stats HTTP/1.1
                        Host: localhost""")
    write(docker, "\r\n\r\n")
    headers = readuntil(docker, "\r\n\r\n")
    occursin("HTTP/1.1 200 OK", headers) || return nothing
    len = parse(Int, readuntil(docker, "\r\n"); base=16)
    len > 0 || return nothing
    body = String(read(docker, len))
    stats = JSON.parse(body)
    close(docker)
    return stats
end

function kill_container(container)
    if !success(pipeline(`docker stop $container`, stdout=devnull))
        @warn "Could not stop container $container"
    end
end

Base.@kwdef struct Configuration
    julia::VersionNumber = Base.VERSION
    # TODO: depwarn, checkbounds, etc
    # TODO: also move buildflags here?
end

# behave as a scalar in broadcast expressions
Base.broadcastable(x::Configuration) = Ref(x)

function run(configs::Vector{Configuration}, pkgs::Vector;
             ninstances::Integer=Sys.CPU_THREADS, retries::Integer=2, kwargs...)
    # here we deal with managing execution: spawning workers, output, result I/O, etc

    prepare_runner()

    # Julia installation and local cache
    instantiated_configs = Dict{Configuration,Tuple{String,String}}()
    for config in configs
        install = prepare_julia(config.julia)
        cache = mktempdir()

        # copy the registry (we can't mount it because permissions might be incompatible)
        # XXX: actually have the target Julia process check-out the registry?
        registry_path = registry_dir()
        @assert isdir(registry_path)
        cp(registry_path, joinpath(cache, "registries"))

        instantiated_configs[config] = (install, cache)
    end

    # global storage
    storage = storage_dir()
    mkpath(storage)

    # ensure we can use Docker's API
    info = let
        docker = connect("/var/run/docker.sock")
        write(docker,
            """GET /info HTTP/1.1
               Host: localhost""")
        write(docker, "\r\n\r\n")
        headers = readuntil(docker, "\r\n\r\n")
        occursin("HTTP/1.1 200 OK", headers) || error("Invalid reply: $headers")
        len = parse(Int, readuntil(docker, "\r\n"); base=16)
        body = String(read(docker, len))
        close(docker)
        JSON.parse(body)
    end

    jobs = vec(collect(Iterators.product(instantiated_configs, pkgs)))

    # use a random test order to (hopefully) get a more reasonable ETA
    shuffle!(jobs)

    njobs = length(jobs)
    ninstances = min(njobs, ninstances)
    running = Vector{Any}(nothing, ninstances)
    times = DateTime[now() for i = 1:ninstances]
    all_workers = Task[]

    done = false
    did_signal_workers = false
    function stop_work()
        if !done
            done = true
            if !did_signal_workers
                for (i, task) in enumerate(all_workers)
                    task == current_task() && continue
                    Base.istaskdone(task) && continue
                    try; schedule(task, InterruptException(); error=true); catch; end
                    running[i] = nothing
                end
                did_signal_workers = true
            end
        end
    end

    start = now()
    io = IOContext(IOBuffer(), :color=>true)
    on_ci = parse(Bool, get(ENV, "CI", "false"))
    p = Progress(njobs; barlen=50, color=:normal)
    function update_output()
        # known statuses
        o = count(==(:ok),      result[!, :status])
        s = count(==(:skip),    result[!, :status])
        f = count(==(:fail),    result[!, :status])
        k = count(==(:kill),    result[!, :status])
        # remaining
        x = njobs - nrow(result)

        function runtimestr(start)
            time = Dates.canonicalize(Dates.CompoundPeriod(now() - start))
            if isempty(time.periods) || first(time.periods) isa Millisecond
                "just started"
            else
                # be coarse in the name of brevity
                string(first(time.periods))
            end
        end

        if on_ci
            println("$x combinations to test ($o succeeded, $f failed, $k killed, $s skipped, $(runtimestr(start)))")
            sleep(10)
        else
            print(io, "Success: ")
            printstyled(io, o; color = :green)
            print(io, "\tFailed: ")
            printstyled(io, f; color = Base.error_color())
            print(io, "\tKilled: ")
            printstyled(io, k; color = Base.error_color())
            print(io, "\tSkipped: ")
            printstyled(io, s; color = Base.warn_color())
            println(io, "\tRemaining: ", x)
            for i = 1:ninstances
                job = running[i]
                str = if job === nothing
                    " #$i: -------"
                else
                    config, pkg = job
                    " #$i: $(pkg.name) @ $(config.julia) ($(runtimestr(times[i])))"
                end
                if i%2 == 1 && i < ninstances
                    print(io, rpad(str, 50))
                else
                    println(io, str)
                end
            end
            print(String(take!(io.io)))
            p.tlast = 0
            update!(p, nrow(result))
            sleep(1)
            CSI = "\e["
            print(io, "$(CSI)$(ceil(Int, ninstances/2)+1)A$(CSI)1G$(CSI)0J")
        end
    end

    result = DataFrame(config = Configuration[],
                       name = String[],
                       uuid = UUID[],
                       version = Union{Missing,VersionNumber}[],
                       status = Symbol[],
                       reason = Union{Missing,Symbol}[],
                       duration = Float64[],
                       log = Union{Missing,String}[])

    # Printer
    @async begin
        try
            while (!isempty(jobs) || !all(==(nothing), running)) && !done
                update_output()
            end
            stop_work()
        catch e
            stop_work()
            isa(e, InterruptException) || rethrow(e)
        end
    end

    # Workers
    try @sync begin
        for i = 1:ninstances
            push!(all_workers, @async begin
                try
                    while !isempty(jobs) && !done
                        (config, (install, cache)), pkg = pop!(jobs)
                        times[i] = now()
                        running[i] = (config, pkg)

                        # can we even test this package?
                        julia_supported = Dict{VersionNumber,Bool}()
                        ctx = Pkg.Types.Context()
                        pkg_version_info = Pkg.Operations.load_versions(ctx, pkg.path)
                        pkg_versions = sort!(collect(keys(pkg_version_info)))
                        pkg_compat =
                            Pkg.Operations.load_package_data(ctx, Pkg.Types.VersionSpec,
                                                             joinpath(pkg.path,
                                                                      "Compat.toml"),
                                                             pkg_versions)
                        for (pkg_version, bounds) in pkg_compat
                            if haskey(bounds, "julia")
                                julia_supported[pkg_version] =
                                    config.julia ∈ bounds["julia"]
                            end
                        end
                        if length(julia_supported) != length(pkg_version_info)
                            # not all versions have a bound for Julia,
                            # so we need to be conservative
                            supported = true
                        else
                            supported = any(values(julia_supported))
                        end
                        if !supported
                            push!(result, [config,
                                           pkg.name, pkg.uuid, missing,
                                           :skip, :unsupported, 0, missing])
                            continue
                        elseif pkg.name in skip_lists[pkg.registry]
                            push!(result, [config,
                                           pkg.name, pkg.uuid, missing,
                                           :skip, :explicit, 0, missing])
                            continue
                        elseif endswith(pkg.name, "_jll")
                            push!(result, [config,
                                           pkg.name, pkg.uuid, missing,
                                           :skip, :jll, 0, missing])
                            continue
                        end

                        # perform an initial run
                        pkg_version, status, reason, log =
                            run_sandboxed_test(install, pkg; cache=cache,
                                               storage=storage, cpus=[i-1], kwargs...)

                        # certain packages are known to have flaky tests; retry them
                        for j in 1:retries
                            if status == :fail && reason == :test_failures &&
                               pkg.name in retry_lists[pkg.registry]
                                times[i] = now()
                                pkg_version, status, reason, log =
                                    run_sandboxed_test(install, pkg; cache=cache,
                                                       storage=storage, cpus=[i-1], kwargs...)
                            end
                        end

                        duration = (now()-times[i]) / Millisecond(1000)
                        push!(result, [config,
                                       pkg.name, pkg.uuid, pkg_version,
                                       status, reason, duration, log])
                        running[i] = nothing
                    end
                catch e
                    stop_work()
                    isa(e, InterruptException) || rethrow(e)
                end
            end)
        end
    end
    catch e
        isa(e, InterruptException) || rethrow(e)
    finally
        stop_work()
        println()

        # clean-up
        for (config, (install,cache)) in instantiated_configs
            rm(install; recursive=true)
            if uid() < 1000 || gid() < 1000
                @warn "Cannot remove cache due to running as system user or group"
            else
                rm(cache; recursive=true)
            end
        end
    end

    return result
end

"""
    run(configs::Vector{Configuration}=[Configuration()],
        pkg_names::Vector{String}=[]]; registry=General, update_registry=true, kwargs...)

Run all tests for all packages in the registry `registry`, or only for the packages as
identified by their name in `pkgnames`, using the configurations from `configs`.
The registry is first updated if `update_registry` is set to true.

Refer to `run_sandboxed_test`[@ref] and `run_sandboxed_julia`[@ref] for more possible
keyword arguments.
"""
function run(configs::Vector{Configuration}=[Configuration()],
             pkg_names::Vector{String}=String[];
             registry::String=DEFAULT_REGISTRY, update_registry::Bool=true, kwargs...)
    prepare_registry(registry; update=update_registry)
    pkgs = read_pkgs(pkg_names)

    run(configs, pkgs; kwargs...)
end

# for backwards compatibility
run(julia_versions::Vector{VersionNumber}, args...; kwargs...) =
    run([Configuration(julia=julia_version) for julia_version in julia_versions], args...;
        kwargs...)
