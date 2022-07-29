const DEFAULT_REGISTRY = "General"

"""
    registry_packages(registry::String=DEFAULT_REGISTRY)::Vector{Package}

Read all packages from a registry and return them as a vector of Package structs.
"""
function registry_packages(registry::String=DEFAULT_REGISTRY; retries::Integer=2)
    packages = Package[]
    registry_instance = only(filter(ri->ri.name == registry,
                             Pkg.Registry.reachable_registries()))
    for (uuid, pkg) in registry_instance
        # TODO: read package compat info so that we can avoid testing uninstallable packages

        push!(packages,
              Package(name=pkg.name,
                      retries=(pkg.name in retry_list ? retries : 0)))
    end

    return packages
end
