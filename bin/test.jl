# script that tests all packages and writes the results to a database file

using NewPkgEval
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

    # get the packages
    NewPkgEval.get_registry(update=true)
    pkgs = NewPkgEval.read_pkgs(pkgnames)

    # prepare the database
    SQLite.execute!(db, """
        CREATE TABLE IF NOT EXISTS builds (package_name TEXT,
                                           julia_release TEXT,
                                           julia_version TEXT,
                                           status TEXT,
                                           log TEXT,
                                           datetime TEXT,
                                           duration REAL)
        """)

    # test!
    for (julia_release, julia_version) in julia_versions
        function store_result(package, start, status, log)
            stop = now()
            elapsed = (stop-start) / Millisecond(1000)

            SQLite.Query(db, "INSERT INTO builds VALUES (?, ?, ?, ?, ?, ?, ?)";
                         values=[package, julia_release, string(julia_version),
                                 string(status), log, string(now()), elapsed])
        end

        NewPkgEval.run(julia_version, pkgs; callback=store_result)
    end

    return
end

isinteractive() || main(pkgnames=nothing, dbfile=joinpath(@__DIR__, "test.db"))
