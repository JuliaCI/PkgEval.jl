# NewPkgEval.jl

*Evaluate Julia packages.*


## Quick start

Start by installing the package:

```shell
git clone https://github.com/JuliaComputing/NewPkgEval.jl.git
cd NewPkgEval.jl
julia --project 'import Pkg; Pkg.instantiate()'
```

Then use the following commands to run the tests of a list of packages on a specific version
of Julia:

```julia
julia> using NewPkgEval

julia> NewPkgEval.run(v"1.2.0", ["Example"])
Dict{String,Symbol} with 1 entry:
  "Example" => :ok
```

Detailed logs will be generated in the `logs/` directory. For this example,
`logs/logs-1.2.0/Example.log` would contain:

```
Resolving package versions...
Installed Example ─ v0.5.3
...
Testing Example tests passed
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

Alternatively, you can download a named release as listed in `Builds.toml`. By calling
`download_julia` with a release name, this release will be downloaded, hashed, and added to
the `Versions.toml` database for later use. The method returns the version number that
corresponds with this added entry; you should use it when calling into other functions of
the package:

```julia
julia_version = NewPkgEval.download_julia("latest")
NewPkgEval.run(julia_version, ...)
```

For even more control, you can build Julia by calling the `build_julia` function, passing a
string that identifies a branch, tag or commit in the Julia Git repository:

```julia
julia_version = NewPkgEval.build_julia("master")
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

Finally, it is also possible to build Julia yourself, in which case you will need to create
a tarball, copy it to the `deps/downloads` directory, and add a correct version stanza to
`Versions.toml`.
