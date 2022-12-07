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
        if (isa(err, SystemError)  && err.errnum in [Libc.ENOENT, Libc.ESRCH]) ||
           (isa(err, Base.IOError) && err.code in [Base.UV_ENOENT, Base.UV_ESRCH])
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
            if (isa(err, SystemError)  && err.errnum in [Libc.ENOENT, Libc.ESRCH]) ||
               (isa(err, Base.IOError) && err.code in [Base.UV_ENOENT, Base.UV_ESRCH])
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
        if (isa(err, SystemError)  && err.errnum == Libc.ESRCH) ||
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
        if (isa(err, SystemError)  && err.errnum in [Libc.ENOENT, Libc.ESRCH]) ||
           (isa(err, Base.IOError) && err.code in [Base.UV_ENOENT, Base.UV_ESRCH])
            # the process has already exited
            return missing
        else
            rethrow(err)
        end
    end

    # this shouldn't happen, but it does occasionally
    isempty(stats) && return missing

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


getuid() = ccall(:getuid, Cint, ())
getgid() = ccall(:getgid, Cint, ())


struct mntent
    fsname::Cstring # name of mounted filesystem
    dir::Cstring    # filesystem path prefix
    type::Cstring   # mount type (see mntent.h)
    opts::Cstring   # mount options (see mntent.h)
    freq::Cint      # dump frequency in days
    passno::Cint    # pass number on parallel fsck
end

function mount_info(path::String)
    found = nothing
    path_stat = stat(path)

    stream = ccall(:setmntent, Ptr{Nothing}, (Cstring, Cstring), "/etc/mtab", "r")
    while true
        # get the next mtab entry
        entry = ccall(:getmntent, Ptr{mntent}, (Ptr{Nothing},), stream)
        entry == C_NULL && break

        # convert it to something usable
        entry = unsafe_load(entry)
        entry = (;
            fsname  = unsafe_string(entry.fsname),
            dir     = unsafe_string(entry.dir),
            type    = unsafe_string(entry.type),
            opts    = split(unsafe_string(entry.opts), ","),
            entry.freq,
            entry.passno,
        )

        mnt_stat = try
            stat(entry.dir)
        catch
            continue
        end

        if mnt_stat.device == path_stat.device
            found = entry
            break
        end
    end
    ccall(:endmntent, Cint, (Ptr{Nothing},), stream)

    return found
end


# A version of `chmod()` that hides all of its errors.
function chmod_recursive(root::String, perms)
    files = String[]
    try
        files = readdir(root)
    catch e
        if !isa(e, Base.IOError)
            rethrow(e)
        end
    end
    for f in files
        path = joinpath(root, f)
        try
            chmod(path, perms)
        catch e
            if !isa(e, Base.IOError)
                rethrow(e)
            end
        end
        if isdir(path) && !islink(path)
            chmod_recursive(path, perms)
        end
    end
end


const kernel_version = Ref{Union{VersionNumber,Missing}}()
function get_kernel_version()
    if !isassigned(kernel_version)
        kver_str = readchomp(`/bin/uname -r`)
        kver = tryparse(VersionNumber, kver_str)
        if kver === nothing
            @warn "Failed to parse kernel version '$kver_str'"
        end
        kernel_version[] = something(kver, missing)
    end
    return kernel_version[]
end


const cgroup_controllers = Ref{Union{Vector{String},Missing}}()
function _get_cgroup_controllers()
    if !ispath("/proc/self/cgroup")
        return missing
    end

    # we only support cgroupv2, with a single unified controller
    # (i.e. not the hybrid cgroupv1/cgroupv2 set-up)
    cgroup_path = let
        controllers = split(readchomp("/proc/self/cgroup"), '\n')
        length(controllers) == 1 || return missing
        unified_controller = split(controllers[1], ':')
        unified_controller[1] == "0" || return missing
        unified_controller[3]
    end

    # find out which controllers are delegated to our cgroup
    controllers_path = joinpath("/sys/fs/cgroup", cgroup_path[2:end], "cgroup.controllers")
    if !ispath(controllers_path)
        controllers_path = joinpath("/sys/fs/cgroup/unified", cgroup_mount[2:end], "cgroup.controllers")
    end
    ispath(controllers_path) || return missing
    return split(readchomp(controllers_path))
end
function get_cgroup_controllers()
    if !isassigned(cgroup_controllers)
        cgroup_controllers[] = coalesce(_get_cgroup_controllers(), [])
    end
    return cgroup_controllers[]
end
