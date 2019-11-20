using NewPkgEval
using Test

# determine the version to use
const verstr = get(ENV, "JULIA_VERSION", string(VERSION))
const v = try
    ver = VersionNumber(verstr)
    NewPkgEval.obtain_julia(ver)
    ver
catch
    # either the string is an invalid version number (assume it is a git ref),
    # or we couldn't obtain this version
    NewPkgEval.build_julia(verstr)
end

@testset "sandbox" begin
    mktemp() do path, io
        NewPkgEval.run_sandboxed_julia(`-e 'print(1337)'`; ver=v, stdout=io)
        close(io)
        @test read(path, String) == "1337"
    end
end

@testset "PkgEval" begin
    pkgnames = ["JSON", "TimerOutputs", "Crayons", "Example"]
    pkgs = NewPkgEval.read_pkgs(pkgnames)

    results = NewPkgEval.run(pkgs, 2, v; time_limit = 0.1)
    for pkg in pkgnames
        @test results[pkg] == :fail
    end

    results = NewPkgEval.run(pkgs, 2, v)
    for pkg in pkgnames
        @test results[pkg] == :ok
        output = read(joinpath(NewPkgEval.log_path(v), "$pkg.log"), String)
        @test occursin("Testing $pkg tests passed", output)
    end
end
