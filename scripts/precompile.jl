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

if config.goal === :seal
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
