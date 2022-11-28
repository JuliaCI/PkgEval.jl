# simple script to quickly test a package in PkgEval's environment

function usage(error=nothing)
    if error !== nothing
        println(stderr, "ERROR: $error")
    end
    println(stderr, """
        Usage: julia test_package.jl [--julia=nightly]
                                     [--name=...] [--version=...] [--rev=...] [--url=...] [--path=...]

        This script can be used to quickly test a package against a specific version of Julia.

        The `--name`, `--url`, `--rev`, etc flags can be used to specify the package to test.
        To test a local development version, use the `--path` flag.

        The `--julia` flag can be used to specify the version of Julia to test with, and defaults to `nightly`.""")
    exit(error === nothing ? 0 : 1)
end

using PkgEval

if isempty(ARGS) || any(x -> x == "--help", ARGS)
    usage()
end

args = Dict()
for arg in ARGS
    startswith(arg, "--") || usage("invalid argument: $arg")
    contains(arg, "=")    || usage("invalid argument: $arg")

    option, value = split(arg, "="; limit=2)
    args[Symbol(option[3:end])] = String(value)
end

config = if haskey(args, :julia)
    Configuration(; julia=args[:julia])
else
    Configuration()
end
delete!(args, :julia)

result = if haskey(args, :path)
    path = expanduser(args[:path])
    delete!(args, :path)
    if !isdir(path)
        usage("invalid path: $path")
    end

    haskey(args, :name) || usage("must specify --name when using --path")
    name = args[:name]
    delete!(args, :name)

    isempty(args) || usage("must only specify --name when using --path")

    pkg = Package(; name, url="/package")
    PkgEval.evaluate_test(config, pkg; echo=true, mounts=Dict("/package:ro" => path))
else
    pkg = Package(; args...)
    PkgEval.evaluate_test(config, pkg; echo=true)
end
exit(result.status == :ok ? 0 : 1)
