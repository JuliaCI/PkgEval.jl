const DEFAULT_REGISTRY = "General"

# Skip these packages when testing packages
const skip_lists = Dict{String,Vector{String}}()

"""
    get_registry([name]; update=false)

Download the given registry, or if it already exists, update it if `update` is true.
`name` must correspond to an existing stanza in the `deps/Registries.toml` file.
"""
function get_registry(name=DEFAULT_REGISTRY; update=false)
    reg = read_registries()[name]
    regspec = RegistrySpec(name = name, url = reg["url"], uuid = UUID(reg["uuid"]))

    # clone and update the registry
    if !any(existing_regspec -> existing_regspec.name == name, Pkg.Types.collect_registries())
        Pkg.Types.clone_or_cp_registries([regspec])
    elseif update
        Pkg.UPDATED_REGISTRY_THIS_SESSION[] = false
        Pkg.Types.update_registries(Pkg.Types.Context(), [regspec])
    end

    # read some metadata
    skip_lists[name] = get(reg, "skip", String[])

    return
end

"""
    read_pkgs([pkgs::Vector{String}]; [registry::String])

Read all packages from a registry and return them as a vector of tuples containing the
package name and registry, its UUID, and a path to it. If `pkgs` is given, only collect
packages matching the names in `pkgs`
"""
function read_pkgs(pkgs::Union{Nothing, Vector{String}}=nothing; registry=DEFAULT_REGISTRY)
    get_registry(registry)
    if pkgs !== nothing
        pkgs = copy(pkgs)
    end

    pkg_data = []
    regpath = registry_path(registry)
    open(joinpath(regpath, "Registry.toml")) do io
        for (_uuid, pkgdata) in Pkg.Types.read_registry(joinpath(regpath, "Registry.toml"))["packages"]
            uuid = UUID(_uuid)
            name = pkgdata["name"]
            if pkgs !== nothing
                idx = findfirst(==(name), pkgs)
                idx === nothing && continue
                deleteat!(pkgs, idx)
            end
            path = abspath(regpath, pkgdata["path"])
            push!(pkg_data, (name=name, uuid=uuid, path=path, registry=registry))
        end
    end
    if pkgs !== nothing && !isempty(pkgs)
        @warn """did not find the following packages in the $registry registry:\n $("  - " .* join(pkgs, '\n'))"""
    end

    return pkg_data
end
