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

function compare(result, julia_reference, julia_version)
    pkg_names = unique(result.name)

    builds    = result[result[!, :julia] .== julia_version, :]
    reference = result[result[!, :julia] .== julia_reference, :]

    # overview
    o = count(==(:ok),      builds[!, :status])
    s = count(==(:skip),    builds[!, :status])
    f = count(==(:fail),    builds[!, :status])
    k = count(==(:kill),    builds[!, :status])
    x = o + s + k + f
    nrow(builds)
    @assert x == nrow(builds)
    print("On v$julia_version, out of $x packages ")
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
    println("Comparing against v$(julia_reference):")
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



# more elaborate comparison by generating a website

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
    :missing_dependency     => "package is missing a dependency",
    :test_failures          => "package has test failures",
    :syntax                 => "package has syntax issues",
    :unknown                => "there were unidentified errors",
    # kill
    :time_limit             => "test duration exceeded the time limit",
    :log_limit              => "test log exceeded the size limit",
)

site_path(paths...) = joinpath(dirname(@__DIR__), "site", paths...)

function render(current_run)
    pkg_names = unique(current_run.name)
    julia_versions = unique(current_run.julia)

    println("Generating site at ", site_path("build"))
    rm(site_path("build"); recursive=true, force=true)
    mkpath(site_path("build", "detail"))

    # load resources
    site_logo = read(site_path("julia_logo.svg"), String)
    site_css = read(site_path("pkg.css"), String)
    site_js = read(site_path("pkg.js"), String)

    # load templates
    index_head = read(site_path("index_head.html"), String)
    index_foot = read(site_path("index_foot.html"), String)
    index_pkg = read(site_path("index_pkg.html"), String)
    pkg_detail = read(site_path("detail.html"), String)

    # render the index head
    index_head = Mustache.render(index_head,
        Dict("SITE_LOGO"        => site_logo,
             "SITE_CSS"         => site_css,
             "LAST_UPDATED"     => string(Dates.today()),  # YYYY-MM-DD
             "PKG_COUNT"        => string(length(pkg_names)),
             "JULIA_VERSIONS"   => join(map(ver -> "v$ver", sort(julia_versions))," — ")
        )
    )

    pkg_output = String[]
    for pkg_name in sort(pkg_names)
        data = Dict()
        data["SITE_LOGO"] = site_logo
        data["SITE_CSS"] = site_css
        data["SITE_JS"] = site_js

        # version-independent values
        data["NAME"] = pkg_name

        # per-version information
        pkg_builds = current_run[current_run[!, :name] .== pkg_name, :]
        sort!(pkg_builds, [:julia])
        data["BUILDS"] = Dict[]
        for build in eachrow(pkg_builds)
            # time information
            duration = Dates.canonicalize(Dates.CompoundPeriod(Dates.Second(round(Int, build.duration))))

            push!(data["BUILDS"], Dict(
                "JULIA"         => build.julia,
                "VERSION"       => coalesce(build.version, false),
                "STATUS"        => build.status,
                "STATUS_TEXT"   => statusses[build.status],
                "REASON"        => coalesce(build.reason, false),
                "REASON_TEXT"   => coalesce(reasons[build.reason], false),
                "DURATION_TEXT" => duration,
                # for per-package detail page
                "LOG"           => coalesce(build.log, false),
                "LOG_LINK"      => build.log === missing ? false :
                                   site_path("build", "logs", pkg_name, "$(build.julia).log")
            ))

            # dump the log to a file (for downloading)
            if build.log !== missing
                mkpath(site_path("build", "logs", pkg_name))
                open(site_path("build", "logs", pkg_name, "$(build.julia).log"), "w") do io
                    write(io, build.log)
                end
            end
        end

        push!(pkg_output, Mustache.render(index_pkg, data))

        # render the package details
        open(site_path("build", "detail", "$(pkg_name).html"), "w") do fp
            println(fp, Mustache.render(pkg_detail, data))
        end
    end

    # output the index
    open(site_path("build", "index.html"),"w") do fp
        println(fp, index_head)
        println(fp, join(pkg_output, "\n"))
        println(fp, index_foot)
    end

    return

end
