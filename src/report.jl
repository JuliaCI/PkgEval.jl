# details on status codes

const statusses = Dict(
    :ok     => "successful",
    :skip   => "skipped",
    :fail   => "unsuccessful",
    :kill   => "interrupted",
)
const reasons = Dict(
    missing                 => missing,
    # skip
    :explicit               => "package was blacklisted",
    :jll                    => "package is a untestable wrapper package",
    :unsupported            => "package is not supported by this Julia version",
    # fail
    :unsatisfiable          => "package could not be installed",
    :untestable             => "package does not have any tests",
    :binary_dependency      => "package requires a missing binary dependency",
    :missing_dependency     => "package is missing a package dependency",
    :missing_package        => "package is using an unknown package",
    :test_failures          => "package has test failures",
    :syntax                 => "package has syntax issues",
    :gc_corruption          => "GC corruption detected",
    :segfault               => "a segmentation fault happened",
    :abort                  => "the process was aborted",
    :unreachable            => "an unreachable instruction was executed",
    :network                => "networking-related issues were detected",
    :unknown                => "there were unidentified errors",
    :uncompilable           => "compilation of the package failed",
    # kill
    :time_limit             => "test duration exceeded the time limit",
    :log_limit              => "test log exceeded the size limit",
    :inactivity             => "tests became inactive",
)
