export evaluate

using Dates
using Random
using DataFrames: DataFrame, nrow, combine, groupby
using ProgressMeter: Progress, update!, next!, finish!, durationstring
using Base.Threads: @threads

const statusses = Dict(
    :ok     => "successful",
    :skip   => "skipped",
    :fail   => "unsuccessful",
    :kill   => "interrupted",
    :crash  => "crashed",
)

function status_message(status)
    return statusses[status]
end

# NOTE: within each status group, reasons are sorted in order of reporting priority
const reasons = [
    missing                 => missing,
    # crash
    :abort                  => "the process was aborted",
    :internal               => "an internal error was encountered",
    :unreachable            => "an unreachable instruction was executed",
    :gc_corruption          => "GC corruption was detected",
    :segfault               => "a segmentation fault happened",
    # fail
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
    # skip
    :unsupported            => "package is not supported by this Julia version",
    :jll                    => "package is a untestable wrapper package",
    :explicit               => "package was blacklisted",
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
    isdir("/proc/$pid/task") || return Int[]
    pids = Int[]
    for tid in readdir("/proc/$pid/task")
        path = "/proc/$pid/task/$tid/children"
        if ispath(path)
            children = read("/proc/$pid/task/$tid/children", String)
            append!(pids, parse.(Int, split(children)))
        end
    end
    return pids
end

function cpu_time(pid)
    isfile("/proc/$pid/stat") || return missing
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
        # package hacks
        "PYTHON" => "",
        "R_HOME" => "*"
    ))
    if haskey(ENV, "JULIA_PKG_SERVER")
        env["JULIA_PKG_SERVER"] = ENV["JULIA_PKG_SERVER"]
    end

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
                    ccall(:uv_kill, Cint, (Cint, Cint), pid, sig)
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
        current_cpu_time === missing && return
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

    return status, reason, log, t1 - t0
end

"""
    evaluate_test(config::Configuration, pkg; use_cache=true, kwargs...)

Run the unit tests for a single package `pkg` inside of a sandbox according to `config`.
The `use_cache` argument determines whether the package can use the caches shared across
jobs (which may be a cause of issues).

Refer to `evaluate_script`[@ref] for more possible `keyword arguments.
"""
function evaluate_test(config::Configuration, pkg::Package; use_cache::Bool=true, kwargs...)
    # at this point, we need to know the UUID of the package
    if pkg.uuid === nothing
        pkg′ = get_packages(config)[pkg.name]
        pkg = Package(pkg; pkg′.uuid)
    end

    if config.compiled
        return evaluate_compiled_test(config, pkg; use_cache, kwargs...)
    end

    # we create our own executor so that we can reuse it (this assumes that the
    # SandboxConfig will have persist=true; maybe this should be a kwarg too?)
    executor = UnprivilegedUserNamespacesExecutor()

    common_script = raw"""
        using Dates
        elapsed(t) = "$(round(time() - t; digits=2))s"

        using Pkg
        using Base: UUID, PkgId
        package_spec = eval(Meta.parse(ARGS[1]))
    """

    script = "begin\n" * common_script * raw"""
        print('#'^80, "\n# PkgEval set-up\n#\n\n")
        println("Started at ", now(UTC), "\n")
        t0 = time()

        using InteractiveUtils
        versioninfo()

        println("\nSet-up completed after $(elapsed(t0))")


        # check if we even need to install the package
        # (it might be available in the system image already)
        package_id = PkgId(package_spec.uuid, package_spec.name)
        if !Base.root_module_exists(package_id)
            print("\n\n", '#'^80, "\n# Installation\n#\n\n")
            println("Started at ", now(UTC), "\n")
            t1 = time()

            Pkg.add(; package_spec...)

            println("\nInstallation completed after $(elapsed(t1))")
        end


        print("\n\n", '#'^80, "\n# Testing\n#\n\n")
        println("Started at ", now(UTC), "\n")

        bugreporting = get(ENV, "PKGEVAL_RR", "false") == "true"
        if bugreporting
            println("Tests will be executed under rr.\n")
        end

        t2 = time()
        try
            if bugreporting
                Pkg.test(package_spec.name; julia_args=`--bug-report=rr-local`)
            else
                Pkg.test(package_spec.name)
            end

            println("\nTesting completed after $(elapsed(t2))")
        catch err
            println("\nTesting failed after $(elapsed(t2))")
            showerror(stdout, err)
            Base.show_backtrace(stdout, catch_backtrace())
            println()

            exit(1)
        end""" * "\nend"

    args = `$(repr(package_spec_tuple(pkg)))`

    mounts = Dict{String,String}()
    env = Dict{String,String}()

    # caches are mutable, so they can get corrupted during a run. that's why it's possible
    # to run without them (in case of a retry), and is also why we set them up here rather
    # than in `sandboxed_julia` (because we know we've verified caches before enterint here)
    if use_cache
        # we can split the compile cache in a global and local part, copying over changes
        # after the test completes to avoid races.
        shared_compilecache = get_compilecache(config)
        local_compilecache = mktempdir()
        mounts["/usr/local/share/julia/compiled:ro"] = shared_compilecache
        mounts[joinpath(config.home, ".julia", "compiled")*":rw"] = local_compilecache

        # in principle, we'd have to do this too for the package cache, but because the
        # compilecache header contains full paths we can't ever move packages from the
        # local to the global cache. instead, we verify the package cache before retrying.
        packages = joinpath(storage_dir, "packages")
        mounts[joinpath(config.home, ".julia", "packages")*":rw"] = packages

        # for consistency, we do the same for artifacts (although we could split that cache).
        artifacts = joinpath(storage_dir, "artifacts")
        mounts[joinpath(config.home, ".julia", "artifacts")*":rw"] = artifacts
    end

    # TODO: perform the status/reason analysis here
    status, reason, log, elapsed = if config.rr
        # extend the timeout to account for the rr record overhead
        rr_config = Configuration(config; time_limit=config.time_limit*2)

        rr_env = merge(env, Dict("PKGEVAL_RR" => "true"))
        evaluate_script(rr_config, script, args; mounts, env=rr_env, executor, kwargs...)
    else
        evaluate_script(config, script, args; mounts, env, executor, kwargs...)
    end
    elapsed_str = "$(round(elapsed; digits=2))s"

    log *= "\n\n$('#'^80)\n# PkgEval teardown\n#\n\n"
    log *= "Started at $(now(UTC))\n\n"

    if use_cache
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
    end

    # log the status and determine a more accurate reason from the log
    @assert status in [:ok, :fail, :kill]
    ## crashes so bad we override the status
    if status !== :kill
        # ... but not in the case of a kill, as a badly-timed signal may cause crashes
        if occursin("GC error (probable corruption)", log)
            status = :crash
            reason = :gc_corruption
        elseif occursin(r"signal \(.+\): Segmentation fault", log)
            status = :crash
            reason = :segfault
        elseif occursin(r"signal \(.+\): Abort", log)
            status = :crash
            reason = :abort
        elseif occursin("Unreachable reached", log)
            status = :crash
            reason = :unreachable
        elseif occursin("Internal error: encountered unexpected error in runtime", log) ||
            occursin("Internal error: stack overflow in type inference", log) ||
            occursin("Internal error: encountered unexpected error during compilation", log)
            status = :crash
            reason = :internal
        end
    end
    ## others we only look for when the test failed
    if status === :fail
        log *= "PkgEval failed after $elapsed_str"

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
    elseif status === :kill
        log *= "PkgEval terminated after $elapsed_str"
    elseif status === :crash
        log *= "PkgEval crashed after $elapsed_str"
    elseif status === :ok
        log *= "PkgEval succeeded after $elapsed_str"
    end
    if reason !== missing
        log *= ": " * reason_message(reason)
    end
    log *= "\n"

    # pick up the installed package version from the log
    version_match = match(Regex("\\+ $(pkg.name) v(\\S+)"), log)
    version = if version_match !== nothing
        try
            VersionNumber(version_match.captures[1])
        catch
            @error "Could not parse installed package version number '$(version_match.captures[1])'"
            missing
        end
    else
        missing
    end

    # pick up the test duration from the log
    duration_match = match(r"Testing (completed|failed) after (\S+)s", log)
    duration = if duration_match !== nothing
        try
            parse(Float64, duration_match.captures[2])
        catch
            @error "Could not parse test duration '$(duration_match.captures[2])'"
            0.0
        end
    else
        0.0
    end

    # pack-up our rr trace. this is expensive, so we only do it for failures.
    if config.rr && status == :crash
        rr_script = "begin\n" * common_script * raw"""
            print("\n\n", '#'^80, "\n# BugReporting post-processing\n#\n\n")
            println("Started at ", now(UTC), "\n")
            t3 = time()

            try
                # use a clean environment, or BugReporting's deps could
                # affect/be affected by the tested package's dependencies.
                Pkg.activate(; temp=true)
                Pkg.add(name="BugReporting", uuid="bcf9a6e7-4020-453c-b88e-690564246bb8")
                using BugReporting

                trace_dir = BugReporting.default_rr_trace_dir()
                trace = BugReporting.find_latest_trace(trace_dir)
                BugReporting.compress_trace(trace, "/traces/$(package_spec.name).tar.zst")
                println("\nBugReporting completed after $(elapsed(t3))")
            catch err
                println("\nBugReporting failed after $(elapsed(t3))")
                showerror(stdout, err)
                Base.show_backtrace(stdout, catch_backtrace())
                println()
            end""" * "\nend"

        trace_dir = mktempdir()
        trace_file = joinpath(trace_dir, "$(pkg.name).tar.zst")
        rr_mounts = merge(mounts, Dict("/traces:rw" => trace_dir))

        rr_config = Configuration(config; time_limit=config.time_limit*2)
        _, _, rr_log, _ = evaluate_script(rr_config, rr_script, args;
                                          mounts=rr_mounts, env, executor, kwargs...)

        # upload the trace
        # TODO: re-use BugReporting.jl
        if haskey(ENV, "PKGEVAL_RR_BUCKET")
            bucket = ENV["PKGEVAL_RR_BUCKET"]
            unixtime = round(Int, datetime2unix(now()))
            trace_unique_name = "$(pkg.name)-$(unixtime).tar.zst"
            if isfile(trace_file)
                run(`$(s5cmd()) --log error cp -acl public-read $trace_file s3://$(bucket)/$(trace_unique_name)`)
                rr_log *= "Uploaded rr trace to https://s3.amazonaws.com/$(bucket)/$(trace_unique_name)"
            else
                rr_log *= "Testing did not produce an rr trace."
            end
        else
            rr_log *= "Testing produced an rr trace, but PkgEval.jl was not configured to upload rr traces."
        end
        rm(trace_dir; recursive=true)

        # remove inaccurate rr errors (rr-debugger/rr/#3346)
        rr_log = replace(rr_log, r"\[ERROR .* Metadata of .* changed: .*\n" => "")
        log *= rr_log
    end

    cleanup(executor)

    return version, status, reason, duration, log
end

"""
    evaluate_compiled_test(config::Configuration, pkg::Package)

Run the unit tests for a single package `pkg` (see `evaluate_test`[@ref] for details and
a list of supported keyword arguments), after first having compiled a system image that
contains this package and its dependencies.

To find incompatibilities, the compilation happens on an Ubuntu-based runner, while testing
is performed in an Arch Linux container.
"""
function evaluate_compiled_test(config::Configuration, pkg::Package;
                                use_cache::Bool=true, kwargs...)
    @assert !pkg.stdlib
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
        return missing, status, reason, 0.0, log
    end

    # run the tests in the regular environment
    test_config = Configuration(config;
        compiled = false,
        julia_args = `$(config.julia_args) --project=$project_path --sysimage $sysimage_path`,
    )
    version, status, reason, duration, test_log =
        evaluate_test(test_config, pkg; mounts, use_cache, kwargs...)

    rm(sysimage_dir; recursive=true)
    rm(project_dir; recursive=true)
    return version, status, reason, duration, log * "\n\n" * test_log
end

function verify_artifacts(artifacts)
    removals = []
    removals_lock = ReentrantLock()

    # collect directories we need to check
    jobs = []
    for entry in readdir(artifacts)
        path = joinpath(artifacts, entry)

        tree_hash = tryparse(Base.SHA1, entry)
        if tree_hash === nothing
            # remove directory entries that do not look like a valid artifact
            @debug "An invalid artifact was found: $entry"
            push!(removals, path)
        else
            push!(jobs, (path, tree_hash))
        end
    end

    # determine which ones need to be removed.
    # this is expensive, so use multiple threads.
    isinteractive() || println("Verifying artifacts...")
    p = Progress(length(jobs); desc="Verifying artifacts: ", enabled=isinteractive())
    @threads for (path, tree_hash) in jobs
        if tree_hash != Base.SHA1(Pkg.GitTools.tree_hash(path))
            # remove corrupt artifacts
            @debug "A broken artifact was found: $entry"
            lock(removals_lock) do
                push!(removals, path)
            end
        end

        next!(p)
    end

    # remove the directories
    for path in removals
        try
            rm(path; recursive=true)
        catch err
            @error "Failed to remove $path" exception=(err, catch_backtrace())
        end
    end
end

function remove_uncacheable_packages(registry, packages)
    # collect directories we need to check
    jobs = []
    registry_instance = Pkg.Registry.RegistryInstance(registry)
    for (_, pkg) in registry_instance
        pkginfo = Registry.registry_info(pkg)
        for (v, vinfo) in pkginfo.version_info
            tree_hash = vinfo.git_tree_sha1
            for slug in (Base.version_slug(pkg.uuid, tree_hash),
                         Base.version_slug(pkg.uuid, tree_hash, 4))
                path = joinpath(packages, pkg.name, slug)
                ispath(path) || continue
                push!(jobs, (path, pkg.name, tree_hash))
            end
        end
    end

    # determine which ones need to be removed.
    # this is expensive, so use multiple threads.
    removals = []
    removals_lock = ReentrantLock()
    isinteractive() || println("Verifying packages...")
    p = Progress(length(jobs); desc="Verifying packages: ", enabled=isinteractive())
    @threads for (path, name, tree_hash) in jobs
        remove = false

        if ispath(joinpath(path, "deps", "build.jl"))
            # we cannot cache packages that have a build script,
            # because that would result in the build script not being run.
            @debug "Package $(name) has a build script, and cannot be cached"
            remove = true
        elseif Base.SHA1(Pkg.GitTools.tree_hash(path)) != tree_hash
            # the contents of the package should match what's in the registry,
            # so that we don't cache broken checkouts or other weirdness.
            @debug "Package $(name) has been modified, and cannot be cached"
            remove = true
        end

        if remove
            lock(removals_lock) do
                push!(removals, path)
            end
        end

        next!(p)
    end

    # remove the directories
    for path in removals
        try
            rm(path; recursive=true)
        catch err
            @error "Failed to remove $path" exception=(err, catch_backtrace())
        end
    end
end

"""
    evaluate(configs::Vector{Configuration}, [packages::Vector{Package}];
             ninstances=Sys.CPU_THREADS, retry::Bool=true, validate::Bool=true, kwargs...)

Run tests for `packages` using `configs`. If no packages are specified, default to testing
all packages in the configured registry. The configurations can be specified as an array, or
as a dictionary where the key can be used to name the configuration (and more easily
identify it in the output dataframe).

The `ninstances` keyword argument determines how many packages are tested in parallel;
`retry` determines whether packages that did not fail on all configurations are retries;
`validate` enables validation of artifact and package caches before running tests.

Refer to `evaluate_test`[@ref] and `sandboxed_julia`[@ref] for more possible keyword
arguments.
"""
function evaluate(configs::Vector{Configuration}, packages::Vector{Package}=Package[];
                  ninstances::Integer=Sys.CPU_THREADS, retry::Bool=true, validate::Bool=true)
    if isempty(packages)
        registry_configs = unique(config->config.registry, values(configs))
        packages = intersect(map(get_packages, registry_configs)...)
    end

    # ensure the configurations have unique names
    config_names = map(config->config.name, configs) |> unique
    if length(config_names) != length(configs)
        error("Configurations must have unique names; got $(length(configs)) configurations, but only $(length(config_names)) name(s): $(join(config_names, ", "))")
    end

    # validate the package and artifact caches (which persist across evaluations)
    if validate
        registry_dir = get_registry(first(values(configs)))
        package_dir = joinpath(storage_dir, "packages")
        remove_uncacheable_packages(registry_dir, package_dir)
        artifact_dir = joinpath(storage_dir, "artifacts")
        verify_artifacts(artifact_dir)
    end

    # determine the jobs to run
    jobs = Job[]
    for config in configs, package in values(packages)
        push!(jobs, Job(config, package, true))
    end
    ## use a random test order to (hopefully) get a more reasonable ETA
    shuffle!(jobs)

    result = DataFrame(configuration = String[],
                       package = String[],
                       version = Union{Missing,VersionNumber}[],
                       status = Symbol[],
                       reason = Union{Missing,Symbol}[],
                       duration = Float64[],
                       log = Union{Missing,String}[])

    # pre-filter the jobs for packages we'll skip to get a better ETA
    skips = similar(result)
    jobs = filter(jobs) do job
        if job.package.name in skip_list
            push!(skips, [job.config.name, job.package.name, missing,
                          :skip, :explicit, 0, missing])
            return false
        elseif endswith(job.package.name, "_jll")
            push!(skips, [job.config.name, job.package.name, missing,
                          :skip, :jll, 0, missing])
            return false
        else
            return true
        end
    end

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

    p = Progress(njobs; desc="Running tests: ", enabled=isinteractive())
    try @sync begin
        # Workers
        for i = 1:ninstances
            push!(all_workers, @async begin
                try
                    while !isempty(jobs) && !done
                        job = pop!(jobs)
                        times[i] = now()
                        running[i] = (job.config.name, job.package)

                        # test the package
                        config′ = Configuration(job.config; cpus=[i-1])
                        pkg_version, status, reason, duration, log =
                            evaluate_test(config′, job.package; job.use_cache)

                        push!(result, [job.config.name, job.package.name,
                                       pkg_version, status, reason, duration, log])
                        running[i] = nothing

                        if retry
                            # if we're done testing this package, consider retrying failures
                            package_results = result[result.package .== job.package.name, :]
                            nrow(package_results) == length(configs) || continue
                            # NOTE: this check also prevents retrying multiple times

                            failures = filter(package_results) do row
                                row.status in [:fail, :kill, :crash]
                            end
                            if length(configs) == 1 || nrow(failures) != length(configs)
                                for row in eachrow(failures)
                                    # retry the failed job in a pristine environment
                                    config = configs[findfirst(config->config.name == row.configuration, configs)]
                                    config′ = if row.status !== :crash
                                        # if the package failed, retry without rr, as it
                                        # may have caused the failure. this is a bit of a
                                        # hack, but improves retry reliability a lot.
                                        Configuration(config; rr=false)
                                    else
                                        # however, do not disable rr if the failure involved
                                        # a crash, for which rr traces are very important.
                                        config
                                    end
                                    push!(jobs, Job(config′, job.package, false))
                                end

                                # XXX: this needs a proper API in ProgressMeter.jl
                                #      (maybe an additional argument to `update!`)
                                njobs += nrow(failures)
                                p.n = njobs
                            end
                        end
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
                start = time()
                sleep_time = 1
                while (!isempty(jobs) || !all(==(nothing), running)) && !done
                    if isinteractive()
                        function showvalues()
                            # known statuses
                            # NOTE: we filtered skips, so don't need to report them here
                            o = count(==(:ok),      result[!, :status])
                            f = count(==(:fail),    result[!, :status])
                            c = count(==(:crash),   result[!, :status])
                            k = count(==(:kill),    result[!, :status])

                            [(:success, o), (:failed, f), (:crashed, c), (:killed, k)]
                        end
                        update!(p, nrow(result); showvalues)
                        sleep(sleep_time)
                    else
                        remaining_jobs = njobs - nrow(result)   # `jobs` doesn't include running
                        print("Running tests: $remaining_jobs remaining")

                        elapsed_time = time() - start
                        est_total_time = njobs * elapsed_time / nrow(result)
                        if 0 <= est_total_time <= typemax(Int)
                            eta_sec = round(Int, est_total_time - elapsed_time )
                            eta = durationstring(eta_sec)
                            print(" (ETA: $eta)")
                        end

                        println()
                        sleep(sleep_time)

                        # don't flood the logs
                        if sleep_time < 300
                            sleep_time *= 1.5
                        end
                    end
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
        finish!(p)
    end

    # remove duplicates from retrying, keeping only the last result
    nresults = nrow(result)
    result = combine(groupby(result, [:configuration, :package]), last)
    if nrow(result) != nresults
        println("Removed $(nresults - nrow(result)) duplicate evaluations that resulted from retrying tests.")
    end

    append!(result, skips)
    return result
end
