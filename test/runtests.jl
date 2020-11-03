using NewPkgEval
using Test

# determine the version to use
const version = get(ENV, "JULIA_VERSION", string(VERSION))
@info "Testing with Julia $version"
const julia = NewPkgEval.obtain_julia(version)::VersionNumber
@info "Resolved to Julia v$julia"
const install = NewPkgEval.prepare_julia(julia)

@testset "sandbox" begin
    NewPkgEval.prepare_runner()
    mktemp() do path, io
        NewPkgEval.run_sandboxed_julia(install, `-e 'print(1337)'`; stdout=io,
                                       tty=false, interactive=false)
        close(io)
        @test read(path, String) == "1337"
    end

    # print versioninfo so we can verify in CI logs that the correct version is used
    NewPkgEval.run_sandboxed_julia(install, `-e 'using InteractiveUtils; versioninfo()'`;
                                   tty=false, interactive=false)
end

const pkgnames = ["TimerOutputs", "Crayons", "Example", "Gtk"]

@testset "low-level interface" begin
    NewPkgEval.prepare_registry()

    pkgs = NewPkgEval.read_pkgs(pkgnames)

    # timeouts
    results = NewPkgEval.run([julia], pkgs; time_limit = 0.1)
    @test all(results.status .== :kill)
end

@testset "main entrypoint" begin
    results = NewPkgEval.run([julia], pkgnames)
    if !(version == "master" || version == "nightly")
        @test all(results.status .== :ok)
        for result in eachrow(results)
            @test occursin("Testing $(result.name) tests passed", result.log)
        end
    end
end

@testset "reporting" begin
    lts = v"1.0.5"
    stable = v"1.2.0"
    results = NewPkgEval.run([lts, stable], ["Example"])
    NewPkgEval.compare(results, lts, stable)
end

NewPkgEval.purge()
rm(install; recursive=true)
