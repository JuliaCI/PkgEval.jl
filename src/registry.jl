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
        key = (config.julia, config.compiled)
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
    # standard libraries are generally not registered, and even if they are,
    # installing and loading them will always use the embedded version.
    stdlibs = Dict{String,Package}()
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
        stdlibs[name] = Package(; name, uuid=UUID(uuid))
    end
    success(proc) || error("Failed to list standard libraries")

    # iterate packages from the registry
    packages = Dict{String,Package}()
    registry = get_registry(config)
    registry_instance = Pkg.Registry.RegistryInstance(registry)
    for (_, pkg) in registry_instance
        # TODO: read package compat info so that we can avoid testing uninstallable packages
        packages[pkg.name] = Package(; pkg.name, pkg.uuid)
    end

    # merge both, preferring stdlib versions
    for (uuid, package) in stdlibs
        # ... unless we're compiling, in which case it doesn't make sense to test stdlibs
        if config.compiled
            delete!(packages, uuid)
        else
            packages[uuid] = package
        end
    end

    return packages
end

# look up the tree hash of a package/slug combination.
# this is useful for verifying the package store on disk.
# returns nothing if the combination wasn't found in the registry.
function lookup_package_slug(registry::String, package::String, slug::String)
    if haskey(registry_package_slug_cache, registry)
        cache = registry_package_slug_cache[registry]
    else
        cache = Dict{Tuple{String,String}, Base.SHA1}()

        registry_instance = Pkg.Registry.RegistryInstance(registry)
        for (_, pkg) in registry_instance
            pkginfo = Registry.registry_info(pkg)
            for (v, vinfo) in pkginfo.version_info
                tree_hash = vinfo.git_tree_sha1
                for slug in (Base.version_slug(pkg.uuid, tree_hash),
                             Base.version_slug(pkg.uuid, tree_hash, 4))
                    cache[(pkg.name, slug)] = tree_hash
                end
            end
        end

        registry_package_slug_cache[registry] = cache
    end

    get(cache, (package, slug), nothing)
end
const registry_package_slug_cache = Dict()
