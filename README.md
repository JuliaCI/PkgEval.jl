# PkgEval.jl

*Evaluate Julia packages.*

PkgEval.jl is a package to test one or more Julia versions against the Julia
package ecosystem, and is used by Nanosoldier.jl for keeping track of package
compatibility of upcoming Julia versions.

Note that for now, **PkgEval.jl is Linux-only**, and even requires a
sufficiently recent kernel (at least 5.11, or a distribution like Ubuntu that
has back-ported support for unprivileged overlayfs mounts in user namespaces).

On other platforms, such as macOS, the `bin/evaluate.jl` script (see below) can
still be used: given a Docker-compatible container runtime (Docker Desktop,
OrbStack, Colima, ...), it automatically re-executes itself inside a Linux
container, where the sandboxing code works as-is. Note that on Apple silicon
this evaluates the aarch64 build of Julia, whereas Nanosoldier tests x86_64,
so results may (rarely) differ.


## Quick start

PkgEval is not a registered package, so you'll need to install it from Git:

```shell
git clone https://github.com/JuliaCI/PkgEval.jl.git
cd PkgEval.jl
julia --project -e 'import Pkg; Pkg.instantiate()'
```

You may also have to explicitly allow user namespaces, as well as dial down perf
event restrictions for `rr` to work. Both of these are configured through sysctl,
e.g., by creating `/etc/sysctl.d/99-pkgeval.conf` with the following contents:

```
# for crun (only needed on recent Ubuntu/Debian)
kernel.unprivileged_userns_clone = 1
kernel.apparmor_restrict_unprivileged_userns = 0

# for rr (only needed when you want to run under `rr`)
kernel.perf_event_paranoid = 1

# creating this file requires a `systemctl restart systemd-sysctl` or reboot to apply
```

Optionally, for resource constraints to work, you have to configure the systemd
user service to delegate additional control groups:

```
$ sudo mkdir -p /etc/systemd/system/user@.service.d
$ cat <<EOF | sudo tee /etc/systemd/system/user@.service.d/delegate.conf
[Service]
Delegate=cpu cpuset io memory pids
EOF
$ sudo systemctl daemon-reload
```

To quickly test a package, a script has been provided under the `bin/` folder:

```shell
$ julia --project bin/test_package.jl --name=Example
Package evaluation of Example started at 2022-11-27T09:30:27.777
...
Testing completed after 1.04s
```

This script can also be used to test specific versions of a package by setting any of the
`--version`, `--rev`, or `--url` arguments. To test a version of a package you only have
locally, e.g., a development version, use the `--path` argument instead:

```shell
$ julia --project bin/test_package.jl --name Example --path=~/.julia/dev/Example
```

By default, this will use the latest `nightly` version of Julia, which is what PkgEval
uses. To use another version, use the `--julia` argument, e.g., `--julia=1.11`.

To evaluate many packages at once, and generate an HTML report like the ones Nanosoldier
produces in response to `@nanosoldier runtests()`, use `bin/evaluate.jl`. For example, to
compare a local build of Julia against the nightly release, using all packages that
depend on Crayons:

```shell
$ julia --project bin/evaluate.jl --primary=~/Julia/julia/usr --against=nightly \
        --depends-on=Crayons --output=/tmp/crayons-report
```

The `--primary` and `--against` flags accept a version number, a release name
(`nightly`, `stable`), a repository spec (`myfork/julia#branch`, built from source if no
CI binaries are available), or the path to a local Julia installation. Packages are
selected with `--packages=A,B,C` or `--depends-on=Y` (add `--transitive=true` for
indirect dependents); without a selection, the whole registry is evaluated. The output
directory is self-contained: `report.html` links to the per-package logs stored next to
it. See `--help` for all options.


## API

To use PkgEval programmatically, there are three main interfaces do deal with:

- `Configuration` objects to determine how to execute tests (which Julia version, build
  flags, any environment variables, ...)
- `Package` objects to select packages to test
- the `evaluate` function to evaluate every package on each provieded configuration,
  returning the results in a DataFrame

```julia-repl
julia> using PkgEval

julia> config = Configuration(; julia="1.10");

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

### Selecting packages by dependency

To test a set of packages related to another package, e.g., all the packages that would be
affected by a change to one of your packages, use `PkgEval.package_dependents` to query the
registry's dependency graph:

```julia-repl
julia> config = Configuration();

# all packages that directly depend on Crayons, excluding JLL packages
julia> names = filter(!endswith("_jll"), PkgEval.package_dependents(config, "Crayons"; transitive=false));

# all packages that transitively depend on Crayons
julia> names = PkgEval.package_dependents(config, "Crayons");

julia> evaluate([config], [Package(; name) for name in names])
```

The related `PkgEval.package_dependencies(config)` returns the forward dependency graph,
i.e., a dictionary mapping each registered package to its dependencies.


## Why does my package fail?

If you want to debug why your package fails, it's probably easiest to use an interactive
shell:

```julia-repl
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

```julia-repl
julia> config = Configuration(julia="master",
                              buildflags=["JULIA_CPU_TARGET=native", "JULIA_PRECOMPILE=0"])

# NOTE: buildflags are specified to speed-up the build
```
