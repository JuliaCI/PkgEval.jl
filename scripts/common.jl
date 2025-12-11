include("../src/PkgEvalCore.jl")
using .PkgEvalCore

using Pkg
using Base: UUID

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
