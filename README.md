# NewPkgEval - Evaluate julia packages

# Basic usage
In order to run PkgEval against a julia branch do the following:

1. Obtain NewPkgEval
```
git clone git@github.com:JuliaComputing/NewPkgEval.jl.git
```

2. Build a julia binary distribution

You have to choices. Either you build a binary distribution of julia yourself
(or let the buildbots do it), you you may use the script that ships
with NewPkgEval to do it for you. To use the built-in script,
run
```
cd util
julia -e 'using Pkg; pkg"add BinaryBuilder"; pkg"add GitHub"'
julia build_julia.jl --verbose --branch my_branch
```
This will register a julia version called `1.2.0-my_branch` in deps/Versions.toml,
using a stanza that looks like so:
```
["1.2.0-my_branch"]
file = "julia.v1.2.0-my_branch.x86_64-linux-gnu.tar.gz"
sha = "9c796bfd7cb53604d6b176c45d38069d8f816efbe69d717b92d713bc080c89eb"
```
If something goes wrong, or you built julia yourself, you may have to add that stanza
manually and copy the tarball from the products/ directory into `deps/downloads`.

3. Run PkgEval
```julia
using NewPkgEval
pkgs = NewPkgEval.read_all_pkgs();
dg = NewPkgEval.PkgDepGraph(pkgs, v"1.2.0-my_branch")
results = NewPkgEval.run_all(dg, 20, v"1.2.0-my_branch")
```
