function with_mounted_shards(f, runner)
    BinaryBuilder.mount_shards(runner; verbose=true)
    try
        f()
    finally
        BinaryBuilder.unmount_shards(runner; verbose=true)
    end
end

"""
    run_sandboxed_julia(args=``; ver::VersionNumber, do_obtain=true, kwargs...)

Run Julia inside of a sandbox, passing the given arguments `args` to it. The keyword
argument `ver` specifies the version of Julia to use, and `do_obtain` dictates whether
the specified version should first be downloaded. If `do_obtain` is `false`, it must
already be installed.
"""
function run_sandboxed_julia(args=``; ver::VersionNumber, do_obtain=true,
                             stdin=stdin, stdout=stdout, stderr=stderr)
    runner, cmd = runner_sandboxed_julia(args; ver=ver, do_obtain=do_obtain)
    with_mounted_shards(runner) do
        Base.run(pipeline(cmd, stdin=stdin, stdout=stdout, stderr=stderr))
    end
end

function runner_sandboxed_julia(args=``; ver::VersionNumber, do_obtain=true)
    if do_obtain
        obtain_julia(ver)
    else
        @assert ispath(julia_path(ver))
    end
    tmpdir = joinpath(tempdir(), "NewPkgEval")
    mkpath(tmpdir)
    tmpdir = mktempdir(tmpdir)
    runner = BinaryBuilder.UserNSRunner(tmpdir,
        workspaces=[
            installed_julia_dir(ver)                    => "/maps/julia",
            joinpath(first(DEPOT_PATH), "registries")   => "/maps/registries"
        ])
    cmd = `/maps/julia/bin/julia --color=yes $args`
    cmd = setenv(`$(runner.sandbox_cmd) -- $(cmd)`, runner.env) # extracted from run_interactive in BinaryBuilder
    return runner, cmd
end

log_path(ver) = joinpath(@__DIR__, "..", "logs/logs-$ver")

"""
    run_sandboxed_test(pkg; ver::VersionNumber, do_depwarns=false, log_limit = 5*1024^2, time_limit=60*45, kwargs...)

Run the unit tests for a single package `pkg` inside of a sandbox using the Julia version
`ver`. If `do_depwarns` is `true`, deprecation warnings emitted while running the package's
tests will cause the tests to fail. Test will be forcibly interrupted after `time_limit`
seconds or if the log becomes larger than `log_limit`.

A log for the tests is written to a version-specific directory in the NewPkgEval root
directory.
"""
function run_sandboxed_test(pkg::AbstractString; ver, log_limit = 5*1024^2 #= 5 MB =#,
                            time_limit = 45*60, do_depwarns=false, kwargs...)
    mkpath(log_path(ver))
    arg = """
        using Pkg

        # Map the local registries to the sandbox
        mkpath("/root/.julia")
        run(`ln -s /maps/registries /root/.julia/registries`)

        # Prevent Pkg from updating registy on the Pkg.add
        ENV["CI"] = true
        Pkg.UPDATED_REGISTRY_THIS_SESSION[] = true

        Pkg.add($(repr(pkg)))
        Pkg.test($(repr(pkg)))
    """
    cmd = do_depwarns ? `--depwarn=error` : ``
    cmd = `$cmd -e $arg`
    runner, cmd = runner_sandboxed_julia(cmd; ver=ver, kwargs...)

    log = joinpath(log_path(ver), "$pkg.log")
    open(log, "w") do f
        with_mounted_shards(runner) do
            p = Base.run(pipeline(cmd, stdout=f, stderr=f, stdin=devnull); wait=false)
            killed = Ref(false)
            t = Timer(time_limit) do timer
                process_running(p) || return # exit callback
                killed[] = true
                kill_process(p)
            end
            t2 = @async while true
                process_running(p) || break
                if stat(log).size > log_limit
                    kill_process(p)
                    killed[] = true
                    break
                end
                flush(f)
                sleep(2)
            end
            succeeded = success(p)
            close(t)
            wait(t2)
            return (killed[], succeeded)
        end
    end
end

function kill_process(p)
    if BinaryBuilder.runner_override == "privileged"
        pid = getpid(p)
        Base.run(`sudo kill $pid`)
        sleep(3)
        if process_running(p)
            Base.run(`sudo kill -9 $pid`)
        end
    else
        kill(p)
        sleep(3)
        if process_running(p)
            kill(p, 9)
        end
    end
end

"""
    run(depsgraph, ninstances, version[, result]; do_depwarns=false,
        time_limit=60*45)

Run all tests for all packages in the given package dependency graph using `ninstances`
workers and the specified version of Julia. An existing result `Dict` can be specified,
in which case the function will write to that.

If the keyword argument `do_depwarns` is `true`, deprecation warnings emitted in package
tests will cause the package's tests to fail, i.e. Julia is run with `--depwarn=error`.

Tests will be forcibly interrupted after `time_limit` seconds.
"""
function run(pkgs::Vector, ninstances::Integer, ver::VersionNumber, result=Dict{String,Symbol}();
             do_depwarns=false, time_limit=60*45)
    obtain_julia(ver)

    # In case we need to provide sudo password, do that before starting the actual testing
    run_sandboxed_julia(`-e '1'`; ver=ver)

    pkgs = copy(pkgs)
    npkgs = length(pkgs)
    ninstances = min(npkgs, ninstances)
    running = Vector{Union{Nothing, Symbol}}(nothing, ninstances)
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
    function update_output()
        o = count(==(:ok),      values(result))
        f = count(==(:fail),    values(result))
        s = count(==(:skipped), values(result))
        x = npkgs - (o + f + s)

        function runtimestr(start)
            time = Dates.canonicalize(Dates.CompoundPeriod(now() - start))
            isempty(time.periods) || pop!(time.periods) # get rid of milliseconds
            if isempty(time.periods)
                "just started"
            else
                "running for $time"
            end
        end

        if on_ci
            println("$x packages to test ($o succeeded, $f failed, $s skipped, $(runtimestr(start)))")
            sleep(10)
        else
            print(io, "Success: ")
            printstyled(io, o; color = :green)
            print(io, "\tFailed: ")
            printstyled(io, f; color = Base.error_color())
            print(io, "\tSkipped: ")
            printstyled(io, s; color = Base.warn_color())
            println(io, "\tRemaining: ", x)
            for i = 1:ninstances
                r = running[i]
                if r === nothing
                    println(io, "Worker $i: -------")
                else
                    println(io, "Worker $i: $(r) $(runtimestr(times[i]))")
                end
            end
            print(String(take!(io.io)))
            sleep(1)
            CSI = "\e["
            print(io, "$(CSI)$(ninstances+1)A$(CSI)1G$(CSI)0J")
        end
    end

    try @sync begin
        # Printer
        @async begin
            try
                while (!isempty(pkgs) || !all(==(nothing), running)) && !done
                    update_output()
                end
                stop_work()
            catch e
                stop_work()
                !isa(e, InterruptException) && rethrow(e)
            end
        end

        # Workers
        for i = 1:ninstances
            push!(all_workers, @async begin
                try
                    while !isempty(pkgs) && !done
                        pkg = pop!(pkgs)
                        if pkg.name in skip_lists[pkg.registry]
                            result[pkg.name] = :skip
                        else
                            running[i] = Symbol(pkg.name)
                            times[i] = now()
                            killed, succeeded = NewPkgEval.run_sandboxed_test(pkg.name; ver=ver, time_limit=time_limit)
                            result[pkg.name] = killed ? :killed :
                                               succeeded ? :ok : :fail
                            running[i] = nothing
                        end
                    end
                catch e
                    stop_work()
                    isa(e, InterruptException) || rethrow(e)
                end
            end)
        end
    end
    catch e
        e isa InterruptException || rethrow(e)
    end
    return result
end
