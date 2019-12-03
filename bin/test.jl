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
    julia_versions = NewPkgEval.obtain_julia.(julia_releases)
    NewPkgEval.prepare_julia.(julia_versions)

    # get the packages
    NewPkgEval.prepare_registry(update=true)
    pkgs = NewPkgEval.read_pkgs(pkg_names)

    NewPkgEval.prepare_runner()

    # test!
    result = NewPkgEval.run(julia_versions, pkgs)
    result[!, :datetime] .= now(localzone())

    # write to database
    stringify(obj) = ismissing(obj) ? missing : string(obj)
    stringify.(result) |> SQLite.load!(db, "builds")

    # generate a website
    NewPkgEval.render(result)

    return
end

isinteractive() || main(julia_releases=["lts", "stable", "nightly"], pkg_names=String[],
                        dbfile=joinpath(@__DIR__, "test.db"))
