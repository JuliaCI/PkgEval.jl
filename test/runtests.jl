using PkgEval
using Test

pkgnames = ["TimerOutputs", "Crayons", "Example", "Gtk"]

julia = get(ENV, "JULIA", string(VERSION))
@testset "PkgEval using Julia $julia" begin

@testset "sandbox" begin
    config = Configuration(; julia)
    install = PkgEval.prepare_julia(config)

    let
        p = Pipe()
        close(p.in)
        PkgEval.sandboxed_julia(config, install, `-e 'print(1337)'`; stdout=p.out)
        @test read(p.out, String) == "1337"
    end

    # try to compare the version info
    let
        p = Pipe()
        PkgEval.sandboxed_julia(config, install, `-e 'println(VERSION)'`; stdout=p.out)
        version_str = read(p.out, String)
        requested_version = tryparse(VersionNumber, julia)
        if requested_version !== nothing
            @test parse(VersionNumber, version_str) == requested_version
        end
    end
end

@testset "time and output limits" begin
    # timeouts
    results = evaluate([Configuration(; julia, time_limit=0.1)], pkgnames;
                       update_registry=false)
    @test all(results.status .== :kill) && all(results.reason .== :time_limit)

    # log limit
    results = evaluate([Configuration(; julia, log_limit=1)], pkgnames;
                       update_registry=false)
    @test all(results.status .== :kill) && all(results.reason .== :log_limit)
end

@testset "main entrypoint" begin
    results = evaluate([Configuration(; julia)], pkgnames; update_registry=false)
    if !(julia == "master" || julia == "nightly")
        @test all(results.status .== :ok)
        for result in eachrow(results)
            @test occursin("Testing $(result.name) tests passed", result.log)
        end
    end
end

@testset "PackageCompiler" begin
    results = evaluate([Configuration(; julia, compiled=true)], ["Example"];
                       update_registry=false)
    if !(julia == "master" || julia == "nightly")
        @test all(results.status .== :ok)
        for result in eachrow(results)
            @test occursin("Testing $(result.name) tests passed", result.log)
        end
    end
end

end
