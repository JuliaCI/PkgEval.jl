include("../src/PkgEvalCore.jl")
using .PkgEvalCore

using Pkg
using Base: UUID

# compile-cache protocol client (PkgEvalFarm sealing): only when the worker
# provided a cache server *and* this julia carries the loading hook
if haskey(ENV, "PKGEVAL_CACHE_SERVER") && isdefined(Base, :CACHE_FETCH_HOOK)
    include("cache_client.jl")
    PkgEvalCacheClient.install!()
end

# simplified version of utilities from utils.jl (with no need to
# scan for children, as we use this from the parent when idle)
function cpu_time()
    stats = read("/proc/self/stat", String)

    m = match(r"^(\d+) \((.+)\) (.+)", stats)
    @assert m !== nothing "Invalid contents for /proc/self/stat: $stats"
    fields = [[m.captures[1], m.captures[2]]; split(m.captures[3])]
    utime = parse(Int, fields[14])
    stime = parse(Int, fields[15])
    cutime = parse(Int, fields[16])
    cstime = parse(Int, fields[17])

    return (utime + stime + cutime + cstime) / Sys.SC_CLK_TCK
end
function io_bytes()
    stats = read("/proc/self/io", String)

    dict = Dict()
    for line in split(stats, '\n')
        m = match(r"^(.+): (\d+)$", line)
        m === nothing && continue
        dict[m.captures[1]] = parse(Int, m.captures[2])
    end

    return dict["rchar"] + dict["wchar"]
end

# Peak memory of this container's cgroup: the sandbox runs in its own cgroup
# namespace, so /sys/fs/cgroup is our very own subtree. memory.peak is the
# high-watermark of memory.current — note that this *includes* page cache, so
# it reflects the comfortable footprint rather than the hard minimum. It is
# monotonic since container start, so a single read at the end covers
# install + precompile + test. Returns 0 when unavailable (cgroup v1, or the
# memory controller not delegated).
function peak_rss()
    try
        parse(Int, strip(read("/sys/fs/cgroup/memory.peak", String)))
    catch
        0
    end
end

suppress_pkg_output(f::Function) = capture_pkg_output(f; suppress = true)
function capture_pkg_output(f::Function; suppress::Bool = false)
    # Need to handle https://github.com/JuliaLang/Pkg.jl/pull/4499,
    # but also need to handle older Julia versions without ScopedValues
    use_scoped_values = isdefined(Base, :ScopedValues) && (Pkg.DEFAULT_IO isa Base.ScopedValues.ScopedValue)
    if suppress
        io = devnull
    else
        io = IOBuffer()
    end
    if !use_scoped_values
        Pkg.DEFAULT_IO[] = io
    end
    try
        if use_scoped_values
            # Avoid using the @with macro here
            Base.ScopedValues.with(Pkg.DEFAULT_IO => io) do
                f()
            end
        else
            f()
        end
    catch
        # Something went wrong when trying to run f()
        # So print the Pkg output to stdout (unless `suppress` is true)
        if !suppress
            println(String(take!(io)))
        end
        # And then rethrow the exception
        rethrow()
    finally
        if !use_scoped_values
            Pkg.DEFAULT_IO[] = nothing
        end
    end
    return nothing
end

using Dates
elapsed(t) = "$(round(cpu_time() - t; digits=2))s"
