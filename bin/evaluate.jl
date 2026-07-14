# evaluate a selection of packages, optionally comparing two versions of Julia,
# and render the results to an HTML report like the ones Nanosoldier generates.

function usage(error=nothing)
    if error !== nothing
        println(stderr, "ERROR: $error")
    end
    println(stderr, """
        Usage: julia evaluate.jl [--primary=nightly] [--against=...]
                                 [--packages=Example,Crayons] [--depends-on=Crayons]
                                 [--transitive=false] [--jlls=false]
                                 [--output=pkgeval-report] [--ninstances=...]

        This script evaluates a selection of packages using one or two versions of Julia,
        writing an HTML report (report.html), its Markdown source, and per-package logs
        to the output directory.

        The `--primary` and `--against` flags select the versions of Julia to use, and
        accept a version number ("1.10.4"), a release name ("nightly", "stable"), a
        repository spec ("JuliaLang/julia#master"), or the path to a local Julia
        installation. When `--against` is set, the report compares both versions,
        highlighting packages that only fail on the primary one.

        Packages are selected with either the `--packages` flag (a comma-separated list
        of names), or the `--depends-on` flag (all packages depending on the given
        package; add `--transitive=true` to include indirect dependents, and
        `--jlls=true` to include JLL packages). Without a selection, all packages from
        the registry are evaluated.""")
    exit(error === nothing ? 0 : 1)
end

using PkgEval

if any(x -> x == "--help", ARGS)
    usage()
end

args = Dict{Symbol,String}()
for arg in ARGS
    startswith(arg, "--") || usage("unknown argument: $arg")
    contains(arg, "=")    || usage("argument missing value: $arg")

    option, value = split(arg, "="; limit=2)
    flag = Symbol(option[3:end])
    haskey(args, flag) && usage("multiple values for --$flag")
    args[flag] = String(value)
end
for flag in keys(args)
    flag in [:primary, :against, :packages, Symbol("depends-on"),
             :transitive, :jlls, :output, :ninstances] || usage("unknown flag: --$flag")
end

# on non-Linux platforms, transparently re-execute this script inside a Linux container,
# where the existing sandboxing code works unchanged
if !Sys.islinux()
    docker = Sys.which("docker")
    if docker === nothing
        println(stderr, """
            ERROR: evaluating packages requires Linux. To do so from this machine, install a
                   Docker-compatible container runtime (Docker Desktop, OrbStack, Colima, ...)
                   and this script will automatically run itself in a Linux container.""")
        exit(1)
    end

    # local Julia installations cannot be used, as the sandbox runs Linux binaries
    for flag in (:primary, :against)
        haskey(args, flag) || continue
        if ispath(expanduser(args[flag]))
            usage("--$flag points to a local Julia installation, which cannot be used from $(Sys.KERNEL); use a version number, release name, or repository spec instead")
        end
    end

    pkgeval = dirname(@__DIR__)

    println("Building the PkgEval container image...")
    run(pipeline(`$docker build --quiet --tag pkgeval $(joinpath(pkgeval, "bin"))`;
                 stdout=devnull))

    # the report is written to a directory mounted from the host, while the Julia depot
    # (package cache, PkgEval's scratch spaces) persists in a named volume
    output = abspath(expanduser(get(args, :output, "pkgeval-report")))
    mkpath(output)
    flags = String["--$flag=$value" for (flag, value) in args if flag !== :output]
    push!(flags, "--output=/output")

    script = """
        set -e
        julia -e 'using Pkg; Pkg.activate("pkgeval"; shared=true);
                  Pkg.develop(path="/PkgEval"); Pkg.instantiate()'
        exec julia --project=@pkgeval /PkgEval/bin/evaluate.jl "\$@"
        """
    runflags = ["--rm", "--privileged",
                "--volume", "pkgeval-depot:/root/.julia",
                "--volume", "$(pkgeval):/PkgEval",
                "--volume", "$(output):/output"]
    stdout isa Base.TTY && push!(runflags, "--tty")

    proc = run(ignorestatus(`$docker run $runflags pkgeval bash -c $script -- $flags`))
    if isfile(joinpath(output, "report.html"))
        println("\nReport available at $(joinpath(output, "report.html"))")
    end
    exit(proc.exitcode)
end

# resolve a Julia spec: map juliaup-style channel names to PkgEval release names,
# and expand paths to local installations
function julia_spec(spec)
    spec == "release" && return "stable"
    path = expanduser(spec)
    ispath(path) && return abspath(path)
    return spec
end

configs = [Configuration(; name="primary", julia=julia_spec(get(args, :primary, "nightly")))]
if haskey(args, :against)
    push!(configs, Configuration(; name="against", julia=julia_spec(args[:against])))
end

# determine the packages to evaluate
packages = if haskey(args, :packages)
    haskey(args, Symbol("depends-on")) && usage("--packages and --depends-on are mutually exclusive")
    [Package(; name=String(strip(name))) for name in split(args[:packages], ",")]
elseif haskey(args, Symbol("depends-on"))
    transitive = parse(Bool, get(args, :transitive, "false"))
    names = PkgEval.package_dependents(configs[1], args[Symbol("depends-on")]; transitive)
    if !parse(Bool, get(args, :jlls, "false"))
        filter!(!endswith("_jll"), names)
    end
    isempty(names) && usage("no packages depend on $(args[Symbol("depends-on")])")
    println("Selected $(length(names)) packages that $(transitive ? "transitively " : "directly ")depend on $(args[Symbol("depends-on")])")
    [Package(; name) for name in names]
else
    Package[]
end

# run the evaluation
ninstances = parse(Int, get(args, :ninstances, string(Sys.CPU_THREADS)))
elapsed = @elapsed results = evaluate(configs, packages; ninstances)

# sort the report by number of dependents, like Nanosoldier does
dependents = Dict{String,Int}()
try
    for (_, deps) in PkgEval.package_dependencies(configs[1]; transitive=false), dep in deps
        dependents[dep] = get(dependents, dep, 0) + 1
    end
catch err
    @warn "Failed to determine package dependents; report will be sorted alphabetically" exception=err
end

output = get(args, :output, "pkgeval-report")
report = write_report(output, configs, results; elapsed, dependents)

println("\nReport written to $(joinpath(abspath(output), "report.html"))")
exit(report.has_issues ? 1 : 0)
