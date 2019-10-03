# NewPkgEval - Evaluate julia packages

# Basic usage
In order to run PkgEval against a julia do the following:


1. Obtain NewPkgEval and install dependencies

```
git clone https://github.com/JuliaComputing/NewPkgEval.jl.git
cd NewPkgEval.jl
julia --project 'import Pkg; Pkg.instantiate()'
```


2. Build a julia binary distribution

You have two choices. Either you build a binary distribution of julia yourself
(or let the buildbots do it), or you may use NewPkgEval to do it for you:

```jl
import NewPkgEval
NewPkgEval.build_julia(ref="master"; binarybuilder_args=String["--verbose"])
```

where `ref` is a GitHub reference (branch, commit or tag, for example `"v1.2.0"`).
This will register a in deps/Versions.toml, using a stanza that looks like so:
```
["1.2.0"]
file = "julia.v1.2.0.x86_64-linux-gnu.tar.gz"
sha = "9c796bfd7cb53604d6b176c45d38069d8f816efbe69d717b92d713bc080c89eb"
```

If you get a permission error, try to set the variable

`BINARYBUILDER_RUNNER=privileged`

restart Julia and try again.

The builder uses the GitHub API and if you are not authenticated you might get rate limited (should only happen
if you build over and over again).
Setting the environment variable `GITHUB_AUTH` to a github authentication token will authenticate and avoid rate limiting

If something goes wrong, or you built julia yourself, you may have to add that stanza
manually and copy the tarball from the products/ directory into `deps/downloads`.


3. Try the julia sandbox environment

To see that things work as expected, try to run

```
julia> NewPkgEval.run_sandboxed_julia(`-e 'print("hello")'`; ver=v);
hello
```

which will execute the julia command in the sandbox environment of the newly built julia.


4. Run PkgEval

```julia
using NewPkgEval
pkgs = NewPkgEval.read_pkgs();
dg = NewPkgEval.PkgDepGraph(pkgs, v"1.2.0")
results = NewPkgEval.run(dg, 20, v"1.2.0")
```

See the docstrings for more arguments.

If you have problem running more than 1 worker at a time try set the environment variable

``` 
BINARYBUILDER_USE_SQUASHFS=false
``` 
