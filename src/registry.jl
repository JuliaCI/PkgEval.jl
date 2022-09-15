"""
    registry_packages(config::Configuration)::Vector{Package}

Read all packages from a registry and return them as a vector of Package structs.
"""
function registry_packages(config::Configuration)
    packages = Package[]

    # NOTE: we handle Registry check-outs ourselves, so can't use Pkg APIs
    #       (since they do not accept an argument to point to a custom Registry)
    registry = get_registry(config)
    for char in 'A':'Z', entry in readdir(joinpath(registry, string(char)))
        path = joinpath(registry, string(char), entry)
        isdir(path) || continue
        # TODO: read package compat info so that we can avoid testing uninstallable packages
        push!(packages, Package(name=entry))
    end
    return packages
end

get_registry_repo(spec) = get_github_repo(spec, "JuliaRegistries/general")

const registry_lock = ReentrantLock()
const registry_cache = Dict()
function get_registry(config::Configuration)
    lock(registry_lock) do
        dir = get(registry_cache, config.registry, nothing)
        if dir === nothing || !isdir(dir)
            registry_cache[config.registry] = get_registry_repo(config.registry)
        end
        return registry_cache[config.registry]
    end
end
