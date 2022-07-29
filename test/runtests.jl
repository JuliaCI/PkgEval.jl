using PkgEval
using Test

julia = get(ENV, "JULIA", string(VERSION))
julia_version = tryparse(VersionNumber, julia)
@testset "PkgEval using Julia $julia" begin

@testset "sandbox" begin
    config = Configuration(; julia)
    install = PkgEval.install_julia(config)

    let
        p = Pipe()
        close(p.in)
        PkgEval.sandboxed_julia(config, install, `-e 'print(1337)'`; stdout=p.out)
        @test read(p.out, String) == "1337"
    end
end

@testset "julia installation" begin
    let results = evaluate([Configuration(; julia)],
                           [Package(; name="Example")])
        @test size(results, 1) == 1
        @test results[1, :julia_spec] == julia
        if julia_version !== nothing
            @test results[1, :julia_version] == julia_version
        end
    end
end

@testset "package installation" begin
    # by name
    let results = evaluate([Configuration(; julia)],
                           [Package(; name="Example")])
        @test size(results, 1) == 1
        @test results[1, :name] == "Example"
        @test results[1, :version] isa VersionNumber
        @test results[1, :status] == :ok
    end

    # specifying a version
    let results = evaluate([Configuration(; julia)],
                           [Package(; name="Example", version=v"0.5.3")])
        @test size(results, 1) == 1
        @test results[1, :name] == "Example"
        @test results[1, :version] == v"0.5.3"
        @test results[1, :status] == :ok
    end

    # specifying a revision
    let results = evaluate([Configuration(; julia)],
                           [Package(; name="Example", rev="master")])
        @test size(results, 1) == 1
        @test results[1, :name] == "Example"
        @test results[1, :status] == :ok
        @test contains(results[1, :log], "https://github.com/JuliaLang/Example.jl.git#master")
    end

    # specifying the URL
    let results = evaluate([Configuration(; julia)],
                           [Package(; name="Example", url="https://github.com/JuliaLang/Example.jl")])
        @test size(results, 1) == 1
        @test results[1, :name] == "Example"
        @test results[1, :status] == :ok
        @test contains(results[1, :log], "https://github.com/JuliaLang/Example.jl#master")
    end
end

@testset "time and output limits" begin
    # timeouts
    let results = evaluate([Configuration(; julia, time_limit=0.1)],
                           [Package(; name="Example")])
        @test size(results, 1) == 1
        @test results[1, :status] == :kill && results[1, :reason] == :time_limit
    end

    # log limit
    let results = evaluate([Configuration(; julia, log_limit=1)],
                           [Package(; name="Example")])
        @test size(results, 1) == 1
        @test results[1, :status] == :kill && results[1, :reason] == :log_limit
    end
end

@testset "complex packages" begin
    # some more complicate packages that are all expected to pass tests
    package_names = ["TimerOutputs", "Crayons", "Example", "Gtk"]
    packages = [Package(; name) for name in package_names]

    results = evaluate([Configuration(; julia)], packages)
    if !(julia == "master" || julia == "nightly")
        @test all(results.status .== :ok)
        for result in eachrow(results)
            @test occursin("Testing $(result.name) tests passed", result.log)
        end
    end
end

@testset "PackageCompiler" begin
    results = evaluate([Configuration(; julia, compiled=true)],
                       [Package(; name="Example")])
    if !(julia == "master" || julia == "nightly")
        @test all(results.status .== :ok)
        for result in eachrow(results)
            @test occursin("Testing $(result.name) tests passed", result.log)
        end
    end
end

end
