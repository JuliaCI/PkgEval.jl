include("common.jl")

config = eval(Meta.parse(ARGS[1]))
pkg = eval(Meta.parse(ARGS[2]))

println("Package evaluation of $(pkg.name) on Julia $VERSION ($(Base.GIT_VERSION_INFO.commit_short)) started at ", now(UTC))


print("\n\n", '#'^80, "\n# Set-up\n#\n\n")

t0 = cpu_time()

deps = String[]

if config.goal === :test
    push!(deps, "TestEnv")
end

if config.rr == RREnabled
    push!(deps, "BugReporting")

    # instead of using --bug-report, we'll load BugReporting manually, because
    # by default we can't access any unrelated package from within the sandbox
    # created by Pkg, resulting in re-installation and compilation of BugReporting.
    open("bugreport.jl", "w") do io
        # loading an unrelated package like this is normally a bad thing to do,
        # because the versions of BugReporting.jl's dependencies may conflict with
        # the dependencies of the package under evaluation. However, in the session
        # where we load BugReporting.jl we'll never actually load the package we
        # want to test, only re-start Julia under rr, so this should be fine.
        println(io, "pushfirst!(LOAD_PATH, $(repr(Base.ACTIVE_PROJECT[])))")

        # this code is essentially what --bug-report from InteractiveUtils does
        println(io, "using BugReporting")
        println(io, "ENV[\"ENABLE_GDBLISTENER\"] = \"1\"")
        println(io, "println(\"Switching execution to under rr\")")
        println(io, "BugReporting.make_interactive_report(\"rr-local\", ARGS)")
        println(io, "exit(0)")
    end
end

if !isempty(deps)
    # we install PkgEval dependencies in a separate environment
    Pkg.activate("pkgeval"; shared=true)

    io = IOBuffer()
    Pkg.DEFAULT_IO[] = io
    try
        println("Installing PkgEval dependencies...")
        Pkg.add(deps)
        println()
    catch
        # something went wrong installing PkgEval's dependencies
        println(String(take!(io)))
        rethrow()
    finally
        Pkg.DEFAULT_IO[] = nothing
    end

    Pkg.activate()
end

# generating package images is really expensive, without much benefit (for PkgEval)
# so determine here if we need to disable them using additional CLI args
# (we can't do this externally because of JuliaLang/Pkg.jl#3737)
julia_args = String[]
if VERSION < v"1.9-beta1" || (v"1.10-" <= VERSION < v"1.10.0-DEV.204")
    # we don't support pkgimages yet
elseif any(startswith("--pkgimages"), config.julia_args)
    # the user specifically requested pkgimages
else
    if VERSION >= v"1.11-DEV.1119"
        # we can selectively disable pkgimages while allowing reuse of existing ones
        push!(julia_args, "--pkgimages=existing")
    elseif VERSION >= v"1.11-DEV.123"
        # we can only selectively disable all compilation caches. this isn't ideal,
        # but at this point in time (where many stdlibs have been moved out of the
        # system image) it's strictly better than using `--pkgimages=no`
        push!(julia_args, "--compiled-modules=existing")
    else
        # completely disable pkgimages
        push!(julia_args, "--pkgimages=no")
    end
end

# forward all user-provided flags to `Pkg.test` to ensure the test environment uses them.
# we need to do so because Pkg inserts its own flags we want to be able to override (e.g.,
# `--check-bounds`), and because its use of `Base.julia_cmd()` doesn't include all flags
# passed to the current Julia process (e.g. `--inline`).
append!(julia_args, config.julia_args)
julia_args = Cmd(julia_args)

println("\nSet-up completed after $(elapsed(t0))")


print("\n\n", '#'^80, "\n# Installation\n#\n\n")

t0 = cpu_time()
try
    Pkg.add(convert(Pkg.Types.PackageSpec, pkg))

    println("\nInstallation completed after $(elapsed(t0))")
    write("/output/installed", repr(true))
catch
    println("\nInstallation failed after $(elapsed(t0))\n")
    write("/output/installed", repr(false))
    rethrow()
finally
    # even if a package fails to install, it may have been resolved
    # (e.g., when the build phase errors)
    for package_info in values(Pkg.dependencies())
        if package_info.name == pkg.name
            write("/output/version", repr(package_info.version))
            break
        end
    end
end

# ensure the package has a test/runtests.jl file, so we can bail out quicker
src = Base.find_package(pkg.name)
runtests = joinpath(dirname(src), "..", "test", "runtests.jl")
if config.goal === :test && !isfile(runtests)
    error("Package $(pkg.name) did not provide a `test/runtests.jl` file")
end

is_stdlib = any(Pkg.Types.stdlibs()) do (uuid,stdlib)
    name = isa(stdlib, String) ? stdlib : first(stdlib)
    name == pkg.name
end
if is_stdlib
    println("\n$(pkg.name) is a standard library in this Julia build.")

    # we currently only support testing the embedded version of stdlib packages
    if pkg.version !== nothing || pkg.url !== nothing || pkg.rev !== nothing
        error("Packages that are standard libraries can only be tested using the embedded version.")
    end
end


if config.precompile && !is_stdlib
print("\n\n", '#'^80, "\n# Precompilation\n#\n\n")

# we run with JULIA_PKG_PRECOMPILE_AUTO=0 to avoid precompiling on Pkg.add,
# because we can't use the generated images for Pkg.test which uses different
# options (i.e., --check-bounds=yes). however, to get accurate test timings,
# we *should* precompile before running tests, so we do that here manually.

t0 = cpu_time()
try
    script = joinpath(@__DIR__, "precompile.jl")
    # we need to make sure to match the test environment, or at least
    # with respect to CLI flags that affect precompilation caching.
    # that means enabling bounds checking; other CLI flags that affect
    # precompilation caching (debug & opt level, inlining) should either
    # be set to the default, or customized through `julia_args`.
    # see Pkg.jl's `gen_subprocess_cmd` for more details.
    run(```
        $(Base.julia_cmd())
        --check-bounds=yes
        --inline=$(Bool(Base.JLOptions().can_inline) ? "yes" : "no")
        $(julia_args)
        $script $config $pkg
    ```)

    println("\nPrecompilation completed after $(elapsed(t0))")
catch
    println("\nPrecompilation failed after $(elapsed(t0))\n")
end
end


if config.goal === :load
print("\n\n", '#'^80, "\n# Loading\n#\n\n")

t0 = cpu_time()
io0 = io_bytes()
try
    # we load the package in a session mimicking Pkg's sandbox,
    # because that's what we previously precompiled the package in.
    run(```$(Base.julia_cmd())
           --check-bounds=yes
           --inline=$(Bool(Base.JLOptions().can_inline) ? "yes" : "no")
           $(julia_args)
           -e $("using $(pkg.name)")```)

    println("\nLoading completed after $(elapsed(t0))")
catch
    println("\nLoading failed after $(elapsed(t0))\n")
    rethrow()
finally
    write("/output/duration", repr(cpu_time()-t0))
    write("/output/input_output", repr(io_bytes()-io0))
end
end


if config.goal === :test
print("\n\n", '#'^80, "\n# Testing\n#\n\n")

t0 = cpu_time()
io0 = io_bytes()
try
    if config.rr == RREnabled
        Pkg.test(pkg.name; julia_args=`$julia_args --load bugreport.jl`)
    else
        Pkg.test(pkg.name; julia_args)
    end

    println("\nTesting completed after $(elapsed(t0))")
catch
    println("\nTesting failed after $(elapsed(t0))\n")
    rethrow()
finally
    write("/output/duration", repr(cpu_time()-t0))
    write("/output/input_output", repr(io_bytes()-io0))
end
end
