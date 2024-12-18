# PkgEval.jl

*Evaluate Julia packages.*

PkgEval.jl is a package to test one or more Julia versions against the Julia
package ecosystem, and is used by Nanosoldier.jl for keeping track of package
compatibility of upcoming Julia versions.

Note that for now, **PkgEval.jl is Linux-only**, and even requires a
sufficiently recent kernel (at least 5.11, or a distribution like Ubuntu that
has back-ported support for unprivileged overlayfs mounts in user namespaces).


## Quick start

PkgEval is not a registered package, so you'll need to install it from Git:

```shell
git clone https://github.com/JuliaCI/PkgEval.jl.git
cd PkgEval.jl
julia --project -e 'import Pkg; Pkg.instantiate()'
```

While PkgEval uses user-namespaces and thus does not require `root` permissions,
some distributions have recently locked-down this feature for security reasons.
If you run into permission errors, try toggling any of the two `sysctl`s below
(by using `sysctl -w` or saving the setting in `/etc/sysctl.conf` or in a file
in `/etc/sysctl.d`):

```
kernel.unprivileged_userns_clone = 1
# or
kernel.apparmor_restrict_unprivileged_userns = 0
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


## Resource constraints

PkgEval uses cgroups for restricting the resources each package can use. By default however,
non-root users can control the `memory` and `pids` cgroup controllers. To enable PkgEval
to control more resources, run the following commands:

```
$ sudo mkdir -p /etc/systemd/system/user@.service.d
$ cat <<EOF | sudo tee /etc/systemd/system/user@.service.d/delegate.conf
[Service]
Delegate=cpu cpuset io memory pids
EOF
$ sudo systemctl daemon-reload
```

In addition, some container runtimes (i.e. `runc`) want full control over the current
cgroup, which can be done by launching Julia as a scoped service:

```
systemd-run --user --scope -p Delegate=yes julia ...
```
