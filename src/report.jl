# details on status codes

const statusses = Dict(
    :ok     => "successful",
    :skip   => "skipped",
    :fail   => "unsuccessful",
    :kill   => "interrupted",
)
const reasons = Dict(
    missing                 => missing,
    # skip
    :explicit               => "package was blacklisted",
    :jll                    => "package is a untestable wrapper package",
    :unsupported            => "package is not supported by this Julia version",
    # fail
    :unsatisfiable          => "package could not be installed",
    :untestable             => "package does not have any tests",
    :binary_dependency      => "package requires a missing binary dependency",
    :missing_dependency     => "package is missing a package dependency",
    :missing_package        => "package is using an unknown package",
    :test_failures          => "package has test failures",
    :syntax                 => "package has syntax issues",
    :gc_corruption          => "GC corruption detected",
    :segfault               => "a segmentation fault happened",
    :abort                  => "the process was aborted",
    :unreachable            => "an unreachable instruction was executed",
    :unknown                => "there were unidentified errors",
    # kill
    :time_limit             => "test duration exceeded the time limit",
    :log_limit              => "test log exceeded the size limit",
    :inactivity             => "tests became inactive",
)


# simple comparison of two versions

print_status(status, val=status) = print_status(stdout, status, val)

function print_status(io::IO, status, val=status)
    if status == :ok
        printstyled(io, val; color = :green)
    elseif status == :fail || status == :kill
        printstyled(io, val; color = Base.error_color())
    elseif status == :skip
        printstyled(io, val; color = Base.warn_color())
    else
        error("Unknown status $status")
    end
end

function compare(result, config_against, config)
    pkg_names = unique(result.name)

    builds    = result[result[!, :config] .== config, :]
    reference = result[result[!, :config] .== config_against, :]

    # overview
    o = count(==(:ok),      builds[!, :status])
    s = count(==(:skip),    builds[!, :status])
    f = count(==(:fail),    builds[!, :status])
    k = count(==(:kill),    builds[!, :status])
    x = o + s + k + f
    nrow(builds)
    @assert x == nrow(builds)
    print("On v$config, out of $x packages ")
    print_status(:ok, o)
    print(" passed, ")
    print_status(:fail, f)
    print(" failed, ")
    print_status(:kill, k)
    print(" got killed and ")
    print_status(:skip, s)
    println(" were skipped.")

    println()

    # summary of differences
    println("Comparing against $(config_against):")
    new_failures = 0
    new_successes = 0
    for current in eachrow(builds)
        pkg_name = current[:name]

        previous = reference[reference[!, :name] .== pkg_name, :]
        nrow(previous) == 0 && continue
        previous = first(previous)

        if current[:status] != previous[:status]
            print("- $pkg_name status was $(previous[:status])")
            ismissing(previous[:reason]) || print(" (reason: $(previous[:reason]))")
            print(", now ")
            print_status(current[:status])
            ismissing(current[:reason]) || print(" (reason: $(current[:reason]))")
            println()
            if current.status == :fail || current.status == :kill
                new_failures += 1
            elseif current.status == :ok
                new_successes += 1
            end
        end
    end
    print("In summary, ")
    print_status(:ok, new_successes)
    print(" packages now succeed, while ")
    print_status(:fail, new_failures)
    println(" have started to fail.")

    return
end
