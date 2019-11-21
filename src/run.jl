function with_mounted_shards(f, runner)
    BinaryBuilder.mount_shards(runner; verbose=true)
    try
        f()
    finally
        BinaryBuilder.unmount_shards(runner; verbose=true)
    end
end

"""
    run_sandboxed_julia(julia::VersionNumber, args=``; do_obtain=true, kwargs...)

Run Julia inside of a sandbox, passing the given arguments `args` to it. The keyword
argument `julia` specifies the version of Julia to use, and `do_obtain` dictates whether
the specified version should first be downloaded. If `do_obtain` is `false`, it must
already be installed.
"""
function run_sandboxed_julia(julia::VersionNumber, args=``; stdin=stdin, stdout=stdout,
                             stderr=stderr, kwargs...)
    runner, cmd = runner_sandboxed_julia(julia, args; kwargs...)
    with_mounted_shards(runner) do
        Base.run(pipeline(cmd, stdin=stdin, stdout=stdout, stderr=stderr))
    end
end

function runner_sandboxed_julia(julia::VersionNumber, args=``; do_obtain=true)
    if do_obtain
        obtain_julia(julia)
    else
        @assert ispath(julia_path(julia))
    end
    tmpdir = joinpath(tempdir(), "NewPkgEval")
    mkpath(tmpdir)
    tmpdir = mktempdir(tmpdir)
    runner = BinaryBuilder.UserNSRunner(tmpdir,
        workspaces=[
            installed_julia_dir(julia)                    => "/maps/julia",
            joinpath(first(DEPOT_PATH), "registries")   => "/maps/registries"
        ])
    cmd = `/maps/julia/bin/julia --color=yes $args`
    cmd = setenv(`$(runner.sandbox_cmd) -- $(cmd)`, runner.env) # extracted from run_interactive in BinaryBuilder
    return runner, cmd
end

"""
    run_sandboxed_test(julia::VersionNumber, pkg; do_depwarns=false, log_limit=5*1024^2, time_limit=60*45)

Run the unit tests for a single package `pkg` inside of a sandbox using the Julia version
`julia`. If `do_depwarns` is `true`, deprecation warnings emitted while running the package's
tests will cause the tests to fail. Test will be forcibly interrupted after `time_limit`
seconds or if the log becomes larger than `log_limit`.

A log for the tests is written to a version-specific directory in the NewPkgEval root
directory.
"""
function run_sandboxed_test(julia::VersionNumber, pkg::String; log_limit = 5*1024^2 #= 5 MB =#,
                            time_limit = 45*60, do_depwarns=false, kwargs...)
    mkpath(log_path(julia))
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
    runner, cmd = runner_sandboxed_julia(julia, cmd; kwargs...)

    mktemp() do log, f
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
            return (killed[], succeeded, read(log, String))
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

function run(julia::VersionNumber, pkgs::Vector; ninstances::Integer=Sys.CPU_THREADS,
             callback=nothing, kwargs...)
    obtain_julia(julia)

    # In case we need to provide sudo password, do that before starting the actual testing
    run_sandboxed_julia(julia, `-e '1'`)

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
        # known statuses
        o = count(==(:ok),      values(result))
        s = count(==(:skipped), values(result))
        # everything else is a failure
        f = length(result) - (o + s)
        # remaining
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

    result = Dict{String,Symbol}()
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
                        times[i] = now()
                        if pkg.name in skip_lists[pkg.registry]
                            result[pkg.name] = :skip
                            log = nothing
                        else
                            running[i] = Symbol(pkg.name)
                            killed, succeeded, log = NewPkgEval.run_sandboxed_test(julia, pkg.name; kwargs...)
                            result[pkg.name] = killed ? :killed :
                                               succeeded ? :ok : :fail
                            running[i] = nothing

                            # figure out a more accurate failure reason from the log
                            if result[pkg.name] == :fail
                                if occursin("ERROR: Unsatisfiable requirements detected for package", log)
                                    # NOTE: might be the package itself, or one of its dependencies
                                    result[pkg.name] = :unsatisfiable
                                elseif occursin("ERROR: Package $(pkg.name) did not provide a `test/runtests.jl` file", log)
                                    result[pkg.name] = :untestable
                                elseif occursin("cannot open shared object file: No such file or directory", log)
                                    result[pkg.name] = :binary_dependency
                                end
                            end
                        end

                        # report to the caller
                        if callback !== nothing
                            callback(pkg.name, times[i], result[pkg.name], log)
                        else
                            write(joinpath(log_path(julia), "$(pkg.name).log"), log)
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

"""
    run(julia::VersionNumber, pkgnames=nothing; registry=General, update_registry=true, kwargs...)

Run all tests for all packages in the registry `registry`, or only for the packages as
identified by their name in `pkgnames`, using Julia version `julia` on `ninstances` workers.
By default, the registry will be first updated unless `update_registry` is set to false.

Refer to `run_sandboxed_test`[@ref] for other possible keyword arguments.
"""
function run(julia::VersionNumber=Base.VERSION, pkgnames::Union{Nothing, Vector{String}}=nothing;
             registry::String=DEFAULT_REGISTRY, update_registry::Bool=true, kwargs...)
    get_registry(registry; update=update_registry)
    pkgs = read_pkgs(pkgnames)
    run(julia, pkgs; kwargs...)
end
