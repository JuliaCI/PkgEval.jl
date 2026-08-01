# Base.CACHE_FETCH_HOOK client for PkgEvalFarm's loopback compile-cache
# protocol (the farm's docs/sealing.md). Loaded by common.jl when
# PKGEVAL_CACHE_SERVER is set and the running julia carries the hook.
#
# Trust model: this code runs inside the sandbox, next to arbitrary package
# code, so nothing here is trusted. It can only GET artifacts (which the
# loader revalidates like any depot candidate) and report context. The worker
# on the other side of the socket enforces namespacing on publication.
#
# Everything is loaded eagerly here, before the hook is installed, so the hook
# itself never triggers package loading (a hard requirement of the hook
# contract).

module PkgEvalCacheClient

using Sockets, SHA, TOML

const SERVER = get(ENV, "PKGEVAL_CACHE_SERVER", "")
const NAMESPACE = get(ENV, "PKGEVAL_CACHE_NAMESPACE", "default")
# effectively unbounded: the proxy answers immediately unless it is
# *productively* holding the fetch while this exact key's derivation
# completes, and cutting a hold short would silently break artifact sharing
# for the rest of the job — the evaluation's own time limit is the bound
const FETCH_DEADLINE = something(tryparse(Float64,
    get(ENV, "PKGEVAL_CACHE_FETCH_DEADLINE", "")), 86400.0)

## minimal HTTP/1.1 over a TCP socket: the server is a loopback proxy the
## worker runs; a watchdog timer bounds every exchange so a wedged proxy can
## never stall loading

function http_request(method::String, path::String, body::Vector{UInt8}=UInt8[];
                      deadline::Float64=10.0)
    m = match(r"^http://([0-9a-zA-Z.-]+):(\d+)$", SERVER)
    m === nothing && return nothing
    sock = try
        Sockets.connect(String(m[1]), parse(Int, m[2]))
    catch
        return nothing
    end
    watchdog = Timer(_ -> close(sock), deadline)
    try
        write(sock, "$method $path HTTP/1.1\r\nHost: farm\r\nConnection: close\r\n" *
                    "Content-Length: $(length(body))\r\n\r\n")
        write(sock, body)
        status = let line = readline(sock)
            parts = split(line, ' '; limit=3)
            length(parts) >= 2 ? something(tryparse(Int, parts[2]), 0) : 0
        end
        content_length, chunked = nothing, false
        while true
            line = readline(sock)
            isempty(line) && break
            header = lowercase(line)
            if startswith(header, "content-length:")
                content_length = tryparse(Int, strip(last(split(header, ':'; limit=2))))
            elseif startswith(header, "transfer-encoding:") && occursin("chunked", header)
                chunked = true
            end
        end
        payload = if chunked
            io = IOBuffer()
            while true
                n = parse(Int, strip(first(split(readline(sock), ';'))); base=16)
                n == 0 && break
                write(io, read(sock, n))
                readline(sock)   # trailing CRLF of the chunk
            end
            take!(io)
        elseif content_length !== nothing
            read(sock, content_length)
        else
            read(sock)   # Connection: close delimits the body
        end
        return (status, payload)
    catch
        return nothing
    finally
        close(watchdog)
        close(sock)
    end
end

## build-context key: the full resolution context of the cachefile we want.
## Both the fetch side and the publication side (emit_produced_keys) compute
## keys with this same function in the same process kind, which is what makes
## them match without any cachefile-header parsing.

function dep_build_id(id::Base.PkgId)
    mod = Base.maybe_root_module(id)
    mod isa Module && return Base.module_build_id(mod)
    paths = try
        Base.find_all_in_cache_path(id)
    catch
        String[]
    end
    isempty(paths) && return nothing
    # the loader prefers the newest candidate; in the farm's fresh per-job
    # depots there is exactly one. parse_cache_buildid composes the same full
    # (checksum << 64) | lo form module_build_id reports for loaded modules —
    # the two paths must agree or producer/consumer keys diverge.
    path = last(sort(paths; by=mtime))
    try
        build_id, file_uuid = Base.parse_cache_buildid(path)
        file_uuid == id.uuid || return nothing
        return build_id
    catch
        return nothing
    end
end

# One manifest snapshot per context computation: uuid -> (name, entry).
function manifest_by_uuid()
    project = Base.active_project()
    project === nothing && return nothing
    manifest_path = Base.project_file_manifest_path(project)
    (manifest_path === nothing || !isfile(manifest_path)) && return nothing
    manifest = try
        TOML.parsefile(manifest_path)
    catch
        return nothing
    end
    get(manifest, "manifest_format", "1") in ("2.0", "2") ||
        haskey(manifest, "deps") || return nothing
    entries = get(manifest, "deps", manifest)
    entries isa AbstractDict || return nothing
    by_uuid = Dict{Base.UUID,Tuple{String,Dict{String,Any}}}()
    for (name, pkg_entries) in entries
        pkg_entries isa AbstractVector || continue
        for e in pkg_entries
            e isa AbstractDict || continue
            uuid = get(e, "uuid", nothing)
            uuid === nothing && continue
            by_uuid[Base.UUID(String(uuid))] = (String(name), e)
        end
    end
    return by_uuid
end

# The v2 preimage carries, per direct dep, its resolved version and its *own*
# context key: that is what lets a derivation executor reconstruct the exact
# environment (pin versions, fetch dep artifacts by key, recurse through
# their metadata) instead of facing an unresolvable build_id. Computed
# recursively over the manifest with memoization; the driver calls
# concurrently, hence the lock.
const CTX_LOCK = ReentrantLock()
const CTX_CACHE = Dict{Base.UUID,Any}()

function build_context(pkg::Base.PkgId)
    pkg.uuid === nothing && return nothing
    env = manifest_by_uuid()
    env === nothing && return nothing
    return lock(CTX_LOCK) do
        empty_stack = Set{Base.UUID}()
        if haskey(env, pkg.uuid)
            _build_context(pkg.uuid, env, empty_stack)
        else
            # not a manifest entry: possibly a package extension
            _build_ext_context(pkg, env, empty_stack)
        end
    end
end

function _build_context(uuid::Base.UUID, env, stack::Set{Base.UUID})
    haskey(CTX_CACHE, uuid) && return CTX_CACHE[uuid]
    uuid in stack && return nothing   # manifest cycle: unkeyable
    push!(stack, uuid)
    ctx = try
        _build_context_uncached(uuid, env, stack)
    finally
        delete!(stack, uuid)
    end
    # positives only: a context that is unkeyable *now* (deps not yet
    # compiled/fetched — e.g. the serial require site fires before the
    # precompilation driver has processed the deps) may become keyable by the
    # time the hook is consulted again
    ctx === nothing || (CTX_CACHE[uuid] = ctx)
    return ctx
end

function _build_context_uncached(uuid::Base.UUID, env, stack::Set{Base.UUID})
    haskey(env, uuid) || return nothing
    name, entry = env[uuid]
    version = get(entry, "version", nothing)
    tree = get(entry, "git-tree-sha1", nothing)
    (version === nothing || tree === nothing) && return nothing   # dev/stdlib: unkeyable

    # direct deps: names (unambiguous) or a name=>uuid table
    raw_deps = get(entry, "deps", Union{}[])
    dep_uuids = Base.UUID[]
    if raw_deps isa AbstractDict
        for (_, dep_uuid) in raw_deps
            push!(dep_uuids, Base.UUID(String(dep_uuid)))
        end
    else
        by_name = Dict(n => u for (u, (n, _)) in env)
        for dep_name in raw_deps
            dep_uuid = get(by_name, String(dep_name), nothing)
            dep_uuid === nothing && return nothing
            push!(dep_uuids, dep_uuid)
        end
    end
    deps = NamedTuple[]
    for dep_uuid in dep_uuids
        dep_name = haskey(env, dep_uuid) ? env[dep_uuid][1] : ""
        build_id = dep_build_id(Base.PkgId(dep_uuid, dep_name))
        build_id === nothing && return nothing   # unkeyable without the full dep context
        dep_entry = haskey(env, dep_uuid) ? env[dep_uuid][2] : Dict{String,Any}()
        dep_version = something(get(dep_entry, "version", nothing), "-")
        # a dep that is itself unkeyable (stdlib, dev) contributes build_id
        # identity but no fetchable artifact
        dep_ctx = _build_context(dep_uuid, env, stack)
        push!(deps, (; uuid=string(dep_uuid), name=dep_name,
                     build_id=UInt128(build_id), version=String(dep_version),
                     key=dep_ctx === nothing ? "-" : dep_ctx.key))
    end
    sort!(deps; by=d -> d.uuid)

    flags = _cache_flags()
    flags === nothing && return nothing
    prefs = _prefs_hash(uuid)

    canon = join(["v2",
                  "julia=$(VERSION)+$(Base.GIT_VERSION_INFO.commit)",
                  "name=$name",
                  "uuid=$uuid",
                  "version=$version",
                  "tree=$tree",
                  "flags=$flags",
                  "prefs=$prefs",
                  ("dep=$(d.uuid):$(string(d.build_id, base=16)):$(d.version):$(d.key)"
                   for d in deps)...], "\n")
    return (; key=bytes2hex(SHA.sha256(canon)), canon, uuid=string(uuid), name,
            version=String(string(version)), deps)
end

_cache_flags() = try
    Int(Base._cacheflag_to_uint8(Base.CacheFlags()))
catch
    nothing
end

# kept symmetric-by-construction: both sides run this same code in the
# same resolved environment, so a degenerate value only costs fetch
# precision, never a wrong hit (the loader revalidates prefs itself)
_prefs_hash(uuid) = try
    d = Base.get_preferences(uuid)
    isempty(d) ? "0" : bytes2hex(SHA.sha256(sprint(io -> TOML.print(io, d; sorted=true))))
catch
    "0"
end

# Package extensions have no manifest entry of their own: their identity
# derives entirely from the parent — uuid5(parent_uuid, ext_name), the
# parent's version and tree (the extension source lives inside the parent's
# tree), and dep lines for the parent plus the trigger packages (the loader
# loads all of them before the extension, so their build_ids are known).
# Emitted as a "v3" preimage carrying an ext_of line; package preimages stay
# v2, so every published package key is unaffected. An old proxy rejects v3
# as malformed, which the hook already treats as a plain miss.
function _build_ext_context(pkg::Base.PkgId, env, stack::Set{Base.UUID})
    haskey(CTX_CACHE, pkg.uuid) && return CTX_CACHE[pkg.uuid]
    parent_uuid = nothing
    for (u, _) in env
        if Base.uuid5(u, pkg.name) == pkg.uuid
            parent_uuid = u
            break
        end
    end
    parent_uuid === nothing && return nothing
    parent_name, parent_entry = env[parent_uuid]
    version = get(parent_entry, "version", nothing)
    tree = get(parent_entry, "git-tree-sha1", nothing)
    (version === nothing || tree === nothing) && return nothing   # dev parent: unkeyable
    parent_ctx = _build_context(parent_uuid, env, stack)

    # triggers: the parent project's [extensions] entry, resolved through its
    # [weakdeps] and [deps] tables
    parent_src = Base.locate_package(Base.PkgId(parent_uuid, parent_name))
    parent_src === nothing && return nothing
    project = try
        TOML.parsefile(joinpath(dirname(dirname(parent_src)), "Project.toml"))
    catch
        return nothing
    end
    triggers = get(get(project, "extensions", Dict{String,Any}()), pkg.name, nothing)
    triggers === nothing && return nothing
    triggers isa AbstractString && (triggers = [triggers])
    lookup = Dict{String,String}()
    for table in ("deps", "weakdeps"), (k, v) in get(project, table, Dict{String,Any}())
        v isa AbstractString && (lookup[String(k)] = String(v))
    end
    dep_ids = [Base.PkgId(parent_uuid, parent_name)]
    for t in triggers
        u = get(lookup, String(t), nothing)
        u === nothing && return nothing
        push!(dep_ids, Base.PkgId(Base.UUID(u), String(t)))
    end

    deps = NamedTuple[]
    for id in dep_ids
        build_id = dep_build_id(id)
        build_id === nothing && return nothing   # trigger not compiled yet: retry later
        entry = haskey(env, id.uuid) ? env[id.uuid][2] : Dict{String,Any}()
        dep_version = something(get(entry, "version", nothing), "-")
        dep_ctx = id.uuid == parent_uuid ? parent_ctx : _build_context(id.uuid, env, stack)
        push!(deps, (; uuid=string(id.uuid), name=id.name,
                     build_id=UInt128(build_id), version=String(dep_version),
                     key=dep_ctx === nothing ? "-" : dep_ctx.key))
    end
    sort!(deps; by=d -> d.uuid)

    flags = _cache_flags()
    flags === nothing && return nothing
    prefs = _prefs_hash(pkg.uuid)

    canon = join(["v3",
                  "julia=$(VERSION)+$(Base.GIT_VERSION_INFO.commit)",
                  "name=$(pkg.name)",
                  "uuid=$(pkg.uuid)",
                  "ext_of=$parent_uuid",
                  "version=$version",
                  "tree=$tree",
                  "flags=$flags",
                  "prefs=$prefs",
                  ("dep=$(d.uuid):$(string(d.build_id, base=16)):$(d.version):$(d.key)"
                   for d in deps)...], "\n")
    ctx = (; key=bytes2hex(SHA.sha256(canon)), canon, uuid=string(pkg.uuid),
           name=pkg.name, version=String(string(version)), deps,
           ext_of=string(parent_uuid))
    CTX_CACHE[pkg.uuid] = ctx
    return ctx
end

## the hook

const HITS = Ref(0)     # observability for tests/logs
const MISSES = Ref(0)

function fetch_hook(pkg::Base.PkgId, sourcepath::String)
    ctx = build_context(pkg)
    get(ENV, "PKGEVAL_CACHE_DEBUG", "") == "1" &&
        println(stderr, "[cache_client debug] hook ", pkg.name, " ctx=", ctx === nothing ? "nothing" : "ok")
    ctx === nothing && return false
    # one request carries the full preimage: the proxy serves the artifact,
    # or *creates* its derivation and holds this very request until it
    # terminates — so even the first requester of a context waits for the
    # canonical artifact instead of compiling a private copy. A 404 means the
    # derivation terminally failed: compiling locally is then correct.
    resp = http_request("POST", "/ensure/v2/$NAMESPACE",
                        Vector{UInt8}(codeunits(ctx.canon)); deadline=FETCH_DEADLINE)
    if resp === nothing || resp[1] != 200
        MISSES[] += 1
        return false
    end
    payload = resp[2]
    length(payload) < 16 && return false
    # frame: [len_ji::UInt64le][ji][len_so::UInt64le][so]; the pair shares a
    # basename so ocachefile_from_cachefile's convention keeps working
    len_ji = Int(ltoh(reinterpret(UInt64, payload[1:8])[1]))
    length(payload) >= 16 + len_ji || return false
    ji = payload[9:8+len_ji]
    len_so = Int(ltoh(reinterpret(UInt64, payload[9+len_ji:16+len_ji])[1]))
    length(payload) >= 16 + len_ji + len_so || return false
    # candidate discovery requires the exact entry naming (a uuid slug prefix,
    # see Base.find_all_in_cache_path), so derive it from Base itself
    entrypath, entryfile = Base.cache_file_entry(pkg)
    dir = joinpath(DEPOT_PATH[1], entrypath)
    mkpath(dir)
    stem = joinpath(dir, "$(entryfile)_fetched$(first(ctx.key, 8))")
    write(stem * ".ji", ji)
    len_so > 0 && write(stem * ".$(Base.Libc.Libdl.dlext)",
                        payload[17+len_ji:16+len_ji+len_so])
    HITS[] += 1
    return true
end

function install!()
    Base.CACHE_FETCH_HOOK[] = fetch_hook
    # one line of evidence in every evaluation log: how the cache behaved
    atexit() do
        (HITS[] > 0 || MISSES[] > 0) &&
            println(stderr, "[cache_client] hits=", HITS[], " misses=", MISSES[])
    end
    return nothing
end

## publication support (seal jobs): report what this environment produced for
## one unit, keyed with the same build_context the fetch side uses. The worker
## decides what (if anything) to publish — and under which uuid namespace.

function _produced_entry(id::Base.PkgId)
    ctx = build_context(id)
    ctx === nothing && return nothing
    depot = DEPOT_PATH[1]
    paths = filter(p -> startswith(p, depot), Base.find_all_in_cache_path(id))
    isempty(paths) && return nothing
    ji = last(sort(paths; by=mtime))
    so = try
        oc = Base.ocachefile_from_cachefile(ji)
        isfile(oc) ? oc : nothing
    catch
        nothing
    end
    compiled = joinpath(depot, "compiled")
    entry = Dict{String,Any}(
        "uuid" => ctx.uuid, "key" => ctx.key, "preimage" => ctx.canon,
        "version" => ctx.version,
        "ji" => relpath(ji, compiled),
        "so" => so === nothing ? "" : relpath(so, compiled),
        # direct-dep identities and keys: published alongside the
        # artifact (its .meta sidecar) so closures resolve by-key
        "deps" => [Dict("uuid" => d.uuid, "name" => d.name,
                        "version" => d.version, "key" => d.key)
                   for d in ctx.deps])
    hasproperty(ctx, :ext_of) && (entry["ext_of"] = ctx.ext_of)
    return entry
end

# resolve a unit through the manifest, not identify_package: units that are
# not project-direct deps (e.g. a derivation's transitive packages) are
# invisible to Main's load path but present in the environment. An explicit
# uuid bypasses the scan (extension units have no manifest entry at all).
function _unit_id(unit::String, uuid::Union{Nothing,String})
    uuid !== nothing && return Base.PkgId(Base.UUID(uuid), unit)
    env = manifest_by_uuid()
    env === nothing && return nothing
    for (u, (name, _)) in env
        name == unit && return Base.PkgId(u, name)
    end
    return nothing
end

function emit_produced_keys(unit::String, out::String;
                            uuid::Union{Nothing,String}=nothing)
    id = _unit_id(unit, uuid)
    id === nothing && return
    entry = _produced_entry(id)
    entry === nothing && return
    open(out, "w") do io
        TOML.print(io, Dict(unit => entry))
    end
    return
end

# The seal-job variant: the unit plus any of its own extensions that were
# produced in this depot (their triggers happened to be present). Extension
# entries publish under uuid5(unit, ext_name), so they carry the unit's
# authority — the farm verifies that derivation structurally.
function emit_produced_keys_with_extensions(unit::String, out::String)
    id = _unit_id(unit, nothing)
    id === nothing && return
    entries = Dict{String,Any}()
    entry = _produced_entry(id)
    entry === nothing && return
    entries[unit] = entry
    src = Base.locate_package(id)
    exts = try
        src === nothing ? Dict{String,Any}() :
            get(TOML.parsefile(joinpath(dirname(dirname(src)), "Project.toml")),
                "extensions", Dict{String,Any}())
    catch
        Dict{String,Any}()
    end
    for ext_name in keys(exts)
        ext_id = Base.PkgId(Base.uuid5(id.uuid, String(ext_name)), String(ext_name))
        ext_entry = _produced_entry(ext_id)
        ext_entry === nothing && continue   # not triggered in this env
        entries[String(ext_name)] = ext_entry
    end
    open(out, "w") do io
        TOML.print(io, entries)
    end
    return
end

end # module
