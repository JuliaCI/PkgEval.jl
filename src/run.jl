function prepare_runner()
    cd(joinpath(dirname(@__DIR__), "runner")) do
        image = chomp(read(`docker build --quiet --tag newpkgeval .`, String))
    end
    return
end

"""
    run_sandboxed_julia(julia::VersionNumber, args=``; wait=true, interactive=true,
                        stdin=stdin, stdout=stdout, stderr=stderr, kwargs...)

Run Julia inside of a sandbox, passing the given arguments `args` to it. The argument
`julia` specifies the version of Julia to use.

The argument `wait` determines if the process will be waited on, and defaults to true. If
setting this argument to `false`, remember that the sandbox is using on Docker and killing
the process does not necessarily kill the container. It is advised to use the `name` keyword
argument to set the container name, and use that to kill the Julia process.

The keyword argument `interactive` maps to the Docker option, and defaults to true.
"""
function run_sandboxed_julia(julia::VersionNumber, args=``; wait=true,
                             stdin=stdin, stdout=stdout, stderr=stderr, kwargs...)
    container = spawn_sandboxed_julia(julia, args; kwargs...)
    Base.run(pipeline(`docker attach $container`, stdin=stdin, stdout=stdout, stderr=stderr); wait=wait)
end

function spawn_sandboxed_julia(julia::VersionNumber, args=``; interactive=true, name=nothing)
    cmd = `docker run --detach`

    # mount data
    @assert ispath(julia_path(julia))
    installed_julia_path = installed_julia_dir(julia)
    @assert isdir(installed_julia_path)
    registry_path = joinpath(first(DEPOT_PATH), "registries")
    @assert isdir(registry_path)
    cmd = ```$cmd --mount type=bind,source=$installed_julia_path,target=/opt/julia
                  --mount type=bind,source=$registry_path,target=/opt/julia/local/share/julia/registries,readonly```

    if interactive
        cmd = `$cmd --interactive --tty`
    end

    if name !== nothing
        cmd = `$cmd --name $name`
    end

    container = chomp(read(`$cmd --rm newpkgeval /opt/julia/bin/julia $args`, String))
    return something(name, container)
end

"""
    run_sandboxed_test(julia::VersionNumber, pkg; do_depwarns=false, log_limit=2^20,
                       time_limit=60*60)

Run the unit tests for a single package `pkg` inside of a sandbox using Julia version
`julia`. If `do_depwarns` is `true`, deprecation warnings emitted while running the
package's tests will cause the tests to fail. Test will be forcibly interrupted after
`time_limit` seconds (defaults to 1h) or if the log becomes larger than `log_limit`
(defaults to 1MB).

A log for the tests is written to a version-specific directory in the NewPkgEval root
directory.

Refer to `run_sandboxed_julia`[@ref] for more possible `keyword arguments.
"""
function run_sandboxed_test(julia::VersionNumber, pkg; log_limit = 2^20 #= 1 MB =#,
                            time_limit = 60*60, do_depwarns=false, kwargs...)
    # everything related to testing in Julia: version compatibility, invoking Pkg, etc

    if pkg.name in skip_lists[pkg.registry]
        return missing, :skip, :explicit, missing
    elseif endswith(pkg.name, "_jll")
        return missing, :skip, :jll, missing
    end

    # can we even test this package?
    pkg_versions = Pkg.Operations.load_versions(pkg.path)
    julia_supported = Dict{VersionNumber,Bool}()
    pkg_compat = Pkg.Operations.load_package_data_raw(Pkg.Types.VersionSpec,
                                                      joinpath(pkg.path, "Compat.toml"))
    for (version_range, bounds) in pkg_compat
        if haskey(bounds, "julia")
            for pkg_version in keys(pkg_versions)
                if pkg_version in version_range
                    julia_supported[pkg_version] = julia ∈ bounds["julia"]
                end
            end
        end
    end
    if length(julia_supported) != length(pkg_versions)
        # not all versions have a bound for Julia, so we need to be conservative
        supported = true
    else
        supported = any(values(julia_supported))
    end
    if !supported
        return missing, :skip, :unsupported, missing
    end

    # prepare for launching a container
    container = "Julia_v$(julia)-$(pkg.name)"
    arg = raw"""
        using InteractiveUtils
        versioninfo()
        println()

        using Pkg
        Pkg.UPDATED_REGISTRY_THIS_SESSION[] = true

        ENV["CI"] = true
        ENV["PKGEVAL"] = true

        Pkg.add(ARGS...)
        Pkg.test(ARGS...)
    """
    cmd = do_depwarns ? `--depwarn=error` : ``
    cmd = `$cmd -e $arg $(pkg.name)`

    mktemp() do path, f
        p = run_sandboxed_julia(julia, cmd; stdout=f, stderr=f, stdin=devnull,
                                interactive=false, wait=false, name=container, kwargs...)
        status = nothing
        reason = missing
        version = missing

        # kill on timeout
        t = Timer(time_limit) do timer
            process_running(p) || return
            status = :kill
            reason = :time_limit
            kill_container(p, container)
        end

        # kill on too-large logs
        t2 = @async while true
            process_running(p) || break
            if stat(path).size > log_limit
                kill_container(p, container)
                status = :kill
                reason = :log_limit
                break
            end
            sleep(2)
        end

        succeeded = success(p)
        log = read(path, String)
        close(t)
        wait(t2)

        # pick up the installed package version from the log
        let match = match(Regex("Installed $(pkg.name) .+ v(.+)"), log)
            if match !== nothing
                version = VersionNumber(match.captures[1])
            end
        end

        if succeeded
            status = :ok
        elseif status === nothing
            status = :fail
            reason = :unknown

            # figure out a more accurate failure reason from the log
            if occursin("ERROR: Unsatisfiable requirements detected for package", log)
                # NOTE: might be the package itself, or one of its dependencies
                reason = :unsatisfiable
            elseif occursin("ERROR: Package $(pkg.name) did not provide a `test/runtests.jl` file", log)
                reason = :untestable
            elseif occursin("cannot open shared object file: No such file or directory", log)
                reason = :binary_dependency
            elseif occursin(r"Package .+ does not have .+ in its dependencies", log)
                reason = :missing_dependency
            elseif occursin(r"Package .+ not found in current path", log)
                reason = :missing_package
            elseif occursin("Some tests did not pass", log) || occursin("Test Failed", log)
                reason = :test_failures
            elseif occursin("ERROR: LoadError: syntax", log)
                reason = :syntax
            elseif occursin("signal (11): Segmentation fault", log)
                reason = :segfault
            elseif occursin("Unreachable reached", log)
                reason = :unreachable
            end
        end

        return version, status, reason, log
    end
end

kill_container(p, container) = Base.run(`docker stop $container`)

function run(julia_versions::Vector{VersionNumber}, pkgs::Vector;
             ninstances::Integer=Sys.CPU_THREADS, kwargs...)
    # here we deal with managing execution: spawning workers, output, result I/O, etc

    jobs = [(julia=julia, pkg=pkg) for julia in julia_versions for pkg in pkgs]

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

    try @sync begin
        # Printer
        @async begin
            try
                while (!isempty(jobs) || !all(==(nothing), running)) && !done
                    update_output()
                end
                println()
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
                    while !isempty(jobs) && !done
                        job = pop!(jobs)
                        times[i] = now()
                        running[i] = job
                        pkg_version, status, reason, log =
                            run_sandboxed_test(job.julia, job.pkg; kwargs...)
                        duration = (now()-times[i]) / Millisecond(1000)
                        push!(result, [job.julia, job.pkg.name, job.pkg.uuid, pkg_version,
                                       status, reason, duration, log])
                        running[i] = nothing

                        if log !== missing
                            mkpath(log_path(job.julia))
                            write(joinpath(log_path(job.julia), "$(job.pkg.name).log"), log)
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
    # high-level entry-point that takes care of everything

    prepare_registry(registry; update=update_registry)

    prepare_runner()
    pkgs = read_pkgs(pkg_names)

    prepare_julia.(julia_versions)
    run(julia_versions, pkgs; kwargs...)
end
