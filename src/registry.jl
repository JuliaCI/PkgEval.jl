const DEFAULT_REGISTRY = "General"

const skip_lists = Dict{String,Vector{String}}()
const retry_lists = Dict{String,Vector{String}}()

"""
    prepare_registry([name])

Prepare the given registry for use by this package and update it if `update` is true.
`name` must correspond to an existing stanza in the `deps/Registries.toml` file.
"""
function prepare_registry(name=DEFAULT_REGISTRY; update::Bool=false)
    reg = read_registries()[name]
    regspec = RegistrySpec(name = name, url = reg["url"], uuid = UUID(reg["uuid"]))

    # clone and update the registry
    if !any(existing_regspec -> existing_regspec.name == name, Pkg.Types.collect_registries())
        Pkg.Types.clone_or_cp_registries([regspec])
    elseif update
        Pkg.Registry.update(name)
    end

    # read some metadata
    skip_lists[name] = get(reg, "skip", String[])
    retry_lists[name] = get(reg, "retry", String[])

    return
end

"""
    read_pkgs([pkgs::Vector{String}]; [registry::String])

Read all packages from a registry and return them as a vector of tuples containing the
package name and registry, its UUID, and a path to it. If `pkgs` is given, only collect
packages matching the names in `pkgs`
"""
function read_pkgs(pkg_names::Vector{String}=String[]; registry=DEFAULT_REGISTRY)
    pkg_names = Set(pkg_names)
    want_all = isempty(pkg_names)

    pkg_data = []
    regpath = registry_path(registry)
    open(joinpath(regpath, "Registry.toml")) do io
        for (_uuid, pkgdata) in Pkg.Types.read_registry(joinpath(regpath, "Registry.toml"))["packages"]
            uuid = UUID(_uuid)
            name = pkgdata["name"]

            if !want_all
                name in pkg_names || continue
                delete!(pkg_names, name)
            end

            path = abspath(regpath, pkgdata["path"])
            push!(pkg_data, (name=name, uuid=uuid, path=path, registry=registry))
        end
    end

    if !want_all && !isempty(pkg_names)
        @warn """did not find the following packages in the $registry registry:\n $("  - " .* join(pkg_names, '\n'))"""
    end

    return pkg_data
end
