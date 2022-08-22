# PkgEval.jl

*Evaluate Julia packages.*


## Quick start

PkgEval is not a registered package, so you'll need to install it from Git:

```shell
git clone https://github.com/JuliaCI/PkgEval.jl.git
cd PkgEval.jl
julia --project -e 'import Pkg; Pkg.instantiate()'
```

Then start Julia with `julia --project` and use the following commands to run the tests of a
list of packages on a selection of Julia configurations:

```julia
julia> using PkgEval

julia> config = Configuration(; julia="1.7");

julia> package = Package(; name="Example");

julia> evaluate([config], [package])
1×9 DataFrame
 Row │ julia_spec  julia_version  compiled  name     version    ⋯
     │ String      VersionNumber  Bool      String   VersionN…? ⋯
─────┼───────────────────────────────────────────────────────────
   1 │ 1.7         1.7.0             false  Example  0.5.3      ⋯
                                                4 columns omitted
```

Test logs are part of this dataframe in the `log` column. For example, in this case:

```
Resolving package versions...
Installed Example ─ v0.5.3
...
Testing Example tests passed
```


## Why does my package fail?

If you want to debug why your package fails, it's probably easiest to use an interactive
shell:

```julia
julia> using PkgEval

julia> config = Configuration()
PkgEval configuration(
  ...
)

julia> PkgEval.sandboxed_julia(config)

   _       _ _(_)_     |  Documentation: https://docs.julialang.org
  (_)     | (_) (_)    |
   _ _   _| |_  __ _   |  Type "?" for help, "]?" for Pkg help.
  | | | | | | |/ _` |  |
  | | |_| | | | (_| |  |  Version 1.9.0-DEV.1163 (2022-08-21)
 _/ |\__'_|_|_|\__'_|  |  Commit 696f7d3dfe1 (1 day old master)
|__/                   |

julia> # we're in the PkgEval sandbox here
```

Now you can install, load and test your package. This will, by default, use a nightly build
of Julia. If you want PkgEval.jl to compile Julia, e.g. to test a specific version, create
a Configuration instance as such:

```julia
julia> config = Configuration(julia="master",
                              buildflags=["JULIA_CPU_TARGET=native", "JULIA_PRECOMPILE=0"])

# NOTE: buildflags are specified to speed-up the build
```
