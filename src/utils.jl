isdebug(group) =
    Base.CoreLogging.current_logger_for_env(Base.CoreLogging.Debug, group, PkgEval) !== nothing

"""
    PkgEval.purge()

Remove temporary files and folders that are unlikely to be re-used in the future, e.g.,
temporary Julia installs or compilation cache of packages.

Artifacts that are more likely to be re-used in the future, e.g., downloaded Julia builds
or check-outs of Git repositories, are saved in scratch spaces instead.
"""
function purge()
    lock(rootfs_lock) do
        for dir in values(rootfs_cache)
            isdir(dir) && rm(dir; recursive=true)
        end
        empty!(rootfs_cache)
    end

    lock(julia_lock) do
        for dir in values(julia_cache)
            isdir(dir) && rm(dir; recursive=true)
        end
        empty!(julia_cache)
    end

    lock(compiled_lock) do
        for dir in values(compiled_cache)
            isdir(dir) && rm(dir; recursive=true)
        end
        empty!(compiled_cache)
    end

    return
end
