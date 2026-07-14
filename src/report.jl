export write_report

# rendering of evaluation results to a Markdown/HTML report, ported from Nanosoldier.jl
# so that local runs can generate the same kind of report as `@nanosoldier runtests()`.

using DataFrames: DataFrame, nrow, leftjoin, groupby
import CommonMark

const COLOR_MAP = map(('▁' => ("#666", "skip"),
                       '▃' => ("#60F", "crash"),
                       '▅' => ("#F03", "fail"),
                       '▆' => ("#F60", "load"),
                       '▇' => ("#0F0", "test"),
                      )) do (char, (color, title))
    Regex("($char+)") => SubstitutionString("<span style=\"color: $color\" title=\"$title\">\\1</span>")
end

function readable_duration(seconds)
    str = ""
    if seconds > 60*60*24
        days = Int(seconds ÷ (60*60*24))
        seconds -= days * 60*60*24
        str *= days > 1 ? "$days days" : "$days day"
    end
    if seconds > 60*60
        hours = Int(seconds ÷ (60*60))
        seconds -= hours * 60*60
        isempty(str) || (str *= ", ")
        str *= hours > 1 ? "$hours hours" : "$hours hour"
    end
    if seconds > 60
        minutes = Int(seconds ÷ 60)
        seconds -= minutes * 60
        isempty(str) || (str *= ", ")
        str *= minutes > 1 ? "$minutes minutes" : "$minutes minute"
    end
    if seconds > 0 || isempty(str)
        seconds = trunc(Int, seconds)
        isempty(str) || (str *= ", ")
        str *= seconds > 1 ? "$seconds seconds" : "$seconds second"
    end
    return str
end

# combine the primary and against results into a single dataframe, joined on package.
# columns from the against results are suffixed with `_1`, and a `source` column
# indicates whether a package was tested on both configurations or only the primary.
function make_package_results(primary::DataFrame, against::Union{DataFrame,Nothing})
    if against !== nothing
        return leftjoin(primary, against,
                        on=:package, makeunique=true, source=:source)
    else
        package_results = copy(primary)
        package_results[!, :source] .= "left_only" # fake a left join
        return package_results
    end
end

function print_package_results(io::IO, package_results, hasagainst::Bool;
                               primary_name::String, against_name::Union{String,Nothing},
                               summary::Bool=false,
                               history=nothing, history_heading::String="History",
                               dependents::Dict{String,Int}=Dict{String,Int}())
    # report test results in groups based on the test status
    for (status, (title, verb, emoji)) in
            (:crash  => ("crashed",                 "crashed",              "❗"),
             :fail   => ("failed",                  "failed",               "✖"),
             :test   => ("passed tests",            "passed tests",         "✔"),
             :load   => ("at least loaded",         "successfully loaded",  "~"),
             :skip   => ("were skipped altogether", "were skipped",         "➖"))
        # NOTE: no `groupby(package_results, :status)` because we can't impose ordering
        group = package_results[package_results[!, :status] .== status, :]
        sort!(group, :package; by=pkg->(-get(dependents, pkg, 0), pkg))

        if !isempty(group)
            println(io, "## $emoji Packages that $title\n")

            # report on a single test
            function reportrow(test)
                primary_log = "logs/$(test.package)/$(primary_name).log"
                primary_status = String(test.status)

                # "against" entries are suffixed with `_1` because of the join
                if test.source == "both"
                    # PkgEval always compares the same package versions, so only report it once
                    print(io, "| $(test.package) | ")
                    if test.version !== missing
                        print(io, "v$(test.version) | ")
                    elseif test.version_1 !== missing
                        print(io, "v$(test.version_1) | ")
                    else
                        print(io, "missing | ")
                    end

                    print(io, "[$primary_status]($primary_log) | ")

                    against_log = "logs/$(test.package)/$(against_name).log"
                    against_status = String(test.status_1)
                    print(io, "[$against_status]($against_log) |")
                else
                    print(io, "| [$(test.package)")
                    if test.version !== missing
                        print(io, " v$(test.version)")
                    end
                    print(io, "]($primary_log) |")
                end
                if history !== nothing
                    print(io, " <span class=\"history\">$(get(history, test.package, "missing"))</span> |")
                end

                println(io)
            end

            # report on groups of tests
            function reportsubgroup(subgroup)
                reason = if first(subgroup).reason === missing
                    "other"
                else
                    reason_message(first(subgroup).reason)
                end
                if summary
                    println(io, " - $(uppercasefirst(reason)): $(nrow(subgroup)) packages")
                else
                    println(io, """
                        <details open><summary>$(uppercasefirst(reason)): $(nrow(subgroup)) packages</summary>
                        <p>
                        """)
                    println(io)

                    five_col = any(row->row.source == "both", eachrow(subgroup))
                    header = five_col ? "| Package | Version | Primary | Against |" : "| Package |"
                    divider = five_col ? "| ------- | ------- | ------- | ------- |" : "| ------- |"
                    if history !== nothing
                        header *= " $history_heading |"
                        divider *= " ------- |"
                    end
                    println(io, header)
                    println(io, divider)
                    foreach(reportrow, eachrow(subgroup))
                    println(io)

                    println(io, """
                        </p>
                        </details>
                        """)
                end
            end
            function reportgroup(group)
                subgroups = groupby(group, :reason; skipmissing=true)
                for key in sort(keys(subgroups); by=key->reason_severity(key.reason))
                    reportsubgroup(subgroups[key])
                end

                # print tests without a reason separately, at the end
                others = group[group[!, :reason] .=== missing, :]
                if !isempty(others)
                    reportsubgroup(others)
                end

                println(io)
            end

            if hasagainst
                # first report on tests that changed status
                changed_tests = filter(test->test.source == "both" &&
                                             test.status != test.status_1, group)
                if !isempty(changed_tests)
                    println(io, "**$(nrow(changed_tests)) packages $verb only on the current version.**")
                    println(io)
                    reportgroup(changed_tests)
                end

                # now report the other ones
                unchanged_tests = filter(test->test.source == "left_only" ||
                                               test.status == test.status_1, group)
                if !isempty(unchanged_tests)
                    headline = "$(nrow(unchanged_tests)) packages $verb on the previous version too."
                    if summary
                        println(io, headline)
                    else
                        println(io, """
                            <details><summary><strong>$headline</strong></summary>
                            <p>
                            """)
                        unchanged_tests = copy(unchanged_tests)     # only report the
                        unchanged_tests[!, :source] .= "left_only"  # primary result
                        reportgroup(unchanged_tests)
                        println(io, """
                            </p>
                            </details>
                            """)
                    end
                end
            else
                # just report on all tests
                println(io, "$(nrow(group)) packages $verb.")
                println(io)
                reportgroup(group)
            end

            println(io)
        end
    end
end

function print_report(io::IO, primary_df::DataFrame, against_df::Union{DataFrame,Nothing};
                      primary_name::String, against_name::Union{String,Nothing},
                      title::String="Package Evaluation Report",
                      preface::String="",
                      elapsed::Union{Real,Nothing}=nothing,
                      versioninfo::Dict{String,String}=Dict{String,String}(),
                      history=nothing, history_heading::String="History",
                      dependents::Dict{String,Int}=Dict{String,Int}())
    hasagainst = against_df !== nothing

    # print report preface + job properties #
    #---------------------------------------#

    println(io, "# $title\n")
    if !isempty(preface)
        println(io, preface)
    end

    # print summary of tested packages #
    #----------------------------------#

    total_duration = sum(primary_df.duration) +
                     (hasagainst ? sum(against_df.duration) : 0)
    total_tests = nrow(primary_df) + (hasagainst ? nrow(against_df) : 0)
    if elapsed !== nothing
        println(io, """
                    Testing took $(readable_duration(elapsed)) (or, sequentially, $(readable_duration(total_duration)) to evaluate $total_tests packages).
                    """)
    else
        println(io, """
                    Testing took $(readable_duration(total_duration)) of sequential compute time to evaluate $total_tests packages.
                    """)
    end

    l = count(==(:load),    primary_df.status)
    t = count(==(:test),    primary_df.status)
    s = count(==(:skip),    primary_df.status)
    c = count(==(:crash),   primary_df.status)
    f = count(==(:fail),    primary_df.status)
    x = nrow(primary_df)

    println(io, """
                In total, $x packages were evaluated, out of which $t successfully tested, $l were not tested but did load successfully, $c crashed, $f failed and $s were skipped.
                """)

    println(io)

    # print result list #
    #-------------------#

    package_results = make_package_results(primary_df, against_df)

    new_failures = if hasagainst
        filter(test->test.source == "both" &&
                     test.status in (:fail, :crash) &&
                     test.status_1 in (:test, :load), package_results)
    else
        filter(test->test.status in (:fail, :crash), package_results)
    end
    has_issues = !isempty(new_failures)
    if hasagainst && has_issues
        println(io, """
                    **$(nrow(new_failures)) packages started failing on the primary configuration.**
                    """)
    end

    # main results body
    print_package_results(io, package_results, hasagainst;
                          primary_name, against_name, history, history_heading, dependents)

    # print build version info #
    #--------------------------#

    if haskey(versioninfo, primary_name)
        print(io, """
                  ## Version Info

                  #### Primary Build

                  ```
                  $(versioninfo[primary_name])
                  ```
                  """)

        if hasagainst && haskey(versioninfo, against_name)
            println(io)
            print(io, """
                      #### Comparison Build

                      ```
                      $(versioninfo[against_name])
                      ```
                      """)
        end
    end

    println(io, "<!-- Generated on $(now()) by PkgEval.jl -->")

    return has_issues
end

function render_html(report_md::String; title::String="Package Evaluation Report")
    parser = CommonMark.Parser()
    CommonMark.enable!(parser, CommonMark.TableRule())
    ast = parser(report_md)
    body = CommonMark.html(ast)
    report_html = """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="utf-8">
            <title>$title</title>
            <style>
            body {
                font-family: sans-serif;
                max-width: 65rem;
            }
            .history {
                font-family: monospace;
            }
            </style>
        </head>
        <body>$body</body>
        </html>
    """
    return replace(report_html, COLOR_MAP...)
end

# query the version info of the Julia binary used by a configuration
function collect_versioninfo(config::Configuration)
    out = Pipe()
    sandboxed_julia(config, ```-e '
            using InteractiveUtils
            versioninfo(verbose=true)
            '
        ```; stdout=out, stderr=out, stdin=devnull)
    close(out.in)
    return first(split(read(out, String), "Environment"))
end

"""
    write_report(dir, results::DataFrame; primary, against=nothing, kwargs...)
    write_report(dir, configs::Vector{Configuration}, results::DataFrame; kwargs...)

Render the results of [`evaluate`](@ref) to a report, like the ones Nanosoldier generates
in response to `@nanosoldier runtests()`. This writes `report.md`, `report.html` and
per-package logs (`logs/\$package/\$configuration.log`) to `dir`, with the report linking
to the logs relatively so that the directory is self-contained.

When passing the vector of `Configuration`s that was used for the evaluation, the first
configuration is treated as the primary one and the second (if any) as the baseline to
compare against, and version info for each Julia is included in the report. Otherwise,
the configuration names need to be passed explicitly using the `primary` and `against`
keyword arguments.

Other supported keyword arguments:
- `title`: the title of the report;
- `preface`: additional Markdown to include at the top of the report;
- `elapsed`: the wall-clock duration of the evaluation, in seconds;
- `dependents`: a dictionary mapping package names to their number of dependents,
  used to sort the report so that packages with many dependents come first.

Returns a named tuple `(; dir, has_issues)`, where `has_issues` indicates whether any
package (newly) fails or crashes.
"""
function write_report(dir::AbstractString, results::DataFrame;
                      primary::Union{String,Nothing}=nothing,
                      against::Union{String,Nothing}=nothing,
                      title::String="Package Evaluation Report", kwargs...)
    confignames = unique(results.configuration)
    if primary === nothing
        primary = if "primary" in confignames
            "primary"
        elseif length(confignames) == 1
            first(confignames)
        else
            error("Multiple configurations found ($(join(confignames, ", "))); specify which one is the primary one using the `primary` keyword argument")
        end
    end
    primary in confignames ||
        error("Configuration $primary not found in results")
    if against === nothing && length(confignames) == 2
        against = only(filter(!=(primary), confignames))
    end
    against === nothing || against in confignames ||
        error("Configuration $against not found in results")

    primary_df = copy(results[results.configuration .== primary, :])
    against_df = against === nothing ? nothing :
                 copy(results[results.configuration .== against, :])

    # we don't care about the distinction between failed and killed tests,
    # so lump them together
    for df in (primary_df, against_df)
        df === nothing && continue
        df[df[!, :status] .== :kill, :status] .= :fail
    end

    # write logs
    mkpath(dir)
    for df in (primary_df, against_df)
        df === nothing && continue
        configname = df === primary_df ? primary : against
        for test in eachrow(df)
            logdir = joinpath(dir, "logs", test.package)
            mkpath(logdir)
            open(joinpath(logdir, "$(configname).log"), "w") do io
                if !ismissing(test.log)
                    write(io, test.log)
                end
            end
        end
    end

    # generate the report
    io = IOBuffer()
    has_issues = print_report(io, primary_df, against_df;
                              primary_name=primary, against_name=against, title, kwargs...)
    report_md = String(take!(io))
    write(joinpath(dir, "report.md"), report_md)
    write(joinpath(dir, "report.html"), render_html(report_md; title))

    return (; dir=String(dir), has_issues)
end

function write_report(dir::AbstractString, configs::Vector{Configuration},
                      results::DataFrame;
                      versioninfo::Union{Dict{String,String},Nothing}=nothing,
                      preface::Union{String,Nothing}=nothing, kwargs...)
    isempty(configs) && throw(ArgumentError("no configurations specified"))
    length(configs) <= 2 ||
        throw(ArgumentError("can only report on a primary and an against configuration"))
    primary = configs[1].name
    against = length(configs) == 2 ? configs[2].name : nothing

    if preface === nothing
        io = IOBuffer()
        println(io, "## Job Properties\n")
        println(io, "*Primary configuration:* `julia = $(repr(configs[1].julia))`\n")
        if against !== nothing
            println(io, "*Against configuration:* `julia = $(repr(configs[2].julia))`\n")
        end
        preface = String(take!(io))
    end

    # version info can only be queried where the sandbox is available
    if versioninfo === nothing
        versioninfo = Dict{String,String}()
        if Sys.islinux()
            for config in configs
                try
                    versioninfo[config.name] = collect_versioninfo(config)
                catch err
                    @error "Failed to retrieve versioninfo() for configuration $(config.name)" exception=(err, catch_backtrace())
                end
            end
        end
    end

    return write_report(dir, results; primary, against, preface, versioninfo, kwargs...)
end
