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

if config.goal === :test
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
