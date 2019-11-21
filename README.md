# NewPkgEval - Evaluate julia packages

# Basic usage
In order to run PkgEval against a Julia package do the following:


1. Obtain NewPkgEval and install dependencies

    ```
    git clone https://github.com/JuliaComputing/NewPkgEval.jl.git
    cd NewPkgEval.jl
    julia --project 'import Pkg; Pkg.instantiate()'
    ```


2. Obtain a binary Julia distribution

    You have three choices. Either you use a specific version of Julia that has been
    registered in `Versions.toml` already, and will automatically be downloaded, verified
    and unpacked when required as such:

    ```jl
    import NewPkgEval
    NewPkgEval.obtain_julia(v"1.2.0")
    ```

    If you want to use an unreleased version of Julia as provided by the build bots, you can
    add or use an entry from `Builds.toml` and call `download_julia`. The exact version of
    these entries is often not known beforehand, and because of that the function returns
    the exact version number you should use with other functions in NewPkgEval:

    ```jl
    ver = NewPkgEval.download_julia("latest")
    NewPkgEval.run(..., ver, ...)
    ```

    It also adds an entry to Versions.toml:

    ```
    ["1.4.0-DEV-8f7855a7c3"]
    file = "julia-1.4.0-DEV-8f7855a7c3.tar.gz"
    sha = "dcd105b94906359cae52656129615a1446e7aee1e992ae9c06a15554d83a46f0"

    ```

    Finally, you can also build Julia from Git using BinaryBuilder using the `build_julia`
    method. Similarly, it adds an entry to Versions.toml and returns the version identifier
    you should then use:

    ```jl
    ver = NewPkgEval.build_julia("master")
    ```

    If you get a permission error, try to set the variable

    `BINARYBUILDER_RUNNER=privileged`

    restart Julia and try again.

    If something goes wrong, or you built julia yourself, you may have to add that stanza
    manually and copy the tarball from the products/ directory into `deps/downloads`.


3. Try the julia sandbox environment

    To see that things work as expected, try to run

    ```
    julia> NewPkgEval.run_sandboxed_julia(`-e 'print("hello")'`; ver=ver);
    hello
    ```

    which will execute the julia command in the sandbox environment of the newly built julia.


4. Run PkgEval

    ```julia
    using NewPkgEval
    pkgs = NewPkgEval.read_pkgs(); # can also give a vector of packages here
    results = NewPkgEval.run(pkgs, 20, v"1.2.0")
    ```

    See the docstrings for more arguments.

    If you have problem running more than 1 worker at a time try set the environment variable

    ```
    BINARYBUILDER_USE_SQUASHFS=false
    ```
