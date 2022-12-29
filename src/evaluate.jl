export evaluate

using Dates
using Random
using DataFrames: DataFrame, nrow, combine, groupby
using ProgressMeter: Progress, update!, next!, finish!, durationstring
using Base.Threads: @threads
import REPL

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
    :untestable             => "package does not have any tests",
    :uninstallable          => "package could not be installed",
    :unsupported            => "package is not supported by this Julia version",
    :blacklisted            => "package was blacklisted",
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
            compiled_cache[key] = mktempdir(prefix="pkgeval_$(config.name)_compilecache_")
        end
        return compiled_cache[key]
    end
end

function effective_time_limit(config::Configuration)
    if config.rr
        # extend the timeout to account for the rr record overhead
        return config.time_limit[] * 2
    else
        return config.time_limit[]
    end
end

"""
    evaluate_script(config::Configuration, script::String, args=``)

Run a Julia script `script` in non-interactive mode, returning the process status and a
failure reason if any (both represented by a symbol), and the full log.

Refer to `sandboxed_julia`[@ref] for more possible `keyword arguments.
"""
function evaluate_script(config::Configuration, script::String, args=``;
                         env::Dict{String,String}=Dict{String,String}(),
                         mounts::Dict{String,String}=Dict{String,String}(),
                         echo::Bool=false, kwargs...)
    @assert config.log_limit > 0

    env = merge(env, Dict(
        # package hacks
        "PYTHON" => "",
        "R_HOME" => "*"
    ))
    if haskey(ENV, "JULIA_PKG_SERVER")
        env["JULIA_PKG_SERVER"] = ENV["JULIA_PKG_SERVER"]
    end

    input = Pipe()
    output = Pipe()
    args = `-e 'include_string(Main, read(stdin,String))' --color=no $args`
    proc = sandboxed_julia(config, args; stdout=output, stderr=output, stdin=input,
                           wait=false, env, mounts, kwargs...)
    close(output.in)

    # pass the script over standard input to avoid exceeding max command line size,
    # and keep the process listing somewhat clean
    println(input, script)
    close(input)

    function stop()
        if process_running(proc)
            # we need to be careful we don't end up killing only the sandbox process
            recursive_kill(proc, Base.SIGTERM)
            t = Timer(10) do timer
                recursive_kill(proc, Base.SIGKILL)
            end
            wait(proc)
            close(t)
        end
        close(output)
    end

    status = nothing
    reason = missing

    # kill on timeout
    timeout_monitor = Timer(effective_time_limit(config)) do timer
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
            line = readline(output; keep=true)
            echo && print(stdout, line)
            print(io, line)

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

    try
        wait(proc)
    catch err
        stop()
        isa(err, InterruptException) || rethrow()
        # this is a Julia-level interrupt, probably because of a CTRL-C.
        status = :kill
    end
    close(timeout_monitor)
    close(inactivity_monitor)
    log = fetch(log_monitor)

    # if we didn't kill the process, figure out the status from the exit code
    if status === nothing
        if success(proc)
            status = :ok
        elseif proc.exitcode == 134 # SIGABRT
            status = :crash
            reason = :abort
        elseif proc.exitcode == 139 # SIGSEGV
            status = :crash
            reason = :segfault
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

    return (; log, status, reason)
end

const common_script = raw"""
    # simplified version of cpu_time in utils.jl (doesn't need to
    # scan for children, as we use this from the parent when idle)
    function cpu_time()
        stats = read("/proc/self/stat", String)

        m = match(r"^(\d+) \((.+)\) (.+)", stats)
        @assert m !== nothing "Invalid contents for /proc/self/stat: $stats"
        fields = [[m.captures[1], m.captures[2]]; split(m.captures[3])]
        utime = parse(Int, fields[14])
        stime = parse(Int, fields[15])
        cutime = parse(Int, fields[16])
        cstime = parse(Int, fields[17])

        return (utime + stime + cutime + cstime) / Sys.SC_CLK_TCK
    end

    using Dates
    elapsed(t) = "$(round(cpu_time() - t; digits=2))s"
"""

"""
    evaluate_test(config::Configuration, pkg; use_cache=true, kwargs...)

Run the unit tests for a single package `pkg` inside of a sandbox according to `config`.
The `use_cache` argument determines whether the package can use the caches shared across
jobs (which may be a cause of issues).

Refer to `evaluate_script`[@ref] for more possible `keyword arguments.
"""
function evaluate_test(config::Configuration, pkg::Package; use_cache::Bool=true,
                       mounts::Dict{String,String}=Dict{String,String}(),
                       env::Dict{String,String}=Dict{String,String}(), kwargs...)
    mounts = copy(mounts)
    env = copy(env)

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

    # caches are mutable, so they can get corrupted during a run. that's why it's possible
    # to run without them (in case of a retry), and is also why we set them up here rather
    # than in `sandboxed_julia` (because we know we've verified caches before enterint here)
    if use_cache
        # we can split the compile cache in a global and local part, copying over changes
        # after the test completes to avoid races.
        shared_compilecache = get_compilecache(config)
        local_compilecache = mktempdir(prefix="pkgeval_$(pkg.name)_compilecache_")
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

    # structured output will be written to the /output directory. this is to avoid having to
    # parse log output, which is fragile. a simple pipe would be sufficient, but Julia
    # doesn't export those, and named pipes aren't portable to all platforms.
    output_dir = mktempdir(prefix="pkgeval_$(pkg.name)_output_")
    mounts["/output:rw"] = output_dir

    script = "begin\n" * common_script * raw"""
        using Pkg
        using Base: UUID
        package_spec = eval(Meta.parse(ARGS[1]))

        println("Package evaluation of $(package_spec.name) started at ", now(UTC))

        println()
        using InteractiveUtils
        versioninfo()


        print("\n\n", '#'^80, "\n# Installation\n#\n\n")

        t0 = cpu_time()
        try
            Pkg.add(; package_spec...)

            println("\nInstallation completed after $(elapsed(t0))")
            write("/output/installed", repr(true))
        catch
            println("\nInstallation failed after $(elapsed(t0))\n")
            write("/output/installed", repr(false))
            rethrow()
        finally
            # even if a package fails to install, it may have been resolved
            # (e.g., when the build phase errors)
            if haskey(Pkg.dependencies(), package_spec.uuid)
                version = Pkg.dependencies()[package_spec.uuid].version
                write("/output/version", repr(version))
            end
        end


        print("\n\n", '#'^80, "\n# Precompilation\n#\n\n")

        # we run with JULIA_PKG_PRECOMPILE_AUTO=0 to avoid precompiling on Pkg.add,
        # because we can't use the generated images for Pkg.test which uses different
        # options (i.e., --check-bounds=yes). however, to get accurate test timings,
        # we *should* precompile before running tests, so we do that here manually.

        t0 = cpu_time()
        try
            run(```$(Base.julia_cmd())
                   --check-bounds=yes
                   -e 'using Pkg
                       Pkg.activate(; temp=true)
                       Pkg.add("TestEnv")
                       using TestEnv
                       Pkg.activate()
                       TestEnv.activate(ARGS[1])
                       Pkg.precompile()' $(package_spec.name)```)

            println("\nPrecompilation completed after $(elapsed(t0))")
        catch
            println("\nPrecompilation failed after $(elapsed(t0))\n")
        end


        print("\n\n", '#'^80, "\n# Testing\n#\n\n")

        if haskey(Pkg.Types.stdlibs(), package_spec.uuid)
            println("\n$(package_spec.name) is a standard library in this Julia build.")

            # we currently only support testing the embedded version of stdlib packages
            if haskey(package_spec, :version) ||
               haskey(package_spec, :url) ||
               haskey(package_spec, :ref)
                error("Packages that are standard libraries can only be tested using the embedded version.")
            end
        end

        bugreporting = get(ENV, "PKGEVAL_RR", "false") == "true"
        if bugreporting
            println("Tests will be executed under rr.\n")
        end

        t0 = cpu_time()
        try
            if bugreporting
                Pkg.test(package_spec.name; julia_args=`--bug-report=rr-local`)
            else
                Pkg.test(package_spec.name)
            end

            println("\nTesting completed after $(elapsed(t0))")
        catch
            println("\nTesting failed after $(elapsed(t0))\n")
            rethrow()
        finally
            write("/output/duration", repr(cpu_time()-t0))
        end""" * "\nend"

    args = `$(repr(package_spec_tuple(pkg)))`

    if config.rr
        env["PKGEVAL_RR"] = "true"
    end

    (; log, status, reason) = evaluate_script(config, script, args;
                                              mounts, env, executor, kwargs...)
    log *= "\n"

    # parse structured output
    output = Dict()
    for (entry, type, default) in [("installed", Bool, false),
                                   ("version", Union{Nothing,VersionNumber}, missing),
                                   ("duration", Float64, 0.0)]
        file = joinpath(output_dir, entry)
        output[entry] = if isfile(file)
            str = read(file, String)
            try
                eval(Meta.parse(str))::type
            catch
                @warn "Could not parse $entry of $(pkg.name) on $(config.name) (got '$str', expected a $type)"
                default
            end
        else
            default
        end
    end
    if output["version"] === nothing
        # this happens with unversioned stdlibs
        output["version"] = missing
    end

    # log the status and reason
    @assert status in [:ok, :fail, :kill]
    ## special cases where we override the status (if we didn't actively kill the process)
    if status !== :kill
        ## e.g. testing might have failed because we couldn't install the package
        if !output["installed"]
            status = :skip
            reason = :uninstallable
        elseif occursin("Package $(pkg.name) did not provide a `test/runtests.jl` file", log)
            status = :skip
            reason = :untestable
        end
        ## e.g. testing might have succeeded but there may have been an internal error
        if occursin("GC error (probable corruption)", log)
            status = :crash
            reason = :gc_corruption
        elseif occursin("Unreachable reached", log)
            status = :crash
            reason = :unreachable
        elseif occursin("Internal error: encountered unexpected error in runtime", log) ||
               occursin("Internal error: stack overflow in type inference", log) ||
               occursin("Internal error: encountered unexpected error during compilation", log)
            status = :crash
            reason = :internal
        elseif occursin(r"signal \(.+\): Abort", log) ||                # sigdie handler
               occursin("(received signal: 6)", log)                    # Pkg log
            status = :crash
            reason = :abort
        elseif occursin(r"signal \(.+\): Segmentation fault", log) ||   # sigdie handler
               occursin("(received signal: 11)", log)                   # Pkg log
            status = :crash
            reason = :segfault
        end
    end
    ## in other cases we look at the log to determine a failure reason
    if status === :fail
        log *= "PkgEval failed"

        reason = if occursin("cannot open shared object file: No such file or directory", log)
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
                occursin("Temporary failure in name resolution", log) ||
                occursin("listen: address already in use", log)
            :network
        elseif occursin("ERROR: LoadError: syntax", log)
            :syntax
        elseif occursin("Some tests did not pass", log) || occursin("Test Failed", log)
            :test_failures
        else
            :unknown
        end
    elseif status === :kill
        log *= "PkgEval terminated"
    elseif status === :crash
        log *= "PkgEval crashed"
    elseif status === :skip
        log *= "PkgEval skipped"
    elseif status === :ok
        log *= "PkgEval succeeded"
    end
    if reason !== missing
        log *= ": " * reason_message(reason)
    end
    log *= "\n"

    # pack-up our rr trace. this is expensive, so we only do it for failures.
    if config.rr && status == :crash
        rr_script = "begin\n" * common_script * raw"""
            using Pkg
            using Base: UUID
            package_spec = eval(Meta.parse(ARGS[1]))

            print("\n\n", '#'^80, "\n# Bug reporting\n#\n\n")
            t0 = cpu_time()

            try
                # use a clean environment, or BugReporting's deps could
                # affect/be affected by the tested package's dependencies.
                Pkg.activate(; temp=true)
                Pkg.add(name="BugReporting", uuid="bcf9a6e7-4020-453c-b88e-690564246bb8")
                using BugReporting

                trace_dir = BugReporting.default_rr_trace_dir()
                trace = BugReporting.find_latest_trace(trace_dir)
                BugReporting.compress_trace(trace, "/output/$(package_spec.name).tar.zst")
                println("\nBugReporting completed after $(elapsed(t0))")
            catch err
                println("\nBugReporting failed after $(elapsed(t0))")
                showerror(stdout, err)
                Base.show_backtrace(stdout, catch_backtrace())
                println()
            end""" * "\nend"

        trace = joinpath(output_dir, "$(pkg.name).tar.zst")

        rr_config = Configuration(config; time_limit=config.time_limit*2)
        rr_log = evaluate_script(rr_config, rr_script, args;
                                 mounts, env, executor, kwargs...).log

        # upload the trace
        # TODO: re-use BugReporting.jl
        if haskey(ENV, "PKGEVAL_RR_BUCKET")
            bucket = ENV["PKGEVAL_RR_BUCKET"]
            unixtime = round(Int, datetime2unix(now()))
            trace_unique_name = "$(pkg.name)-$(unixtime).tar.zst"
            if isfile(trace)
                run(`$(s5cmd()) --log error cp -acl public-read $trace s3://$(bucket)/$(trace_unique_name)`)
                rr_log *= "Uploaded rr trace to https://s3.amazonaws.com/$(bucket)/$(trace_unique_name)"
            else
                rr_log *= "Testing did not produce an rr trace."
            end
        else
            rr_log *= "Testing produced an rr trace, but PkgEval.jl was not configured to upload rr traces."
        end

        # remove inaccurate rr errors (rr-debugger/rr/#3346)
        rr_log = replace(rr_log, r"\[ERROR .* Metadata of .* changed: .*\n" => "")
        log *= rr_log
    end

    # (cache and) clean-up output created by this package
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
        verify_compilecache(local_compilecache; show_status=false)
        copy_files(src=local_compilecache, dst=shared_compilecache)
        rm(local_compilecache; recursive=true)
    end
    rm(output_dir; recursive=true)
    cleanup(executor)

    return (; log, status, reason, version=output["version"], duration=output["duration"])
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
    script = "begin\n" * common_script * raw"""
        using Pkg
        using Base: UUID
        package_spec = eval(Meta.parse(ARGS[1]))
        sysimage_path = ARGS[2]

        println("Package compilation of $(package_spec.name) started at ", now(UTC))

        println()
        using InteractiveUtils
        versioninfo()


        print("\n\n", '#'^80, "\n# Installation\n#\n\n")
        t0 = time()

        if haskey(Pkg.Types.stdlibs(), package_spec.uuid)
            error("Packages that are standard libraries cannot be compiled again.")
        end

        println("Installing PackageCompiler...")
        project = Base.active_project()
        Pkg.activate(; temp=true)
        Pkg.add(name="PackageCompiler", uuid="9b87118b-4619-50d2-8e1e-99f35a4d4d9d")
        using PackageCompiler
        Pkg.activate(project)

        println("\nInstalling $(package_spec.name)...")

        Pkg.add(; package_spec...)

        println("\nCompleted after $(elapsed(t0))")


        print("\n\n", '#'^80, "\n# Compilation\n#\n\n")
        t1 = time()

        create_sysimage([package_spec.name]; sysimage_path)
        println("\nCompleted after $(elapsed(t1))")

        s = stat(sysimage_path).size
        println("Generated system image is ", Base.format_bytes(s))
    """ * "\nend"

    sysimage_path = "/sysimage/sysimg.so"
    args = `$(repr(package_spec_tuple(pkg))) $sysimage_path`

    sysimage_dir = mktempdir(prefix="pkgeval_$(pkg.name)_sysimage_")
    mounts = Dict(
        dirname(sysimage_path)*":rw"    => sysimage_dir,
    )

    compile_config = Configuration(config;
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

    (; status, reason, log) =
        evaluate_script(compile_config, script, args; mounts, kwargs...)
    log *= "\n"

    # log the status and determine a more accurate reason from the log
    @assert status in [:ok, :fail, :kill]
    if status === :ok
        log *= "PackageCompiler succeeded"
    elseif status === :fail
        log *= "PackageCompiler failed"
        reason = :uncompilable
    elseif status === :kill
        log *= "PackageCompiler terminated"
    end
    if reason !== missing
        log *= ": " * reason_message(reason)
    end
    log *= "\n"

    if status !== :ok
        rm(sysimage_dir; recursive=true)
        return (; log, status, reason, version=missing, duration=0.0)
    end

    # run the tests in the regular environment
    compile_log = log
    test_config = Configuration(config;
        compiled = false,
        julia_args = `$(config.julia_args) --sysimage $sysimage_path`,
    )
    (; log, status, reason, version, duration) =
        evaluate_test(test_config, pkg; mounts, use_cache, kwargs...)
    log = compile_log * "\n\n" * '#'^80 * "\n" * '#'^80 * "\n\n\n" * log

    rm(sysimage_dir; recursive=true)
    return (; log, status, reason, version, duration)

end


function verify_artifacts(artifacts; show_status::Bool=true)
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
    if show_status
        isinteractive() || println("Verifying artifacts...")
    end
    p = Progress(length(jobs); desc="Verifying artifacts: ",
                 enabled=isinteractive() && show_status)
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

function verify_compilecache(compilecache; show_status::Bool=true)
    if show_status
        isinteractive() || println("Verifying compilecache...")
    end
    removals = String[]

    # only direct entries in the compilecache are version dirs
    version_paths = String[]
    for version in readdir(compilecache)
        path = joinpath(compilecache, version)
        if isdir(path) && contains(version, r"^v\d+\.\d+$")
            push!(version_paths, path)
        else
            @debug "A broken version directory was found: $path"
            push!(removals, path)
        end
    end

    # below that, we should only have packages
    package_paths = String[]
    for version_path in version_paths, package in readdir(version_path)
        path = joinpath(version_path, package)
        if isdir(path)
            push!(package_paths, path)
        else
            @debug "A broken package directory was found: $path"
            push!(removals, path)
        end
    end

    # below that, we should only have specific files
    for package_path in package_paths
        for file in readdir(package_path)
            path = joinpath(package_path, file)
            if !isfile(path) || !endswith(file, r"\.(ji|so)"i)
                @debug "A broken file was found: $path"
                push!(removals, path)
            end
        end
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

function remove_uncacheable_packages(registry, package_dir; show_status::Bool=true)
    removals = String[]

    # only direct entries in the package cache are package directories
    packages = String[]
    for package in readdir(package_dir)
        path = joinpath(package_dir, package)
        if isdir(path)
            push!(packages, package)
        else
            @debug "A broken package entry was found: $path"
            push!(removals, path)
        end
    end

    # below that, we should only have directories that are 4 or 5-char slugs
    jobs = []
    for package in packages, slug in readdir(joinpath(package_dir, package))
        path = joinpath(package_dir, package, slug)
        tree_hash = lookup_package_slug(registry, package, slug)
        if isdir(path) && 4 <= length(slug) <= 5 && tree_hash !== nothing
            push!(jobs, (path, package, tree_hash))
        else
            @debug "A broken slug directory was found: $path"
            push!(removals, path)
        end
    end

    # now verify the tree hashes of each package/slug directory
    removals_lock = ReentrantLock()
    if show_status
        isinteractive() || println("Verifying packages...")
    end
    p = Progress(length(jobs); desc="Verifying packages: ",
                 enabled=isinteractive() && show_status)
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
             ninstances=Sys.CPU_THREADS, retry::Bool=true, validate::Bool=true,
             blacklist::Vector{String}, kwargs...)

Run tests for `packages` using `configs`. If no packages are specified, default to testing
all packages in the configured registry. The configurations can be specified as an array, or
as a dictionary where the key can be used to name the configuration (and more easily
identify it in the output dataframe).

The `ninstances` keyword argument determines how many packages are tested in parallel;
`retry` determines whether packages that did not fail on all configurations are retries;
`validate` enables validation of artifact and package caches before running tests.

The `blacklist` keyword argument can be used to skip testing of packages, specified by name.
The blacklist is always extended with a hard-coded set of packages known to be problematic.

Refer to `evaluate_test`[@ref] and `sandboxed_julia`[@ref] for more possible keyword
arguments.
"""
function evaluate(configs::Vector{Configuration}, packages::Vector{Package}=Package[];
                  ninstances::Integer=Sys.CPU_THREADS, retry::Bool=true,
                  validate::Bool=true, blacklist::Vector{String}=String[])
    if isempty(packages)
        registry_configs = unique(config->config.registry, values(configs))
        packages = intersect(values.(map(get_packages, registry_configs))...)::Vector{Package}
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
    for config in configs, package in packages
        job = if package.name in skip_rr_list
            config′ = Configuration(config; rr=false)
            Job(config′, package, true)
        else
            Job(config, package, true)
        end
        push!(jobs, job)
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
        if endswith(job.package.name, "_jll")
            # JLLs we ignore completely; it's not useful to include them in the skip count
            return false
        elseif job.package.name in blacklist || job.package.name in skip_list
            push!(skips, [job.config.name, job.package.name, missing,
                          :skip, :blacklisted, 0, missing])
            return false
        else
            return true
        end
    end

    njobs = length(jobs)
    ninstances = min(njobs, ninstances)
    running = Vector{Any}(missing, ninstances)
    tasks = Task[]

    done = false
    function stop_work()
        if !done
            done = true
            for task in tasks
                task == current_task() && continue
                Base.istaskdone(task) && continue
                try; schedule(task, InterruptException(); error=true); catch; end
            end
        end
    end

    # Workers
    p = Progress(njobs; desc="Running tests: ", enabled=isinteractive())
    for i = 1:ninstances
        push!(tasks, @async begin
            try
                while !isempty(jobs) && !done
                    job = pop!(jobs)
                    running[i] = (; job.config, job.package, time=time())

                    # test the package
                    config′ = Configuration(job.config; cpus=[i-1])
                    (; log, status, reason, version, duration) =
                        evaluate_test(config′, job.package; job.use_cache)

                    push!(result, [job.config.name, job.package.name,
                                    version, status, reason, duration, log])

                    if retry
                        # if we're done testing this package, consider retrying failures
                        package_results = result[result.package .== job.package.name, :]
                        nrow(package_results) == length(configs) || continue
                        # NOTE: this check also prevents retrying multiple times

                        failures = filter(package_results) do row
                            row.status !== :ok
                        end
                        ## if we only have a single configuration, retry every failure
                        retry_worthy = length(configs) == 1
                        ## otherwise only retry if we didn't fail all configurations
                        ## (to double-check those configurations introduced the failure)
                        retry_worthy |= nrow(failures) != length(configs)
                        ## also retry if the kind of failure is different across configs
                        retry_worthy |= length(unique(failures.status)) > 1 ||
                                 length(unique(failures.reason)) > 1
                        if retry_worthy
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
                # XXX: why do we still need to catch InterruptException here?
                #      it should be handled by the manual @sync below.
                #      removing this results in exceptions in unrelated code,
                #      e.g., during the `combine` at the end.
                isa(err, InterruptException) || rethrow(err)
            finally
                running[i] = nothing
            end
        end)
    end

    # Printer
    push!(tasks, @async begin
        start = time()
        sleep_time = 1
        while !done
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

                # for a more truthful ETA, we assume packages that are running will time out
                actually_running = filter(x->x !== nothing && x !== missing, running)
                ## calculate an ETA based on the jobs that aren't currently running
                elapsed_time = time() - start
                idle_jobs = njobs - length(actually_running)
                est_total_time = idle_jobs * elapsed_time / nrow(result)
                ## add the time it takes to run the latest job until it times out
                if !isempty(actually_running)
                    latest_job = actually_running[findmax(x->x.time, actually_running)[2]]
                    est_total_time += effective_time_limit(latest_job.config) -
                                      (time() - latest_job.time)
                end

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
    end)

    # Keyboard monitor (for more reliable CTRL-C handling)
    if isa(stdin, Base.TTY)
        # NOTE: `pushfirst!` since we **really** want this task to complete
        pushfirst!(tasks, @async begin
            term = REPL.Terminals.TTYTerminal("xterm", stdin, stdout, stderr)
            REPL.Terminals.raw!(term, true)
            try
                while !done
                    c = read(term, Char)
                    if c == '\x3'
                        println("Caught Ctrl-C, stopping...")
                        stop_work()
                        break
                    elseif c == '?'
                        println("Currently running: ",
                                join(map(x->x.package.name, filter(!isnothing, running)), ", "))
                    end
                end
            finally
                REPL.Terminals.raw!(term, false)
            end
        end)
    end

    # monitor tasks for failure so that each one doesn't need a try/catch + stop_work()
    try
        while true
            if any(istaskfailed, tasks)
                println("Caught an error, stopping...")
                break
            elseif all(istaskdone, tasks) || all(isnothing, running)
                break
            end
            sleep(1)
        end
    catch err
        # in case the sleep got interrupted
        isa(err, InterruptException) || rethrow()
    finally
        finish!(p)
        stop_work()
    end
    ## `wait()` to actually catch any exceptions
    for task in tasks
        try
            wait(task)
        catch err
            while isa(err, TaskFailedException)
                err = current_exceptions(err.task)[1].exception
            end
            isa(err, InterruptException) || rethrow()
        end
    end

    # remove duplicates from retrying, keeping only the last result
    if !isempty(result)
        nresults = nrow(result)
        result = combine(groupby(result, [:configuration, :package]), last)
        if nrow(result) != nresults
            println("Removed $(nresults - nrow(result)) duplicate evaluations that resulted from retrying tests.")
        end
    end

    append!(result, skips)
    return result
end
