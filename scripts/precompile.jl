include("common.jl")

config = eval(Meta.parse(ARGS[1]))
pkg = eval(Meta.parse(ARGS[2]))

Pkg.activate("pkgeval"; shared=true)

# precompile PkgEval run-time dependencies (notably BugReporting.jl)
Pkg.precompile()

# try to use TestEnv to precompile the package test dependencies
try
    using TestEnv
    Pkg.activate()
    TestEnv.activate(pkg.name)
catch err
    @error "Failed to use TestEnv.jl; test dependencies will not be precompiled" exception=(err, catch_backtrace())
    Pkg.activate()
end
Pkg.precompile()
