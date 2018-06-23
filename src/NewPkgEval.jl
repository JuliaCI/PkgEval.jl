module NewPkgEval

    using BinaryBuilder
    using BinaryProvider
    using LightGraphs
    import Pkg.TOML
    using Pkg
    using Pkg: UUID
    using Dates
    using DataStructures
    import LibGit2

    const julia_url = "https://julialang-s3.julialang.org/bin/linux/x64/0.7/julia-0.7.0-alpha-linux-x86_64.tar.gz"
    downloads_dir(name) = joinpath(@__DIR__, "..", "deps", "downloads", name)
    julia_path() = joinpath(@__DIR__, "..", "deps", "julia")
    function obtain_julia()
        download_verify_unpack(
            julia_url,
            "8a1adb1fddbdd3e7a05c9ee8dfa322e2940dabe01b8acbb5806478643ed54ed9",
            julia_path();
            tarball_path=downloads_dir(basename(julia_url)),
            force=true
        )
    end

    function run_sandboxed_julia(args=``; kwargs...)
        obtain_julia()
        get_registry()
        jp = joinpath(julia_path(), first(readdir(julia_path())))
        runner = BinaryBuilder.UserNSRunner(pwd(),
            mappings=[
                jp => "/opt/julia",
                registry_path() => "/opt/Uncurated"
            ])
        BinaryBuilder.run_interactive(runner, `/opt/julia/bin/julia --color=yes $args`; kwargs...)
    end

    log_path() = joinpath(@__DIR__, "..", "logs")
    function run_sandboxed_test(pkg)
        log = joinpath(log_path(), "$pkg.log")
        c = quote
            mkpath("/root/.julia/registries")
            open("/etc/hosts", "w") do f
                println(f, "127.0.0.1\tlocalhost")
            end
            run(`ln -s /opt/Uncurated/ /root/.julia/registries/Uncurated`)
            Pkg.add($pkg)
            Pkg.test($pkg)
        end
        arg = "using Pkg; eval($(repr(c)))"
        try
            open(log, "w") do f
                run_sandboxed_julia(`-e $arg`; stdout=f, stderr=f)
            end
            return true
        catch e
            return false
        end
    end

    const CSI = "\e["

    function show_result(io::IO, dg, queue, results)
        print(io, "Success: ")
        o, f, s = count(==(:ok), values(results)), count(==(:fail), values(results)),
            count(==(:skipped), values(results))
        printstyled(io, o; color = :green)
        print(io, "\tFailed: ")
        printstyled(io, f; color = :red)
        print(io, "\tSkipped: ")
        printstyled(io, s; color = :yellow)
        print(io, "\tCurrent frontier: ")
        print(io, length(queue))
        print(io, "\tRemaining: ")
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

    const skip_list = [
        "AbstractAlgebra" # Hangs forever
    ]

    function run_all(dg, ninstances)
        frontier = BitSet()
        pkgs = copy(dg.names)
        running = Vector{Union{Nothing, Symbol}}(nothing, ninstances)
        times = DateTime[now() for i = 1:ninstances]
        processed = BitSet()
        cond = Condition()
        queue = binary_maxheap(PkgEntry)
        # Add packages without dependencies to the frontier
        for p in filter(v->length(outneighbors(dg.g, v)) == 0, vertices(dg.g))
            (dg.names[p] in skip_list) && continue
            push!(queue, PkgEntry(length(inneighbors(dg.g, p)), p))
        end
        result = Dict{String, Symbol}()
        for x in skip_list
            result[x] = :skipped
        end
        @sync begin
            @async begin
                try
                    buf = IOBuffer()
                    io = IOContext(buf, :color => true)
                    while !isempty(queue) || !all(==(nothing), running)
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
                catch e
                    isa(e, InterruptException) && rethrow(e)
                    rethrow(e)
                end
            end
            for i = 1:ninstances
                @async begin
                    while !isempty(queue) || !all(==(nothing), running)
                        while isempty(queue)
                            wait(cond)
                        end
                        try
                            pkgno = pop!(queue).idx
                            pkg = dg.names[pkgno]
                            running[i] = pkg
                            times[i] = now()
                            result[pkg] = run_sandboxed_test(pkg) ? :ok : :fail
                            running[i] = nothing
                            push!(processed, pkgno)
                            for revdep in inneighbors(dg.g, pkgno)
                                if result[pkg] != :ok
                                    skip_pkg!(result, dg, revdep)
                                else
                                    (revdep in processed) && continue
                                    # Last dependency to finish adds it to
                                    # the frontier
                                    all_processed = true
                                    for dep in outneighbors(dg.g, revdep)
                                        if !(dep in processed) || result[dg.names[dep]] != :ok
                                            all_processed = false
                                            break
                                        end
                                    end
                                    all_processed || continue
                                    haskey(result, dg.names[revdep]) && continue
                                    push!(queue, PkgEntry(length(inneighbors(dg.g, revdep)), revdep))
                                    notify(cond)
                                end
                            end
                        catch e
                            isa(e, InterruptException) && rethrow(e)
                            @error e
                            print("\n"^25)
                        end
                    end
                end
            end
        end
        result
    end

    function read_all_pkgs()
        pkgs = Tuple{String, UUID, String}[]
        for registry in Pkg.registries()
            open(joinpath(registry, "Registry.toml")) do io
                # skip forward until [packages] section
                for line in eachline(io)
                    occursin(r"^ \s* \[ \s* packages \s* \] \s* $"x, line) && break
                end
                for line in eachline(io)
                    m = match(Pkg.Types.line_re, line)
                    m == nothing &&
                            error("misformatted registry.toml package entry: $line")
                    uuid = UUID(m.captures[1])
                    name = Base.unescape_string(m.captures[2])
                    path = abspath(registry, Base.unescape_string(m.captures[3]))
                    push!(pkgs, (name, uuid, path))
                end
            end
        end
        pkgs
    end

    registry_path() = joinpath(@__DIR__, "..", "work", "registry")

    function get_registry()
        if !isdir(registry_path())
            creds = LibGit2.CachedCredentials()
            url = Pkg.Types.DEFAULT_REGISTRIES["Uncurated"]
            repo = Pkg.GitTools.clone(url, registry_path(); header = "registry Uncurated from $(repr(url))", credentials = creds)
            close(repo)
        end
    end

    struct PkgDepGraph
        vertex_map::Dict{UUID, Int}
        uuid::Vector{UUID}
        names::Vector{String}
        g::LightGraphs.SimpleGraphs.SimpleDiGraph
    end

    function read_stdlib()
        ret = Tuple{String, UUID}[]
        stdlibs = readdir(Sys.STDLIB)
        for stdlib in stdlibs
            proj = TOML.parsefile(joinpath(Sys.STDLIB, stdlib, "Project.toml"))
            push!(ret, (proj["name"], UUID(proj["uuid"])))
        end
        ret
    end

    function PkgDepGraph(pkgs)
        # Add packages
        vertex_map = Dict(pkg[2] => i for (i, pkg) in enumerate(pkgs))
        uuids = map(x->x[2], pkgs)
        names = map(x->x[1], pkgs)
        # Add stdlibs to vertex map
        stdlibs = read_stdlib()
        for (i, (name, uuid)) in enumerate(stdlibs)
            vertex_map[uuid] = length(pkgs) + i
            push!(names, name)
            push!(uuids, uuid)
        end
        g = LightGraphs.SimpleGraphs.SimpleDiGraph(length(pkgs) + length(stdlibs))
        for (name, uuid, path) in pkgs
            vers = Pkg.Operations.load_versions(path)
            max_ver = maximum(keys(vers))
            data = Pkg.Operations.load_package_data(UUID, joinpath(path, "Deps.toml"), max_ver)
            data === nothing && continue
            for (k,v) in data
                if !haskey(vertex_map, v)
                    @warn "Dependency $k ($v) not in registry"
                    continue
                end
                add_edge!(g, vertex_map[uuid], vertex_map[v])
            end
        end
        PkgDepGraph(vertex_map, uuids, names, g)
    end

    function no_dep_pkgs(g::PkgDepGraph)
        filter(v->length(outneighbors(g.g, v)) == 0, vertices(g.g))
    end

end # module
