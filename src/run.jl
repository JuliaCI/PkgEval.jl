function prepare_runner()
    cd(joinpath(dirname(@__DIR__), "runner")) do
        Base.run(`docker build . -t newpkgeval`)
    end
    return
end

"""
    run_sandboxed_julia(julia::VersionNumber, args=``; do_obtain=true, kwargs...)

Run Julia inside of a sandbox, passing the given arguments `args` to it. The argument
`julia` specifies the version of Julia to use, which should be readily available (i.e. the
user is responsible for having called `prepare_julia`).
"""
function run_sandboxed_julia(julia::VersionNumber, args=``; stdin=stdin, stdout=stdout,
                             stderr=stderr, kwargs...)
    cmd = runner_sandboxed_julia(julia, args; kwargs...)
    Base.run(pipeline(cmd, stdin=stdin, stdout=stdout, stderr=stderr))
end

function runner_sandboxed_julia(julia::VersionNumber, args=``; interactive=true)
    cmd = `docker run`

    # mount data
    @assert ispath(julia_path(julia))
    installed_julia_path = installed_julia_dir(julia)
    @assert isdir(installed_julia_path)
    registry_path = joinpath(first(DEPOT_PATH), "registries")
    @assert isdir(registry_path)
    cmd = ```$cmd --mount type=bind,source=$installed_julia_path,target=/maps/julia,readonly
                  --mount type=bind,source=$registry_path,target=/maps/registries,readonly```

    if interactive
        cmd = `$cmd --interactive --tty`
    end

    `$cmd --rm newpkgeval /maps/julia/bin/julia $args`
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
    cmd = runner_sandboxed_julia(julia, cmd; interactive=false, kwargs...)

    mktemp() do log, f
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

function kill_process(p)
    kill(p)
    sleep(3)
    if process_running(p)
        kill(p, 9)
    end
end

function run(julia::VersionNumber, pkgs::Vector; ninstances::Integer=Sys.CPU_THREADS,
             callback=nothing, kwargs...)
    prepare_julia(julia)

    length(readlines(`docker images -q newpkgeval`)) == 0 && error("Docker image not found, please run NewPkgEval.prepare_runner() first.")

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
        s = count(==(:skip),    values(result))
        f = count(==(:fail),    values(result))
        k = count(==(:killed),  values(result))
        # remaining
        x = npkgs - length(result)

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
            println("$x packages to test ($o succeeded, $f failed, $k killed, $s skipped, $(runtimestr(start)))")
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
                        log = missing
                        pkg_version = missing
                        reason = missing
                        if pkg.name in skip_lists[pkg.registry]
                            result[pkg.name] = :skip
                        else
                            running[i] = Symbol(pkg.name)
                            killed, succeeded, log = NewPkgEval.run_sandboxed_test(julia, pkg.name; kwargs...)
                            result[pkg.name] = killed ? :killed :
                                               succeeded ? :ok : :fail
                            running[i] = nothing

                            # pick up the installed package version from the log
                            let match = match(Regex("Installed $(pkg.name) .+ v(.+)"), log)
                                if match !== nothing
                                    pkg_version = VersionNumber(match.captures[1])
                                end
                            end

                            # figure out a more accurate failure reason from the log
                            if result[pkg.name] == :fail
                                if occursin("ERROR: Unsatisfiable requirements detected for package", log)
                                    # NOTE: might be the package itself, or one of its dependencies
                                    reason = :unsatisfiable
                                elseif occursin("ERROR: Package $(pkg.name) did not provide a `test/runtests.jl` file", log)
                                    reason = :untestable
                                elseif occursin("cannot open shared object file: No such file or directory", log)
                                    reason = :binary_dependency
                                elseif occursin(r"Package .+ does not have .+ in its dependencies", log)
                                    reason = :missing_dependency
                                elseif occursin("Some tests did not pass", log)
                                    reason = :test_failures
                                elseif occursin("ERROR: LoadError: syntax", log)
                                    reason = :syntax
                                else
                                    reason = :unknown
                                end
                            end
                        end

                        # report to the caller
                        if callback !== nothing
                            callback(pkg.name, pkg_version, times[i], result[pkg.name], reason, log)
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
    prepare_registry(registry; update=update_registry)
    prepare_runner()
    pkgs = read_pkgs(pkgnames)
    run(julia, pkgs; kwargs...)
end
