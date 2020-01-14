#!/usr/bin/env julia
#
# bisection script to find at which Julia commit a package started failing
#
# start by setting-up a bisection:  git bisect start BAD_COMMIT GOOD_COMMIT
# then run this script:             git run ./path_to_script.jl PackageName

using NewPkgEval
using LibGit2

repo = GitRepo(pwd())
head = LibGit2.head_oid(repo)
hash = string(head)

isempty(ARGS) && error("You should specify at least a single package")

try
    @info "Building Julia commit $hash"
    julia_version = NewPkgEval.perform_julia_build(hash; precompile=false)

    NewPkgEval.prepare_julia(julia_version)
    NewPkgEval.prepare_runner()
    NewPkgEval.prepare_registry()

    pkgs = NewPkgEval.read_pkgs(ARGS)
    for pkg in pkgs
        @info "Testing package '$(pkg.name)'"
        version, status, reason, log = NewPkgEval.run_sandboxed_test(julia_version, pkg)
        if status !== :ok
            @error "$(pkg.name) failed tests" status=NewPkgEval.statusses[status] reason=NewPkgEval.reasons[reason]
            exit(1)
        end
    end
catch ex
    @error "Could not check commit $hash" exception=(ex, catch_backtrace())
    exit(125)
end

@info "All good"
exit(0)
