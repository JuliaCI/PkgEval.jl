export Configuration

lazy_artifact(x) = @artifact_str(x)

const rootfs_lock = ReentrantLock()
const rootfs_cache = Dict()
function create_rootfs(config::Configuration)
    lock(rootfs_lock) do
        get!(rootfs_cache, (config.distro, config.uid, config.user, config.gid, config.group, config.home)) do
            base = lazy_artifact(config.distro)

            # a bare rootfs isn't usable out-of-the-box
            derived = mktempdir()
            cp(base, derived; force=true)

            # add a user and group
            chmod(joinpath(derived, "etc/passwd"), 0o644)
            open(joinpath(derived, "etc/passwd"), "a") do io
                println(io, "$(config.user):x:$(config.uid):$(config.gid)::$(config.home):/bin/bash")
            end
            chmod(joinpath(derived, "etc/group"), 0o644)
            open(joinpath(derived, "etc/group"), "a") do io
                println(io, "$(config.group):x:$(config.gid):")
            end
            chmod(joinpath(derived, "etc/shadow"), 0o640)
            open(joinpath(derived, "etc/shadow"), "a") do io
                println(io, "$(config.user):*:::::::")
            end

            # replace resolv.conf
            rm(joinpath(derived, "etc/resolv.conf"); force=true)
            write(joinpath(derived, "etc/resolv.conf"), read("/etc/resolv.conf"))

            return derived
        end
    end
end

"""
    sandboxed_julia(config::Configuration, install::String, args=``; env=Dict(), mounts=Dict(),
                    wait=true, stdin=stdin, stdout=stdout, stderr=stderr, kwargs...)

Run Julia inside of a sandbox, passing the given arguments `args` to it. The argument `wait`
determines if the process will be waited on. Streams can be connected using the `stdin`,
`stdout` and `sterr` arguments. Returns a `Process` object.

Further customization is possible using the `env` arg, to set environment variables, and the
`mounts` argument to mount additional directories.
"""
function sandboxed_julia(config::Configuration, install::String, args=``; wait=true,
                         stdin=stdin, stdout=stdout, stderr=stderr, kwargs...)
    # XXX: even when preferred_executor() returns UnprivilegedUserNamespacesExecutor,
    #      sometimes a stray sudo happens at run time? no idea how.
    exe_typ = UnprivilegedUserNamespacesExecutor
    exe = exe_typ()

    cmd = sandboxed_julia_cmd(config, install, exe, args; kwargs...)
    proc = run(pipeline(cmd; stdin, stderr, stdout); wait)

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

function sandboxed_julia_cmd(config::Configuration, install::String, executor, args=``;
                             env::Dict{String,String}=Dict{String,String}(),
                             mounts::Dict{String,String}=Dict{String,String}())
    rootfs = create_rootfs(config)
    read_only_maps = Dict(
        "/"                                 => rootfs,
        config.julia_install_dir            => install,
        "/usr/local/share/julia/registries" => joinpath(first(DEPOT_PATH), "registries"),
    )

    artifacts_path = joinpath(storage_dir, "artifacts")
    mkpath(artifacts_path)
    read_write_maps = merge(mounts, Dict(
        joinpath(config.home, ".julia/artifacts")   => artifacts_path
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

    cmd = `$(config.julia_install_dir)/bin/julia`

    # restrict resource usage
    if !isempty(config.cpus)
        cmd = `/usr/bin/taskset --cpu-list $(join(config.cpus, ',')) $cmd`
        env["JULIA_CPU_THREADS"] = string(length(config.cpus)) # JuliaLang/julia#35787
    end

    # NOTE: we use persist=true so that modifications to the rootfs are backed by
    #       actual storage on the host, and not just the (1G hard-coded) tmpfs,
    #       because some packages like to generate a lot of data during testing.

    sandbox_config = SandboxConfig(read_only_maps, read_write_maps, env;
                                   config.uid, config.gid, pwd=config.home, persist=true,
                                   verbose=isdebug(:sandbox))
    Sandbox.build_executor_command(executor, sandbox_config, `$cmd $(config.julia_args) $args`)
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
    sandboxed_script(config::Configuration, install::String, script::String, args=``)

Run a Julia script `script` in non-interactive mode, returning the process status and a
failure reason if any (both represented by a symbol), and the full log.

Refer to `sandboxed_julia`[@ref] for more possible `keyword arguments.
"""
function sandboxed_script(config::Configuration, install::String, script::String, args=``;
                          kwargs...)
    @assert config.log_limit > 0

    cmd = `--eval 'eval(Meta.parse(read(stdin,String)))' $args`

    env = Dict(
        "JULIA_PKG_PRECOMPILE_AUTO" => "0",
        # package hacks
        "PYTHON" => "",
        "R_HOME" => "*"
    )
    if haskey(ENV, "JULIA_PKG_SERVER")
        env["JULIA_PKG_SERVER"] = ENV["JULIA_PKG_SERVER"]
    end

    input = Pipe()
    output = Pipe()
    proc = sandboxed_julia(config, install, cmd; env, wait=false,
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
    timeout_monitor = Timer(config.time_limit) do timer
        process_running(proc) || return
        status = :kill
        reason = :time_limit
        stop()
    end

    # kill on inactivity (less than 1 second of CPU usage every minute)
    previous_cpu_time = nothing
    inactivity_monitor = Timer(60; interval=30) do timer
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
        while !eof(output)
            print(io, readline(output; keep=true))

            # kill on too-large logs
            if io.size > config.log_limit
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

    if sizeof(log) > config.log_limit
        # even though the monitor above should have limited the log size,
        # a single line may still have exceeded the limit, so make sure we truncate.
        ind = prevind(log, config.log_limit)
        log = log[1:ind]
    end

    return status, reason, log
end

"""
    sandboxed_test(config::Configuration, install::String, pkg; kwargs...)

Run the unit tests for a single package `pkg` inside of a sandbox using a Julia installation
at `install`.

Refer to `sandboxed_script`[@ref] for more possible `keyword arguments.
"""
function sandboxed_test(config::Configuration, install::String, pkg::Package; kwargs...)
    if config.compiled
        return compiled_test(config, install, pkg; kwargs...)
    end

    script = raw"""
        try
            using Dates
            print('#'^80, "\n# PkgEval set-up: $(now())\n#\n\n")

            using InteractiveUtils
            versioninfo()
            println()


            print("\n\n", '#'^80, "\n# Installation: $(now())\n#\n\n")

            using Pkg
            package_spec = eval(Meta.parse(ARGS[1]))
            Pkg.add(; package_spec...)


            print("\n\n", '#'^80, "\n# Testing: $(now())\n#\n\n")

            Pkg.test(package_spec.name)

            println("\nPkgEval succeeded")
        catch err
            print("\nPkgEval failed: ")
            showerror(stdout, err)
            Base.show_backtrace(stdout, catch_backtrace())
            println()
        finally
            print("\n\n", '#'^80, "\n# PkgEval teardown: $(now())\n#\n\n")
        end"""

    # generate a PackageSpec we'll use to install the package
    args = `$(repr(package_spec_tuple(pkg)))`
    if config.depwarn
        args = `--depwarn=error $args`
    end

    status, reason, log = sandboxed_script(config, install, script, args; kwargs...)

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
            elseif occursin("GC error (probable corruption)", log)
                :gc_corruption
            elseif occursin("signal (11): Segmentation fault", log)
                :segfault
            elseif occursin("signal (6): Abort", log)
                :abort
            elseif occursin("Unreachable reached", log)
                :unreachable
            elseif occursin("failed to clone from", log) ||
                   occursin(r"HTTP/\d \d+ while requesting", log) ||
                   occursin("Could not resolve host", log) ||
                   occursin("Resolving timed out after", log) ||
                   occursin("Could not download", log) ||
                   occursin(r"Error: HTTP/\d \d+", log)
                :network
            elseif occursin("ERROR: LoadError: syntax", log)
                :syntax
            elseif occursin("Some tests did not pass", log) || occursin("Test Failed", log)
                :test_failures
            else
                :unknown
            end
        end
    end

    return version, status, reason, log
end

"""
    compiled_test(install::String, pkg)

Run the unit tests for a single package `pkg` (see `compiled_test`[@ref] for details and
a list of supported keyword arguments), after first having compiled a system image that
contains this package and its dependencies.

To find incompatibilities, the compilation happens on an Ubuntu-based runner, while testing
is performed in an Arch Linux container.
"""
function compiled_test(config::Configuration, install::String, pkg; kwargs...)
    script = raw"""
        try
            using Dates
            print('#'^80, "\n# PackageCompiler set-up: $(now())\n#\n\n")

            using InteractiveUtils
            versioninfo()
            println()


            print("\n\n", '#'^80, "\n# Installation: $(now())\n#\n\n")

            using Pkg
            Pkg.add(["PackageCompiler", ARGS[1]])


            print("\n\n", '#'^80, "\n# Compiling: $(now())\n#\n\n")

            using PackageCompiler

            t = @elapsed create_sysimage(Symbol(ARGS[1]), sysimage_path=ARGS[2])
            s = stat(ARGS[2]).size

            println("Generated system image is ", Base.format_bytes(s), ", compilation took ", trunc(Int, t), " seconds")

            println("\nPackageCompiler succeeded")
        catch err
            print("\nPackageCompiler failed: ")
            showerror(stdout, err)
            Base.show_backtrace(stdout, catch_backtrace())
            println()
        finally
            print("\n\n", '#'^80, "\n# PackageCompiler teardown: $(now())\n#\n\n")
        end"""

    sysimage_path = "/sysimage/sysimg.so"
    args = `$(pkg.name) $sysimage_path`

    sysimage_dir = mktempdir()
    mounts = Dict(dirname(sysimage_path) => sysimage_dir)

    compile_config = Configuration(config;
        time_limit = config.compile_time_limit
    )
    status, reason, log = sandboxed_script(compile_config, install, script, args; mounts,
                                           kwargs...)

    # try to figure out the failure reason
    if status === nothing
        if occursin("PackageCompiler succeeded", log)
            status = :ok
        else
            status = :fail
            reason = :uncompilable
        end
    end

    if status !== :ok
        rm(sysimage_dir; recursive=true)
        return missing, status, reason, log
    end

    # run the tests in an alternate environment (different OS, depot and Julia binaries
    # in another path, etc)
    test_config = Configuration(config;
        compiled = false,
        julia_args = `$(config.julia_args) --sysimage $sysimage_path`,
        # install Julia at a different path
        julia_install_dir="/usr/local/julia",
        # use a different Linux distro
        distro="arch",
        # run as a different user
        user="user",
        group="group",
        home="/home/user",
    )
    version, status, reason, test_log =
        sandboxed_test(test_config, install, pkg; mounts, kwargs...)

    rm(sysimage_dir; recursive=true)
    return version, status, reason, log * "\n" * test_log
end

"""
    evaluate(configs::Vector{Configuration}, packages::Vector{String}=[]]; kwargs...)

Run all tests for all packages in the registry `registry`, or only for the packages as
identified by their name in `pkgnames`, using the configurations from `configs`.
The registry is first updated if `update_registry` is set to true.

Refer to `sandboxed_test`[@ref] and `sandboxed_julia`[@ref] for more possible
keyword arguments.
"""
function evaluate(configs::Vector{Configuration}, packages::Vector{Package};
                  ninstances::Integer=Sys.CPU_THREADS)
    # here we deal with managing execution: spawning workers, output, result I/O, etc

    # Julia installation
    instantiated_configs = Dict()
    for config in configs
        install = install_julia(config)
        # XXX: better get the version from a file in the tree
        version_str = chomp(read(`$install/bin/julia --startup-file=no --eval "println(VERSION)"`, String))
        version = parse(VersionNumber, version_str)
        instantiated_configs[config] = (install, version)
    end

    jobs = vec(collect(Iterators.product(instantiated_configs, packages)))

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
    result = DataFrame(julia_spec = String[],
                       julia_version = VersionNumber[],
                       compiled = Bool[],
                       name = String[],
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
    # TODO: we don't want to do this for both. but rather one of the builds is compiled, the other not...
    try @sync begin
        for i = 1:ninstances
            push!(all_workers, @async begin
                try
                    while !isempty(jobs) && !done
                        (config, (julia_install, julia_version)), pkg = pop!(jobs)
                        times[i] = now()
                        running[i] = (config, pkg)

                        # should we even test this package?
                        if pkg.name in skip_list
                            push!(result, [config.julia, julia_version, config.compiled,
                                           pkg.name, missing,
                                           :skip, :explicit, 0, missing])
                            running[i] = nothing
                            continue
                        elseif endswith(pkg.name, "_jll")
                            push!(result, [config.julia, julia_version, config.compiled,
                                           pkg.name, missing,
                                           :skip, :jll, 0, missing])
                            running[i] = nothing
                            continue
                        end

                        # perform an initial run
                        config′ = Configuration(config; cpus=[i-1])
                        pkg_version, status, reason, log =
                            sandboxed_test(config′, julia_install, pkg)

                        # certain packages are known to have flaky tests; retry them
                        for j in 1:pkg.retries
                            if status == :fail && reason == :test_failures
                                times[i] = now()
                                pkg_version, status, reason, log =
                                    sandboxed_test(config′, julia_install, pkg)
                            end
                        end

                        duration = (now()-times[i]) / Millisecond(1000)
                        push!(result, [config.julia, julia_version, config.compiled,
                                       pkg.name, pkg_version,
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
        for (config, (install,version)) in instantiated_configs
            rm(install; recursive=true)
        end
    end

    return result
end
