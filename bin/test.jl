# script that tests all packages and writes the results to a database file

using DataFrames
using NewPkgEval
using Random
using SQLite
using Dates

function main(;pkgnames=["Example"], julia_releases=["1.2"], registry="General", dbfile=nothing)
    db = if dbfile === nothing
        # in memory
        SQLite.DB()
    else
        SQLite.DB(dbfile)
    end

    # get the Julia versions
    julia_versions = Dict(julia_release => NewPkgEval.download_julia(julia_release)
                          for julia_release in julia_releases)
    NewPkgEval.prepare_julia.(values(julia_versions))

    # get the packages
    NewPkgEval.prepare_registry(update=true)
    pkgs = NewPkgEval.read_pkgs(pkgnames)

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

    # test!
    for (julia_release, julia_version) in julia_versions
        function store_result(package_name, package_version, start, status, reason, log)
            stop = now()
            elapsed = (stop-start) / Millisecond(1000)

            # stringify all values to prevent serialization, but keep `missing`s
            string_or_missing(obj) = ismissing(obj) ? missing : string(obj)

            SQLite.Query(db, "INSERT INTO builds VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)";
                         values=string_or_missing.([package_name, package_version,
                                                    julia_release, julia_version,
                                                    run, status, reason,
                                                    log, now(), elapsed]))
        end

        # use a random test order to (hopefully) get a more reasonable ETA
        NewPkgEval.run(julia_version, shuffle(pkgs); callback=store_result)
    end

    return
end

isinteractive() || main(pkgnames=nothing, dbfile=joinpath(@__DIR__, "test.db"))
