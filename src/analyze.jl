struct PackageResult
    log::String
    pass::Bool
end

mutable struct PackageDiff
    v1_result::Union{Nothing, PackageResult}
    v2_result::Union{Nothing, PackageResult}
end
status(result::Nothing) = nothing
status(result::PackageResult) = result.pass

create_collapse_markdown(header::String, content::String) =
    string("<details><summary>", header, "</summary>\n<p>\n\n", content, "\n\n</p>\n</details>\n")


function export_diff(v1::VersionNumber, v2::VersionNumber, f = joinpath("comparison-$v1-$v2.md"))
    getlogdir(v) = joinpath(@__DIR__, "..", "logs", "logs-" * string(v))
    for v in (v1, v2)
        logdir = getlogdir(v)
        if !isdir(logdir)
            error("log path at $(repr(logdir)) not found")
        end
    end

    diffs = Dict{String, PackageDiff}()
    for (i, v) in enumerate((v1, v2))
        logdir = getlogdir(v)
        for logfile in readdir(logdir)
            pkg, ext = splitext(logfile)
            ext == ".log" || continue
            if !haskey(diffs, pkg)
                diffs[pkg] = PackageDiff(nothing, nothing)
            end
            log = read(joinpath(logdir, logfile), String)
            # TODO: Do better:
            pass = occursin("$pkg tests passed", log)
            result = PackageResult(log, pass)
            if i == 1
                diffs[pkg].v1_result = result
            else
                diffs[pkg].v2_result = result
            end
        end
    end


    io = IOBuffer()
    
    println(io, "# Results of PkgEval for $v1 vs $v2")
    println(io, "## Packages that changes status")
    for (pkg, diff) in diffs
        (status(diff.v1_result) == status(diff.v2_result)) && continue
        println(io, pkg, ": ", status(diff.v1_result), " => ", status(diff.v2_result))
    end

    for (pkg, diff) in diffs
        (status(diff.v1_result) == status(diff.v2_result)) && continue
        if status(diff.v1_result) == false
            print(io, create_collapse_markdown("Test log", diff.v1_result.log))
        end
    end

    str = String(take!(io))
    print(str)
    write(f, str)
end
