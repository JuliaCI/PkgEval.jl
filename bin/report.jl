# script that reports on test results

using SQLite
using DataFrames
using Dates
using Mustache
using TimeZones
using JSON

# human-readable versions of the test statusses and reasons
const statusses = Dict(
    "ok"    => "successful",
    "skip"  => "skipped",
    "fail"  => "unsuccessful",
    "kill"  => "interrupted",
)
const reasons = Dict(
    missing                 => missing,
    # skip
    "explicit"              => "package was blacklisted",
    "jll"                   => "package is a untestable wrapper package",
    "unsupported"           => "package is not supported by this Julia version",
    # fail
    "unsatisfiable"         => "package could not be installed",
    "untestable"            => "package does not have any tests",
    "binary_dependency"     => "package requires a missing binary dependency",
    "missing_dependency"    => "package is missing a dependency",
    "test_failures"         => "package has test failures",
    "syntax"                => "package has syntax issues",
    "unknown"               => "testing failed for unknown reasons",
    # kill
    "time_limit"            => "test duration exceeded the time limit",
    "log_limit"             => "test log exceeded the size limit",
)

site_path(paths...) = joinpath(dirname(@__DIR__), "site", paths...)

function main(;dbfile=joinpath(@__DIR__, "test.db"))
    db = SQLite.DB(dbfile)

    # figure out the last run, and the previous one to compare against
    run = (SQLite.Query(db, "SELECT COALESCE(MAX(run), 0) FROM builds") |> DataFrame)[1,1]
    current_run  = SQLite.Query(db, "SELECT * FROM builds where run == ?", values=[run]) |> DataFrame
    previous_run = SQLite.Query(db, "SELECT * FROM builds where run == ?", values=[run-1]) |> DataFrame

    pkg_names = unique(current_run[!, :package_name])
    julia_releases = unique(current_run[!, :julia_release])
    julia_versions = Dict(first(current_run[current_run[!, :julia_release] .== julia_release,
                                            :julia_version]) => julia_release
                          for julia_release in julia_releases)

    rm(site_path("build"); recursive=true)
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
             "JULIA_VERSIONS"   => join(map(ver -> "v$ver ($(julia_versions[ver]))",
                                            sort(collect(keys(julia_versions))))," — ")
        )
    )

    json = Dict()

    pkg_output = String[]
    for pkg_name in sort(pkg_names)
        data = Dict()
        data["SITE_LOGO"] = site_logo
        data["SITE_CSS"] = site_css
        data["SITE_JS"] = site_js

        # version-independent values
        data["NAME"] = pkg_name

        # per-version information
        pkg_builds = current_run[current_run[!, :package_name] .== pkg_name, :]
        sort!(pkg_builds, [:julia_version])
        data["PKG_BUILDS"] = Dict[]
        json[pkg_name] = Dict[]
        for build in eachrow(pkg_builds)
            # time information
            duration = Dates.canonicalize(Dates.CompoundPeriod(Dates.Second(round(Int, build.duration))))
            # https://github.com/JuliaTime/TimeZones.jl/issues/83
            datetime = something(tryparse(ZonedDateTime, build.datetime),
                                 tryparse(ZonedDateTime, build.datetime, dateformat"yyyy-mm-ddTHH:MM:SS.sszzz"),
                                 tryparse(ZonedDateTime, build.datetime, dateformat"yyyy-mm-ddTHH:MM:SS.szzz"),
                                 tryparse(ZonedDateTime, build.datetime, dateformat"yyyy-mm-ddTHH:MM:SSzzz"))
            time_ago = Dates.canonicalize(Dates.CompoundPeriod(now(localzone()) - datetime))
            while length(time_ago.periods) > 2
                pop!(time_ago.periods)
            end

            push!(data["PKG_BUILDS"], Dict(
                "JULIA_RELEASE" => build.julia_release,
                "JULIA_VERSION" => build.julia_version,
                "PKG_VERSION"   => coalesce(build.package_version, false),
                "STATUS"        => build.status,
                "STATUS_TEXT"   => statusses[build.status],
                "REASON"        => coalesce(build.reason, false),
                "REASON_TEXT"   => coalesce(reasons[build.reason], false),
                "DURATION_TEXT" => duration,
                "TIME_AGO_TEXT" => time_ago,
                # for per-package detail page
                "LOG"           => coalesce(build.log, false),
                "LOG_LINK"      => build.log === missing ? false :
                                   site_path("build", "logs", pkg_name, "$(build.julia_version).log")
            ))

            push!(json[pkg_name], Dict(
                "julia_release"     => build.julia_release,
                "julia_version"     => build.julia_version,
                "package_version"   => build.package_version,
                "status"            => build.status,
                "reason"            => build.reason,
                "datetime"          => build.datetime,
                "duration"          => build.duration,
            ))

            # dump the log to a file (for downloading)
            if build.log !== missing
                mkpath(site_path("build", "logs", pkg_name))
                open(site_path("build", "logs", pkg_name, "$(build.julia_version).log"), "w") do io
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

    # output the JSON database
    open(site_path("build", "pkg.json"),"w") do fp
        JSON.print(fp, json)
    end

    return

end

isinteractive() || main()
