include("common.jl")

function suppress_pkg_output(f::Function)
    # Need to handle https://github.com/JuliaLang/Pkg.jl/pull/4499,
    # but also need to handle older Julia versions without ScopedValues
    use_scoped_values = isdefined(Base, :ScopedValues) && (Pkg.DEFAULT_IO isa Base.ScopedValues.ScopedValue)
    if !use_scoped_values
        Pkg.DEFAULT_IO[] = devnull
    end
    try
        if use_scoped_values
            # Avoid using the @with macro here
            Base.ScopedValues.with(Pkg.DEFAULT_IO => devnull) do
                f()
            end
        else
            f()
        end
    finally
        if !use_scoped_values
            Pkg.DEFAULT_IO[] = nothing
        end
    end
end

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
