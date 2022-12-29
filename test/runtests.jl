using PkgEval
using Test
using Git

julia = get(ENV, "JULIA", "v"*string(VERSION))
julia_release = if contains(julia, r"^v\d")
    parse(VersionNumber, julia)
else
    # this is used to skip testing of actual packages,
    # which generally aren't supported on unreleased Julia versions.
    nothing
end
buildflags = get(ENV, "BUILDFLAGS", "")
@testset "PkgEval using Julia $julia" begin

@testset "Configuration" begin
    # default object: nothing modified
    x = Configuration()
    for field in fieldnames(Configuration)
        @test !ismodified(x, field)
    end

    # setting a field
    y = Configuration(rr=!x.rr)         # make sure we pick a different value
    @test ismodified(y, :rr)
    for field in fieldnames(Configuration)
        if field in [:rr]
            continue
        end
        @test !ismodified(y, field)
    end

    # deriving a Configuration object
    z = Configuration(y; xvfb=x.xvfb)   # test that using the same value also works
    @test ismodified(z, :rr)
    @test ismodified(z, :xvfb)
    for field in fieldnames(Configuration)
        if field in [:rr, :xvfb]
            continue
        end
        @test !ismodified(z, field)
    end
end

config = let
    config_kwargs = Dict{Symbol,Any}(:julia => julia)
    if !isempty(buildflags)
        config_kwargs[:buildflags] = String[split(buildflags)...]
    end
    Configuration(; config_kwargs...)
end
@info sprint(io->print(io, config))

@testset "julia installation" begin
    let
        p = Pipe()
        close(p.in)
        PkgEval.sandboxed_julia(config, `-e 'print(1337)'`; stdout=p.out)
        @test read(p.out, String) == "1337"
    end

    # try to compare the version info
    global julia_version
    julia_version = let
        p = Pipe()
        close(p.in)
        PkgEval.sandboxed_julia(config, `-e 'print(VERSION)'`; stdout=p.out)
        VersionNumber(read(p.out, String))
    end
    if julia_release !== nothing
        @test julia_version == julia_release
    end
end

@testset "environment flags" begin
    let
        p = Pipe()
        close(p.in)
        PkgEval.sandboxed_julia(config, `-e 'print(get(ENV, "FOO", nothing))'`; stdout=p.out)
        @test read(p.out, String) == "nothing"
    end

    let config = Configuration(config; env=["FOO=bar"])
        p = Pipe()
        close(p.in)
        PkgEval.sandboxed_julia(config, `-e 'print(get(ENV, "FOO", nothing))'`; stdout=p.out)
        @test read(p.out, String) == "bar"
    end
end

@testset "package installation" begin
    # by name
    let results = evaluate([config],
                           [Package(; name="Example")])
        @test size(results, 1) == 1
        @test results[1, :package] == "Example"
        @test results[1, :version] isa VersionNumber
        @test results[1, :status] == :ok
    end

    # specifying a version
    let results = evaluate([config],
                           [Package(; name="Example", version=v"0.5.3")];
                           validate=false)
        @test size(results, 1) == 1
        @test results[1, :package] == "Example"
        @test results[1, :version] == v"0.5.3"
        @test results[1, :status] == :ok
    end

    # specifying a revision
    let results = evaluate([config],
                           [Package(; name="Example", rev="master")];
                           validate=false)
        @test size(results, 1) == 1
        @test results[1, :package] == "Example"
        @test results[1, :status] == :ok
        @test contains(results[1, :log], "https://github.com/JuliaLang/Example.jl.git#master")
    end

    # specifying the URL
    let results = evaluate([config],
                           [Package(; name="Example", url="https://github.com/JuliaLang/Example.jl")];
                           validate=false)
        @test size(results, 1) == 1
        @test results[1, :package] == "Example"
        @test results[1, :status] == :ok
        @test contains(results[1, :log], "https://github.com/JuliaLang/Example.jl#master")
    end
end

julia_version >= v"1.9-beta2" && @testset "package precompilation" begin
    # find out where Example.jl will be precompiled
    verstr = "v$(julia_version.major).$(julia_version.minor)"
    compilecache = joinpath(PkgEval.get_compilecache(config), verstr, "Example")

    # wipe the cache and evaluate Example.jl
    rm(compilecache, recursive=true, force=true)
    PkgEval.evaluate_test(config, Package(; name="Example"))

    # make sure we only generated one package image
    @test isdir(compilecache)
    @test length(filter(endswith(".so"), readdir(compilecache))) == 1
end

@testset "time and output limits" begin
    # timeouts
    let results = evaluate([Configuration(config; time_limit=1.)],
                           [Package(; name="Example")];
                           validate=false, retry=false)
        @test size(results, 1) == 1
        @test results[1, :status] == :kill && results[1, :reason] == :time_limit
    end

    # log limit
    let results = evaluate([Configuration(config; log_limit=1)],
                           [Package(; name="Example")];
                           validate=false, retry=false)
        @test size(results, 1) == 1
        @test results[1, :status] == :kill && results[1, :reason] == :log_limit
    end
end

@testset "blacklist" begin
    let results = evaluate([config], [Package(; name="Example")];
                           validate=false, retry=false, blacklist=["Example"])
        @test size(results, 1) == 1
        @test results[1, :status] == :skip && results[1, :reason] == :blacklisted
    end
end

@testset "complex packages" begin
    # some more complicate packages that are all expected to pass tests
    package_names = ["TimerOutputs", "Crayons", "Example", "Gtk"]
    packages = [Package(; name) for name in package_names]

    results = evaluate([config], packages; validate=false)
    if julia_release !== nothing
        @test all(results.status .== :ok)
        for result in eachrow(results)
            @test occursin("Testing $(result.package) tests passed", result.log)
        end
    end
end

@testset "PackageCompiler" begin
    results = evaluate([Configuration(config; name="regular"),
                        Configuration(config; name="compiled", compiled=true)],
                       [Package(; name="Example")];
                       validate=false)
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
    results = evaluate([Configuration(config; rr=true)],
                       [Package(; name="Example")];
                       validate=false)
    @test all(results.status .== :ok)
    @test contains(results[1, :log], "BugReporting")
    if julia_release !== nothing
        @test results[1, :status] == :ok
        @test contains(results[1, :log], "Testing Example tests passed")
    end
end

@testset "stdlibs" begin
    stdlibs = ["UUIDs"]
    non_stdlibs = ["Example"]
    packages = [Package(; name) for name in [stdlibs; non_stdlibs]]

    results = evaluate([config], packages; validate=false)
    @test all(results.status .== :ok)
    for result in eachrow(results)
        if result.package in stdlibs
            @test contains(result.log, "is a standard library")
        else
            @test !contains(result.log, "is a standard library")
        end
    end
end

@testset "scripts" begin
    function julia_exec(args::Cmd, env...)
        cmd = Base.julia_cmd()
        cmd = `$cmd --project=$(Base.active_project()) --color=no $args`

        out = Pipe()
        err = Pipe()
        proc = run(pipeline(addenv(cmd, env...), stdout=out, stderr=err), wait=false)
        close(out.in)
        close(err.in)
        wait(proc)
        proc, read(out, String), read(err, String)
    end

    scripts_dir = joinpath(@__DIR__, "..", "bin")

    # NOTE: we're not using the Julia version configured here,
    #       because custom builds and nightlies aren't cached.
    @testset "test_package(released package)" begin
        script = joinpath(scripts_dir, "test_package.jl")
        proc, out, err = julia_exec(`$script --julia=1.8 --name=Example`)
        isempty(err) || println(err)
        success(proc) || println(out)
        @test success(proc)
    end
    @testset "test_package(local package)" begin
        mktempdir() do dir
            run(`$(git()) clone --quiet https://github.com/JuliaLang/Example.jl $dir`)
            script = joinpath(scripts_dir, "test_package.jl")
            proc, out, err = julia_exec(`$script --julia=1.8 --name=Example --path=$dir`)
            isempty(err) || println(err)
            success(proc) || println(out)
            @test success(proc)
            @test contains(out, r"Example.*#master")
        end
    end
end

PkgEval.purge()

end
