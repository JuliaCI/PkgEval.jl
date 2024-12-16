include("common.jl")

config = eval(Meta.parse(ARGS[1]))
pkg = eval(Meta.parse(ARGS[2]))

try
    Pkg.DEFAULT_IO[] = devnull
    Pkg.activate("pkgeval"; shared=true)
finally
    Pkg.DEFAULT_IO[] = nothing
end

# precompile PkgEval run-time dependencies
println("Precompiling PkgEval dependencies...")
Pkg.precompile()
println()

if config.goal === :test
    # try to use TestEnv to precompile the package test dependencies
    try
        using TestEnv
        Pkg.DEFAULT_IO[] = devnull
        Pkg.activate()
        TestEnv.activate(pkg.name)
    catch err
        @error "Failed to use TestEnv.jl; test dependencies will not be precompiled" exception=(err, catch_backtrace())
        Pkg.activate()
        Pkg.DEFAULT_IO[] = nothing
    end
end

println("Precompiling package dependencies...")
Pkg.precompile()
