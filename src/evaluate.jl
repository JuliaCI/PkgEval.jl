export evaluate

using Dates
using Random
using DataFrames: DataFrame, nrow
using ProgressMeter: Progress, update!

const statusses = Dict(
    :ok     => "successful",
    :skip   => "skipped",
    :fail   => "unsuccessful",
    :kill   => "interrupted",
)

function status_message(status)
    return statusses[status]
end

# NOTE: within each status group, reasons are sorted in order of reporting priority
const reasons = [
    missing                 => missing,
    # skip
    :unsupported            => "package is not supported by this Julia version",
    :jll                    => "package is a untestable wrapper package",
    :explicit               => "package was blacklisted",
    # fail
    :abort                  => "the process was aborted",
    :internal               => "an internal error was encountered",
    :unreachable            => "an unreachable instruction was executed",
    :gc_corruption          => "GC corruption was detected",
    :segfault               => "a segmentation fault happened",
    :syntax                 => "package has syntax issues",
    :uncompilable           => "compilation of the package failed",
    :test_failures          => "package has test failures",
    :untestable             => "package does not have any tests",
    :unsatisfiable          => "package could not be installed",
    :binary_dependency      => "package requires a missing binary dependency",
    :missing_dependency     => "package is missing a package dependency",
    :missing_package        => "package is using an unknown package",
    :network                => "networking-related issues were detected",
    :unknown                => "there were unidentified errors",
    # kill
    :inactivity             => "tests became inactive",
    :time_limit             => "test duration exceeded the time limit",
    :log_limit              => "test log exceeded the size limit",
]

function reason_message(reason)
    i = findfirst(x -> x[1] === reason, reasons)
    if i === nothing
        return "unknown reason"
    else
        return reasons[i][2]
    end
end

function reason_severity(reason)
    i = findfirst(x -> x[1] === reason, reasons)
    return something(i, typemax(Int))
end

const compiled_lock = ReentrantLock()
const compiled_cache = Dict()
function get_compilecache(config::Configuration)
    lock(compiled_lock) do
        key = (config.julia, config.buildflags,
               config.rootfs, config.uid, config.user, config.gid, config.group, config.home)
        dir = get(compiled_cache, key, nothing)
        if dir === nothing || !isdir(dir)
            compiled_cache[key] = mktempdir()
        end
        return compiled_cache[key]
    end
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
    evaluate_script(config::Configuration, script::String, args=``)

Run a Julia script `script` in non-interactive mode, returning the process status and a
failure reason if any (both represented by a symbol), and the full log.

Refer to `sandboxed_julia`[@ref] for more possible `keyword arguments.
"""
function evaluate_script(config::Configuration, script::String, args=``;
                         env::Dict{String,String}=Dict{String,String}(),
                         mounts::Dict{String,String}=Dict{String,String}(), kwargs...)
    @assert config.log_limit > 0

    env = merge(env, Dict(
        # we're likely running many instances, so avoid overusing the CPU
        "JULIA_PKG_PRECOMPILE_AUTO" => "0",

        # package hacks
        "PYTHON" => "",
        "R_HOME" => "*"
    ))
    if haskey(ENV, "JULIA_PKG_SERVER")
        env["JULIA_PKG_SERVER"] = ENV["JULIA_PKG_SERVER"]
    end

    # set-up a compile cache. because we may be running many instances, mount the
    # shared cache read-only, and synchronize entries after we finish the script.
    #
    # in principle, we'd have to do this too for the package cache, but because the
    # compilecache header contains full paths we can't ever move packages from the
    # local to the global cache. instead, we verify the package cache before retrying.
    # for consistency, we do the same for artifacts (although we could split that cache).
    shared_compilecache = get_compilecache(config)
    local_compilecache = mktempdir()
    mounts = merge(mounts, Dict(
        "/usr/local/share/julia/compiled:ro"                => shared_compilecache,
        joinpath(config.home, ".julia", "compiled")*":rw"   => local_compilecache
    ))

    t0 = time()
    input = Pipe()
    output = Pipe()
    proc = sandboxed_julia(config,`--eval 'eval(Meta.parse(read(stdin,String)))' $args`;
                           wait=false, stdout=output, stderr=output, stdin=input,
                           env, mounts, kwargs...)
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
    t1 = time()

    # if we didn't kill the process, figure out the status from the exit code
    if status === nothing
        if success(proc)
            status = :ok
        else
            status = :fail
        end
    end

    if sizeof(log) > config.log_limit
        # even though the monitor above should have limited the log size,
        # a single line may still have exceeded the limit, so make sure we truncate.
        ind = prevind(log, config.log_limit)
        log = log[1:ind]
    end

    # copy new files from the local compilecache into the shared one
    function copy_files(subpath=""; src, dst)
        for entry in readdir(joinpath(src, subpath))
            path = joinpath(subpath, entry)
            srcpath = joinpath(src, path)
            dstpath = joinpath(dst, path)

            if isdir(srcpath)
                isdir(dstpath) || mkdir(joinpath(dst, path))
                copy_files(path; src, dst)
            elseif !ispath(dstpath)
                cp(srcpath, dstpath)
            end
        end
    end
    copy_files(src=local_compilecache, dst=shared_compilecache)
    rm(local_compilecache; recursive=true)

    return status, reason, log, t1 - t0
end

"""
    evaluate_test(config::Configuration, pkg; kwargs...)

Run the unit tests for a single package `pkg` inside of a sandbox according to `config`.

Refer to `evaluate_script`[@ref] for more possible `keyword arguments.
"""
function evaluate_test(config::Configuration, pkg::Package; kwargs...)
    if config.compiled
        return evaluate_compiled_test(config, pkg; kwargs...)
    end

    script = raw"""
        begin
            using Dates
            elapsed(t) = "$(round(time() - t; digits=2))s"

            print('#'^80, "\n# PkgEval set-up\n#\n\n")
            println("Started at ", now(UTC), "\n")
            t0 = time()

            using InteractiveUtils
            versioninfo()

            using Pkg
            using Base: UUID, PkgId
            package_spec = eval(Meta.parse(ARGS[1]))

            bugreporting = get(ENV, "PKGEVAL_RR", "false") == "true" &&
                           package_spec.name != "BugReporting"

            println("\nCompleted after $(elapsed(t0))")


            # check if we even need to install the package
            # (it might be available in the system image already)
            package_id = PkgId(package_spec.uuid, package_spec.name)
            if !Base.root_module_exists(package_id)
                print("\n\n", '#'^80, "\n# Installation\n#\n\n")
                println("Started at ", now(UTC), "\n")
                t1 = time()

                Pkg.add(; package_spec...)

                println("\nCompleted after $(elapsed(t1))")
            end


            print("\n\n", '#'^80, "\n# Testing\n#\n\n")
            println("Started at ", now(UTC), "\n")
            t2 = time()
            try
                if bugreporting
                    Pkg.test(package_spec.name; julia_args=`--bug-report=rr-local`)
                else
                    Pkg.test(package_spec.name)
                end

                println("\nCompleted after $(elapsed(t2))")
            catch err
                print("\nFAILED: ")
                showerror(stdout, err)
                Base.show_backtrace(stdout, catch_backtrace())
                println()

                if bugreporting
                    print("\n\n", '#'^80, "\n# BugReporting post-processing\n#\n\n")
                    println("Started at ", now(UTC), "\n")
                    t3 = time()

                    # pack-up our rr trace. this is expensive, so we only do it for failures.
                    try
                        # use a clean environment, or BugReporting's deps could
                        # affect/be affected by the tested package's dependencies.
                        Pkg.activate(; temp=true)
                        Pkg.add(name="BugReporting", uuid="bcf9a6e7-4020-453c-b88e-690564246bb8")
                        using BugReporting

                        trace_dir = BugReporting.default_rr_trace_dir()
                        trace = BugReporting.find_latest_trace(trace_dir)
                        BugReporting.compress_trace(trace, "/traces/$(package_spec.name).tar.zst")
                        println("\nCompleted after $(elapsed(t3))")
                    catch err
                        print("\nFAILED: ")
                        showerror(stdout, err)
                        Base.show_backtrace(stdout, catch_backtrace())
                        println()
                    end
                end

                exit(1)
            end
        end"""

    args = `$(repr(package_spec_tuple(pkg)))`
    if config.depwarn
        args = `--depwarn=error $args`
    end

    mounts = Dict{String,String}()
    env = Dict{String,String}()

    status, reason, log, elapsed = if config.rr
        trace_dir = mktempdir()
        trace_file = joinpath(trace_dir, "$(pkg.name).tar.zst")
        mounts["/traces:rw"] = trace_dir
        env["PKGEVAL_RR"] = "true"
        haskey(ENV, "PKGEVAL_RR_BUCKET") ||
            @warn maxlog=1 "PKGEVAL_RR_BUCKET not set; will not be uploading rr traces"

        # extend the timeout to account for the rr record overhead
        rr_config = Configuration(config; time_limit=config.time_limit*2)
        evaluate_script(rr_config, script, args; mounts, env, kwargs...)
    else
        evaluate_script(config, script, args; mounts, env, kwargs...)
    end
    elapsed_str = "$(round(elapsed; digits=2))s"

    log *= "\n\n$('#'^80)\n# PkgEval teardown\n#\n\n"
    log *= "Started at $(now(UTC))\n\n"

    # log the status and determine a more accurate reason from the log
    @assert status in [:ok, :fail, :kill]
    ## some errors are so bad we should disregard the status
    override_reason = if occursin("GC error (probable corruption)", log)
        :gc_corruption
    elseif occursin("signal (11): Segmentation fault", log)
        :segfault
    elseif occursin("signal (6): Abort", log)
        :abort
    elseif occursin("Unreachable reached", log)
        :unreachable
    elseif occursin("Internal error: encountered unexpected error in runtime", log) ||
           occursin("Internal error: stack overflow in type inference", log) ||
           occursin("Internal error: encountered unexpected error during compilation", log)
        :internal
    else
        nothing
    end
    ## others we only look for when the test failed
    if status === :fail
        log *= "PkgEval failed after $elapsed_str\n"

        reason = if override_reason !== nothing
            override_reason
        elseif occursin("Unsatisfiable requirements detected for package", log)
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
        elseif occursin("failed to clone from", log) ||
                occursin(r"HTTP/\d \d+ while requesting", log) ||
                occursin("Could not resolve host", log) ||
                occursin("Resolving timed out after", log) ||
                occursin("Could not download", log) ||
                occursin(r"Error: HTTP/\d \d+", log) ||
                occursin("Temporary failure in name resolution", log)
            :network
        elseif occursin("ERROR: LoadError: syntax", log)
            :syntax
        elseif occursin("Some tests did not pass", log) || occursin("Test Failed", log)
            :test_failures
        else
            :unknown
        end
    elseif override_reason !== nothing
        log *= "PkgEval succeeded after $elapsed_str, but the test output contains suspicious errors\n"
        status = :fail
        reason = override_reason
    elseif status === :kill
        log *= "PkgEval terminated after $elapsed_str"
        if reason !== nothing
            log *= ": " * reason_message(reason)
        end
        log *= "\n"
    elseif status === :ok
        log *= "PkgEval succeeded after $elapsed_str\n"
    end

    # pick up the installed package version from the log
    version_match = match(Regex("\\+ $(pkg.name) v(\\S+)"), log)
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

    if config.rr
        # upload an rr trace for interesting failures
        # TODO: re-use BugReporting.jl
        if status == :fail && reason in [:gc_corruption, :segfault, :abort, :unreachable, :internal] &&
           haskey(ENV, "PKGEVAL_RR_BUCKET")
            bucket = ENV["PKGEVAL_RR_BUCKET"]
            unixtime = round(Int, datetime2unix(now()))
            trace_unique_name = "$(pkg.name)-$(unixtime).tar.zst"
            if isfile(trace_file)
                run(`$(s5cmd()) --log error cp -acl public-read $trace_file s3://$(bucket)/$(trace_unique_name)`)
                log *= "Uploaded rr trace to https://s3.amazonaws.com/$(bucket)/$(trace_unique_name)"
            else
                log *= "Testing did not produce an rr trace."
            end
        end
        rm(trace_dir; recursive=true)
    end

    return version, status, reason, log
end

"""
    evaluate_compiled_test(config::Configuration, pkg::Package)

Run the unit tests for a single package `pkg` (see `evaluate_test`[@ref] for details and
a list of supported keyword arguments), after first having compiled a system image that
contains this package and its dependencies.

To find incompatibilities, the compilation happens on an Ubuntu-based runner, while testing
is performed in an Arch Linux container.
"""
function evaluate_compiled_test(config::Configuration, pkg::Package; kwargs...)
    script = raw"""
        begin
            using Dates
            elapsed(t) = "$(round(time() - t; digits=2))s"

            print('#'^80, "\n# PackageCompiler set-up\n#\n\n")
            println("Started at ", now(UTC), "\n")
            t0 = time()

            using InteractiveUtils
            versioninfo()
            println()

            using Pkg
            using Base: UUID
            package_spec = eval(Meta.parse(ARGS[1]))

            println("Installing PackageCompiler...")
            project = Base.active_project()
            Pkg.activate(; temp=true)
            Pkg.add(name="PackageCompiler", uuid="9b87118b-4619-50d2-8e1e-99f35a4d4d9d")
            using PackageCompiler
            Pkg.activate(project)

            println("\nCompleted after $(elapsed(t0))")


            print("\n\n", '#'^80, "\n# Installation\n#\n\n")
            println("Started at ", now(UTC), "\n")
            t1 = time()

            Pkg.add(; package_spec...)

            println("\nCompleted after $(elapsed(t1))")


            print("\n\n", '#'^80, "\n# Compilation\n#\n\n")
            println("Started at ", now(UTC), "\n")
            t2 = time()

            create_sysimage([package_spec.name]; sysimage_path=ARGS[2])
            s = stat(ARGS[2]).size

            println("\nCompleted after $(elapsed(t2))")
            println("Generated system image is ", Base.format_bytes(s))
        end"""

    sysimage_path = "/sysimage/sysimg.so"
    args = `$(repr(package_spec_tuple(pkg))) $sysimage_path`

    project_path="/project"
    project_dir = mktempdir()
    sysimage_dir = mktempdir()
    mounts = Dict(
        dirname(sysimage_path)*":rw"    => sysimage_dir,
        project_path*":rw"              => project_dir)

    compile_config = Configuration(config;
        julia_args = `$(config.julia_args) --project=$project_path`,
        time_limit = config.compile_time_limit,
        # don't record the compilation, only the test execution
        rr = false,
        # discover package relocatability issues by compiling in a different environment
        julia_install_dir="/usr/local/julia",
        rootfs="arch",
        user="user",
        group="group",
        home="/home/user",
        uid=2000,
        gid=2000,
    )

    status, reason, log, elapsed =
        evaluate_script(compile_config, script, args; mounts, kwargs...)
    elapsed_str = "$(round(elapsed; digits=2))s"

    log *= "\n\n$('#'^80)\n# PackageCompiler teardown\n#\n\n"
    log *= "Started at $(now(UTC))\n\n"

    # log the status and determine a more accurate reason from the log
    @assert status in [:ok, :fail, :kill]
    if status === :ok
        log *= "PackageCompiler succeeded after $elapsed_str\n"
    elseif status === :fail
        log *= "PackageCompiler failed after $elapsed_str\n"
        reason = :uncompilable
    elseif status === :kill
        log *= "PackageCompiler terminated after $elapsed_str"
        if reason !== nothing
            log *= ": " * reason_message(reason)
        end
        log *= "\n"
    end

    if status !== :ok
        rm(sysimage_dir; recursive=true)
        rm(project_dir; recursive=true)
        return missing, status, reason, log
    end

    # run the tests in the regular environment
    test_config = Configuration(config;
        compiled = false,
        julia_args = `$(config.julia_args) --project=$project_path --sysimage $sysimage_path`,
    )
    version, status, reason, test_log =
        evaluate_test(test_config, pkg; mounts, kwargs...)

    rm(sysimage_dir; recursive=true)
    rm(project_dir; recursive=true)
    return version, status, reason, log * "\n\n" * test_log
end

function verify_artifacts(artifacts)
    for entry in readdir(artifacts)
        path = joinpath(artifacts, entry)
        remove = false

        tree_hash = tryparse(Base.SHA1, entry)
        if tree_hash === nothing
            # remove directory entries that do not look like a valid artifact
            @warn "An invalid artifact was found: $entry"
            remove = true
        elseif tree_hash != Base.SHA1(Pkg.GitTools.tree_hash(path))
            # remove corrupt artifacts
            @warn "A broken artifact was found: $entry"
            remove = true
        end

        remove && rm(path; recursive=true)
    end
end

function remove_uncacheable_packages(registry, packages)
    registry_instance = Pkg.Registry.RegistryInstance(registry)
    for (_, pkg) in registry_instance
        pkginfo = Registry.registry_info(pkg)
        for (v, vinfo) in pkginfo.version_info
            tree_hash = vinfo.git_tree_sha1
            for slug in (Base.version_slug(pkg.uuid, tree_hash),
                         Base.version_slug(pkg.uuid, tree_hash, 4))
                path = joinpath(packages, pkg.name, slug)
                ispath(path) || continue
                remove = false

                if ispath(joinpath(path, "deps", "build.jl"))
                    # we cannot cache packages that have a build script,
                    # because that would result in the build script not being run.
                    @warn "Package $(pkg.name) has a build script, and cannot be cached"
                    remove = true
                elseif Base.SHA1(Pkg.GitTools.tree_hash(path)) != tree_hash
                    # the contents of the package should match what's in the registry,
                    # so that we don't cache broken checkouts or other weirdness.
                    @warn "Package $(pkg.name) has been modified, and cannot be cached"
                    remove = true
                end

                if remove
                    rm(path; recursive=true)
                end
            end
        end
    end
end

"""
    evaluate(configs::Vector{Configuration}, [packages::Vector{Package}];
             ninstances=Sys.CPU_THREADS, kwargs...)
    evaluate(configs::Dict{String,Configuration}, [packages::Vector{Package}];
             ninstances=Sys.CPU_THREADS, kwargs...)

Run tests for `packages` using `configs`. If no packages are specified, default to testing
all packages in the configured registry. The configurations can be specified as an array,
or as a dictionary where the key can be used to name the configuration (and more easily
identify it in the output dataframe).

The `ninstances` keyword argument determines how many packages are tested in parallel.
Refer to `evaluate_test`[@ref] and `sandboxed_julia`[@ref] for more possible
keyword arguments.
"""
function evaluate(configs::Dict{String,Configuration}, packages::Vector{Package}=Package[];
                  ninstances::Integer=Sys.CPU_THREADS, retry::Bool=true)
    if isempty(packages)
        registry_configs = unique(config->config.registry, values(configs))
        packages = intersect(map(registry_packages, registry_configs)...)
    end

    jobs = Any[]
    for (config_name, config) in configs, package in packages
        push!(jobs, (config_name, config, package))
    end
    # use a random test order to (hopefully) get a more reasonable ETA
    shuffle!(jobs)

    results = _evaluate(jobs)

    # validate the package and artifact caches (which persist across evaluations)
    registry_dir = get_registry(first(values(configs)))
    package_dir = joinpath(storage_dir, "packages")
    remove_uncacheable_packages(registry_dir, package_dir)
    artifact_dir = joinpath(storage_dir, "artifacts")
    verify_artifacts(artifact_dir)

    # if requested, retry failures
    if retry
        failed_results = filter(results) do row
            row.status == :fail || row.status == :kill
        end
        other_results = filter(results) do row
            row.status != :fail && row.status != :kill
        end

        # determine jobs to retry
        retry_jobs = Any[]
        for package in packages
            failures = failed_results[failed_results.package .== package.name, :]
            isempty(failures) && continue

            # in case of a single config, we have nothing to compare again, so retry all
            # failures. if we have multiple configs, only retry failures that didn't
            # occur on all configurations.
            if length(configs) == 1 || nrow(failures) != length(configs)
                for row in eachrow(failures)
                    push!(retry_jobs, (row.configuration, configs[row.configuration], package))
                end
            else
                # don't lose track of this failure
                append!(other_results, failures)
            end
        end

        # retry and merge results
        if length(retry_jobs) > 0
            println("\nRetrying $(length(retry_jobs)) failed jobs...")
            retry_results = _evaluate(retry_jobs)
            results = vcat(other_results, retry_results)
        end
    end

    return results
end

function _evaluate(jobs; ninstances::Integer=Sys.CPU_THREADS)
    # here we deal with managing execution: spawning workers, output, result I/O, etc

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
                    config_name, pkg = job
                    " #$i: $(pkg.name) @ $(config_name) ($(runtimestr(times[i])))"
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

    result = DataFrame(configuration = String[],
                       package = String[],
                       version = Union{Missing,VersionNumber}[],
                       status = Symbol[],
                       reason = Union{Missing,Symbol}[],
                       duration = Float64[],
                       log = Union{Missing,String}[])

    try @sync begin
        # Workers
        for i = 1:ninstances
            push!(all_workers, @async begin
                try
                    while !isempty(jobs) && !done
                        config_name, config, pkg = pop!(jobs)
                        times[i] = now()
                        running[i] = (config_name, pkg)

                        # should we even test this package?
                        if pkg.name in skip_list
                            push!(result, [config_name, pkg.name, missing,
                                           :skip, :explicit, 0, missing])
                            running[i] = nothing
                            continue
                        elseif endswith(pkg.name, "_jll")
                            push!(result, [config_name, pkg.name, missing,
                                           :skip, :jll, 0, missing])
                            running[i] = nothing
                            continue
                        end

                        # test the package
                        config′ = Configuration(config; cpus=[i-1])
                        pkg_version, status, reason, log = evaluate_test(config′, pkg)

                        duration = (now()-times[i]) / Millisecond(1000)
                        push!(result, [config_name, pkg.name, pkg_version,
                                       status, reason, duration, log])
                        running[i] = nothing
                    end
                catch err
                    stop_work()
                    isa(err, InterruptException) || rethrow(err)
                end
            end)
        end

        # Printer
        @async begin
            try
                while (!isempty(jobs) || !all(==(nothing), running)) && !done
                    update_output()
                end
            catch err
                isa(err, InterruptException) || rethrow(err)
            finally
                stop_work()
            end
        end
    end
    catch err
        # XXX: why doesn't it suffice just catching the the InterruptException
        #      (unwrapped from CompositeException) here?
        isa(err, InterruptException) || rethrow(err)
    finally
        stop_work()
        println()
    end

    return result
end

function evaluate(configs::Vector{Configuration}, args...; kwargs...)
    config_dict = Dict{String,Configuration}()
    for (i,config) in enumerate(configs)
        config_dict["config_$i"] = config
    end
    evaluate(config_dict, args...; kwargs...)
end
