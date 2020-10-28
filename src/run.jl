function prepare_runner()
    cd(joinpath(dirname(@__DIR__), "runner")) do
        cmd = `docker build --tag newpkgeval .`
        if !isdebug(:docker)
            cmd = pipeline(cmd, stdout=devnull, stderr=devnull)
        end
        Base.run(cmd)
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

function runner_sandboxed_julia(install::String, args=``; interactive=true, tty=true, name=nothing,
                               cpus::Integer=2, tmpfs::Bool=true, cache=nothing, storage=nothing)
    cmd = `docker run`

    # expose any available GPUs if they are available
    if find_library("libcuda") != ""
        cmd = `$cmd --gpus all -e NVIDIA_VISIBLE_DEVICES=all -e NVIDIA_DRIVER_CAPABILITIES=all`
    end

    # mount data
    julia_path = installed_julia_dir(install)
    @assert isdir(julia_path)
    registry_path = registry_dir()
    @assert isdir(registry_path)
    cmd = ```$cmd --mount type=bind,source=$julia_path,target=/opt/julia,readonly
                  --mount type=bind,source=$registry_path,target=/usr/local/share/julia/registries,readonly
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
        cmd = `$cmd --tmpfs /home/pkgeval:exec,uid=1000,gid=1000`
        # FIXME: tmpfs mounts don't copy uid/gid back, so we need to correct this manually
        #        https://github.com/opencontainers/runc/issues/1647
        # FIXME: this also breaks mounting artifacts in .julia directly
    end

    # restrict resource usage
    cmd = `$cmd --cpus=$cpus --env JULIA_NUM_THREADS=$cpus`

    # allow limitless precompilation files
    cmd = `$cmd --env JULIA_MAX_NUM_PRECOMPILE_FILES=$(typemax(Int))`

    if interactive
        cmd = `$cmd --interactive`
    end

    if tty
        cmd = `$cmd --tty`
    end

    if name !== nothing
        cmd = `$cmd --name $name`
    end

    `$cmd --rm newpkgeval xvfb-run /opt/julia/bin/julia $args`
end

"""
    run_sandboxed_test(install::String, pkg; do_depwarns=false,
                       log_limit=2^20, time_limit=60*60)

Run the unit tests for a single package `pkg` inside of a sandbox using a Julia installation
at `install`. If `do_depwarns` is `true`, deprecation warnings emitted while running the
package's tests will cause the tests to fail. Test will be forcibly interrupted after
`time_limit` seconds (defaults to 1h) or if the log becomes larger than `log_limit`
(defaults to 1MB).

A log for the tests is written to a version-specific directory in the NewPkgEval root
directory.

Refer to `run_sandboxed_julia`[@ref] for more possible `keyword arguments.
"""
function run_sandboxed_test(install::String, pkg; log_limit = 2^20 #= 1 MB =#,
                            time_limit = 60*60, do_depwarns=false, kwargs...)
    # prepare for launching a container
    container = "$(pkg.name)-$(randstring(8))"
    script = raw"""
        try
            using Dates
            print('#'^80, "\n# PkgEval set-up: $(now())\n#\n\n")

            using InteractiveUtils
            versioninfo()
            println()

            mkpath(".julia")

            # global storage of downloaded artifacts
            mkpath("/storage/artifacts")
            symlink("/storage/artifacts", ".julia/artifacts")

            # local storage of compiled packages
            # FIXME: disabled, as this significantly regresses total PkgEval run time
            if false && isdefined(Base, :MAX_NUM_PRECOMPILE_FILES) &&
            Base.MAX_NUM_PRECOMPILE_FILES isa Ref &&
            Base.MAX_NUM_PRECOMPILE_FILES[] > 10
                mkpath("/cache/compiled")
                symlink("/cache/compiled", ".julia/compiled")
            end

            using Pkg
            Pkg.UPDATED_REGISTRY_THIS_SESSION[] = true

            ENV["CI"] = true
            ENV["PKGEVAL"] = true
            ENV["JULIA_PKGEVAL"] = true

            ENV["PYTHON"] = ""
            ENV["R_HOME"] = "*"


            print("\n\n", '#'^80, "\n# Installation: $(now())\n#\n\n")

            Pkg.add(ARGS...)


            print("\n\n", '#'^80, "\n# Testing: $(now())\n#\n\n\n")

            Pkg.test(ARGS...)
        finally
            print("\n\n", '#'^80, "\n# PkgEval teardown: $(now())\n#\n\n")
        end"""
    cmd = do_depwarns ? `--depwarn=error` : ``
    cmd = `$cmd --eval 'eval(Meta.parse(read(stdin,String)))' $(pkg.name)`

    input = Pipe()
    output = Pipe()

    p = run_sandboxed_julia(install, cmd; stdout=output, stderr=output, stdin=input,
                            tty=false, wait=false, name=container, kwargs...)

    # pass the script over standard input to avoid exceeding max command line size,
    # and keep the process listing somewhat clean
    println(input, script)
    close(input.in)

    # kill on timeout
    t = Timer(time_limit) do timer
        process_running(p) || return
        status = :kill
        reason = :time_limit
        kill_container(p, container)
    end

    # collect output and stats
    t2 = @async begin
        io = IOBuffer()
        stats = nothing
        while process_running(p)
            line = readline(output)
            println(io, line)

            # right before the container ends, gather some statistics
            if occursin("PkgEval teardown", line)
                docker = connect("/var/run/docker.sock")
                write(docker, """GET /containers/$container/stats HTTP/1.1
                                 Host: localhost""")
                write(docker, "\r\n\r\n")
                headers = readuntil(docker, "\r\n\r\n")
                if occursin("HTTP/1.1 200 OK", headers)
                    len = parse(Int, readuntil(docker, "\r\n"); base=16)
                    if len > 0
                        stats = String(read(docker, len))
                    end
                end
                close(docker)

                close(input.in)
            end

            # kill on too-large logs
            if io.size > log_limit
                kill_container(p, container)
                status = :kill
                reason = :log_limit
                break
            end
        end
        return String(take!(io)), stats
    end

    succeeded = success(p)
    close(output)
    close(t)
    log, stats = fetch(t2)

    # append some simple statistics to the log
    # TODO: serialize the statistics
    if stats !== nothing
        json = JSON.parse(stats)
        io = IOBuffer()

        try
            cpu_stats = json["cpu_stats"]
            @printf(io, "CPU usage: %.2fs (%.2fs user, %.2fs kernel)\n",
                    cpu_stats["cpu_usage"]["total_usage"]/1e9,
                    cpu_stats["cpu_usage"]["usage_in_usermode"]/1e9,
                    cpu_stats["cpu_usage"]["usage_in_kernelmode"]/1e9)
            println(io)

            println(io, "Network usage:")
            for (network, network_stats) in json["networks"]
                println(io, "- $network: $(Base.format_bytes(network_stats["rx_bytes"])) received, $(Base.format_bytes(network_stats["tx_bytes"])) sent")
            end
        catch err
            print(io, "Could not render usage statistics: ")
            Base.showerror(io, err)
            Base.show_backtrace(io, catch_backtrace())
            println(io)
        end

        println(io)
        println(io, "Raw statistics: $stats")

        log *= String(take!(io))
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
    if succeeded
        status = :ok
        reason = missing
    else
        status = :fail

        # figure out a more accurate failure reason from the log
        reason = if occursin("ERROR: Unsatisfiable requirements detected for package", log)
            # NOTE: might be the package itself, or one of its dependencies
            :unsatisfiable
        elseif occursin("ERROR: Package $(pkg.name) did not provide a `test/runtests.jl` file", log)
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

    return version, status, reason, log
end

function kill_container(p, container)
    cmd = `docker stop $container`
    if !isdebug(:docker)
        cmd = pipeline(cmd, stdout=devnull, stderr=devnull)
    end
    Base.run(cmd)
end

function run(julia_versions::Vector{VersionNumber}, pkgs::Vector;
             ninstances::Integer=Sys.CPU_THREADS, retries::Integer=2, kwargs...)
    # here we deal with managing execution: spawning workers, output, result I/O, etc

    prepare_runner()

    # Julia installation and local cache
    julia_environments = Dict{VersionNumber,Tuple{String,String}}()
    for julia in julia_versions
        install = prepare_julia(julia)
        cache = mktempdir()
        julia_environments[julia] = (install, cache)
    end

    # global storage
    storage = storage_dir()
    mkpath(storage)

    # make sure data is writable
    for (julia, (install,cache)) in julia_environments
        Base.run(```docker run --mount type=bind,source=$storage,target=/storage
                               --mount type=bind,source=$cache,target=/cache
                               newpkgeval
                               sudo chown -R pkgeval:pkgeval /storage /cache```)
    end

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

    jobs = [(julia=julia, install=install, cache=cache,
             pkg=pkg) for (julia,(install,cache)) in julia_environments
                      for pkg in pkgs]

    # use a random test order to (hopefully) get a more reasonable ETA
    shuffle!(jobs)

    njobs = length(jobs)
    ninstances = min(njobs, ninstances)
    running = Vector{Union{Nothing, eltype(jobs)}}(nothing, ninstances)
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
                    " #$i: $(job.pkg.name) @ $(job.julia) ($(runtimestr(times[i])))"
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

    result = DataFrame(julia = VersionNumber[],
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
                        job = pop!(jobs)
                        times[i] = now()
                        running[i] = job

                        # can we even test this package?
                        julia_supported = Dict{VersionNumber,Bool}()
                        if VERSION >= v"1.5"
                            ctx = Pkg.Types.Context()
                            pkg_version_info = Pkg.Operations.load_versions(ctx, job.pkg.path)
                            pkg_versions = sort!(collect(keys(pkg_version_info)))
                            pkg_compat =
                                Pkg.Operations.load_package_data(Pkg.Types.VersionSpec,
                                                                 joinpath(job.pkg.path,
                                                                          "Compat.toml"),
                                                                 pkg_versions)
                            for (pkg_version, bounds) in pkg_compat
                                if haskey(bounds, "julia")
                                    julia_supported[pkg_version] =
                                        job.julia ∈ bounds["julia"]
                                end
                            end
                        else
                            pkg_version_info = Pkg.Operations.load_versions(job.pkg.path)
                            pkg_compat =
                                Pkg.Operations.load_package_data_raw(Pkg.Types.VersionSpec,
                                                                     joinpath(job.pkg.path,
                                                                              "Compat.toml"))
                            for (version_range, bounds) in pkg_compat
                                if haskey(bounds, "julia")
                                    for pkg_version in keys(pkg_version_info)
                                        if pkg_version in version_range
                                            julia_supported[pkg_version] =
                                                job.julia ∈ bounds["julia"]
                                        end
                                    end
                                end
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
                            push!(result, [job.julia, job.pkg.name, job.pkg.uuid, missing,
                                           :skip, :unsupported, 0, missing])
                            continue
                        elseif job.pkg.name in skip_lists[job.pkg.registry]
                            push!(result, [job.julia, job.pkg.name, job.pkg.uuid, missing,
                                           :skip, :explicit, 0, missing])
                            continue
                        elseif endswith(job.pkg.name, "_jll")
                            push!(result, [job.julia, job.pkg.name, job.pkg.uuid, missing,
                                           :skip, :jll, 0, missing])
                            continue
                        end

                        # perform an initial run
                        pkg_version, status, reason, log =
                            run_sandboxed_test(job.install, job.pkg; cache=job.cache,
                                               storage=storage, kwargs...)

                        # certain packages are known to have flaky tests; retry them
                        for j in 1:retries
                            if status == :fail && reason == :test_failures &&
                               job.pkg.name in retry_lists[job.pkg.registry]
                                times[i] = now()
                                pkg_version, status, reason, log =
                                    run_sandboxed_test(job.install, job.pkg; cache=job.cache,
                                                       storage=storage, kwargs...)
                            end
                        end

                        duration = (now()-times[i]) / Millisecond(1000)
                        push!(result, [job.julia, job.pkg.name, job.pkg.uuid, pkg_version,
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
        for (julia, (install,cache)) in julia_environments
            rm(install; recursive=true)
            uid = ccall(:getuid, Cint, ())
            gid = ccall(:getgid, Cint, ())
            Base.run(```docker run --mount type=bind,source=$cache,target=/cache
                                   newpkgeval
                                   sudo chown -R $uid:$gid /cache```)
            rm(cache; recursive=true)
        end
    end

    return result
end

"""
    run(julia_versions::Vector{VersionNumber}=[Base.VERSION],
        pkg_names::Vector{String}=[]]; registry=General, update_registry=true, kwargs...)

Run all tests for all packages in the registry `registry`, or only for the packages as
identified by their name in `pkgnames`, using Julia versions `julia_versions`.
The registry is first updated if `update_registry` is set to true.

Refer to `run_sandboxed_test`[@ref] and `run_sandboxed_julia`[@ref] for more possible
keyword arguments.
"""
function run(julia_versions::Vector{VersionNumber}=[Base.VERSION],
             pkg_names::Vector{String}=String[];
             registry::String=DEFAULT_REGISTRY, update_registry::Bool=true, kwargs...)
    prepare_registry(registry; update=update_registry)
    pkgs = read_pkgs(pkg_names)

    run(julia_versions, pkgs; kwargs...)
end
