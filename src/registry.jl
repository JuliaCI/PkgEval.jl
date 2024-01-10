const registry_lock = ReentrantLock()
const registry_cache = Dict()
function get_registry(config::Configuration)
    if ispath(config.registry)
        return config.registry
    end

    lock(registry_lock) do
        dir = get(registry_cache, config.registry, nothing)
        if dir === nothing || !isdir(dir)
            repo, ref = parse_repo_spec(config.registry, "JuliaRegistries/General")
            registry_cache[config.registry] = if haskey(known_registries, repo) && ref == "master"
                # if this is a known registry, try to get it from the configured pkg server
                try
                    uuid = known_registries[repo]
                    get_pkgserver_registry(uuid)
                catch err
                    @error "Failed to get $repo registry from package server" exception=(err, catch_backtrace())
                    get_github_checkout(repo, ref)
                end
            else
                # otherwise, just grab it from GitHub directly
                get_github_checkout(repo, ref)
            end
        end
        return registry_cache[config.registry]
    end
end

# NOTE: we keep a list of known registries and their UUID so that we can defer to the
#       package server without having to query the Registry.toml. This also makes it
#       possible to fork a registry and run PkgEval on it without having to modify the UUID.
const known_registries = Dict{String,UUID}(
    "JuliaRegistries/General" => UUID("23338594-aafe-5451-b93e-139f81909106"),
)

function get_pkgserver_registry(requested_uuid)
    pkgserver = get(ENV, "JULIA_PKG_SERVER", "pkg.julialang.org")

    registries_url = "https://$pkgserver/registries"
    registries = Dict(map(split(sprint(io->Downloads.download(registries_url, io)))) do url
        _, prefix, uuid, hash = split(url, '/')
        UUID(uuid) => String(url)
    end)
    haskey(registries, requested_uuid) || error("Configured package server does not host requested registry $requested_uuid")
    registry = registries[requested_uuid]

    registry_url = "https://$pkgserver/$(registry)"
    dir = mktempdir(prefix="pkgeval_registry_")
    Pkg.PlatformEngines.download_verify_unpack(registry_url, nothing, dir;
                                               ignore_existence=true)

    return dir
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
            for (uuid, pkg) in Pkg.Types.stdlibs()
                name = isa(pkg, String) ? pkg : first(pkg)
                println("$(uuid) $(name)")
            end
        end"""
    p = Pipe()
    close(p.in)
    proc = sandboxed_julia(config, `-e $stdlib_script`; stdout=p.out)
    while !eof(p.out)
        line = readline(p.out)
        entries = split(line, ' ')
        length(entries) == 2 || continue
        uuid, name = entries
        stdlibs[name] = Package(; name, uuid=UUID(uuid))
    end
    success(proc) || error("Failed to list standard libraries")

    # iterate packages from the registry
    packages = Dict{String,Package}()
    registry = get_registry(config)
    registry_instance = Pkg.Registry.RegistryInstance(registry)
    for (_, pkg) in registry_instance
        # for simplicity, we only consider the latest version of each package.
        # this ensures we'll always test the same version across configurations.
        #
        # we could be smarter here and intersect the known versions of a package
        # with each Julia version, but that's a lot more complicated.
        info = Pkg.Registry.registry_info(pkg)
        version = maximum(keys(info.version_info))

        # check if this package is compatible with the current Julia version
        compat = true
        for (version_range, bounds) in info.compat
            version in version_range || continue
            if haskey(bounds, "julia") && julia_version(config) ∉ bounds["julia"]
                compat = false
                break
            end
        end
        compat || continue

        packages[pkg.name] = Package(; pkg.name, pkg.uuid, version)
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

"""
    package_dependencies(config; transitive=true)

This function returns a dictionary of package dependencies for each package in the registry.

## Arguments
- `config`: The configuration object for the registry.
- `transitive`: A boolean indicating whether to include transitive dependencies. Default is `true`.

## Returns
A dictionary where the keys are package names and the values are vectors of package names representing the dependencies.

"""
function package_dependencies(config; transitive=true)
    dependencies = Dict{String,Vector{String}}()

    # iterate packages from the registry
    registry = get_registry(config)
    registry_instance = Pkg.Registry.RegistryInstance(registry)
    for (_, pkg) in registry_instance
        # we only consider the latest version of each package; see `get_packages`
        info = Pkg.Registry.registry_info(pkg)
        version = maximum(keys(info.version_info))

        # iterate the dependencies
        pkg_deps = Set{String}()
        for (version_range, deps) in info.deps
            version in version_range || continue
            for (name, uuid) in deps
                push!(pkg_deps, name)
            end
        end
        delete!(pkg_deps, "julia")
        dependencies[pkg.name] = collect(pkg_deps)
    end

    if transitive
        function get_deps!(pkg, deps_seen=String[])
            new_deps = get(dependencies, pkg, [])
            for dep in new_deps
                if !(dep in deps_seen)
                    push!(deps_seen, dep)
                    get_deps!(dep, deps_seen)
                end
            end
            return deps_seen
        end

        for (pkg, deps) in dependencies
            dependencies[pkg] = get_deps!(pkg)
        end
    end

    return dependencies
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
