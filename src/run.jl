export Configuration

const rootfs_cache = Dict()

lazy_artifact(x) = @artifact_str(x)

const rootfs_lock = ReentrantLock()
rootfs() = lock(rootfs_lock) do
    lazy_artifact("debian")
end

"""
    run_sandboxed_julia(install::String, args=``; env=Dict(), mounts=Dict(),
                        wait=true, stdin=stdin, stdout=stdout, stderr=stderr,
                        install_dir="/opt/julia", kwargs...)

Run Julia inside of a sandbox, passing the given arguments `args` to it. The argument `wait`
determines if the process will be waited on. Streams can be connected using the `stdin`,
`stdout` and `sterr` arguments. Returns a `Process` object.

Further customization is possible using the `env` arg, to set environment variables, and the
`mounts` argument to mount additional directories. With `install_dir`, the directory where
Julia is installed can be chosen.
"""
function run_sandboxed_julia(install::String, args=``; wait=true,
                             mounts::Dict{String,String}=Dict{String,String}(),
                             kwargs...)
    config, cmd = runner_sandboxed_julia(install, args;
                                         uid=1000, gid=1000, homedir="/home/pkgeval",
                                         kwargs...)

    # XXX: even when preferred_executor() returns UnprivilegedUserNamespacesExecutor,
    #      sometimes a stray sudo happens at run time? no idea how.
    exe_typ = UnprivilegedUserNamespacesExecutor
    exe = exe_typ()
    proc = Base.run(exe, config, cmd; wait)

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

# global Xvfb process for use by all containers
const xvfb_lock = ReentrantLock()
const xvfb_proc = Ref{Union{Base.Process,Nothing}}(nothing)

# global copy of resolv.conf to mount in all containers
const resolvconf_lock = ReentrantLock()
const resolvconf_path = Ref{Union{String,Nothing}}(nothing)

function runner_sandboxed_julia(install::String, args=``; install_dir="/opt/julia",
                                stdin=stdin, stdout=stdout, stderr=stderr,
                                env::Dict{String,String}=Dict{String,String}(),
                                mounts::Dict{String,String}=Dict{String,String}(),
                                uid::Int=0, gid::Int=0, homedir::String="/root",
                                xvfb::Bool=true, cpus::Vector{Int}=Int[])
    # sometimes resolv.conf points to a location we can't bind mount from (for whatever reason)
    resolvconf_file = lock(resolvconf_lock) do
        if resolvconf_path[] == nothing
            path, io = mktemp()
            write(io, read("/etc/resolv.conf", String))
            close(io)
            resolvconf_path[] = path
        end
        resolvconf_path[]
    end

    julia_path = installed_julia_dir(install)
    read_only_maps = Dict(
        "/" => rootfs(),
        "/etc/resolv.conf"                      => resolvconf_file,
        install_dir                             => julia_path,
        "/usr/local/share/julia/registries"     => registry_dir(),
    )

    artifacts_path = joinpath(storage_dir(), "artifacts")
    mkpath(artifacts_path)
    read_write_maps = merge(mounts, Dict(
        joinpath(homedir, ".julia/artifacts")   => artifacts_path
    ))

    env = merge(env, Dict(
        # PkgEval detection
        "CI" => "true",
        "PKGEVAL" => "true",
        "JULIA_PKGEVAL" => "true",

        # use the provided registry
        # NOTE: putting a registry in a non-primary depot entry makes Pkg use it as-is,
        #       without needingb to set Pkg.UPDATED_REGISTRY_THIS_SESSION.
        "JULIA_DEPOT_PATH" => "::/usr/local/share/julia",

        # some essential env vars (since we don't run from a shell)
        "PATH" => "/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin",
        "HOME" => homedir,
    ))
    if haskey(ENV, "TERM")
        env["TERM"] = ENV["TERM"]
    end

    if xvfb
        lock(xvfb_lock) do
            if xvfb_proc[] === nothing || !process_running(xvfb_proc[])
                proc = Base.run(`Xvfb :1 -screen 0 1024x768x16`; wait=false)
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

    cmd = `$install_dir/bin/julia`

    # restrict resource usage
    if !isempty(cpus)
        cmd = `/usr/bin/taskset --cpu-list $(join(cpus, ',')) $cmd`
        env["JULIA_CPU_THREADS"] = string(length(cpus)) # JuliaLang/julia#35787
    end

    # NOTE: we use persist=true so that modifications to the rootfs are backed by
    #       actual storage on the host, and not just the (1G hard-coded) tmpfs,
    #       because some packages like to generate a lot of data during testing.

    config = SandboxConfig(read_only_maps, read_write_maps, env;
                           uid, gid, pwd=homedir, persist=true,
                           stdin, stdout, stderr, verbose=isdebug(:sandbox))

    return config, `$cmd $args`
end

function process_children(pid)
    pids = Int[]
    for tid in readdir("/proc/$pid/task")
        children = read("/proc/$pid/task/$tid/children", String)
        append!(pids, parse.(Int, split(children)))
    end
    pids
end

function cpu_time(pid)
    stats = read("/proc/$pid/stat", String)
    m = match(r"^(\d+) \((.+)\) (.+)", stats)
    @assert m !== nothing
    fields = [[m.captures[1], m.captures[2]]; split(m.captures[3])]
    utime = parse(Int, fields[14])
    stime = parse(Int, fields[15])
    cutime = parse(Int, fields[16])
    cstime = parse(Int, fields[17])
    total_time = (utime + stime + cutime + cstime) / Sys.SC_CLK_TCK

    # cutime and cstime are only updated when the child exits,
    # so recursively scan all known children
    total_time += sum(cpu_time, process_children(pid); init=0.0)

    return total_time
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
    script = raw"""
        try
            using Dates
            print('#'^80, "\n# PkgEval set-up: $(now())\n#\n\n")

            using InteractiveUtils
            versioninfo()
            println()


            print("\n\n", '#'^80, "\n# Installation: $(now())\n#\n\n")

            using Pkg
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
        end"""
    cmd = do_depwarns ? `--depwarn=error` : ``
    cmd = `$cmd --eval 'eval(Meta.parse(read(stdin,String)))' $(pkg.name)`

    input = Pipe()
    output = Pipe()

    env = Dict(
        "JULIA_PKG_PRECOMPILE_AUTO" => "0",
        # package hacks
        "PYTHON" => "",
        "R_HOME" => "*"
    )
    if haskey(ENV, "JULIA_PKG_SERVER")
        env["JULIA_PKG_SERVER"] = ENV["JULIA_PKG_SERVER"]
    end

    proc = run_sandboxed_julia(install, cmd; env, wait=false,
                               stdout=output, stderr=output, stdin=input,
                               kwargs...)
    close(output.in)

    # pass the script over standard input to avoid exceeding max command line size,
    # and keep the process listing somewhat clean
    println(input, script)
    close(input)

    function stop()
        if process_running(proc)
            # FIXME: if we only kill proc, we sometimes only end up killing the sandbox.
            #        shouldn't the sandbox handle this, e.g., by creating a process group?
            function recursive_kill(proc, sig)
                parent_pid = getpid(proc)
                for pid in reverse([parent_pid; process_children(parent_pid)])
                    ccall(:uv_kill, Cint, (Cint, Cint), pid, Base.SIGKILL)
                end
                return
            end

            recursive_kill(proc, Base.SIGINT)
            terminator = Timer(5) do timer
                recursive_kill(proc, Base.SIGTERM)
            end
            killer = Timer(10) do timer
                recursive_kill(proc, Base.SIGKILL)
            end
            wait(proc)
            close(terminator)
            close(killer)
        end
        close(output)
    end

    status = nothing
    reason = missing

    # kill on timeout
    timeout_monitor = Timer(time_limit) do timer
        process_running(proc) || return
        status = :kill
        reason = :time_limit
        stop()
    end

    # kill on inactivity (less than 1 second of CPU usage every minute)
    previous_cpu_time = nothing
    inactivity_monitor = Timer(6; interval=30) do timer
        process_running(proc) || return
        pid = getpid(proc)
        current_cpu_time = cpu_time(pid)
        if current_cpu_time > 0 && previous_cpu_time !== nothing
            cpu_time_diff = current_cpu_time - previous_cpu_time
            if 0 <= cpu_time_diff < 1
                status = :kill
                reason = :inactivity
                stop()
            end
        end
        previous_cpu_time = current_cpu_time
    end

    # collect output
    log_monitor = @async begin
        io = IOBuffer()
        while isopen(output)
            write(io, output)

            # kill on too-large logs
            if io.size > log_limit
                process_running(proc) || break
                status = :kill
                reason = :log_limit
                stop()
                break
            end
        end
        return String(take!(io))
    end

    wait(proc)
    close(timeout_monitor)
    close(inactivity_monitor)
    log = fetch(log_monitor)
    @assert !isopen(output) && eof(output)

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
    if status === nothing
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

    # Julia installation
    instantiated_configs = Dict{Configuration,String}()
    for config in configs
        install = prepare_julia(config.julia)
        instantiated_configs[config] = install
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

        if !isinteractive()
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

    # NOTE: we expand the Configuration into separate columns
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
                        (config, install), pkg = pop!(jobs)
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
                            push!(result, [config.julia,
                                           pkg.name, pkg.uuid, missing,
                                           :skip, :unsupported, 0, missing])
                            running[i] = nothing
                            continue
                        elseif pkg.name in skip_lists[pkg.registry]
                            push!(result, [config.julia,
                                           pkg.name, pkg.uuid, missing,
                                           :skip, :explicit, 0, missing])
                            running[i] = nothing
                            continue
                        elseif endswith(pkg.name, "_jll")
                            push!(result, [config.julia,
                                           pkg.name, pkg.uuid, missing,
                                           :skip, :jll, 0, missing])
                            running[i] = nothing
                            continue
                        end

                        # perform an initial run
                        pkg_version, status, reason, log =
                            run_sandboxed_test(install, pkg; cpus=[i-1], kwargs...)

                        # certain packages are known to have flaky tests; retry them
                        for j in 1:retries
                            if status == :fail && reason == :test_failures &&
                               pkg.name in retry_lists[pkg.registry]
                                times[i] = now()
                                pkg_version, status, reason, log =
                                    run_sandboxed_test(install, pkg; cpus=[i-1], kwargs...)
                            end
                        end

                        duration = (now()-times[i]) / Millisecond(1000)
                        push!(result, [config.julia,
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
        for (config, install) in instantiated_configs
            rm(install; recursive=true)
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
prepare_runner() = return
