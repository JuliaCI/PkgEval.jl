using NewPkgEval
using Test

# determine the version to use
const version = get(ENV, "JULIA_VERSION", string(VERSION))
const julia = try
    # maybe it already refers to a version in Versions.toml
    v = VersionNumber(version)
    NewPkgEval.prepare_julia(v)
    v
catch
    # maybe it points to a build in Builds.jl
    try
        NewPkgEval.download_julia(version)
    catch
        # assume it points to something in our Git repository
        NewPkgEval.build_julia(version)
    end
end
NewPkgEval.prepare_julia(julia::VersionNumber)

@testset "sandbox" begin
    NewPkgEval.prepare_runner()
    mktemp() do path, io
        NewPkgEval.run_sandboxed_julia(julia, `-e 'print(1337)'`; stdout=io)
        close(io)
        @test read(path, String) == "1337"
    end

    # print versioninfo so we can verify in CI logs that the correct version is used
    NewPkgEval.run_sandboxed_julia(julia, `-e 'using InteractiveUtils; versioninfo()'`)
end

const pkgnames = ["TimerOutputs", "Crayons", "Example"]

@testset "low-level interface" begin
    NewPkgEval.prepare_registry()

    pkgs = NewPkgEval.read_pkgs(pkgnames)

    # timeouts
    results = NewPkgEval.run([julia], pkgs; time_limit = 0.1)
    @test all(results.status .== :kill)
end

@testset "main entrypoint" begin
    results = NewPkgEval.run([julia], pkgnames)
    @test all(results.status .== :ok)
    for pkg in pkgnames
        output = read(joinpath(NewPkgEval.log_path(julia), "$pkg.log"), String)
        @test occursin("Testing $pkg tests passed", output)
    end
end

@testset "reporting" begin
    lts = v"1.0.5"
    stable = v"1.2.0"
    results = NewPkgEval.run([lts, stable], ["Example"])
    NewPkgEval.compare(results, lts, stable)
    NewPkgEval.render(results)
end
