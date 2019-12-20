# NewPkgEval.jl

*Evaluate Julia packages.*


## Quick start

To use NewPkgEval.jl, you need to Docker and make sure you can start containers (typically,
you need to be a member of the `docker` group):

```
$ docker run hello-world
Hello from Docker!
This message shows that your installation appears to be working correctly.
```

Start by installing the package:

```shell
git clone https://github.com/JuliaComputing/NewPkgEval.jl.git
cd NewPkgEval.jl
julia --project -e 'import Pkg; Pkg.instantiate()'
```

Then start Julia with `julia --project` and use the following commands to run the tests of a
list of packages on a selection of Julia versions:

```julia
julia> using NewPkgEval

julia> julia_versions = NewPkgEval.obtain_julia.(["1.3", "nightly"])
2-element Array{VersionNumber,1}:
 v"1.3.0"
 v"1.4.0-DEV-3c182bc5c2"

julia> NewPkgEval.run(julia_versions, ["Example"])
2×8 DataFrames.DataFrame. Omitted printing of 1 columns
│ Row │ julia                   │ registry │ name    │ version   │ status │ reason  │ duration │
│     │ VersionNumber           │ String   │ String  │ Version…⍰ │ Symbol │ Symbol⍰ │ Float64  │
├─────┼─────────────────────────┼──────────┼─────────┼───────────┼────────┼─────────┼──────────┤
│ 1   │ v"1.3.0"                │ General  │ Example │ v"0.5.3"  │ ok     │ missing │ 6.94     │
│ 2   │ v"1.4.0-DEV-3c182bc5c2" │ General  │ Example │ v"0.5.3"  │ ok     │ missing │ 6.948    │
```

Detailed logs will be generated in the `logs/` directory. For this example,
`logs/logs-1.3.0/Example.log` would contain:

```
Resolving package versions...
Installed Example ─ v0.5.3
...
Testing Example tests passed
```

Other `run` methods, that offer more options and control over the testing process, are
available as well. These methods however require you to first prepare the environment
yourself, by calling `prepare_registry` to set-up the package registry, `prepare_runner` to
build the Docker image, and `prepare_julia` to download and unpack a binary version of
Julia.


## Why does my package fail?

If you want to debug why your package fails, it's probably easiest to use an interactive
shell:

```julia
julia> using NewPkgEval

julia> julia_version = v"1.3.0"  # use `obtain_julia` if you need a specific build

julia> NewPkgEval.prepare_julia(julia_version)
julia> NewPkgEval.prepare_runner()
julia> NewPkgEval.prepare_registry()

julia> NewPkgEval.run_sandboxed_julia(julia_version)
```

Now you can install, load end test your package. If that fails because of some missing
dependency, you can just install that using the `apt` package manager within the container:

```
julia> # in the spawned container's Julia session, switch to REPL mode by pressing ;

shell> sudo apt update
shell> sudo apt install ...
```

Once you've found the missing dependency and verified that it fixes the tests of your
package, make a [pull
request](https://github.com/JuliaComputing/NewPkgEval.jl/edit/master/runner/Dockerfile) to
include the dependency in the default image.


## Analyzing results

Most of the time, you will want to compare the results that you obtained. For example:

```julia
julia> result = NewPkgEval.run([v"1.2.0", v"1.4.0-DEV-76ebc419f0"], ["AbstractNumbers"])
2×8 DataFrame. Omitted printing of 1 columns
│ Row │ julia                   │ registry │ name            │ version   │ status │ reason        │ duration │
│     │ VersionNumber           │ String   │ String          │ Version…⍰ │ Symbol │ Symbol⍰       │ Float64  │
├─────┼─────────────────────────┼──────────┼─────────────────┼───────────┼────────┼───────────────┼──────────┤
│ 1   │ v"1.2.0"                │ General  │ AbstractNumbers │ v"0.2.0"  │ ok     │ missing       │ 24.768   │
│ 2   │ v"1.4.0-DEV-76ebc419f0" │ General  │ AbstractNumbers │ v"0.2.0"  │ fail   │ test_failures │ 26.803   │
```

If you simply want to compare two Julia versions, use `NewPkgEval.compare`:

```julia
julia> NewPkgEval.compare(result, v"1.2.0", v"1.4.0-DEV-76ebc419f0")
On v1.4.0-DEV-76ebc419f0, out of 1 packages 0 passed, 1 failed, 0 got killed and 0 were skipped.

Comparing against v1.2.0:
- AbstractNumbers status was ok, now fail (reason: test_failures)
In summary, 0 packages now succeed, while 1 have started to fail.
```

For more extensive evaluations, or when more versions are involved, use `NewPkgEval.render`
to generate a HTML site in the `website/build` directory at the root of the repository:

```julia
julia> NewPkgEval.render(result)
Generating site at /home/tim/Julia/pkg/NewPkgEval/site/build
```


## Choosing a different version of Julia

NewPkgEval ultimately needs a binary build of Julia to run tests with, but there's multiple
options to provide such a build. The easiest option is to use a version number that has
already been registered in the `Versions.toml` database, together with an URL and hash to
download an verify the file. An error will be thrown if the specific version cannot be
found. This is done automatically when the `prepare_julia` function is called (you will need
to call this method explicitly if you use a lower-level interface, i.e., anything but the
`run` function from the quick start section above):

```
julia> NewPkgEval.prepare_julia(v"1.2.0-nonexistent")
ERROR: Requested Julia version not found
```

Alternatively, you can download a named release as listed in `Releases.toml`. By calling
`obtain_julia_release` with a release name, this release will be downloaded, hashed, and
added to the `Versions.toml` database for later use. The method returns the version number
that corresponds with this added entry; you should use it when calling into other functions
of the package:

```julia
julia_version = NewPkgEval.obtain_julia_release("nightly")
NewPkgEval.run([julia_version], ...)
```

For even more control, you can build Julia by calling the `perform_julia_build` function,
passing a string that identifies a branch, tag or commit in the Julia Git repository:

```julia
julia_version = NewPkgEval.perform_julia_build("master")
```

Similarly, this function returns a version number that corresponds with an entry added to
`Versions.toml`:

```
["1.4.0-DEV-8f7855a7c3"]
file = "julia-1.4.0-DEV-8f7855a7c3.tar.gz"
sha = "dcd105b94906359cae52656129615a1446e7aee1e992ae9c06a15554d83a46f0"
```

If you get a permission error while building Julia, try to set the variable
`BINARYBUILDER_RUNNER=privileged`, restart Julia and try the build again.

To facilitate all this, there's a higher-level function `obtain_julia` that will try each of
the above methods until a valid version is found and returned. It is of course also possible
to build Julia yourself, in which case you will need to create a tarball, copy it to the
`deps/downloads` directory, and add a correct version stanza to `Versions.toml`.
