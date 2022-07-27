using PkgEval
using Test

pkgnames = ["TimerOutputs", "Crayons", "Example", "Gtk"]

julia = get(ENV, "JULIA", string(VERSION))
@testset "PkgEval using Julia $julia" begin

@testset "sandbox" begin
    config = Configuration(; julia)
    install = PkgEval.prepare_julia(config)

    mktemp() do path, io
        try
            PkgEval.sandboxed_julia(config, install, `-e 'print(1337)'`; stdout=io)
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
    PkgEval.sandboxed_julia(config, install, `-e 'using InteractiveUtils; versioninfo()'`)
end

@testset "time and output limits" begin
    # timeouts
    results = PkgEval.evaluate([Configuration(; julia, time_limit=0.1)], pkgnames;
                               update_registry=false)
    @test all(results.status .== :kill) && all(results.reason .== :time_limit)

    # log limit
    results = PkgEval.evaluate([Configuration(; julia, log_limit=1)], pkgnames;
                               update_registry=false)
    @test all(results.status .== :kill) && all(results.reason .== :log_limit)
end

@testset "main entrypoint" begin
    results = PkgEval.evaluate([Configuration(; julia)], pkgnames;
                               update_registry=false)
    if !(julia == "master" || julia == "nightly")
        @test all(results.status .== :ok)
        for result in eachrow(results)
            @test occursin("Testing $(result.name) tests passed", result.log)
        end
    end
end

@testset "PackageCompiler" begin
    results = PkgEval.evaluate([Configuration(; julia, compiled=true)], ["Example"];
                               update_registry=false)
    if !(julia == "master" || julia == "nightly")
        @test all(results.status .== :ok)
        for result in eachrow(results)
            @test occursin("Testing $(result.name) tests passed", result.log)
        end
    end
end

end
