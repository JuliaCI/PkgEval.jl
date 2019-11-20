using NewPkgEval
using Test

# determine the version to use
const ref = get(ENV, "JULIA_VERSION", string(VERSION))
const ver = try
    # maybe it refers to a version in Versions.toml
    NewPkgEval.obtain_julia(ref)
    ref
catch
    # assume it points to something in our Git repository
    NewPkgEval.build_julia(ref)
end

@testset "sandbox" begin
    mktemp() do path, io
        NewPkgEval.run_sandboxed_julia(`-e 'print(1337)'`; ver=ver, stdout=io)
        close(io)
        @test read(path, String) == "1337"
    end

    NewPkgEval.run_sandboxed_julia(`-e 'using InteractiveUtils; versioninfo()'`; ver=ver)
end

@testset "PkgEval" begin
    pkgnames = ["JSON", "TimerOutputs", "Crayons", "Example"]
    pkgs = NewPkgEval.read_pkgs(pkgnames)

    results = NewPkgEval.run(pkgs, 2, ver; time_limit = 0.1)
    for pkg in pkgnames
        @test results[pkg] == :killed
    end

    results = NewPkgEval.run(pkgs, 2, ver)
    for pkg in pkgnames
        @test results[pkg] == :ok
        output = read(joinpath(NewPkgEval.log_path(ver), "$pkg.log"), String)
        @test occursin("Testing $pkg tests passed", output)
    end
end
