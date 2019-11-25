# script that tests all packages and writes the results to a database file

using DataFrames
using NewPkgEval
using SQLite
using Dates
using TimeZones

function main(;julia_releases=["stable"], pkg_names=["Example"], registry="General",
               dbfile=nothing)
    db = if dbfile === nothing
        # in memory
        SQLite.DB()
    else
        SQLite.DB(dbfile)
    end

    # get the Julia versions
    julia_versions = Dict(NewPkgEval.download_julia(julia_release) => julia_release
                          for julia_release in julia_releases)
    NewPkgEval.prepare_julia.(keys(julia_versions))

    # get the packages
    NewPkgEval.prepare_registry(update=true)
    pkgs = NewPkgEval.read_pkgs(pkg_names)

    NewPkgEval.prepare_runner()

    # prepare the database
    SQLite.execute!(db, """
        CREATE TABLE IF NOT EXISTS builds (package_name TEXT,
                                           package_version TEXT,
                                           julia_release TEXT,
                                           julia_version TEXT,
                                           run INT,
                                           status TEXT,
                                           reason TEXT,
                                           log TEXT,
                                           datetime TEXT,
                                           duration REAL)
        """)

    # find a unique run identifier
    run = (SQLite.Query(db, "SELECT COALESCE(MAX(run), 0) FROM builds") |> DataFrame)[1,1] + 1

    function store_result(julia_version, package_name, package_version, start, status, reason, log)
        stop = now()
        elapsed = (stop-start) / Millisecond(1000)
        julia_release = julia_versions[julia_version]
        zoned_start = ZonedDateTime(start, localzone())

        # stringify all values to prevent serialization, but keep `missing`s
        string_or_missing(obj) = ismissing(obj) ? missing : string(obj)

        SQLite.Query(db, "INSERT INTO builds VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)";
                        values=string_or_missing.([package_name, package_version,
                                                julia_release, julia_version,
                                                run, status, reason,
                                                log, zoned_start, elapsed]))
    end

    # test!
    NewPkgEval.run(collect(keys(julia_versions)), pkgs; callback=store_result)

    return
end

isinteractive() || main(julia_releases=["lts", "stable", "nightly"], pkg_names=String[],
                        dbfile=joinpath(@__DIR__, "test.db"))
