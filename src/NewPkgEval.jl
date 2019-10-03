module NewPkgEval

include("build_julia.jl")

using BinaryBuilder
using BinaryProvider
using LightGraphs
import Pkg.TOML
using Pkg
import Base: UUID
using Dates
using DataStructures: BinaryMaxHeap
import LibGit2

downloads_dir(name) = joinpath(@__DIR__, "..", "deps", "downloads", name)
julia_path(ver) = joinpath(@__DIR__, "..", "deps", "julia-$ver")
versions_file() = joinpath(@__DIR__, "..", "deps", "Versions.toml")
registry_path() = joinpath(first(DEPOT_PATH), "registries", "General")

"""
    get_registry()

Download the default registry, or if it already exists, update it.
"""
function get_registry()
    Pkg.Types.clone_default_registries()
    Pkg.Types.update_registries(Pkg.Types.Context())
end

"""
    read_versions() -> Dict

Parse the `deps/Versions.toml` file containing version and download information for
various versions of Julia.
"""
function read_versions()
    vers = TOML.parse(read(versions_file(), String))
end

"""
    obtain_julia(the_ver)

Download the specified version of Julia using the information provided in `Versions.toml`.
"""
function obtain_julia(the_ver::VersionNumber)
    vers = read_versions()
    for (ver, data) in vers
        ver = VersionNumber(ver)
        ver == the_ver || continue
        if haskey(data, "url")
            file = get(data, "file", "julia-$ver.tar.gz")
            @assert !isabspath(file)
            download_verify_unpack(
                data["url"],
                data["sha"],
                julia_path(ver);
                tarball_path=downloads_dir(file),
                force=true
            )
        else
            file = data["file"]
            !isabspath(file) && (file = downloads_dir(file))
            BinaryProvider.verify(file, data["sha"])
            isdir(julia_path(ver)) || BinaryProvider.unpack(file, julia_path(ver))
        end
        return
    end
    error("Requested Julia version not found")
end

function installed_julia_dir(ver)
     jp = julia_path(ver)
     jp_contents = readdir(jp)
     # Allow the unpacked directory to either be insider another directory (as produced by
     # the buildbots) or directly inside the mapped directory (as produced by the BB script)
     if length(jp_contents) == 1
         jp = joinpath(jp, first(jp_contents))
     end
     jp
end

"""
    run_sandboxed_julia(args=``; ver::VersionNumber, do_obtain=true, kwargs...)

Run Julia inside of a sandbox, passing the given arguments `args` to it. The keyword
argument `ver` specifies the version of Julia to use, and `do_obtain` dictates whether
the specified version should first be downloaded. If `do_obtain` is `false`, it must
already be installed.
"""
function run_sandboxed_julia(args=``; ver::VersionNumber, do_obtain=true, kwargs...)
    if do_obtain
        obtain_julia(ver)
    else
        @assert ispath(julia_path(ver))
    end
    ispath(registry_path()) || error("Please run `NewPkgEval.get_registry()` first")
    runner = BinaryBuilder.UserNSRunner(pwd(),
        workspaces=[
            installed_julia_dir(ver) => "/maps/julia",
            registry_path() => "/maps/registries/General"
        ])
    BinaryBuilder.run_interactive(runner, `/maps/julia/bin/julia --color=yes $args`; kwargs...)
end

log_path(ver) = joinpath(@__DIR__, "..", "logs/logs-$ver")

"""
    run_sandboxed_test(pkg; ver::VersionNumber, do_depwarns=false, time_limit=typemax(UInt), kwargs...)

Run the unit tests for a single package `pkg` inside of a sandbox using the Julia version
`ver`. If `do_depwarns` is `true`, deprecation warnings emitted while running the package's
tests will cause the tests to fail. Test will be forcibly interrupted after `time_limit` seconds.

A log for the tests is written to a version-specific directory in the NewPkgEval root
directory.
"""
function run_sandboxed_test(pkg; ver::VersionNumber, do_depwarns=false, time_limit=typemax(UInt), kwargs...)
    @assert ispath(julia_path(ver))
    mkpath(log_path(ver))
    log = joinpath(log_path(ver), "$pkg.log")
    arg = """
        using Pkg
        open("/etc/hosts", "w") do f
            println(f, "127.0.0.1\tlocalhost")
        end
        #run(`mount -t devpts -o newinstance jrunpts /dev/pts`)
        #run(`mount -o bind /dev/pts/ptmx /dev/ptmx`)
        #run(`mount -t tmpfs tempfs /dev/shm`)
        mkpath("/root/.julia/registries")
        run(`ln -s /maps/registries/General /root/.julia/registries/General`)
        Pkg.UPDATED_REGISTRY_THIS_SESSION[] = true
        Pkg.add($(repr(pkg)))
        Pkg.test($(repr(pkg)))
    """
    cmd = ``
    do_depwarns && (cmd = `--depwarn=error`)
    cmd = `$cmd -e $arg`
    timed_out = false
    open(log, "w") do f
        try
            t = @async run_sandboxed_julia(cmd; ver=ver, kwargs..., stdout=f, stderr=f)
            Timer(time_limit) do timer
                timed_out = true
                try; schedule(t, InterruptException(); error=true); catch; end
            end
            wait(t)
            return !timed_out
        catch e
            return false
        end
    end
end

const CSI = "\e["

function show_result(io::IO, dg, queue, results)
    print(io, "Success: ")
    o, f, s = count(==(:ok), values(results)), count(==(:fail), values(results)),
        count(==(:skipped), values(results))
    q = length(queue)
    printstyled(io, o; color = :green)
    print(io, "\tFailed: ")
    printstyled(io, f; color = Base.error_color())
    print(io, "\tSkipped: ")
    printstyled(io, s; color = Base.warn_color())
    print(io, "\tCurrent Frontier/Remaining: ")
    print(io, q, '/')
    print(io, length(vertices(dg.g)) - (o+f+s))
    println(io)
end

struct PkgEntry
    degree::Int
    idx::Int
end
Base.:<(a::PkgEntry, b::PkgEntry) = a.degree < b.degree

function skip_pkg!(result, dg, to_skip)
    result[dg.names[to_skip]] = :skipped
    for revdep in inneighbors(dg.g, to_skip)
        if haskey(result, dg.names[revdep]) &&
            result[dg.names[revdep]] == :skipped
            continue
        end
        skip_pkg!(result, dg, revdep)
    end
end

# Skip these packages when testing packages
const skip_list = [
    "AbstractAlgebra", # Hangs forever
    "DiscretePredictors", # Hangs forever
    "LinearLeastSquares", # Hangs forever
    "SLEEF", # Hangs forever
    "OrthogonalPolynomials", # Hangs forever
    "IndexableBitVectors",
    "LatinHypercubeSampling", # Hangs forever
    "DynamicalBilliards", # Hangs forever
    "ChangePrecision", # Hangs forever
    "Rectangle", # Hangs forever
    "Parts", # Hangs forever
    "ZippedArrays", # Hangs forever
    "Chunks", # Hangs forever
    "Electron",
    "DotOverloading",
    "ValuedTuples",
    "HCubature",
    "SequentialMonteCarlo",
    "RequirementVersions",
    "NumberedLines",
    "LazyContext",
    "RecurUnroll", # deleted, hangs
    "TypedBools", # deleted, hangs
    "LazyCall", # deleted, hangs
    "MeshCatMechanisms",
    "SessionHacker",
    "Embeddings",
    "GeoStatsDevTools",
    "DataDeps", # hangs
    "DataDepsGenerators", # hangs
    "MackeyGlass", # deleted, hangs
    "Keys", #deleted, hangs
]

# Blindly assume these packages are okay
const ok_list = [
    "BinDeps", # Not really ok, but packages may list it just as a fallback
    "Homebrew",
    "WinRPM",
    "NamedTuples", # As requested by quinnj
    "Compat",
]

# Stdlibs are assumed to be ok
append!(ok_list, readdir(Sys.STDLIB))

"""
    run(depsgraph, ninstances, version[, result]; do_depwarns=false, 
        time_limit=typemax(UInt), skip_dependees_for_failed_pkgs=false)

Run all tests for all packages in the given package dependency graph using `ninstances`
workers and the specified version of Julia. An existing result `Dict` can be specified,
in which case the function will write to that.

If the keyword argument `do_depwarns` is `true`, deprecation warnings emitted in package
tests will cause the package's tests to fail, i.e. Julia is run with `--depwarn=error`.

Tests will be forcibly interrupted after `time_limit` seconds.
"""
function run(dg, ninstances::Integer, ver::VersionNumber, result = Dict{String, Symbol}();
             do_depwarns=false, time_limit=typemax(UInt), skip_dependees_for_failed_pkgs = false)
    obtain_julia(ver)

    # In case we need to provide sudo password, do that before starting the actual testing
    run_sandboxed_julia(`-e '1'`; ver=ver)

    get_registry() # make sure local registry is updated
    frontier = BitSet()
    pkgs = copy(dg.names)
    running = Vector{Union{Nothing, Symbol}}(nothing, ninstances)
    times = DateTime[now() for i = 1:ninstances]
    processed = BitSet()
    cond = Condition()
    queue = BinaryMaxHeap{PkgEntry}()
    completed = Channel(Inf)
    # Add packages without dependencies to the frontier
    for x in ok_list
        i = findfirst(==(x), dg.names)
        if i !== nothing
            result[x] = :ok
            put!(completed, i)
        end
    end
    for p in filter(v->length(outneighbors(dg.g, v)) == 0, vertices(dg.g))
        (dg.names[p] in skip_list) && continue
        (haskey(result, dg.names[p])) && continue
        push!(queue, PkgEntry(length(inneighbors(dg.g, p)), p))
    end
    for x in skip_list
        pkg = findfirst(==(x), dg.names)
        if pkg === nothing
            # @warn "Package $(x) in skip list, but not found"
            continue
        end
        skip_pkg!(result, dg, pkg)
    end
    done = false
    processing = false
    all_workers = Task[]
    did_signal_workers = false
    function stop_work()
        if !done
            (done = true; notify(cond); put!(completed, -1))
            if !did_signal_workers
                for task in all_workers
                    task == current_task() && continue
                    !Base.istaskdone(task) || continue
                    try; schedule(task, InterruptException(); error=true); catch; end
                end
                did_signal_workers = true
            end
        end
    end
    @sync begin
        @async begin
            try
                buf = IOBuffer()
                io = IOContext(buf, :color => true)
                while !isempty(queue) || !all(==(nothing), running) || isready(completed) || processing
                    show_result(io, dg, queue, result)
                    for i = 1:ninstances
                        r = running[i]
                        if r === nothing
                            println(io, "Worker $i: -------")
                        else
                            println(io, "Worker $i: $(r) running for ", Dates.canonicalize(Dates.CompoundPeriod(now() - times[i])))
                        end
                    end
                    print(String(take!(buf)))
                    sleep(1)
                    print(io, "$(CSI)$(ninstances+1)A$(CSI)1G$(CSI)0J")
                end
                stop_work()
                println("done")
            catch e
                Base.@show e
                stop_work()
                !isa(e, InterruptException) && rethrow(e)
            end
        end
        # Scheduler
        @async begin
            try
                while !done
                    pkgno = take!(completed)
                    pkgno == -1 && break
                    processing = true
                    push!(processed, pkgno)
                    for revdep in inneighbors(dg.g, pkgno)
                        if skip_dependees_for_failed_pkgs && result[dg.names[pkgno]] != :ok
                            skip_pkg!(result, dg, revdep)
                        else
                            (revdep in processed) && continue
                            # Last dependency to finish adds it to
                            # the frontier
                            all_processed = true
                            for dep in outneighbors(dg.g, revdep)
                                if !(dep in processed) || (skip_dependees_for_failed_pkgs && result[dg.names[dep]] != :ok)
                                    all_processed = false
                                    break
                                end
                            end
                            all_processed || continue
                            haskey(result, dg.names[revdep]) && continue
                            push!(queue, PkgEntry(length(inneighbors(dg.g, revdep)), revdep))
                        end
                    end
                    notify(cond)
                    processing = false
                end
            catch e
                @Base.show e
                stop_work()
                !isa(e, InterruptException) && rethrow(e)
            end
        end
        # Workers
        for i = 1:ninstances
            push!(all_workers, @async begin
                try
                    while !done
                        if isempty(queue)
                            wait(cond)
                            continue
                        end
                        pkgno = pop!(queue).idx
                        pkg = dg.names[pkgno]
                        running[i] = Symbol(pkg)
                        times[i] = now()
                        result[pkg] = run_sandboxed_test(pkg, do_depwarns=do_depwarns, ver=ver,
                                                         time_limit = time_limit, do_obtain=false) ? :ok : :fail
                        running[i] = nothing
                        put!(completed, pkgno)
                    end
                catch e
                    @Base.show e
                    stop_work()
                    !isa(e, InterruptException) && rethrow(e)
                end
            end)
        end
    end
    result
end

function run_pkg_deps(pkg, dg, ninstances)
    result = Dict{String, Symbol}()
    nbs = unique(LightGraphs.neighborhood(dg.g, findfirst(==(pkg), dg.names), typemax(Int)))
    for pkg in dg.names[filter(x->!(x in nbs), 1:length(dg.names))]
        result[pkg] = :skipped
    end
    run(dg, ninstances, result)
end

"""
    read_pkgs([pkgs::Vector{String}])

Read packages from the default registry and return them as a vector of tuples containing
the package name, its UUID, and a path to it. If `pkgs` is given, only collect packages
matching the names in `pkgs`
"""
function read_pkgs(pkgs::Union{Nothing, Vector{String}}=nothing)
    pkg_data = Tuple{String, UUID, String}[]
    for registry in (registry_path(),)
        open(joinpath(registry, "Registry.toml")) do io
            for (_uuid, pkgdata) in Pkg.Types.read_registry(joinpath(registry, "Registry.toml"))["packages"]
                uuid = UUID(_uuid)
                name = pkgdata["name"]
                if pkgs !== nothing
                    idx = findfirst(==(name), pkgs)
                    idx === nothing && continue
                    deleteat!(pkgs, idx)
                end
                path = abspath(registry, pkgdata["path"])
                push!(pkg_data, (name, uuid, path))
            end
        end
    end
    if pkgs !== nothing && !isempty(pkgs)
        @warn """did not find the following packages in the registry:\n $("  - " .* join(pkgs, '\n'))"""
    end
    pkg_data
end

struct PkgDepGraph
    vertex_map::Dict{UUID, Int}
    uuid::Vector{UUID}
    names::Vector{String}
    g::LightGraphs.SimpleGraphs.SimpleDiGraph
end

"""
    PkgDepGraph(pkgs, ver)

Construct a package dependency graph given a vector of package name, UUID, path tuples
and a specific Julia version.
"""
function PkgDepGraph(pkgs, ver)
    # Add packages
    vertex_map = Dict(pkg[2] => i for (i, pkg) in enumerate(pkgs))
    uuids = map(x->x[2], pkgs)
    names = map(x->x[1], pkgs)
    g = LightGraphs.SimpleGraphs.SimpleDiGraph(length(names))
    for (name, uuid, path) in pkgs
        vers = Pkg.Operations.load_versions(path)
        max_ver = maximum(keys(vers))
        data = Pkg.Operations.load_package_data(UUID, joinpath(path, "Deps.toml"), max_ver)
        data === nothing && continue
        for (k,v) in data
            if !haskey(vertex_map, v)
                # @error("Dependency $k ($v) not in registry")
                continue
            end
            add_edge!(g, vertex_map[uuid], vertex_map[v])
        end
    end
    # Arbitrarily break dependency cycles
    cycs = LightGraphs.simplecycles(g)
    for cyc in cycs
        rem_edge!(g, cyc[end], cyc[1])
    end
    PkgDepGraph(vertex_map, uuids, names, g)
end

function analyze_results(dg, result)
    # Print the top packages by recursive benefit if fixed
    failed_pkgs = filter(((k,v),)->v == :fail, result)
    r = Dict(begin
        id = findfirst(==(k), dg.names)
        # Avoid cycles
        visited = BitSet()
        stack = Int[id]
        push!(visited, id)
        n = 0
        while !isempty(stack)
            x = pop!(stack)
            for y in inneighbors(dg.g, x)
                (y in visited) && continue
                push!(visited, y)
                push!(stack, y)
                n += 1
            end
        end
        k => n
    end for (k, v) in failed_pkgs)
    sort(collect(r), by = x->x[2], rev = true)
end

function analyze_results_pkg(pkg, dg, result)
    nbs = unique(LightGraphs.neighborhood(dg.g, findfirst(==(pkg), dg.names), typemax(Int)))
    nbs_names = dg.names[nbs]
    nresult = filter(((k,v),)->k in nbs_names, result)
    analyze_results(dg, nresult)
end

end # module
