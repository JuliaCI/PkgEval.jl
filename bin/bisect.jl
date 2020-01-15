#!/usr/bin/env julia
#
# bisection script to find at which Julia commit a package started failing
#
# start by setting-up a bisection:  git bisect start BAD_COMMIT GOOD_COMMIT
# then run this script:             git run ./path_to_script.jl PackageName

using DataFrames
using NewPkgEval
using LibGit2

repo = GitRepo(pwd())
head = LibGit2.head_oid(repo)
hash = string(head)
shorthash = chomp(read(`git rev-parse --short $hash`, String))

try
    julia_version = NewPkgEval.perform_julia_build(hash; precompile=false)

    # gather results. run each test three times to catch flaky errors
    isempty(ARGS) && error("You should specify at least a single package")
    results = NewPkgEval.run([julia_version, julia_version, julia_version], ARGS;
                             update_registry=false, retries=0)
    results[results[!, :status] .== :kill, :status] .= :fail    # merge killed and failed

    # analyze
    has_issues = false
    for group in groupby(results, :name)
        pkg = first(group).name
        if all(eachrow(group).status .== :ok)
            @info "$pkg passed tests"
        elseif any(eachrow(group).status .== :skip)
            error("$pkg was skipped")
        elseif any(eachrow(group).status .== :fail)
            has_issues = true
            log = "$pkg-$shorthash.log"
            test = first(filter(row->row.status == :fail, group))
            @warn "$pkg failed tests: $(NewPkgEval.reasons[test.reason]) (see $log)"
            open(log, "w") do io
                println(io, test.log)
            end
        end
    end

    # report to Git
    exit(has_issues ? 1 : 0)
catch ex
    @error "Could not check commit" exception=(ex, catch_backtrace())
    exit(125)
end
