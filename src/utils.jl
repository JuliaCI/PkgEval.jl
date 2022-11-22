isdebug(group) =
    Base.CoreLogging.current_logger_for_env(Base.CoreLogging.Debug, group, PkgEval) !== nothing

# split the spec into the repository and the name of the commit/branch/tag
# (e.g. `maleadt/julia#master` -> `("maleadt/julia", "master")`)
function parse_repo_spec(spec, default_repo)
    parts = split(spec, '#')
    repo, ref = if length(parts) == 2
        parts
    elseif length(parts) == 1
        default_repo, spec
    else
        error("Invalid repository/commit specification $spec")
        return nothing
    end

    return repo, ref
end

function get_github_checkout(repo, ref)
    # perform a bare check-out of the repo
    # TODO: check-out different repositories into a single bare check-out under different
    #       remotes? most objects are going to be shared, so this would save time and space.
    @debug "Cloning/updating $repo..."
    clone = joinpath(download_dir, repo)
    if !ispath(joinpath(clone, "config"))
        run(`$(git()) clone --quiet --bare https://github.com/$(repo).git $clone`)
    end

    # explicitly fetch the requested commit from the remote and put it on the master branch.
    # we need to do this as not all specs (e.g. `pull/42/merge`) might be available locally
    run(`$(git()) -C $clone fetch --quiet --force origin $ref:master`)

    # check-out the actual source code into a temporary directory
    checkout = mktempdir()
    run(`$(git()) clone --quiet --branch master $clone $checkout`)
    return checkout
end

"""
    PkgEval.purge()

Remove temporary files and folders that are unlikely to be re-used in the future, e.g.,
temporary Julia installs or a compilation cache of packages.

Artifacts that are more likely to be re-used in the future, e.g., downloaded Julia builds
or check-outs of Git repositories, are saved in scratch spaces instead.
"""
function purge()
    lock(julia_lock) do
        for dir in values(julia_cache)
            isdir(dir) && rm(dir; recursive=true)
        end
        empty!(julia_cache)
    end

    lock(registry_lock) do
        for dir in values(registry_cache)
            isdir(dir) && rm(dir; recursive=true)
        end
        empty!(registry_cache)
    end

    lock(rootfs_lock) do
        for dir in values(rootfs_cache)
            isdir(dir) && rm(dir; recursive=true)
        end
        empty!(rootfs_cache)
    end

    lock(compiled_lock) do
        for dir in values(compiled_cache)
            isdir(dir) && rm(dir; recursive=true)
        end
        empty!(compiled_cache)
    end

    return
end

const _github_auth = Ref{Any}()
function github_auth()
    if !isassigned(_github_auth)
        _github_auth[] = if haskey(ENV, "GITHUB_AUTH")
            GitHub.authenticate(ENV["GITHUB_AUTH"])
        else
            GitHub.AnonymousAuth()
        end
    end
    return _github_auth[]
end
