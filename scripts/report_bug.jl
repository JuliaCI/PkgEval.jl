include("common.jl")

config = eval(Meta.parse(ARGS[1]))
pkg = eval(Meta.parse(ARGS[2]))

print("\n\n", '#'^80, "\n# Bug reporting\n#\n\n")
t0 = cpu_time()

try
    # use a clean environment, or BugReporting's deps could
    # affect/be affected by the tested package's dependencies.
    Pkg.activate(; temp=true)
    Pkg.add(name="BugReporting", uuid="bcf9a6e7-4020-453c-b88e-690564246bb8")
    using BugReporting

    trace_dir = BugReporting.default_rr_trace_dir()
    trace = BugReporting.find_latest_trace(trace_dir)
    BugReporting.compress_trace(trace, "/output/$(pkg.name).tar.zst")
    println("\nBugReporting completed after $(elapsed(t0))")
catch err
    println("\nBugReporting failed after $(elapsed(t0))")
    showerror(stdout, err)
    Base.show_backtrace(stdout, catch_backtrace())
    println()
end
