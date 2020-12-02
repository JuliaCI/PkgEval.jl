using PkgEval
using Test

# determine which Julia to use
const julia_spec = get(ENV, "JULIA_SPEC", string(VERSION))
@info "Testing with Julia $julia_spec"
const julia_version = PkgEval.obtain_julia(julia_spec)::VersionNumber
@info "Resolved to Julia v$julia_version"
const julia_install = PkgEval.prepare_julia(julia_version)

@testset "sandbox" begin
    PkgEval.prepare_runner()
    mktemp() do path, io
        try
            PkgEval.run_sandboxed_julia(julia_install, `-e 'print(1337)'`; stdout=io,
                                        tty=false, interactive=false)
            close(io)
            @test read(path, String) == "1337"
        catch
            # if we failed to spawn a container, make sure to print the reason
            flush(io)
            @error read(path, String)
            rethrow()
        end
    end

    # print versioninfo so we can verify in CI logs that the correct version is used
    PkgEval.run_sandboxed_julia(julia_install, `-e 'using InteractiveUtils; versioninfo()'`;
                                tty=false, interactive=false)
end

const pkgnames = ["TimerOutputs", "Crayons", "Example", "Gtk"]

@testset "low-level interface" begin
    PkgEval.prepare_registry()

    pkgs = PkgEval.read_pkgs(pkgnames)

    # timeouts
    results = PkgEval.run([Configuration(julia=julia_version)], pkgs; time_limit = 0.1)
    @test all(results.status .== :kill)
end

@testset "main entrypoint" begin
    results = PkgEval.run([Configuration(julia=julia_version)], pkgnames)
    if !(julia_spec == "master" || julia_spec == "nightly")
        @test all(results.status .== :ok)
        for result in eachrow(results)
            @test occursin("Testing $(result.name) tests passed", result.log)
        end
    end
end

@testset "reporting" begin
    lts = Configuration(julia=v"1.0.5")
    stable = Configuration(julia=v"1.2.0")
    results = PkgEval.run([lts, stable], ["Example"])
    PkgEval.compare(results, lts, stable)
end

PkgEval.purge()
rm(julia_install; recursive=true)
