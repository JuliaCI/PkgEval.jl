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
    # depots there is exactly one
    path = last(sort(paths; by=mtime))
    header = try
        Base.parse_cache_header(path)
    catch
        return nothing
    end
    for (modkey, build_id) in header[1]
        modkey == id && return UInt128(build_id)
    end
    return nothing
end

function build_context(pkg::Base.PkgId)
    pkg.uuid === nothing && return nothing
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
    pkg_entries = get(entries, pkg.name, nothing)
    pkg_entries isa AbstractVector || return nothing
    entry = nothing
    for e in pkg_entries
        get(e, "uuid", "") == string(pkg.uuid) && (entry = e; break)
    end
    entry === nothing && return nothing
    version = get(entry, "version", nothing)
    tree = get(entry, "git-tree-sha1", nothing)
    (version === nothing || tree === nothing) && return nothing   # dev/stdlib: unkeyable

    # direct deps: names (unambiguous) or a name=>uuid table
    raw_deps = get(entry, "deps", Union{}[])
    deps = Tuple{String,UInt128}[]
    dep_ids = Base.PkgId[]
    if raw_deps isa AbstractDict
        for (_, uuid) in raw_deps
            push!(dep_ids, Base.PkgId(Base.UUID(String(uuid)), ""))
        end
    else
        for name in raw_deps
            dep_entries = get(entries, String(name), nothing)
            dep_entries isa AbstractVector && length(dep_entries) == 1 || return nothing
            push!(dep_ids, Base.PkgId(Base.UUID(String(dep_entries[1]["uuid"])), String(name)))
        end
    end
    for id in dep_ids
        build_id = dep_build_id(id)
        build_id === nothing && return nothing   # unkeyable without the full dep context
        push!(deps, (string(id.uuid), UInt128(build_id)))
    end
    sort!(deps)

    flags = try
        Int(Base._cacheflag_to_uint8(Base.CacheFlags()))
    catch
        return nothing
    end
    # kept symmetric-by-construction: both sides run this same code in the
    # same resolved environment, so a degenerate value only costs fetch
    # precision, never a wrong hit (the loader revalidates prefs itself)
    prefs = try
        d = Base.get_preferences(pkg.uuid)
        isempty(d) ? "0" : bytes2hex(SHA.sha256(sprint(io -> TOML.print(io, d; sorted=true))))
    catch
        "0"
    end

    canon = join(["v1",
                  "julia=$(VERSION)+$(Base.GIT_VERSION_INFO.commit)",
                  "uuid=$(pkg.uuid)",
                  "version=$version",
                  "tree=$tree",
                  "flags=$flags",
                  "prefs=$prefs",
                  ("dep=$u:$(string(b, base=16))" for (u, b) in deps)...], "\n")
    return (; key=bytes2hex(SHA.sha256(canon)), canon, uuid=string(pkg.uuid))
end

## the hook

const HITS = Ref(0)    # observability for tests/logs

function fetch_hook(pkg::Base.PkgId, sourcepath::String)
    ctx = build_context(pkg)
    ctx === nothing && return false
    resp = http_request("GET", "/cache/v1/$NAMESPACE/$(ctx.uuid)/$(ctx.key)")
    if resp === nothing || resp[1] != 200
        # report the miss with its full context: the worker can turn this into
        # a learned edge today and a derivation request tomorrow
        http_request("POST", "/want/v1", Vector{UInt8}(codeunits(ctx.canon)); deadline=2.0)
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

install!() = (Base.CACHE_FETCH_HOOK[] = fetch_hook; nothing)

## publication support (seal jobs): report what this environment produced for
## one unit, keyed with the same build_context the fetch side uses. The worker
## decides what (if anything) to publish — and under which uuid namespace.

function emit_produced_keys(unit::String, out::String)
    id = Base.identify_package(unit)
    id === nothing && return
    ctx = build_context(id)
    ctx === nothing && return
    depot = DEPOT_PATH[1]
    paths = filter(p -> startswith(p, depot), Base.find_all_in_cache_path(id))
    isempty(paths) && return
    ji = last(sort(paths; by=mtime))
    so = try
        oc = Base.ocachefile_from_cachefile(ji)
        isfile(oc) ? oc : nothing
    catch
        nothing
    end
    compiled = joinpath(depot, "compiled")
    entry = Dict("uuid" => ctx.uuid, "key" => ctx.key, "preimage" => ctx.canon,
                 "ji" => relpath(ji, compiled),
                 "so" => so === nothing ? "" : relpath(so, compiled))
    open(out, "w") do io
        TOML.print(io, Dict(unit => entry))
    end
    return
end

end # module
