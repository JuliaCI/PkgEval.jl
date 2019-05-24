using NewPkgEval
using Test

v = NewPkgEval.build_julia("v1.2.0")
pkgs = NewPkgEval.read_pkgs(["Crayons", "Example"])
dg = NewPkgEval.PkgDepGraph(pkgs, v)
results = NewPkgEval.run(dg, 1, v)
@test results["Example"] == :ok
@test results["Crayons"] == :ok
results = NewPkgEval.run(dg, 1, v; time_limit = 0.1)
@test results["Example"] == :fail
@test results["Crayons"] == :fail
