include("common.jl")

config = eval(Meta.parse(ARGS[1]))
pkg = eval(Meta.parse(ARGS[2]))

suppress_pkg_output() do
    Pkg.activate("pkgeval"; shared=true)
end

# precompile PkgEval run-time dependencies
println("Precompiling PkgEval dependencies...")
Pkg.precompile()
println()

if config.goal in (:test, :seal)
    # try to use TestEnv to precompile the package test dependencies
    try
        using TestEnv
        suppress_pkg_output() do
            Pkg.activate()
            TestEnv.activate(pkg.name)
        end
    catch err
        @error "Failed to use TestEnv.jl; test dependencies will not be precompiled" exception=(err, catch_backtrace())
        Pkg.activate()
    end
else
    suppress_pkg_output() do
        Pkg.activate()
    end
end

println("Precompiling package dependencies...")
Pkg.precompile()

if config.goal in (:seal, :derive)
    # under the cache protocol, also report what this environment produced for
    # the unit under seal, keyed identically to how consumers will ask for it
    if @isdefined(PkgEvalCacheClient)
        try
            if config.goal === :seal
                # a seal covers the unit and any of its extensions this
                # environment triggered
                PkgEvalCacheClient.emit_produced_keys_with_extensions(
                    pkg.name, "/output/seal_keys.toml")
            else
                # derivations name their unit exactly; extension units have no
                # manifest entry, so the uuid must come from the want
                PkgEvalCacheClient.emit_produced_keys(pkg.name, "/output/seal_keys.toml";
                    uuid=pkg.uuid === nothing ? nothing : string(pkg.uuid))
            end
        catch err
            @error "failed to emit produced cache keys" exception=(err, catch_backtrace())
        end
    end

    # report the resolved environment (the true dependency graph, test deps
    # included) for publication ordering and learned scheduling edges
    import TOML
    graph = Dict{String,Any}()
    for (uuid, info) in Pkg.dependencies()
        graph[info.name] = Dict(
            "uuid" => string(uuid),
            "version" => info.version === nothing ? "" : string(info.version),
            "deps" => sort!(collect(keys(info.dependencies))))
    end
    open("/output/seal_graph.toml", "w") do io
        TOML.print(io, graph)
    end
end
