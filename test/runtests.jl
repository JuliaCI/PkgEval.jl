using PkgEval
using Test

julia = get(ENV, "JULIA", string(VERSION))
julia_release = if contains(julia, r"^v\d")
    parse(VersionNumber, julia)
else
    nothing
end
@testset "PkgEval using Julia $julia" begin

@testset "julia installation" begin
    config = Configuration(; julia)

    let
        p = Pipe()
        close(p.in)
        PkgEval.sandboxed_julia(config, `-e 'print(1337)'`; stdout=p.out)
        @test read(p.out, String) == "1337"
    end

    # try to compare the version info
    if julia_release !== nothing
        p = Pipe()
        close(p.in)
        PkgEval.sandboxed_julia(config, `-e 'println(VERSION)'`; stdout=p.out)
        version_str = read(p.out, String)
        @test parse(VersionNumber, version_str) == julia_release
    end
end

@testset "package installation" begin
    # by name
    let results = evaluate([Configuration(; julia)],
                           [Package(; name="Example")])
        @test size(results, 1) == 1
        @test results[1, :package] == "Example"
        @test results[1, :version] isa VersionNumber
        @test results[1, :status] == :ok
    end

    # specifying a version
    let results = evaluate([Configuration(; julia)],
                           [Package(; name="Example", version=v"0.5.3")])
        @test size(results, 1) == 1
        @test results[1, :package] == "Example"
        @test results[1, :version] == v"0.5.3"
        @test results[1, :status] == :ok
    end

    # specifying a revision
    let results = evaluate([Configuration(; julia)],
                           [Package(; name="Example", rev="master")])
        @test size(results, 1) == 1
        @test results[1, :package] == "Example"
        @test results[1, :status] == :ok
        @test contains(results[1, :log], "https://github.com/JuliaLang/Example.jl.git#master")
    end

    # specifying the URL
    let results = evaluate([Configuration(; julia)],
                           [Package(; name="Example", url="https://github.com/JuliaLang/Example.jl")])
        @test size(results, 1) == 1
        @test results[1, :package] == "Example"
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
    if julia_release !== nothing
        @test all(results.status .== :ok)
        for result in eachrow(results)
            @test occursin("Testing $(result.package) tests passed", result.log)
        end
    end
end

@testset "PackageCompiler" begin
    results = evaluate(Dict("regular"  => Configuration(; julia),
                            "compiled" => Configuration(; julia, compiled=true)),
                       [Package(; name="Example")])
    @test size(results, 1) == 2
    for result in eachrow(results)
        @test result.configuration in ["regular", "compiled"]
        if result.configuration == "regular"
            @test !contains(result.log, "PackageCompiler")
        elseif result.configuration == "compiled"
            @test contains(result.log, "PackageCompiler succeeded")
        end
        if julia_release !== nothing
            @test result.status == :ok
            @test contains(result.log, "Testing Example tests passed")
        end
    end
end

haskey(ENV, "CI") || @testset "rr" begin
    results = evaluate([Configuration(; julia, rr=true)],
                       [Package(; name="Example")])
    @test all(results.status .== :ok)
    @test contains(results[1, :log], "BugReporting")
    if julia_release !== nothing
        @test results[1, :status] == :ok
        @test contains(results[1, :log], "Testing Example tests passed")
    end
end

PkgEval.purge()

end
