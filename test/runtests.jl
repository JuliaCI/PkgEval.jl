using NewPkgEval
using Test

v = NewPkgEval.build_julia("v1.2.0")

pkgnames = ["JSON", "TimerOutputs", "Crayons", "Example"]
pkgs = NewPkgEval.read_pkgs(pkgnames)
results = NewPkgEval.run(pkgs, 2, v)
for pkg in pkgnames
    @test results[pkg] == :ok
    output = read(joinpath(@__DIR__, "..", logs, "logs-"*string(v), pkg*".log"), String)
    @test occursin("Testing $pkg tests passed", output)
end
results = NewPkgEval.run(pkgs, 2, v; time_limit = 0.1)
for pkg in pkgnames
    @test results[pkg] == :fail
end

mktemp() do path, io
    NewPkgEval.run_sandboxed_julia(`-e 'print(1337)'`; ver=v"1.1.1", stdout=io)
    close(io)
    @test read(path, String) == "1337"
end
