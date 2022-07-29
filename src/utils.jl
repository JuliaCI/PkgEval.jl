isdebug(group) =
    Base.CoreLogging.current_logger_for_env(Base.CoreLogging.Debug, group, PkgEval) !== nothing

function purge()
    lock(julia_lock) do
        for dir in values(julia_cache)
            rm(dir; recursive=true)
        end
        empty!(julia_cache)
    end

    lock(rootfs_lock) do
        for dir in values(rootfs_cache)
            rm(dir; recursive=true)
        end
        empty!(rootfs_cache)
    end

    return
end
