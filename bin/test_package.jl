# simple script to quickly test a package in PkgEval's environment

function usage(error=nothing)
    if error !== nothing
        println(stderr, "ERROR: $error")
    end
    println(stderr, """
        Usage: julia test_package.jl [--julia=nightly] [--julia_args=""] [--env=""] [--rr=false]
                                     [--name=...] [--version=...] [--rev=...] [--url=...] [--path=...]

        This script can be used to quickly test a package against a specific version of Julia.

        The `--name`, `--url`, `--rev`, etc flags can be used to specify the package to test.
        To test a local development version, use the `--path` flag.

        The `--julia` flag can be used to specify the version of Julia to test with, and defaults to `nightly`.
        To pass additional arguments to Julia, use one or more `--julia_args` flag.
        Similarly, to set environment variables, use one or more `--env` flag.
        With the `--rr` flag you can enable running under `rr`.""")
    exit(error === nothing ? 0 : 1)
end

using PkgEval

if isempty(ARGS) || any(x -> x == "--help", ARGS)
    usage()
end

args = Dict()
for arg in ARGS
    startswith(arg, "--") || usage("unknown argument: $arg")
    contains(arg, "=")    || usage("argument missing value: $arg")

    option, value = split(arg, "="; limit=2)
    flag = Symbol(option[3:end])
    if haskey(args, flag)
        push!(args[flag], String(value))
    else
        args[flag] = [String(value)]
    end
end

# create the Configuration object
config_flags = [(:julia => String), (:julia_args => Vector{String}),
                (:env => Vector{String}), (:rr => Bool)]
config_args = Dict()
function parse_value(typ, val)
    if typ === String
        val
    else
        parse(typ, val)
    end
end
for (flag, typ) in config_flags
    if haskey(args, flag)
        config_args[flag] = if typ <: Vector
            parse_value.(Ref(eltype(typ)), args[flag])
        else
            length(args[flag]) == 1 || usage("multiple values for --$flag")
            parse_value(typ, only(args[flag]))
        end
        delete!(args, flag)
    end
end
config = Configuration(; config_args...)

# remaining arguments should be singular
for flag in keys(args)
    length(args[flag]) == 1 || usage("multiple values for --$flag")
end
args = Dict(key => only(val) for (key, val) in args)

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
    PkgEval.evaluate_package(config, pkg; echo=true, mounts=Dict("/package:ro" => path))
else
    pkg = Package(; args...)
    PkgEval.evaluate_package(config, pkg; echo=true)
end
exit(result.status == :ok ? 0 : 1)
