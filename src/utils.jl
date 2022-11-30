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

    # we'd like to be able to use tildes and carets (e.g. `master~10`), but those aren't
    # valid refspecs... so split those off and we'll deal with them later
    m = match(r"^(.*?)([~^].*)?$", ref)
    ref, mod = if m !== nothing
        m.captures
    else
        ref, nothing
    end

    # explicitly fetch the requested commit from the remote and put it on the master branch.
    # we need to do this as not all specs (e.g. `pull/42/merge`) might be available locally
    run(`$(git()) -C $clone fetch --quiet --force origin $ref:master`)

    # check-out the actual source code into a temporary directory
    checkout = mktempdir(prefix="pkgeval_checkout_")
    run(`$(git()) clone --quiet --branch master $clone $checkout`)
    if mod !== nothing
        run(`$(git()) -C $checkout reset --quiet --hard HEAD$mod`)
    end
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


# list the children of a process.
# note that this may return processes that have already exited, so beware of TOCTOU.
function process_children(pid)
    tids = try
        readdir("/proc/$pid/task")
    catch err # TOCTOU
        if (isa(err, SystemError)  && err.code == Libc.ENOENT) ||
           (isa(err, Base.IOError) && err.code == Base.UV_ENOENT)
            # the process has already exited
            return Int[]
        else
            rethrow()
        end
    end

    pids = Int[]
    for tid in tids
        try
            children = read("/proc/$pid/task/$tid/children", String)
            append!(pids, parse.(Int, split(children)))
        catch err # TOCTOU
            if (isa(err, SystemError)  && err.code == Libc.ENOENT) ||
               (isa(err, Base.IOError) && err.code == Base.UV_ENOENT)
                # the task has already exited
            else
                rethrow()
            end
        end
    end
    return pids
end


# kill a process and all of its children
function recursive_kill(proc, sig)
    parent_pid = try
        getpid(proc)
    catch err # TOCTOU
        if (isa(err, SystemError)  && err.code == Libc.ESRCH) ||
           (isa(err, Base.IOError) && err.code == Base.UV_ESRCH)
            # the process has already exited
            return
        else
            rethrow(err)
        end
    end
    for pid in reverse([parent_pid; process_children(parent_pid)])
        ccall(:uv_kill, Cint, (Cint, Cint), pid, sig)
    end
    return
end


# look up the CPU time consumed by a process and its children
function cpu_time(pid)
    stats = try
        read("/proc/$pid/stat", String)
    catch err # TOCTOU
        if (isa(err, SystemError)  && err.code == Libc.ENOENT) ||
           (isa(err, Base.IOError) && err.code == Base.UV_ENOENT)
            # the process has already exited
            return missing
        else
            rethrow(err)
        end
    end

    m = match(r"^(\d+) \((.+)\) (.+)", stats)
    if m === nothing
        throw(ArgumentError("Invalid contents for /proc/$pid/stat: $stats"))
    end
    fields = [[m.captures[1], m.captures[2]]; split(m.captures[3])]
    utime = parse(Int, fields[14])
    stime = parse(Int, fields[15])
    cutime = parse(Int, fields[16])
    cstime = parse(Int, fields[17])
    total_time = (utime + stime + cutime + cstime) / Sys.SC_CLK_TCK

    # cutime and cstime are only updated when the child exits,
    # so recursively scan all known children
    total_time += sum(cpu_time, process_children(pid); init=0.0)

    return total_time
end
