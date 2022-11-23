const registry_lock = ReentrantLock()
const registry_cache = Dict()
function get_registry(config::Configuration)
    lock(registry_lock) do
        dir = get(registry_cache, config.registry, nothing)
        if dir === nothing || !isdir(dir)
            repo, ref = parse_repo_spec(config.registry, "JuliaRegistries/General")
            registry_cache[config.registry] = get_github_checkout(repo, ref)
        end
        return registry_cache[config.registry]
    end
end

"""
    packages(config::Configuration)::Dict{String,Package}

Determine the packages that we can test for a given configuration.
"""
function get_packages(config::Configuration)
    lock(packages_lock) do
        key = config.julia
        val = get(packages_cache, key, nothing)
        if val === nothing
            packages_cache[key] = _get_packages(config)
        end
        return packages_cache[key]
    end
end
const packages_lock = ReentrantLock()
const packages_cache = Dict()

function _get_packages(config::Configuration)
    packages = Dict{String,Package}()

    registry = get_registry(config)
    registry_instance = Pkg.Registry.RegistryInstance(registry)
    for (_, pkg) in registry_instance
        # TODO: read package compat info so that we can avoid testing uninstallable packages
        packages[pkg.name] = Package(; pkg.name, pkg.uuid)
    end

    # standard libraries are generally not registered, and even if they are,
    # installing and loading them will always use the embedded version.
    # so iterate them using the target Julia, and overwrite any existing entries
    stdlib_script = raw"""begin
            using Pkg
            for (uuid, (name,version)) in Pkg.Types.stdlibs()
                println("$(uuid) $(name)")
            end
        end"""
    p = Pipe()
    close(p.in)
    proc = sandboxed_julia(config, `-e $stdlib_script`; stdout=p.out)
    while !eof(p.out)
        line = readline(p.out)
        uuid, name = split(line, ' ')
        packages[name] = Package(; name, uuid=UUID(uuid), stdlib=true)
    end
    success(proc) || error("Failed to list standard libraries")

    return packages
end
